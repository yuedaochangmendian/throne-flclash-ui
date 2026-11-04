package io.nekohasekai.sagernet.bg

import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.net.IpPrefix
import android.net.ProxyInfo
import android.os.Build
import android.os.ParcelFileDescriptor
import io.nekohasekai.sagernet.*
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.ktx.*
import io.nekohasekai.sagernet.ui.VpnRequestActivity
import io.nekohasekai.sagernet.utils.PlatformNotifications
import io.throneproj.mobile.Mobile
import io.throneproj.mobile.RoutePrefix
import io.throneproj.mobile.RoutePrefixIterator
import io.throneproj.mobile.StringIterator
import io.throneproj.mobile.TunOptions
import java.net.InetAddress
import android.net.VpnService as BaseVpnService

class VpnService : BaseVpnService(),
    BaseService.Interface {

    companion object {

        const val PRIVATE_VLAN4_CLIENT = "172.19.0.1"
        const val PRIVATE_VLAN4_ROUTER = "172.19.0.2"
        const val FAKEDNS_VLAN4_CLIENT = "198.18.0.0"
        const val PRIVATE_VLAN6_CLIENT = "fdfe:dcba:9876::1"
        const val PRIVATE_VLAN6_ROUTER = "fdfe:dcba:9876::2"

    }

    @Volatile
    var conn: ParcelFileDescriptor? = null

    private var metered = false

    override var upstreamInterfaceName: String? = null

    override suspend fun startProcesses() {
        DataStore.vpnService = this
        super.startProcesses() // launch proxy instance
    }

    @Suppress("EXPERIMENTAL_API_USAGE")
    override suspend fun killProcesses(): Throwable? {
        val currentConnection = conn
        var cleanupError: Throwable? = null
        Logs.i(
            "VpnLifecycleTrace stage=tun-close begin " +
                "hasConnection=${currentConnection != null}"
        )
        try {
            currentConnection?.close()
            Logs.i("VpnLifecycleTrace stage=tun-close success")
        } catch (error: Throwable) {
            Logs.w(
                "VpnLifecycleTrace stage=tun-close failed " +
                    "type=${error.javaClass.name} message=${error.message}"
            )
            cleanupError = error
        } finally {
            conn = null
            // The kernel caches the fd it was given (throne_start_tun) and reuses it on
            // the next OpenTun. Without this the second start after a stop skipped
            // establishing the interface altogether — no tun0, no VPN network, while the
            // UI still reported Running — because it trusted the previous, already closed
            // descriptor. Dropping the cached fd (and the TunInterface global ref) makes
            // every start ask the platform for a fresh interface.
            runCatching { io.throne.bbox.core.Core.stopTun() }
                .onFailure { Logs.w("bridge: stopTun failed: ${it.message}") }
        }
        super.killProcesses()?.let { error ->
            if (cleanupError == null) {
                cleanupError = error
            } else if (cleanupError !== error) {
                cleanupError?.addSuppressed(error)
            }
        }
        Logs.i(
            "VpnLifecycleTrace stage=kill done hasCleanupError=${cleanupError != null}"
        )
        return cleanupError
    }

    override fun onBind(intent: Intent) = when (intent.action) {
        SERVICE_INTERFACE -> super<BaseVpnService>.onBind(intent)
        else -> super<BaseService.Interface>.onBind(intent)
    }

    override val data = BaseService.Data(this)
    override val tag = "SagerNetVpnService"
    override fun createNotification(profileName: String) =
        ServiceNotification(this, profileName, "service-vpn")

    private fun isAlwaysOnVpn(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && runCatching { isAlwaysOn }.getOrDefault(false)

    override fun onNoProfile() {
        if (isAlwaysOnVpn()) PlatformNotifications.alwaysOnNoProfile(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The system starts an always-on VPN whatever the service mode says; the rest of the app follows the mode.
        if (DataStore.serviceMode != Key.MODE_VPN && isAlwaysOnVpn()) DataStore.serviceMode = Key.MODE_VPN
        if (DataStore.serviceMode == Key.MODE_VPN) {
            if (prepare(this) != null) {
                startActivity(
                    Intent(
                        this, VpnRequestActivity::class.java
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } else return super<BaseService.Interface>.onStartCommand(intent, flags, startId)
        }
        stopRunner()
        return Service.START_NOT_STICKY
    }

    inner class NullConnectionException : NullPointerException(),
        BaseService.ExpectedException {
        override fun getLocalizedMessage() = getString(R.string.reboot_required)
    }

    // The generated tun inbound is the only source of truth for the interface layout.

    /** The Builder fields one tun layout needs, fed either by gobind TunOptions or the FFI JSON. */
    interface TunSpec {
        val mtu: Int
        val inet4Address: List<TunPrefix>
        val inet6Address: List<TunPrefix>
        val autoRoute: Boolean
        val dnsMode: String
        val dnsServerAddress: List<String>
        val inet4RouteAddress: List<TunPrefix>
        val inet6RouteAddress: List<TunPrefix>
        val inet4RouteExcludeAddress: List<TunPrefix>
        val inet6RouteExcludeAddress: List<TunPrefix>
        val inet4RouteRange: List<TunPrefix>
        val inet6RouteRange: List<TunPrefix>
        val includePackage: List<String>
        val excludePackage: List<String>
        val httpProxyEnabled: Boolean
        val httpProxyServer: String
        val httpProxyServerPort: Int
        val httpProxyBypassDomain: List<String>
    }

    class TunPrefix(val address: String, val prefix: Int)

    /** The fallback path: the gobind TunOptions the core hands its PlatformInterface. */
    private class GobindTunSpec(private val o: TunOptions) : TunSpec {
        override val mtu: Int get() = o.getMTU()
        override val inet4Address get() = o.getInet4Address().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet6Address get() = o.getInet6Address().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val autoRoute: Boolean get() = o.getAutoRoute()
        override val dnsMode: String get() = o.getDNSMode().value
        override val dnsServerAddress get() = o.getDNSServerAddress().toList()
        override val inet4RouteAddress get() = o.getInet4RouteAddress().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet6RouteAddress get() = o.getInet6RouteAddress().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet4RouteExcludeAddress get() = o.getInet4RouteExcludeAddress().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet6RouteExcludeAddress get() = o.getInet6RouteExcludeAddress().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet4RouteRange get() = o.getInet4RouteRange().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val inet6RouteRange get() = o.getInet6RouteRange().toList().map { TunPrefix(it.address(), it.prefix()) }
        override val includePackage get() = o.getIncludePackage().toList()
        override val excludePackage get() = o.getExcludePackage().toList()
        override val httpProxyEnabled: Boolean get() = o.isHTTPProxyEnabled()
        override val httpProxyServer: String get() = o.getHTTPProxyServer()
        override val httpProxyServerPort: Int get() = o.getHTTPProxyServerPort()
        override val httpProxyBypassDomain get() = o.getHTTPProxyBypassDomain().toList().filter { it.isNotBlank() }
    }

    /** The FFI path: the TunOptions handle crossed as JSON (Core.tunSpecJson). */
    private class JsonTunSpec(json: String) : TunSpec {
        private val o = org.json.JSONObject(json)
        private fun prefixes(key: String): List<TunPrefix> = runCatching {
            val arr = o.optJSONArray(key) ?: return@runCatching emptyList<TunPrefix>()
            (0 until arr.length()).map {
                val p = arr.getJSONObject(it)
                TunPrefix(p.optString("address"), p.optInt("prefix"))
            }
        }.getOrDefault(emptyList())

        private fun strings(key: String): List<String> = runCatching {
            val arr = o.optJSONArray(key) ?: return@runCatching emptyList<String>()
            (0 until arr.length()).map { arr.optString(it) }
        }.getOrDefault(emptyList())

        override val mtu: Int get() = o.optInt("mtu")
        override val inet4Address get() = prefixes("inet4Address")
        override val inet6Address get() = prefixes("inet6Address")
        override val autoRoute: Boolean get() = o.optBoolean("autoRoute")
        override val dnsMode: String get() = o.optString("dnsMode")
        override val dnsServerAddress get() = strings("dnsServerAddress")
        override val inet4RouteAddress get() = prefixes("inet4RouteAddress")
        override val inet6RouteAddress get() = prefixes("inet6RouteAddress")
        override val inet4RouteExcludeAddress get() = prefixes("inet4RouteExcludeAddress")
        override val inet6RouteExcludeAddress get() = prefixes("inet6RouteExcludeAddress")
        override val inet4RouteRange get() = prefixes("inet4RouteRange")
        override val inet6RouteRange get() = prefixes("inet6RouteRange")
        override val includePackage get() = strings("includePackage")
        override val excludePackage get() = strings("excludePackage")
        override val httpProxyEnabled: Boolean get() = o.optBoolean("httpProxyEnabled")
        override val httpProxyServer: String get() = o.optString("httpProxyServer")
        override val httpProxyServerPort: Int get() = o.optInt("httpProxyServerPort")
        override val httpProxyBypassDomain get() = strings("httpProxyBypassDomain").filter { it.isNotBlank() }
    }

    /** The gobind route (NativeInterface.openTun): the core asks for the tun mid-start. */
    fun openTun(options: TunOptions): Int = buildAndEstablish(GobindTunSpec(options))

    /**
     * The FFI route: the kernel asks for the tun through the C callback table. The fd
     * is fed back through Core.startTun with its TunInterface, so protect /
     * resolverProcess reach the kernel without any bridge.
     */
    fun openTunJson(specJson: String, tun: io.throne.bbox.core.TunInterface): Int {
        val fd = buildAndEstablish(JsonTunSpec(specJson))
        runCatching { io.throne.bbox.core.Core.startTun(fd, tun) }
            .onFailure { Logs.w("bridge: startTun failed: ${it.message}") }
        return fd
    }

    private fun buildAndEstablish(options: TunSpec): Int {
        if (prepare(this) != null) error("android: missing VPN permission")
        val builder = Builder()
            .setConfigureIntent(SagerNet.configureIntent(this))
            .setSession(getString(R.string.app_name))
            .setMtu(options.mtu)

        options.inet4Address.forEach { builder.addAddress(it.address, it.prefix) }
        options.inet6Address.forEach { builder.addAddress(it.address, it.prefix) }

        if (options.autoRoute) {
            if (options.dnsMode != Mobile.DNSModeDisabled) {
                options.dnsServerAddress.forEach { builder.addDnsServer(it) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // A family gets its default route only when the tun has an address of it: without any address or
                // route of a family (and no allowFamily call) Android blocks that family, so IPv6 fails fast
                // instead of vanishing into a tun that has no IPv6 address (the core does the same below API 33).
                if (options.inet4RouteAddress.isNotEmpty()) {
                    options.inet4RouteAddress.forEach { builder.addRoute(it.address, it.prefix) }
                } else if (options.inet4Address.isNotEmpty()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                if (options.inet6RouteAddress.isNotEmpty()) {
                    options.inet6RouteAddress.forEach { builder.addRoute(it.address, it.prefix) }
                } else if (options.inet6Address.isNotEmpty()) {
                    builder.addRoute("::", 0)
                }
                // Builder.check rejects a loopback prefix ("Bad address"), and loopback never enters the tun anyway.
                options.inet4RouteExcludeAddress.forEach {
                    val address = InetAddress.getByName(it.address)
                    if (!address.isLoopbackAddress) builder.excludeRoute(IpPrefix(address, it.prefix))
                }
                options.inet6RouteExcludeAddress.forEach {
                    val address = InetAddress.getByName(it.address)
                    if (!address.isLoopbackAddress) builder.excludeRoute(IpPrefix(address, it.prefix))
                }
            } else {
                // Builder.excludeRoute only exists from API 33; below that the core pre-splits
                // "everything minus the excludes" into plain ranges that replace the default routes.
                options.inet4RouteRange.forEach { builder.addRoute(it.address, it.prefix) }
                options.inet6RouteRange.forEach { builder.addRoute(it.address, it.prefix) }
            }
        }

        val includePackage = options.includePackage
        if (includePackage.isNotEmpty()) {
            val added = includePackage.count {
                try {
                    builder.addAllowedApplication(it)
                    true
                } catch (_: PackageManager.NameNotFoundException) {
                    false
                }
            }
            // None of the chosen apps is installed: an empty allow list would capture every app instead of none.
            if (added == 0) builder.addAllowedApplication(packageName)
        }
        options.excludePackage.forEach {
            try {
                builder.addDisallowedApplication(it)
            } catch (_: PackageManager.NameNotFoundException) {
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && options.httpProxyEnabled) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain,
                )
            )
        }

        // Apps may then bind sockets to the underlying network themselves; FCM does this for its push channel.
        if (DataStore.allowBypass) builder.allowBypass()
        updateUnderlyingNetwork(builder)
        metered = DataStore.meteredNetwork
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(metered)
        val connection = builder.establish() ?: throw NullConnectionException()
        // Close any previous fd before overwriting to avoid leaking the old descriptor.
        conn?.close()
        conn = connection
        return connection.fd
    }

    fun updateUnderlyingNetwork(builder: Builder? = null) {
        val networks = SagerNet.underlyingNetwork?.let { arrayOf(it) }
        if (builder != null) {
            if (networks != null) builder.setUnderlyingNetworks(networks)
        } else {
            // null once the network is lost: the VPN follows the system default instead of declaring a gone network.
            setUnderlyingNetworks(networks)
        }
    }

    override fun onRevoke() = stopRunner()

    override fun onDestroy() {
        // Belt and braces: a service torn down without killProcesses (system reclaim,
        // always-on VPN restart) must not leave the kernel holding a dead descriptor.
        runCatching { io.throne.bbox.core.Core.stopTun() }
        DataStore.vpnService = null
        super.onDestroy()
        data.binder.close()
    }
}

private inline fun RoutePrefixIterator.forEach(block: (RoutePrefix) -> Unit) {
    while (hasNext()) block(next())
}

private fun RoutePrefixIterator.toList(): List<RoutePrefix> {
    val values = ArrayList<RoutePrefix>()
    while (hasNext()) values.add(next())
    return values
}

private fun StringIterator.toList(): List<String> {
    val values = ArrayList<String>()
    while (hasNext()) values.add(next())
    return values
}
