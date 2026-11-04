// The platform-wide Android duties. Registered once through Core.setPlatform and
// reached by the kernel via throne_callbacks_t. Object-shaped answers cross as
// JSON so the callback table stays primitive/string-shaped.
package io.throne.bbox.core

interface CorePlatform {
    fun usePlatformAutoDetectInterfaceControl(): Boolean

    fun useProcFS(): Boolean

    /** JSON {userId,userName,processPath,packageNames[]} or "" on failure. */
    fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): String

    /** JSON string array. */
    fun packageNamesByUid(uid: Int): String

    /**
     * Start reporting default-interface changes; report them back through
     * Core.updateDefaultInterface / Core.updateNetworkPath with [listener].
     * Returns an error string or "".
     */
    fun startDefaultInterfaceMonitor(listener: Long): String

    fun closeDefaultInterfaceMonitor(listener: Long): String

    /** JSON array of {index,mtu,name,addresses[],flags,type,dnsServer[],gateway[],metered}. */
    fun getInterfaces(): String

    /** JSON {ssid,bssid} or "". */
    fun readWifiState(): String

    fun clearDnsCache()

    /** Error string or "". */
    fun sendNotification(notificationJson: String): String

    fun cancelNotification(identifier: String, typeId: Int): String

    fun localDnsRaw(): Boolean

    /** Error string or "". */
    fun localDnsLookup(ctx: Long, network: String, domain: String): String

    /** Error string or "". */
    fun localDnsExchange(ctx: Long, message: ByteArray): String
}
