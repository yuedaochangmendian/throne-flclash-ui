// The Bettbox speed test, ported onto sing-box's outbound dialers.
//
// The shape follows Bettbox's core/toolbox/speedtest.go: three providers
// (Apple's mensura CDN, Cloudflare's speed endpoints, speedtest.net), each
// measured over N parallel streams for a fixed duration, with h1/h2/h3
// transports, latency + jitter from 20 samples, download/upload loaded latency,
// RPM from the loaded round trips, and the exit IP read from the provider's own
// trace endpoint. What differs is the dialling: Bettbox sits on mihomo and dials
// through `constant.Proxy`; here the test dials through the running Instance's
// own outbound, so a test measures exactly the hop the user selected.
//
// Additive only: this file declares no type the gobind surface knows, so the
// generated Java API — and everything compiled against it — is unchanged. The
// C ABI in bridge_symbols.h is what Dart and the JNI shim call.
package mobile

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/quic-go"
	"github.com/sagernet/quic-go/http3"
	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	speedTestStreams        = 8
	speedTestMaxStreams     = 16
	speedTestLatencyCount   = 20
	speedTestRequestTimeout = 8 * time.Second
	speedTestSampleInterval = 100 * time.Millisecond
	speedTestLoadedInterval = 400 * time.Millisecond
	speedTestRampUp         = 0.3
	speedTestDownloadBytes  = 25_000_000
	speedTestUploadBytes    = 25_000_000
	speedTestPushInterval   = 200 * time.Millisecond

	appleSpeedTestConfigURL = "https://mensura.cdn-apple.com/api/v1/gm/config"
	cloudflareSpeedTestHost = "https://speed.cloudflare.com"

	speedTestPhaseConnecting = "connecting"
	speedTestPhaseLatency    = "latency"
	speedTestPhaseDownload   = "download"
	speedTestPhaseUpload     = "upload"
	speedTestPhaseDone       = "done"

	speedTestProtocolTCP  = "h1"
	speedTestProtocolH2   = "h2"
	speedTestProtocolQuic = "h3"

	speedTestErrorRejected    = "rejected"
	speedTestErrorBlocked     = "blocked"
	speedTestErrorUnavailable = "unavailable"
	speedTestErrorTimeout     = "timeout"
	speedTestErrorCancelled   = "cancelled"
)

var (
	speedTestExitIPURLs = []string{
		"https://cloudflare.com/cdn-cgi/trace",
		"https://api.ip.sb/cdn-cgi/trace",
	}

	speedTestExitInfoURL   = "http://ip-api.com/json/"
	speedtestNetServersURL = "https://www.speedtest.net/api/js/servers?engine=js&limit=10&https_functional=true"
	speedtestNetScheme     = "https"

	errSpeedTestBlocked       = errors.New("speed test blocked")
	errSpeedTestProxyNotFound = errors.New("speed test outbound not found")
)

var (
	speedBufferPool = sync.Pool{
		New: func() any {
			buf := make([]byte, 64*1024)
			return &buf
		},
	}
	speedUploadPayloadOnce sync.Once
	speedUploadPayload     []byte
)

func getSpeedUploadPayload() []byte {
	speedUploadPayloadOnce.Do(func() {
		speedUploadPayload = make([]byte, 64*1024)
		_, _ = rand.Read(speedUploadPayload)
	})
	return speedUploadPayload
}

// SpeedTestParams is what HandleStartSpeedTest decodes.
type SpeedTestParams struct {
	Provider     string  `json:"provider"`
	Lang         string  `json:"lang"`
	Outbound     string  `json:"outbound"`
	Duration     int     `json:"duration"`
	Protocol     string  `json:"protocol"`
	Streams      int     `json:"streams"`
	UseSystemDns bool    `json:"useSystemDns"`
	ServerHost   string  `json:"serverHost"`
	ServerName   string  `json:"serverName"`
	ServerCc     string  `json:"serverCc"`
	ServerSponsor string `json:"serverSponsor"`
}

// SpeedTestState is the snapshot pushed to the UI.
type SpeedTestState struct {
	Provider        string           `json:"provider"`
	Protocol        string           `json:"protocol"`
	Fallback        bool             `json:"fallback"`
	ExitIp          string           `json:"exitIp"`
	ExitInfo        json.RawMessage  `json:"exitInfo"`
	Streams         int              `json:"streams"`
	Duration        int              `json:"duration"`
	Phase           string           `json:"phase"`
	Progress        float64          `json:"progress"`
	Speed           float64          `json:"speed"`
	Outbound        string           `json:"outbound"`
	Server          *SpeedTestServer `json:"server"`
	Latency         float64          `json:"latency"`
	Jitter          float64          `json:"jitter"`
	Download        float64          `json:"download"`
	Upload          float64          `json:"upload"`
	DownloadLatency float64          `json:"downloadLatency"`
	UploadLatency   float64          `json:"uploadLatency"`
	Rpm             int              `json:"rpm"`
	Bytes           int64            `json:"bytes"`
	Error           string           `json:"error"`
	// The curves the UI draws: one entry per second, in byte/s, download
	// first then upload — Bettbox's chart keeps the same two series.
	DownloadCurve []float64 `json:"downloadCurve"`
	UploadCurve   []float64 `json:"uploadCurve"`
}

