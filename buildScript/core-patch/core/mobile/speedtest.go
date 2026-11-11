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
	"fmt"
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

	// The provider ids the params and the snapshot carry, and the names the
	// fallback order walks.
	speedTestProviderApple      = "apple"
	speedTestProviderCloudflare = "cloudflare"
	speedTestProviderSpeedtest  = "speedtest"

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
	errSpeedTestUnavailable   = errors.New("speed test endpoint unavailable")
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

// SpeedTestParams is what the gobind start decodes.
type SpeedTestParams struct {
	Provider string `json:"provider"`
	Lang     string `json:"lang"`
	Outbound string `json:"outbound"`
	Duration int    `json:"duration"`
	Protocol string `json:"protocol"`
	Streams  int    `json:"streams"`
	// Directions. `null` (absent) means "both", which is what the speed screen
	// and the batch panel ask for; the node card's submenu narrows to one, as
	// Bettbox's TestDownload/TestUpload flags do.
	TestDownload  *bool  `json:"testDownload"`
	TestUpload    *bool  `json:"testUpload"`
	UseSystemDns  bool   `json:"useSystemDns"`
	ServerHost    string `json:"serverHost"`
	ServerName    string `json:"serverName"`
	ServerCc      string `json:"serverCc"`
	ServerSponsor string `json:"serverSponsor"`
}

// downloadEnabled / uploadEnabled fold the nullable pair. With neither flag
// given both directions run; giving only one narrows the test to it.
func (p SpeedTestParams) downloadEnabled() bool {
	if p.TestDownload != nil {
		return *p.TestDownload
	}
	return p.TestUpload == nil || !*p.TestUpload
}

func (p SpeedTestParams) uploadEnabled() bool {
	if p.TestUpload != nil {
		return *p.TestUpload
	}
	return p.TestDownload == nil || !*p.TestDownload
}

