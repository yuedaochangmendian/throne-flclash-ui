package io.throne.bbox.bridge

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.SettingsRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * The outbound identity the status card shows.
 *
 * B-box asks libbox for the routed egress; Throne exposes the same thing as the local mixed inbound, so the probe
 * sends an HTTP request through `mixedPort` and reads what the far end sees. With the service stopped nothing answers
 * that port, so the same request goes out over the phone's own connection instead and reports the direct address.
 * Several public endpoints are asked at once because any of them can rate-limit a shared exit or be blocked.
 */
object BboxEgress {

    data class Info(
        val ip: String? = null,
        // country is the ISO code (US), countryName the human name (United States); the former is all the
        // card needs for its flag, the latter what a richer card shows beside the city and carrier.
        val country: String? = null,
        val countryName: String? = null,
        val region: String? = null,
        val city: String? = null,
        val isp: String? = null,
        val organization: String? = null,
        val asn: String? = null,
        val type: String? = null,
        // The endpoint that answered, so the details screen names the source it actually used
        // rather than the one that was preferred.
        val source: String? = null,
    ) {
        val isEmpty: Boolean get() = ip.isNullOrBlank()
    }

    // ipwho.is answers the richest set (country name, region, city, ISP, ASN) over HTTPS; the
    // rest are fallbacks for when it rate-limits, is slow or is unreachable. The order is the
    // preference order, not the order they are tried: every source is asked at once (Bettbox's
    // race), so a blocked source costs latency only until another one answers.
    private val endpoints = listOf(
        "https://ipwho.is/" to ::parseIpWhoIs,
        "https://uapis.cn/api/v1/network/myip" to ::parseUapis,
        "https://get.geojs.io/v1/ip/geo.json" to ::parseGeojs,
        "https://api.ip.sb/geoip" to ::parseIpSb,
        "https://ipinfo.io/json" to ::parseIpInfo,
    )

    /**
     * The whole probe must answer within this budget, however many sources are slow.
     */
    private const val PROBE_BUDGET_MS = 5_000L

    /**
     * How long the richest source may hold the answer before a fallback takes over. The fallbacks
     * are asked at the same time and usually answer in a few hundred milliseconds, so this is the
     * card's worst case when the preferred source is blocked — it used to be 3.5 s, which is what
     * "the IP takes a while to show up" meant on a network where ipwho.is does not answer.
     */
    private const val PRIMARY_BUDGET_MS = 1_200L

    @Volatile
    private var cached: Info = Info()

    @Volatile
    private var cachedAt = 0L

    // The tunnel answer and the phone's own answer are different addresses; sharing one slot would show the exit
    // of a connection that is no longer in use right after a start or stop.
    @Volatile
    private var cachedDirect: Info = Info()

    @Volatile
    private var cachedDirectAt = 0L

    /**
     * An exit address rarely changes within a session; a route change forces a fresh probe, so a
     * long TTL only spares the card a needless round trip when it is reopened.
     */
    private const val TTL_MS = 300_000L

    // One probe at a time. The card asks on every state change, and a state that
    // flickers faster than the answer used to start a new five-source race per
    // second — fifteen TLS connections and a fresh dispatcher each time, all of it
    // on a phone already busy with the tunnel. Callers queue here instead, and the
    // second one finds the cache the first just filled.
    private val gate = Mutex()

    // Clients are per route, not per probe: building one spawns a dispatcher and a
    // pool, and shutting it down immediately after throws both away.
    @Volatile
    private var tunnelClient: OkHttpClient? = null

    @Volatile
    private var tunnelClientPort = -1

    @Volatile
    private var directClient: OkHttpClient? = null

    fun cached(direct: Boolean = false): Info = if (direct) cachedDirect else cached