type SpeedTestServer struct {
	Ip      string `json:"ip"`
	Country string `json:"country"`
	City    string `json:"city"`
	Colo    string `json:"colo"`
	Host    string `json:"host"`
	Sponsor string `json:"sponsor"`
}

type speedTestTarget struct {
	latencyURL  string
	downloadURL string
	uploadURL   string
	server      *SpeedTestServer
}

type speedSample struct {
	at    time.Duration
	bytes int64
}

type speedTester struct {
	params   SpeedTestParams
	outbound adapter.Outbound
	ctx      context.Context
	client   *http.Client
	probe    *http.Client
	latency  *http.Client
	load     []*http.Client
	closers  []func()
	bytes    atomic.Int64
	mu       sync.RWMutex
	state    SpeedTestState
	prepare  func(ctx context.Context, t *speedTester) (*speedTestTarget, error)
	// The curves so far, appended once per 100 ms sample and read by the
	// snapshot under the same lock.
	downloadCurve []float64
	uploadCurve   []float64
}

var (
	speedTestLock   sync.Mutex
	speedTestCancel context.CancelFunc
	speedTestSerial uint64
)

func beginSpeedTest() (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	speedTestLock.Lock()
	if speedTestCancel != nil {
		speedTestCancel()
	}
	speedTestCancel = cancel
	speedTestSerial++
	serial := speedTestSerial
	speedTestLock.Unlock()
	return ctx, func() {
		speedTestLock.Lock()
		if speedTestSerial == serial {
			speedTestCancel = nil
		}
		speedTestLock.Unlock()
		cancel()
	}
}

// HandleStartSpeedTest runs one test to completion and answers the final state.
// `push` receives the 200 ms snapshots; a nil push only drops them.
func HandleStartSpeedTest(instance *Instance, paramsString string, push func(SpeedTestState)) string {
	params := SpeedTestParams{}
	_ = json.Unmarshal([]byte(paramsString), &params)
	ctx, finish := beginSpeedTest()
	defer finish()

	tester := newSpeedTester(instance, params)
	tester.run(ctx, push)
	data, _ := json.Marshal(tester.snapshot())
	return string(data)
}

// HandleCancelSpeedTest stops the running test, if any.
func HandleCancelSpeedTest() bool {
	speedTestLock.Lock()
	defer speedTestLock.Unlock()
	if speedTestCancel != nil {
		speedTestCancel()
		speedTestCancel = nil
	}
	return true
}

// HandleSpeedTestServers lists speedtest.net servers with their latency, nearest first.
func HandleSpeedTestServers(instance *Instance, outbound, search string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	tester := newSpeedTester(instance, SpeedTestParams{Provider: "speedtest", Outbound: outbound})
	defer tester.release()
	servers, err := tester.fetchSpeedtestNetServers(ctx, search)
	if err != nil {
		return "[]"
	}
	tester.measureSpeedtestNetServers(ctx, servers)
	sort.SliceStable(servers, func(a, b int) bool {
		switch {
		case servers[a].Latency == servers[b].Latency:
			return false
		case servers[a].Latency <= 0:
			return false
		case servers[b].Latency <= 0:
			return true
		case servers[a].Latency < servers[b].Latency:
			return true
		default:
			return false
		}
	})
	data, _ := json.Marshal(servers)
	return string(data)
}

func newSpeedTester(instance *Instance, params SpeedTestParams) *speedTester {
	switch params.Provider {
	case "cloudflare", "speedtest":
	default:
		params.Provider = "apple"
	}
	if params.Duration <= 0 {
		params.Duration = 10
	}
	if params.Duration > 30 {
		params.Duration = 30
	}
	if params.Streams <= 0 {
		params.Streams = speedTestStreams
	}
	if params.Streams > speedTestMaxStreams {
		params.Streams = speedTestMaxStreams
	}
	switch params.Protocol {
	case speedTestProtocolH2, speedTestProtocolQuic:
	default:
		params.Protocol = speedTestProtocolTCP
	}
	t := &speedTester{
		params: params,
		state: SpeedTestState{
			Provider: params.Provider,
			Protocol: speedTestProtocolTCP,
			Streams:  params.Streams,
			Duration: params.Duration,
			Phase:    speedTestPhaseConnecting,
		},
	}
	if instance != nil {
		t.ctx = instance.handle.Context()
		t.outbound = resolveTestOutbound(instance, params.Outbound)
		t.state.Outbound = outboundLabel(instance, params.Outbound)
	}
	switch params.Provider {
	case "cloudflare":
		t.prepare = prepareCloudflareSpeedTest
	case "speedtest":
		t.prepare = prepareSpeedtestNet
	default:
		t.prepare = prepareAppleSpeedTest
	}
	t.client = t.newClient()
	t.probe = t.newClient()
	t.latency = t.client
	t.load = []*http.Client{t.client}
	return t
}