// SpeedTestState is the snapshot pushed to the UI.
type SpeedTestState struct {
	Provider string `json:"provider"`
	Protocol string `json:"protocol"`
	// Fallback reports that the requested transport was not the one used.
	Fallback bool `json:"fallback"`
	// ProviderFallback reports that discovery failed on the requested provider
	// and a sibling measured instead. It is a separate field because the two
	// fallbacks are decided in different phases, and sharing one flag let the
	// protocol write erase the provider one. Both are plain booleans on the
	// JSON envelope, which is a map the bridge marshals — no gobind type grows.
	ProviderFallback bool             `json:"providerFallback"`
	ExitIp           string           `json:"exitIp"`
	ExitInfo         json.RawMessage  `json:"exitInfo"`
	Streams          int              `json:"streams"`
	Duration         int              `json:"duration"`
	Phase            string           `json:"phase"`
	Progress         float64          `json:"progress"`
	Speed            float64          `json:"speed"`
	Outbound         string           `json:"outbound"`
	Server           *SpeedTestServer `json:"server"`
	Latency          float64          `json:"latency"`
	Jitter           float64          `json:"jitter"`
	Download         float64          `json:"download"`
	Upload           float64          `json:"upload"`
	DownloadLatency  float64          `json:"downloadLatency"`
	UploadLatency    float64          `json:"uploadLatency"`
	Rpm              int              `json:"rpm"`
	Bytes            int64            `json:"bytes"`
	Error            string           `json:"error"`
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

func newSpeedTester(instance *Instance, params SpeedTestParams) (*speedTester, error) {
	switch params.Provider {
	case speedTestProviderCloudflare, speedTestProviderSpeedtest:
	default:
		params.Provider = speedTestProviderApple
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
		resolved, err := resolveTestOutbound(instance, params.Outbound)
		if err != nil {
			return nil, err
		}
		t.outbound = resolved
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
	return t, nil
}

// resolveTestOutbound picks the outbound the test dials through: the one the
// caller named, else the box's default. `DIRECT` (and an empty tag on a box
// with no outbounds) answers nil, which means "dial the platform's own path".
//
// A tag that names nothing is an error, not a direct connection: silently
// measuring the host's own link while the UI still labels the run with the
// vanished node is worse than refusing.
func resolveTestOutbound(instance *Instance, tag string) (adapter.Outbound, error) {
	if instance == nil || instance.outbounds == nil {
		if tag != "" && !strings.EqualFold(tag, "DIRECT") {
			return nil, errSpeedTestProxyNotFound
		}
		return nil, nil
	}
	if tag == "" {
		return instance.outbounds.Default(), nil
	}
	if strings.EqualFold(tag, "DIRECT") {
		return nil, nil
	}
	outbound, ok := instance.outbounds.Outbound(tag)
	if !ok {
		return nil, errSpeedTestProxyNotFound
	}
	return outbound, nil
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
		DialContext:     t.dial,
		TLSClientConfig: t.tlsConfig(),
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
	// The exit lookup runs here, before the deferred release closes the probe
	// client it dials through. Asking afterwards silently fell back to the
	// host's connection.
	exit := t.ExitInfo(ctx)
	t.update(func(state *SpeedTestState) {
		state.Speed = 0
		state.Progress = 1
		state.Error = errorCode
		if exit != "" {
			state.ExitInfo = json.RawMessage(exit)
		}
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
	// An explicitly unavailable endpoint keeps that verdict even when it
	// arrived wrapped: the classifier's default branch means the same thing,
	// but naming it here keeps a wrapped HTTP/transport error from being read
	// as a timeout.
	if errors.Is(err, errSpeedTestUnavailable) {
		return speedTestErrorUnavailable
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
	samples, latencyErr := t.measureLatency(ctx, target, speedTestLatencyCount, func(done int) {
		t.update(func(state *SpeedTestState) {
			state.Progress = float64(done) / speedTestLatencyCount
		})
	})
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if len(samples) == 0 {
		// No latency sample at all. Hand the last attempt's error to the
		// classifier so it can tell a timeout from a dead endpoint; returning a
		// bare sentinel here made `timeout` unreachable on this path, so a slow
		// endpoint always read as "unavailable".
		if latencyErr != nil {
			return latencyErr
		}
		return errSpeedTestUnavailable
	}
	latency, jitter := latencyStats(samples)
	t.update(func(state *SpeedTestState) {
		state.Latency = latency
		state.Jitter = jitter
	})

	t.setPhase(speedTestPhaseDownload)
	var downloadLoaded, uploadLoaded []float64
	if t.params.downloadEnabled() {
		download, loaded, refused := t.measureLoad(ctx, target, t.downloadWorker(target.downloadURL), false)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if download <= 0 {
			// Nothing came back. The workers recorded why: a non-200 on the
			// download URL is a refusal (`blocked`), anything else is an
			// endpoint that could not deliver bytes (`unavailable`).
			if refused {
				return errSpeedTestBlocked
			}
			return errSpeedTestUnavailable
		}
		downloadLoaded = loaded
		t.update(func(state *SpeedTestState) {
			state.Download = download
			state.DownloadLatency = median(loaded)
		})
	}

	t.setPhase(speedTestPhaseUpload)
	if t.params.uploadEnabled() {
		upload, loaded, refused := t.measureLoad(ctx, target, t.uploadWorker(target.uploadURL), true)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		uploadLoaded = loaded
		// An upload that transferred nothing is a failed direction. It used to
		// be reported as a completed run with `upload = -1` — the card said
		// Complete for a test whose uploads had all been refused.
		if upload <= 0 && refused {
			return errSpeedTestBlocked
		}
		all := append(append([]float64{}, downloadLoaded...), uploadLoaded...)
		t.update(func(state *SpeedTestState) {
			state.Upload = upload
			if upload <= 0 {
				state.Upload = -1
			}
			state.UploadLatency = median(uploadLoaded)
			if value := median(all); value > 0 {
				state.Rpm = int(60000 / value)
			}
		})
	} else if value := median(downloadLoaded); value > 0 {
		// A download-only run still has loaded round trips worth reporting.
		t.update(func(state *SpeedTestState) {
			state.Rpm = int(60000 / value)
		})
	}
	return nil
}

// speedTestFallbacks lists the providers to try, in order, after the requested
// one failed to produce a target. A provider's discovery endpoint can be
// unreachable from one exit while the others answer (Apple's mensura CDN and
// speedtest.net's list sit behind different networks), and reporting the whole
// run as "unavailable" when a sibling provider would have measured fine is a
// dead end for the user. Bettbox picks its endpoint once; FlClash retries.
func speedTestFallbacks(requested string) []string {
	order := []string{speedTestProviderApple, speedTestProviderCloudflare, speedTestProviderSpeedtest}
	fallbacks := make([]string, 0, len(order))
	for _, provider := range order {
		if provider != requested {
			fallbacks = append(fallbacks, provider)
		}
	}
	return fallbacks
}

// prepareFor switches the tester onto another provider and runs its discovery.
// The clients stay as built: every provider is dialled through the same
// outbound, so only the target differs.
func (t *speedTester) prepareFor(ctx context.Context, provider string) (*speedTestTarget, error) {
	previous := t.prepare
	t.prepare = prepareForProvider(provider)
	target, err := t.prepare(ctx, t)
	if err != nil {
		t.prepare = previous
	}
	return target, err
}

func prepareForProvider(provider string) func(context.Context, *speedTester) (*speedTestTarget, error) {
	switch provider {
	case speedTestProviderCloudflare:
		return prepareCloudflareSpeedTest
	case speedTestProviderSpeedtest:
		return prepareSpeedtestNet
	default:
		return prepareAppleSpeedTest
	}
}

func (t *speedTester) resolveTarget(ctx context.Context) (*speedTestTarget, error) {
	target, err := t.prepare(ctx, t)
	if err != nil && ctx.Err() == nil && t.params.Provider != "" {
		// Discovery failed on the requested provider. Try the siblings before
		// giving up: the endpoint the user named is a preference, not a
		// requirement, and every provider measures the same hop.
		for _, provider := range speedTestFallbacks(t.params.Provider) {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			retry, retryErr := t.prepareFor(ctx, provider)
			if retryErr != nil {
				continue
			}
			target, err = retry, nil
			t.update(func(state *SpeedTestState) {
				state.Provider = provider
				state.ProviderFallback = true
			})
			break
		}
	}
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
	// The trace's own `ip` is the only thing the target needs from this call:
	// it is what the run measures through and what the card shows. Demanding
	// `cf-ray` as well rejected every path where something in front of
	// Cloudflare (a CDN mirror, a corporate gateway, this box's own HTTP
	// stack rewriting headers) stripped it, and the rejection surfaced as
	// "blocked" even though the endpoint had just answered 200 with a
	// perfectly good exit IP.
	if resp.StatusCode != http.StatusOK || trace["ip"] == "" {
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
	if resp.StatusCode != http.StatusOK || json.Unmarshal(body, &config) != nil {
		return nil, errSpeedTestBlocked
	}
	// The config only has to name the directions this run measures: a
	// download-only test needs a large-download URL, an upload-only one needs
	// the upload URL, and a both-directions test needs both. Demanding every
	// field regardless of the run is how a config that simply omitted one URL
	// turned into a "blocked" verdict for a test that would have worked. A
	// latency URL is always required, but either download URL can serve it.
	if config.Urls.Small == "" && config.Urls.Large == "" {
		return nil, errSpeedTestBlocked
	}
	if t.params.downloadEnabled() && config.Urls.Large == "" {
		return nil, errSpeedTestBlocked
	}
	if t.params.uploadEnabled() && config.Urls.Upload == "" {
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
		// The server list answered but no server's latency probe succeeded.
		// That is every candidate being unreachable from this exit, not the
		// list itself being blocked — the endpoint just proved reachable
		// enough to hand us the list.
		return nil, errSpeedTestUnavailable
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
		// An empty list is the provider having no candidate from this exit.
		// "Blocked" claims the endpoint refused us, but it answered 200 with
		// JSON — say unavailable so the card stops pointing at a firewall.
		return nil, errSpeedTestUnavailable
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

// measureLatency samples the endpoint's round trips. It returns the samples and
// the last error any attempt produced: with no samples the caller has to tell a
// dead endpoint from a slow one, and the old signature dropped exactly that
// information, so every failure read as `unavailable`.
func (t *speedTester) measureLatency(ctx context.Context, target *speedTestTarget, count int, progress func(int)) ([]float64, error) {
	samples := make([]float64, 0, count)
	var lastErr error
	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			break
		}
		rtt, resp, err := t.latencyOnce(ctx, t.latency, target.latencyURL)
		if err != nil {
			lastErr = err
		} else {
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
	return samples, lastErr
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

// speedWorkerErrors records what the load workers ran into. It exists because
// `startWorkers` used to count failures and drop the errors: a provider that
// answered 403 on /download therefore surfaced as "unavailable", and an
// upload-only run whose every attempt was refused finished as a successful test
// that transferred nothing. Keeping the first few errors is enough — the
// verdict only needs to know whether something refused us.
type speedWorkerErrors struct {
	mu   sync.Mutex
	errs []error
}

func (e *speedWorkerErrors) add(err error) {
	e.mu.Lock()
	if len(e.errs) < 8 {
		e.errs = append(e.errs, err)
	}
	e.mu.Unlock()
}

// blocked reports whether any worker saw an explicit refusal, which is a
// different verdict from "nothing came back".
func (e *speedWorkerErrors) blocked() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, err := range e.errs {
		if errors.Is(err, errSpeedTestBlocked) {
			return true
		}
	}
	return false
}

// measureLoad runs one direction: [streams] workers pull as much as they can
// for the configured duration while a second sampler times the endpoint under
// that load, and a third records the throughput curve. It returns the stable
// rate, the loaded round trips, and whether any worker refusal was recorded.
func (t *speedTester) measureLoad(ctx context.Context, target *speedTestTarget, worker func(context.Context, *http.Client, *atomic.Int64) error, upload bool) (float64, []float64, bool) {
	_, _, _ = t.latencyOnce(ctx, t.probe, target.latencyURL)
	duration := time.Duration(t.params.Duration) * time.Second
	loadCtx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()

	counter := &atomic.Int64{}
	var wg sync.WaitGroup
	errors := &speedWorkerErrors{}
	t.startWorkers(loadCtx, &wg, worker, counter, errors)
	loaded := t.sampleLoadedLatency(loadCtx, target)
	samples := t.sampleThroughput(loadCtx, counter, duration, upload)
	cancel()
	wg.Wait()
	return stableSpeed(samples), loaded, errors.blocked()
}

// startWorkers keeps [streams] goroutines pulling until the context ends. A
// worker that fails backs off; past three times the stream count the whole
// direction gives up rather than spinning on a dead endpoint. Errors are
// recorded so the caller can tell a refusal from an empty measurement.
func (t *speedTester) startWorkers(loadCtx context.Context, wg *sync.WaitGroup, worker func(context.Context, *http.Client, *atomic.Int64) error, counter *atomic.Int64, errors *speedWorkerErrors) {
	var failures atomic.Int32
	limit := int32(t.params.Streams * 3)
	for i := 0; i < t.params.Streams; i++ {
		client := t.load[i%len(t.load)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			for loadCtx.Err() == nil {
				err := worker(loadCtx, client, counter)
				if err == nil {
					continue
				}
				// A cancellation is how the load window ends, not a failure.
				if loadCtx.Err() != nil {
					continue
				}
				errors.add(err)
				if failures.Add(1) > limit {
					return
				}
				time.Sleep(200 * time.Millisecond)
			}
		}()
	}
}

// sampleLoadedLatency times the endpoint under load every 400 ms until the
// context ends. It joins only its own sampler: the load workers belong to the
// caller's group and end with the same context.
func (t *speedTester) sampleLoadedLatency(loadCtx context.Context, target *speedTestTarget) []float64 {
	var mu sync.Mutex
	loaded := make([]float64, 0, int(time.Duration(t.params.Duration)*time.Second/speedTestLoadedInterval)+4)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(speedTestLoadedInterval)
		defer ticker.Stop()
		for {
			select {
			case <-loadCtx.Done():
				return
			case <-ticker.C:
				rtt, _, err := t.latencyOnce(loadCtx, t.probe, target.latencyURL)
				if err != nil {
					continue
				}
				mu.Lock()
				loaded = append(loaded, rtt)
				mu.Unlock()
			}
		}
	}()
	<-done
	mu.Lock()
	defer mu.Unlock()
	return loaded
}

// sampleThroughput records the transferred bytes every 100 ms, pushing the
// windowed rate to the UI as it goes and growing the chart's own series.
func (t *speedTester) sampleThroughput(loadCtx context.Context, counter *atomic.Int64, duration time.Duration, upload bool) []speedSample {
	start := time.Now()
	samples := make([]speedSample, 0, int(duration/speedTestSampleInterval)+4)
	samples = append(samples, speedSample{at: 0, bytes: 0})
	ticker := time.NewTicker(speedTestSampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-loadCtx.Done():
			samples = append(samples, speedSample{at: time.Since(start), bytes: counter.Load()})
			return samples
		case <-ticker.C:
			samples = append(samples, speedSample{at: time.Since(start), bytes: counter.Load()})
			t.reportWindow(samples, duration, upload)
		}
	}
}

// reportWindow pushes the latest one-second window as the live speed and a
// point of the chart's series for this direction.
func (t *speedTester) reportWindow(samples []speedSample, duration time.Duration, upload bool) {
	speed := windowSpeed(samples, time.Second)
	progress := float64(samples[len(samples)-1].at) / float64(duration)
	t.update(func(state *SpeedTestState) {
		state.Speed = speed
		state.Progress = progress
		if upload {
			t.uploadCurve = append(t.uploadCurve, speed)
		} else {
			t.downloadCurve = append(t.downloadCurve, speed)
		}
	})
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
		// A panic mid-test must still release the single slot: every later
		// start would be refused with "already running" until the process
		// restarted, which is exactly the wedge this flag must never make.
		defer func() {
			if recovered := recover(); recovered != nil {
				failSpeedTest(fmt.Sprintf("speed test panicked: %v", recovered))
			}
		}()

		p := SpeedTestParams{}
		_ = json.Unmarshal([]byte(params), &p)
		ctx, finish := beginSpeedTest()
		defer finish()

		tester, err := newSpeedTester(instance, p)
		if err != nil {
			publishFailure(err)
			return
		}
		tester.run(ctx, func(state SpeedTestState) {
			bettboxSpeedTestMu.Lock()
			bettboxSpeedTestState = state
			bettboxSpeedTestMu.Unlock()
		})
		finishSpeedTest(tester.snapshot())
	}()
	return true
}

// finishSpeedTest publishes the run's own final snapshot and releases the
// single test slot.
func finishSpeedTest(state SpeedTestState) {
	bettboxSpeedTestMu.Lock()
	bettboxSpeedTestState = state
	releaseSpeedTestSlotLocked()
	bettboxSpeedTestMu.Unlock()
}

// failSpeedTest ends the run in place — the phase and verdict change, whatever
// the test already gathered stays on the curve — and releases the single slot.
// A panic must land here: dropping the whole state would erase the samples the
// run managed before it died.
func failSpeedTest(verdict string) {
	bettboxSpeedTestMu.Lock()
	bettboxSpeedTestState.Phase = speedTestPhaseDone
	bettboxSpeedTestState.Progress = 1
	bettboxSpeedTestState.Error = verdict
	releaseSpeedTestSlotLocked()
	bettboxSpeedTestMu.Unlock()
}

// releaseSpeedTestSlotLocked frees the single-test slot; the caller holds
// [bettboxSpeedTestMu].
func releaseSpeedTestSlotLocked() {
	bettboxSpeedTestRunning = false
	if bettboxSpeedTestDone != nil {
		close(bettboxSpeedTestDone)
		bettboxSpeedTestDone = nil
	}
}

// publishFailure ends the current run with [err] as its verdict, so a test
// that never started still reports why instead of hanging at "connecting".
func publishFailure(err error) {
	verdict := speedTestErrorUnavailable
	if errors.Is(err, errSpeedTestProxyNotFound) {
		verdict = err.Error()
	}
	failSpeedTest(verdict)
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
	speedTestLock.Lock()
	defer speedTestLock.Unlock()
	if speedTestCancel != nil {
		speedTestCancel()
		speedTestCancel = nil
	}
	return true
}

// BettboxSpeedTestServers lists speedtest.net servers with their latency,
// nearest first, as JSON.
func BettboxSpeedTestServers(instance *Instance, outbound string, search string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	tester, err := newSpeedTester(instance, SpeedTestParams{Provider: "speedtest", Outbound: outbound})
	if err != nil {
		return "[]"
	}
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

// BettboxSpeedTestOutbounds lists the running box's outbound tags, the picker
// the desktop fills from its proxy list.
func BettboxSpeedTestOutbounds(instance *Instance) string {
	data, _ := json.Marshal(speedTestOutbounds(instance))
	return string(data)
}