    /**
     * Probes the egress, through the mixed inbound unless [direct]. Returns the cached answer while it is fresh unless
     * [force]; a failure keeps the previous answer and reports the error through [onError].
     *
     * Every source is asked in parallel and the preferred one is waited for first, so the card answers as soon as the
     * rich source replies and still gets an answer when that source is blocked — the old sequential loop spent up to
     * 12 s per endpoint before giving up.
     */
    suspend fun probe(force: Boolean = false, direct: Boolean = false, onError: (String) -> Unit = {}): Info =
        gate.withLock { probeLocked(force, direct, onError) }

    private suspend fun probeLocked(force: Boolean, direct: Boolean, onError: (String) -> Unit): Info {
        val now = System.currentTimeMillis()
        val fresh = if (direct) {
            now - cachedDirectAt < TTL_MS && !cachedDirect.isEmpty
        } else {
            now - cachedAt < TTL_MS && !cached.isEmpty
        }
        if (!force && fresh) return cached(direct)
        val http = clientFor(direct) ?: return cached(direct)
        val failure = AtomicReference<String?>(null)
        val answer = race(http, failure)
        if (answer != null && !answer.isEmpty) {
            if (direct) {
                cachedDirect = answer
                cachedDirectAt = System.currentTimeMillis()
            } else {
                cached = answer
                cachedAt = System.currentTimeMillis()
            }
            return answer
        }
        onError(failure.get() ?: "Unreachable")
        return cached(direct)
    }

    /**
     * Asks every source at once. The preferred source gets [PRIMARY_BUDGET_MS] on its own; if it has not answered by
     * then, the first fallback that did wins. Nothing may outlive [PROBE_BUDGET_MS].
     */
    private suspend fun race(http: OkHttpClient, failure: AtomicReference<String?>): Info? = coroutineScope {
        val calls = CopyOnWriteArrayList<Call>()
        try {
            val (primaryUrl, primaryParse) = endpoints.first()
            val primary = async { fetch(http, primaryUrl, primaryParse, calls, failure) }
            val fallbacks = Channel<Info>(Channel.UNLIMITED)
            val rest: List<Job> = endpoints.drop(1).map { (url, parse) ->
                launch { fetch(http, url, parse, calls, failure)?.let { fallbacks.send(it) } }
            }
            val preferred = withTimeoutOrNull(PRIMARY_BUDGET_MS) { primary.await() }
            if (preferred != null) return@coroutineScope preferred
            val remaining = PROBE_BUDGET_MS - PRIMARY_BUDGET_MS
            val fallback = withTimeoutOrNull(remaining) { fallbacks.receive() }
            rest.forEach { it.cancel() }
            fallback
        } finally {
            // Whatever is still in flight is no longer wanted: cancelling the calls unblocks the
            // threads that a cancelled coroutine cannot interrupt on its own.
            calls.forEach { runCatching { it.cancel() } }
        }
    }

    /** One source's request. Records why it failed so a total failure can say what went wrong. */
    private suspend fun fetch(
        http: OkHttpClient,
        url: String,
        parse: (JSONObject) -> Info,
        calls: MutableList<Call>,
        failure: AtomicReference<String?>,
    ): Info? = withContext(Dispatchers.IO) {
        try {
            val call = http.newCall(Request.Builder().url(url).header("Accept", "application/json").build())
            calls += call
            call.execute().use { response ->
                if (!response.isSuccessful) {
                    failure.set("HTTP ${response.code}")
                    return@use null
                }
                val info = parse(JSONObject(response.body?.string().orEmpty()))
                if (info.isEmpty) failure.set("Empty answer")
                info.takeUnless { it.isEmpty }?.copy(source = url)
            }
        } catch (e: Exception) {
            failure.set(e.message ?: e.javaClass.simpleName)
            null
        }
    }

    /** The client for one route; null when the tunnel is asked for but no inbound is configured yet. */
    private fun clientFor(direct: Boolean): OkHttpClient? {
        if (direct) {
            return directClient ?: newClient(null).also { directClient = it }
        }
        val port = DataStore.inboundSocksPort
        if (port <= 0) return null
        val cached = tunnelClient
        if (cached != null && tunnelClientPort == port) return cached
        val client = newClient(port)
        tunnelClient = client
        tunnelClientPort = port
        return client
    }