// resolveTestOutbound picks the outbound the test dials through: the one the
// caller named, else the box's default. A nil answer means "dial directly".
func resolveTestOutbound(instance *Instance, tag string) adapter.Outbound {
	if instance == nil || instance.outbounds == nil {
		return nil
	}
	if tag != "" && !strings.EqualFold(tag, "DIRECT") {
		if outbound, ok := instance.outbounds.Outbound(tag); ok {
			return outbound
		}
		return nil
	}
	if tag == "" {
		return instance.outbounds.Default()
	}
	return nil
}

func outboundLabel(instance *Instance, tag string) string {
	if tag != "" {
		return tag
	}
	if instance != nil && instance.outbounds != nil {
		if def := instance.outbounds.Default(); def != nil {
			return def.Tag()
		}
	}
	return ""
}

// dial sends a TCP connection through the test outbound. `direct` keeps the
// platform dialer, which is what a `DIRECT` test must do.
func (t *speedTester) dial(ctx context.Context, network, address string) (net.Conn, error) {
	if t.outbound == nil {
		var dialer net.Dialer
		return dialer.DialContext(ctx, network, address)
	}
	return t.outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
}

func (t *speedTester) tlsConfig() *tls.Config {
	return &tls.Config{InsecureSkipVerify: false, MinVersion: tls.VersionTLS12}
}

func (t *speedTester) newClient() *http.Client {
	transport := &http.Transport{
		DialContext:         t.dial,
		TLSClientConfig:     t.tlsConfig(),
		// h1 only: TLSNextProto left empty keeps Go from upgrading to h2,
		// because the h2 case builds its own client.
		MaxIdleConnsPerHost: speedTestMaxStreams * 2,
		DisableCompression:  true,
		TLSHandshakeTimeout: speedTestRequestTimeout,
	}
	return &http.Client{Transport: transport}
}

func (t *speedTester) newH2Client() *http.Client {
	transport := &http.Transport{
		DialContext:         t.dial,
		TLSClientConfig:     t.tlsConfig(),
		ForceAttemptHTTP2:   true,
		DisableCompression:  true,
		TLSHandshakeTimeout: speedTestRequestTimeout,
	}
	t.closers = append(t.closers, transport.CloseIdleConnections)
	return &http.Client{Transport: transport}
}

func (t *speedTester) newQuicClient() *http.Client {
	transport := &http3.Transport{
		TLSClientConfig: t.tlsConfig(),
		QUICConfig:      &quic.Config{},
	}
	t.closers = append(t.closers, func() { _ = transport.Close() })
	return &http.Client{Transport: transport}
}

func (t *speedTester) setupH2(ctx context.Context, target *speedTestTarget) bool {
	latency := t.newH2Client()
	_, resp, err := t.latencyOnce(ctx, latency, target.latencyURL)
	if err != nil || resp.ProtoMajor != 2 {
		return false
	}
	load := make([]*http.Client, t.params.Streams)
	for i := range load {
		load[i] = t.newH2Client()
	}
	t.latency = latency
	t.probe = t.newH2Client()
	t.load = load
	return true
}

func (t *speedTester) setupQuic(ctx context.Context, target *speedTestTarget) bool {
	latency := t.newQuicClient()
	if _, resp, err := t.latencyOnce(ctx, latency, target.latencyURL); err != nil || resp.ProtoMajor < 3 {
		return false
	}
	load := make([]*http.Client, t.params.Streams)
	for i := range load {
		load[i] = t.newQuicClient()
	}
	t.latency = latency
	t.probe = t.newQuicClient()
	t.load = load
	return true
}

func (t *speedTester) update(fn func(state *SpeedTestState)) {
	t.mu.Lock()
	fn(&t.state)
	t.mu.Unlock()
}

func (t *speedTester) snapshot() SpeedTestState {
	t.mu.RLock()
	defer t.mu.RUnlock()
	state := t.state
	state.Bytes = t.bytes.Load()
	state.DownloadCurve = append([]float64(nil), t.downloadCurve...)
	state.UploadCurve = append([]float64(nil), t.uploadCurve...)
	return state
}

func (t *speedTester) setPhase(phase string) {
	t.update(func(state *SpeedTestState) {
		state.Phase = phase
		state.Progress = 0
		state.Speed = 0
	})
}

func (t *speedTester) release() {
	t.client.CloseIdleConnections()
	t.probe.CloseIdleConnections()
	for _, closer := range t.closers {
		closer()
	}
}

