package io.nekohasekai.sagernet.database

import org.json.JSONObject
import java.io.File

/**
 * A READ-ONLY view of the route documents the kernel owns (ADR 0002, phase 3c).
 *
 * Phase 3b had Kotlin writing these files. Once the Go dispatcher answers the routing
 * actions, two writers on one document set is a lost-update waiting to happen — whichever
 * side cached a set first wins. So the writer is Go only (`route_store.go`, `route_actions.go`
 * in the core patch) and this object is the reader: `RouteManager` still needs to answer
 * `ConfigGenerator` and the group route picker synchronously, and it cannot call into Go.
 *
 * There are deliberately NO write methods here. If a write is ever needed on this side it
 * goes through the action bus to the kernel, not through a second file writer.
 *
 * A missing or unparseable document answers null so every caller falls back to Room. That is
 * the property that makes the switch safe: it can skip itself, it cannot lose data.
 */
object RouteJsonStore {

    private const val PROFILES = "route_profiles"
    private const val RULES = "route_rules"

    /** Where the documents live; the host sets it once the kernel base path is known. */
    @Volatile
    var directory: File? = null

    /**
     * Diagnostics sink. Injected rather than calling android.util.Log directly: the JVM
     * unit tests exercise the corrupt-file path, and an unmocked Log.w would fail them for
     * a reason that has nothing to do with the behaviour under test.
     */
    @Volatile
    var logger: (String, Throwable?) -> Unit = { message, error ->
        if (error != null) {
            io.nekohasekai.sagernet.ktx.Logs.w(message, error)
        } else {
            io.nekohasekai.sagernet.ktx.Logs.w(message)
        }
    }

    /**
     * True when the kernel has written the document set. Either file is enough: the export
     * always writes both, and a profile set with no rules is a legitimate state (a fresh
     * Default profile).
     */
    val ready: Boolean
        get() {
            val dir = directory ?: return false
            return File(dir, "$PROFILES.json").isFile || File(dir, "$RULES.json").isFile
        }

    fun allProfiles(): List<RouteProfileEntity>? = readRows(PROFILES)?.mapNotNull(::rowToProfile)

    fun allRules(): List<RouteRuleEntity>? = readRows(RULES)?.mapNotNull(::rowToRule)

    /** One profile without its rules, matching `RouteDao.getProfile`. */
    fun getProfile(id: Long): RouteProfileEntity? = allProfiles()?.firstOrNull { it.id == id }

    fun rulesOf(profileId: Long): List<RouteRuleEntity> =
        allRules()?.filter { it.routeProfileId == profileId }?.sortedBy { it.ruleOrder }.orEmpty()

    fun count(): Long = allProfiles()?.size?.toLong() ?: 0L

    fun allIds(): List<Long> = allProfiles()?.map { it.id }?.sorted().orEmpty()

    fun isUsable(id: Long): Boolean = allProfiles()?.firstOrNull { it.id == id }?.let { !it.isRaw } ?: false

    // --- row -> entity ----------------------------------------------------------

    private fun rowToProfile(row: JSONObject) = RouteProfileEntity().apply {
        id = row.optLong("id")
        name = row.optString("name")
        defaultOutboundId = row.optLong("default_outbound_id", -1L)
        isRemote = row.optInt("is_remote") != 0
        remoteUrl = row.optString("remote_url")
        autoUpdate = row.optInt("auto_update") != 0
        remoteLastUpdate = row.optLong("remote_last_update")
        isRaw = row.optInt("is_raw") != 0
        rawRoute = row.optString("raw_route")
        preventModifications = row.optInt("prevent_modifications") != 0
        endpointProfileIds = row.optString("endpoint_profile_ids", "[]")
        innerHopEndpointIds = row.optString("inner_hop_endpoint_ids", "[]")
        dnsJson = row.optString("dns_json")
        customDns = row.optInt("custom_dns") != 0
        sourceGid = row.optLong("source_gid", -1L)
        disabledGlobalRuleJson = row.optString("disabled_global_rule_json", "[]")
    }

    private fun rowToRule(row: JSONObject) = RouteRuleEntity().apply {
        routeProfileId = row.optLong("route_profile_id")
        ruleOrder = row.optInt("rule_order")
        name = row.optString("name")
        type = row.optInt("type")
        ipVersion = row.optString("ip_version")
        network = row.optString("network")
        protocol = row.optString("protocol")
        inboundJson = row.optString("inbound_json", "[]")
        domainJson = row.optString("domain_json", "[]")
        domainSuffixJson = row.optString("domain_suffix_json", "[]")
        domainKeywordJson = row.optString("domain_keyword_json", "[]")
        domainRegexJson = row.optString("domain_regex_json", "[]")
        sourceIpCidrJson = row.optString("source_ip_cidr_json", "[]")
        sourceIpIsPrivate = row.optInt("source_ip_is_private") != 0
        ipCidrJson = row.optString("ip_cidr_json", "[]")
        ipIsPrivate = row.optInt("ip_is_private") != 0
        sourcePortJson = row.optString("source_port_json", "[]")
        sourcePortRangeJson = row.optString("source_port_range_json", "[]")
        portJson = row.optString("port_json", "[]")
        portRangeJson = row.optString("port_range_json", "[]")
        processNameJson = row.optString("process_name_json", "[]")
        processPathJson = row.optString("process_path_json", "[]")
        processPathRegexJson = row.optString("process_path_regex_json", "[]")
        packageNameJson = row.optString("package_name_json", "[]")
        packageNameRegexJson = row.optString("package_name_regex_json", "[]")
        networkTypeJson = row.optString("network_type_json", "[]")
        wifiSsidJson = row.optString("wifi_ssid_json", "[]")
        wifiBssidJson = row.optString("wifi_bssid_json", "[]")
        ruleSetJson = row.optString("rule_set_json", "[]")
        sniffersJson = row.optString("sniffers_json", "[]")
        action = row.optString("action")
        outboundId = row.optLong("outbound_id", -1L)
        rejectMethod = row.optString("reject_method")
        overrideAddress = row.optString("override_address")
        overridePort = row.optString("override_port")
        tlsFragment = row.optInt("tls_fragment") != 0
        tlsFragmentFallbackDelay = row.optString("tls_fragment_fallback_delay")
        tlsRecordFragment = row.optInt("tls_record_fragment") != 0
        tlsSpoof = row.optString("tls_spoof")
        tlsSpoofMethod = row.optString("tls_spoof_method")
        strategy = row.optString("strategy")
        disabled = row.optInt("disabled") != 0
        invert = row.optInt("invert") != 0
        noDrop = row.optInt("no_drop") != 0
        sniffOverrideDest = row.optInt("sniff_override_dest") != 0
        networkIsExpensive = row.optInt("network_is_expensive") != 0
    }

    /** Rows of one document, or null when it is absent/unreadable (caller falls back). */
    private fun readRows(name: String): List<JSONObject>? {
        val dir = directory ?: return null
        val file = File(dir, "$name.json")
        if (!file.isFile) return null
        return try {
            val root = JSONObject(file.readText())
            val rows = root.optJSONArray("rows") ?: return null
            buildList { for (i in 0 until rows.length()) rows.optJSONObject(i)?.let { add(it) } }
        } catch (e: Exception) {
            logger("unreadable $name.json; falling back to Room", e)
            null
        }
    }
}