    private fun newClient(port: Int?): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(6, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .callTimeout(12, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
        if (port == null) return builder.build()
        val host = DataStore.inboundAddress.ifBlank { SettingsRegistry.LOOPBACK_ADDRESS }
        return builder.proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))).build()
    }

    fun invalidate() {
        cached = Info()
        cachedAt = 0L
        cachedDirect = Info()
        cachedDirectAt = 0L
        // The route changed, so the pooled sockets of the previous route are worthless.
        runCatching { tunnelClient?.connectionPool?.evictAll() }
        runCatching { directClient?.connectionPool?.evictAll() }
    }

    private fun parseIpSb(json: JSONObject): Info = Info(
        ip = json.optString("ip").takeIf { it.isNotBlank() },
        country = json.optString("country").takeIf { it.isNotBlank() },
        organization = json.optString("organization").takeIf { it.isNotBlank() },
        asn = json.optString("asn").takeIf { it.isNotBlank() },
        type = json.optString("type").takeIf { it.isNotBlank() } ?: "IPv4",
    )

    /**
     * uapis.cn answers a flat object with the region as one string ("中国 广东 广州"), the operator and the
     * AS number. It carries no ISO country code, so the card shows the country name instead of a flag.
     */
    private fun parseUapis(json: JSONObject): Info {
        val region = json.optString("region").split(' ', '　').filter { it.isNotBlank() }
        return Info(
            ip = json.optString("ip").takeIf { it.isNotBlank() },
            countryName = region.getOrNull(0),
            region = region.getOrNull(1),
            city = region.getOrNull(2),
            isp = json.optString("isp").takeIf { it.isNotBlank() },
            organization = json.optString("llc").takeIf { it.isNotBlank() },
            asn = json.optString("asn").takeIf { it.isNotBlank() },
        )
    }

    /** geojs.io keys the AS number as a bare integer and repeats the operator in two fields. */
    private fun parseGeojs(json: JSONObject): Info {
        val asn = json.optString("asn").takeIf { it.isNotBlank() }?.let { if (it.startsWith("AS")) it else "AS$it" }
        val organization = json.optString("organization_name").ifBlank { json.optString("organization") }
        return Info(
            ip = json.optString("ip").takeIf { it.isNotBlank() },
            country = json.optString("country_code").takeIf { it.isNotBlank() },
            countryName = json.optString("country").takeIf { it.isNotBlank() },
            region = json.optString("region").takeIf { it.isNotBlank() },
            city = json.optString("city").takeIf { it.isNotBlank() },
            organization = organization.takeIf { it.isNotBlank() },
            asn = asn,
        )
    }

    private fun parseIpInfo(json: JSONObject): Info {
        val org = json.optString("org").takeIf { it.isNotBlank() }
        val asn = org?.substringBefore(' ')?.takeIf { it.startsWith("AS") }
        return Info(
            ip = json.optString("ip").takeIf { it.isNotBlank() },
            country = json.optString("country").takeIf { it.isNotBlank() },
            organization = org?.substringAfter(' ', org),
            asn = asn,
            type = if (json.optString("ip").contains(':')) "IPv6" else "IPv4",
        )
    }

    private fun parseIpWhoIs(json: JSONObject): Info {
        val connection = json.optJSONObject("connection")
        val asn = connection?.optInt("asn", -1)?.takeIf { it > 0 }?.let { "AS$it" }
        return Info(
            ip = json.optString("ip").takeIf { it.isNotBlank() },
            country = json.optString("country_code").takeIf { it.isNotBlank() },
            countryName = json.optString("country").takeIf { it.isNotBlank() },
            region = json.optString("region").takeIf { it.isNotBlank() },
            city = json.optString("city").takeIf { it.isNotBlank() },
            isp = connection?.optString("isp")?.takeIf { it.isNotBlank() },
            organization = connection?.optString("org")?.takeIf { it.isNotBlank() },
            asn = asn,
            type = json.optString("type").takeIf { it.isNotBlank() },
        )
    }
}