func (t *speedTester) run(ctx context.Context, push func(SpeedTestState)) {
	defer t.release()

	if push != nil {
		pushCtx, stopPush := context.WithCancel(ctx)
		pushDone := make(chan struct{})
		go func() {
			defer close(pushDone)
			ticker := time.NewTicker(speedTestPushInterval)
			defer ticker.Stop()
			for {
				select {
				case <-pushCtx.Done():
					return
				case <-ticker.C:
					push(t.snapshot())
				}
			}
		}()
		defer func() {
			stopPush()
			<-pushDone
		}()
	}

	errorCode := ""
	if err := t.execute(ctx); err != nil {
		errorCode = t.classify(ctx, err)
	}
	t.update(func(state *SpeedTestState) {
		state.Speed = 0
		state.Progress = 1
		state.Error = errorCode
		if errorCode == "" {
			state.Phase = speedTestPhaseDone
		}
	})
}

func (t *speedTester) classify(ctx context.Context, err error) string {
	if errors.Is(ctx.Err(), context.Canceled) {
		return speedTestErrorCancelled
	}
	if t.outbound != nil {
		switch t.outbound.Type() {
		case "block", "reject":
			return speedTestErrorRejected
		}
	}
	if errors.Is(err, errSpeedTestBlocked) {
		return speedTestErrorBlocked
	}
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return speedTestErrorTimeout
	}
	return speedTestErrorUnavailable
}

func (t *speedTester) fetch(ctx context.Context, client *http.Client, url string, limit int64) (*http.Response, []byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, speedTestRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return nil, nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	t.bytes.Add(int64(len(body)))
	return resp, body, err
}

func (t *speedTester) execute(ctx context.Context) error {
	target, err := t.resolveTarget(ctx)
	if err != nil {
		return err
	}

	if t.params.Protocol != speedTestProtocolTCP {
		protocol := speedTestProtocolTCP
		if t.params.Protocol == speedTestProtocolQuic && t.setupQuic(ctx, target) {
			protocol = speedTestProtocolQuic
		} else if ctx.Err() == nil && t.setupH2(ctx, target) {
			protocol = speedTestProtocolH2
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		t.update(func(state *SpeedTestState) {
			state.Protocol = protocol
			state.Fallback = protocol != t.params.Protocol
		})
	}

	t.setPhase(speedTestPhaseLatency)
	samples := t.measureLatency(ctx, target, speedTestLatencyCount, func(done int) {
		t.update(func(state *SpeedTestState) {
			state.Progress = float64(done) / speedTestLatencyCount
		})
	})
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if len(samples) == 0 {
		return errSpeedTestBlocked
	}
	latency, jitter := latencyStats(samples)
	t.update(func(state *SpeedTestState) {
		state.Latency = latency
		state.Jitter = jitter
	})

	t.setPhase(speedTestPhaseDownload)
	download, downloadLoaded := t.measureLoad(ctx, target, t.downloadWorker(target.downloadURL), false)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if download <= 0 {
		return errSpeedTestBlocked
	}
	t.update(func(state *SpeedTestState) {
		state.Download = download
		state.DownloadLatency = median(downloadLoaded)
	})

	t.setPhase(speedTestPhaseUpload)
	upload, uploadLoaded := t.measureLoad(ctx, target, t.uploadWorker(target.uploadURL), true)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	loaded := append(append([]float64{}, downloadLoaded...), uploadLoaded...)
	t.update(func(state *SpeedTestState) {
		state.Upload = upload
		if upload <= 0 {
			state.Upload = -1
		}
		state.UploadLatency = median(uploadLoaded)
		if value := median(loaded); value > 0 {
			state.Rpm = int(60000 / value)
		}
	})
	return nil
}

func (t *speedTester) resolveTarget(ctx context.Context) (*speedTestTarget, error) {
	target, err := t.prepare(ctx, t)
	t.update(func(state *SpeedTestState) {
		if target != nil {
			state.Server = target.server
		}
	})
	if ip := t.fetchExitIP(ctx, target); ip != "" {
		t.update(func(state *SpeedTestState) {
			state.ExitIp = ip
		})
	}
	return target, err
}

func (t *speedTester) fetchExitIP(ctx context.Context, target *speedTestTarget) string {
	if target != nil && target.server != nil && target.server.Ip != "" {
		return target.server.Ip
	}
	if ctx.Err() != nil {
		return ""
	}
	for _, url := range speedTestExitIPURLs {
		fetchCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		resp, body, err := t.fetch(fetchCtx, t.probe, url, 4096)
		cancel()
		if ctx.Err() != nil {
			return ""
		}
		if err != nil || resp.StatusCode != http.StatusOK {
			continue
		}
		if ip := parseCloudflareTrace(string(body))["ip"]; net.ParseIP(ip) != nil {
			return ip
		}
	}
	return ""
}

// ExitInfo reads ip-api.com's answer for the exit; "" when it cannot be read.
func (t *speedTester) ExitInfo(ctx context.Context) string {
	url := speedTestExitInfoURL
	if t.params.Lang != "" {
		url += "?lang=" + t.params.Lang
	}
	fetchCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	resp, body, err := t.fetch(fetchCtx, t.probe, url, 16*1024)
	if err != nil || resp.StatusCode != http.StatusOK {
		return ""
	}
	var info struct {
		Status string `json:"status"`
		Query  string `json:"query"`
	}
	if json.Unmarshal(body, &info) != nil || info.Status == "fail" || info.Query == "" {
		return ""
	}
	return string(body)
}

func prepareCloudflareSpeedTest(ctx context.Context, t *speedTester) (*speedTestTarget, error) {
	resp, body, err := t.fetch(ctx, t.client, cloudflareSpeedTestHost+"/cdn-cgi/trace", 4096)
	if err != nil {
		return nil, err
	}
	trace := parseCloudflareTrace(string(body))
	if resp.StatusCode != http.StatusOK || resp.Header.Get("cf-ray") == "" || trace["ip"] == "" {
		return nil, errSpeedTestBlocked
	}
	return &speedTestTarget{
		latencyURL:  cloudflareSpeedTestHost + "/__down?bytes=0",
		downloadURL: cloudflareSpeedTestHost + "/__down?bytes=" + strconv.Itoa(speedTestDownloadBytes),
		uploadURL:   cloudflareSpeedTestHost + "/__up",
		server: &SpeedTestServer{
			Ip:      trace["ip"],
			Country: strings.ToUpper(trace["loc"]),
			Colo:    strings.ToUpper(trace["colo"]),
			Host:    "speed.cloudflare.com",
		},
	}, nil
}

func parseCloudflareTrace(body string) map[string]string {
	result := make(map[string]string, 16)
	rem := body
	for len(rem) > 0 {
		var line string
		line, rem, _ = strings.Cut(rem, "\n")
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			result[key] = value
		}
	}
	return result
}

func prepareAppleSpeedTest(ctx context.Context, t *speedTester) (*speedTestTarget, error) {
	resp, body, err := t.fetch(ctx, t.client, appleSpeedTestConfigURL, 64*1024)
	if err != nil {
		return nil, err
	}
	var config struct {
		TestEndpoint string `json:"test_endpoint"`
		Urls         struct {
			Small  string `json:"small_https_download_url"`
			Large  string `json:"large_https_download_url"`
			Upload string `json:"https_upload_url"`
		} `json:"urls"`
	}
	if resp.StatusCode != http.StatusOK || json.Unmarshal(body, &config) != nil ||
		config.Urls.Large == "" || config.Urls.Upload == "" {
		return nil, errSpeedTestBlocked
	}
	latencyURL := config.Urls.Small
	if latencyURL == "" {
		latencyURL = config.Urls.Large
	}
	country, colo := parseAppleEndpoint(config.TestEndpoint)
	return &speedTestTarget{
		latencyURL:  latencyURL,
		downloadURL: config.Urls.Large,
		uploadURL:   config.Urls.Upload,
		server: &SpeedTestServer{
			Country: country,
			Colo:    colo,
			Host:    config.TestEndpoint,
		},
	}, nil
}

type speedtestNetServer struct {
	Host    string  `json:"host"`
	Name    string  `json:"name"`
	Cc      string  `json:"cc"`
	Sponsor string  `json:"sponsor"`
	Latency float64 `json:"latency"`
}

func prepareSpeedtestNet(ctx context.Context, t *speedTester) (*speedTestTarget, error) {
	if host := strings.TrimSpace(t.params.ServerHost); host != "" {
		target := speedtestNetTarget(speedtestNetServer{
			Host: host, Name: t.params.ServerName, Cc: t.params.ServerCc, Sponsor: t.params.ServerSponsor,
		})
		_, resp, err := t.latencyOnce(ctx, t.client, target.latencyURL)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != http.StatusOK {
			return nil, errSpeedTestBlocked
		}
		return target, nil
	}
	target, err := prepareSpeedtestNetOnce(ctx, t)
	if err == nil || ctx.Err() != nil {
		return target, err
	}
	return prepareSpeedtestNetOnce(ctx, t)
}

func prepareSpeedtestNetOnce(ctx context.Context, t *speedTester) (*speedTestTarget, error) {
	servers, err := t.fetchSpeedtestNetServers(ctx, "")
	if err != nil {
		return nil, err
	}
	server, ok := t.pickSpeedtestNetServer(ctx, servers)
	if !ok {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errSpeedTestBlocked
	}
	return speedtestNetTarget(server), nil
}

func speedtestNetTarget(server speedtestNetServer) *speedTestTarget {
	base := speedtestNetScheme + "://" + server.Host
	return &speedTestTarget{
		latencyURL:  base + "/latency.txt",
		downloadURL: base + "/download?size=" + strconv.Itoa(speedTestDownloadBytes),
		uploadURL:   base + "/upload",
		server: &SpeedTestServer{
			Country: strings.ToUpper(server.Cc),
			City:    server.Name,
			Host:    server.Host,
			Sponsor: server.Sponsor,
		},
	}
}

func (t *speedTester) fetchSpeedtestNetServers(ctx context.Context, search string) ([]speedtestNetServer, error) {
	listURL := speedtestNetServersURL
	if search = strings.TrimSpace(search); search != "" {
		listURL += "&search=" + url.QueryEscape(search)
	}
	resp, body, err := t.fetch(ctx, t.client, listURL, 256*1024)
	if err != nil {
		return nil, err
	}
	var servers []speedtestNetServer
	if resp.StatusCode != http.StatusOK || json.Unmarshal(body, &servers) != nil {
		return nil, errSpeedTestBlocked
	}
	kept := servers[:0]
	for _, server := range servers {
		if server.Host != "" {
			kept = append(kept, server)
		}
	}
	servers = kept
	if len(servers) == 0 && search == "" {
		return nil, errSpeedTestBlocked
	}
	return servers, nil
}

func (t *speedTester) measureSpeedtestNetServers(ctx context.Context, servers []speedtestNetServer) {
	var wg sync.WaitGroup
	for index := range servers {
		servers[index].Latency = 0
		wg.Add(1)
		go func(server *speedtestNetServer) {
			defer wg.Done()
			rtt, resp, err := t.latencyOnce(ctx, t.client, speedtestNetScheme+"://"+server.Host+"/latency.txt")
			if err == nil && resp.StatusCode == http.StatusOK {
				server.Latency = math.Max(rtt, 0.001)
			}
		}(&servers[index])
	}
	wg.Wait()
}

func (t *speedTester) pickSpeedtestNetServer(ctx context.Context, servers []speedtestNetServer) (speedtestNetServer, bool) {
	t.measureSpeedtestNetServers(ctx, servers)
	best := -1
	for index, server := range servers {
		if server.Latency > 0 && (best < 0 || server.Latency < servers[best].Latency) {
			best = index
		}
	}
	if best < 0 {
		return speedtestNetServer{}, false
	}
	return servers[best], true
}

func parseAppleEndpoint(host string) (string, string) {
	label, _, _ := strings.Cut(host, "-")
	if len(label) < 5 {
		return "", ""
	}
	for _, r := range label[:5] {
		if r < 'a' || r > 'z' {
			return "", ""
		}
	}
	return strings.ToUpper(label[:2]), strings.ToUpper(label[2:5])
}

func (t *speedTester) latencyOnce(ctx context.Context, client *http.Client, url string) (float64, *http.Response, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var wrote, first time.Time
	trace := &httptrace.ClientTrace{
		WroteRequest:         func(httptrace.WroteRequestInfo) { wrote = time.Now() },
		GotFirstResponseByte: func() { first = time.Now() },
	}
	req, err := http.NewRequestWithContext(httptrace.WithClientTrace(reqCtx, trace), http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, err
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	headers := time.Now()
	n, _ := io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	t.bytes.Add(n)
	if wrote.IsZero() {
		wrote = start
	}
	if first.IsZero() {
		first = headers
	}
	rtt := float64(first.Sub(wrote).Microseconds())/1000 - parseServerTiming(resp.Header.Get("server-timing"))
	if rtt <= 0 {
		rtt = float64(first.Sub(wrote).Microseconds()) / 1000
	}
	return rtt, resp, nil
}

func parseServerTiming(header string) float64 {
	rem := header
	for len(rem) > 0 {
		var part string
		part, rem, _ = strings.Cut(rem, ";")
		key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok && key == "dur" {
			if dur, err := strconv.ParseFloat(value, 64); err == nil {
				return dur
			}
		}
	}
	return 0
}

func (t *speedTester) measureLatency(ctx context.Context, target *speedTestTarget, count int, progress func(int)) []float64 {
	samples := make([]float64, 0, count)
	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			break
		}
		rtt, resp, err := t.latencyOnce(ctx, t.latency, target.latencyURL)
		if err == nil {
			samples = append(samples, rtt)
			if city := resp.Header.Get("cf-meta-city"); city != "" && target.server != nil && target.server.City == "" {
				server := *target.server
				server.City = city
				target.server = &server
				t.update(func(state *SpeedTestState) {
					state.Server = &server
				})
			}
		}
		progress(i + 1)
	}
	return samples
}

func (t *speedTester) downloadWorker(url string) func(context.Context, *http.Client, *atomic.Int64) error {
	return func(ctx context.Context, client *http.Client, counter *atomic.Int64) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return errSpeedTestBlocked
		}
		bufPtr := speedBufferPool.Get().(*[]byte)
		defer speedBufferPool.Put(bufPtr)
		c := &speedCounter{counter: counter, total: &t.bytes}
		_, err = io.CopyBuffer(c, resp.Body, *bufPtr)
		return err
	}
}

func (t *speedTester) uploadWorker(url string) func(context.Context, *http.Client, *atomic.Int64) error {
	payload := getSpeedUploadPayload()
	return func(ctx context.Context, client *http.Client, counter *atomic.Int64) error {
		body := &speedUploadReader{payload: payload, remaining: speedTestUploadBytes, counter: counter, total: &t.bytes}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, body)
		if err != nil {
			return err
		}
		req.ContentLength = speedTestUploadBytes
		req.Header.Set("Content-Type", "application/octet-stream")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= http.StatusBadRequest {
			return errSpeedTestBlocked
		}
		return nil
	}
}

func (t *speedTester) measureLoad(ctx context.Context, target *speedTestTarget, worker func(context.Context, *http.Client, *atomic.Int64) error, upload bool) (float64, []float64) {
	_, _, _ = t.latencyOnce(ctx, t.probe, target.latencyURL)
	duration := time.Duration(t.params.Duration) * time.Second
	loadCtx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	counter := &atomic.Int64{}
	var wg sync.WaitGroup
	var failures atomic.Int32
	for i := 0; i < t.params.Streams; i++ {
		client := t.load[i%len(t.load)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			for loadCtx.Err() == nil {
				if err := worker(loadCtx, client, counter); err != nil && loadCtx.Err() == nil {
					if failures.Add(1) > int32(t.params.Streams*3) {
						return
					}
					time.Sleep(200 * time.Millisecond)
				}
			}
		}()
	}

	var loadedMu sync.Mutex
	loaded := make([]float64, 0, int(duration/speedTestLoadedInterval)+4)
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(speedTestLoadedInterval)
		defer ticker.Stop()
		for {
			select {
			case <-loadCtx.Done():
				return
			case <-ticker.C:
				if rtt, _, err := t.latencyOnce(loadCtx, t.probe, target.latencyURL); err == nil {
					loadedMu.Lock()
					loaded = append(loaded, rtt)
					loadedMu.Unlock()
				}
			}
		}
	}()

	start := time.Now()
	samples := make([]speedSample, 0, int(duration/speedTestSampleInterval)+4)
	samples = append(samples, speedSample{at: 0, bytes: 0})
	ticker := time.NewTicker(speedTestSampleInterval)
sampling:
	for {
		select {
		case <-loadCtx.Done():
			break sampling
		case <-ticker.C:
			sample := speedSample{at: time.Since(start), bytes: counter.Load()}
			samples = append(samples, sample)
			speed := windowSpeed(samples, time.Second)
			progress := float64(sample.at) / float64(duration)
			t.update(func(state *SpeedTestState) {
				state.Speed = speed
				state.Progress = progress
				// One point per sample; the chart draws them as they land, the
				// way Bettbox's own series fills in during a run.
				if upload {
					t.uploadCurve = append(t.uploadCurve, speed)
				} else {
					t.downloadCurve = append(t.downloadCurve, speed)
				}
			})
		}
	}
	ticker.Stop()
	samples = append(samples, speedSample{at: time.Since(start), bytes: counter.Load()})
	cancel()
	wg.Wait()

	loadedMu.Lock()
	defer loadedMu.Unlock()
	return stableSpeed(samples), loaded
}

type speedCounter struct {
	counter *atomic.Int64
	total   *atomic.Int64
}

func (c *speedCounter) Write(p []byte) (int, error) {
	c.counter.Add(int64(len(p)))
	c.total.Add(int64(len(p)))
	return len(p), nil
}

type speedUploadReader struct {
	payload   []byte
	offset    int
	remaining int64
	counter   *atomic.Int64
	total     *atomic.Int64
}

func (r *speedUploadReader) Read(p []byte) (int, error) {
	if r.remaining <= 0 {
		return 0, io.EOF
	}
	toRead := len(p)
	if int64(toRead) > r.remaining {
		toRead = int(r.remaining)
	}
	n := 0
	for n < toRead {
		chunk := copy(p[n:toRead], r.payload[r.offset:])
		r.offset += chunk
		if r.offset >= len(r.payload) {
			r.offset = 0
		}
		n += chunk
	}
	r.remaining -= int64(n)
	r.counter.Add(int64(n))
	r.total.Add(int64(n))
	return n, nil
}

func (r *speedUploadReader) Close() error { return nil }

func windowSpeed(samples []speedSample, window time.Duration) float64 {
	if len(samples) < 2 {
		return 0
	}
	last := samples[len(samples)-1]
	first := samples[0]
	for i := len(samples) - 2; i >= 0; i-- {
		first = samples[i]
		if last.at-samples[i].at >= window {
			break
		}
	}
	elapsed := (last.at - first.at).Seconds()
	if elapsed <= 0 {
		return 0
	}
	return float64(last.bytes-first.bytes) * 8 / elapsed
}

func stableSpeed(samples []speedSample) float64 {
	if len(samples) < 2 {
		return 0
	}
	last := samples[len(samples)-1]
	cut := time.Duration(float64(last.at) * speedTestRampUp)
	first := samples[0]
	for _, sample := range samples {
		if sample.at >= cut {
			first = sample
			break
		}
	}
	elapsed := (last.at - first.at).Seconds()
	if elapsed <= 0 {
		return 0
	}
	return float64(last.bytes-first.bytes) * 8 / elapsed
}

func median(values []float64) float64 {
	n := len(values)
	if n == 0 {
		return 0
	}
	if n == 1 {
		return values[0]
	}
	if n == 2 {
		return (values[0] + values[1]) / 2
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	middle := n / 2
	if n%2 == 0 {
		return (sorted[middle-1] + sorted[middle]) / 2
	}
	return sorted[middle]
}

func latencyStats(samples []float64) (float64, float64) {
	if len(samples) < 2 {
		return median(samples), 0
	}
	var total float64
	for i := 1; i < len(samples); i++ {
		diff := samples[i] - samples[i-1]
		if diff < 0 {
			diff = -diff
		}
		total += diff
	}
	return median(samples), total / float64(len(samples)-1)
}

// speedTestOutbounds lists the running box's selectable outbound tags, the
// picker Bettbox fills from mihomo's proxy list.
func speedTestOutbounds(instance *Instance) []string {
	if instance == nil || instance.outbounds == nil {
		return nil
	}
	tags := make([]string, 0, 16)
	for _, outbound := range instance.outbounds.Outbounds() {
		tags = append(tags, outbound.Tag())
	}
	return tags
}

// --- the gobind surface ----------------------------------------------------
//
// gomobile binds these four, so Kotlin (and the channel behind it) reaches the
// test without any change to the generated C ABI. The call shapes follow the
// core's own StartSpeedTest/QuerySpeedTest pair: start returns at once, the UI
// polls the snapshot while `Running` is true, and the last snapshot after it
// flips carries the results.

var (
	bettboxSpeedTestMu      sync.Mutex
	bettboxSpeedTestState   SpeedTestState
	bettboxSpeedTestRunning bool
	bettboxSpeedTestDone    chan struct{}
	bettboxSpeedTestExit    string
)

// StartBettboxSpeedTest starts one test on the running instance and returns at
// once. `params` is the SpeedTestParams JSON; an empty string runs the Apple
// provider with the defaults. Answers false when a test is already running.
func StartBettboxSpeedTest(instance *Instance, params string) bool {
	bettboxSpeedTestMu.Lock()
	if bettboxSpeedTestRunning {
		bettboxSpeedTestMu.Unlock()
		return false
	}
	bettboxSpeedTestRunning = true
	bettboxSpeedTestDone = make(chan struct{})
	bettboxSpeedTestExit = ""
	bettboxSpeedTestState = SpeedTestState{Phase: speedTestPhaseConnecting}
	bettboxSpeedTestMu.Unlock()

	go func() {
		p := SpeedTestParams{}
		_ = json.Unmarshal([]byte(params), &p)
		ctx, finish := beginSpeedTest()
		defer finish()

		tester := newSpeedTester(instance, p)
		// The exit lookup rides on the probe client, which is only valid while
		// the tester is alive, so it happens inside run's own lifetime.
		tester.run(ctx, func(state SpeedTestState) {
			bettboxSpeedTestMu.Lock()
			bettboxSpeedTestState = state
			bettboxSpeedTestMu.Unlock()
		})
		final := tester.snapshot()
		exit := tester.ExitInfo(context.Background())

		bettboxSpeedTestMu.Lock()
		bettboxSpeedTestState = final
		if exit != "" {
			bettboxSpeedTestState.ExitInfo = json.RawMessage(exit)
		}
		bettboxSpeedTestRunning = false
		if bettboxSpeedTestDone != nil {
			close(bettboxSpeedTestDone)
			bettboxSpeedTestDone = nil
		}
		bettboxSpeedTestMu.Unlock()
	}()
	return true
}

// QueryBettboxSpeedTest returns the current snapshot as JSON, `{state, running}`.
func QueryBettboxSpeedTest() string {
	bettboxSpeedTestMu.Lock()
	running := bettboxSpeedTestRunning
	state := bettboxSpeedTestState
	bettboxSpeedTestMu.Unlock()
	state.Bytes = 0
	data, _ := json.Marshal(map[string]interface{}{"state": state, "running": running})
	return string(data)
}

// CancelBettboxSpeedTest stops the running test; the snapshot then reports the
// cancelled error, as a stopped desktop test does.
func CancelBettboxSpeedTest() bool {
	return HandleCancelSpeedTest()
}

// BettboxSpeedTestServers lists speedtest.net servers, nearest first, as JSON.
func BettboxSpeedTestServers(instance *Instance, outbound string, search string) string {
	return HandleSpeedTestServers(instance, outbound, search)
}

// BettboxSpeedTestOutbounds lists the running box's outbound tags, the picker
// the desktop fills from its proxy list.
func BettboxSpeedTestOutbounds(instance *Instance) string {
	data, _ := json.Marshal(speedTestOutbounds(instance))
	return string(data)
}
