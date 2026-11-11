package io.nekohasekai.sagernet.database

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The `route_profiles` / `route_rules` tables as JSON documents (ADR 0002, phase 3b).
 *
 * `RouteManager` keeps its public API and its model conversions (`RouteProfileEntity.of` /
 * `toModel`); only the row storage moves. Each row is written as a field map, so ids, JSON
 * blobs, booleans and nulls survive a round-trip without a hand-written mapper — the same
 * reasoning as [io.flrone.bridge.RoomToJsonMigration], which produced the initial files.
 *
 * Writes are atomic (temp file + rename). A read failure returns null, and the caller
 * ([RouteManager]) falls back to Room, so a corrupt or half-written document can never lose
 * a user's routes: the database is still there and still authoritative until the JSON side
 * has proven it can serve the same data.
 */
object RouteJsonStore {

    private const val PROFILES = "route_profiles"
    private const val RULES = "route_rules"

    /** Where the documents live; set once the host knows its database path. */
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
     * True when the document set has been established; the switch to JSON only happens then.
     *
     * Either file is enough: the one-time export always writes both, and a profile set with
     * no rules is a legitimate state (a fresh Default profile). Requiring both would leave
     * `save()` on Room after the first profile was written here, so the two stores would
     * diverge — the failure mode this switch exists to avoid.
     */
    val ready: Boolean
        get() {
            val dir = directory ?: return false
            return File(dir, "$PROFILES.json").isFile || File(dir, "$RULES.json").isFile
        }

    // --- read -----------------------------------------------------------------

    fun allProfiles(): List<RouteProfileEntity>? = readRows(PROFILES)?.mapNotNull { row ->
        rowToProfile(row)
    }

    fun allRules(): List<RouteRuleEntity>? = readRows(RULES)?.mapNotNull { row ->
        rowToRule(row)
    }

    /** One profile without its rules, matching `RouteDao.getProfile`. */
    fun getProfile(id: Long): RouteProfileEntity? = allProfiles()?.firstOrNull { it.id == id }

    fun rulesOf(profileId: Long): List<RouteRuleEntity> =
        allRules()?.filter { it.routeProfileId == profileId }?.sortedBy { it.ruleOrder }.orEmpty()

    fun count(): Long = allProfiles()?.size?.toLong() ?: 0L

    fun allIds(): List<Long> = allProfiles()?.map { it.id }?.sorted().orEmpty()

    fun isUsable(id: Long): Boolean =
        allProfiles()?.firstOrNull { it.id == id }?.let { !it.isRaw } ?: false

    // --- write ----------------------------------------------------------------

    /** Inserts [entity], assigning the next id when it carries none; returns the id. */
    fun insertProfile(entity: RouteProfileEntity): Long {
        val rows = allProfilesRaw().toMutableList()
        val id = if (entity.id > 0L) entity.id else (rows.maxOfOrNull { it.optLong("id") } ?: 0L) + 1L
        entity.id = id
        rows.removeAll { it.optLong("id") == id }
        rows.add(profileToRow(entity))
        writeRows(PROFILES, rows)
        return id
    }

    /** Returns 0 when no row with that id existed, like Room's update. */
    fun updateProfile(entity: RouteProfileEntity): Int {
        val rows = allProfilesRaw().toMutableList()
        val index = rows.indexOfFirst { it.optLong("id") == entity.id }
        if (index < 0) return 0
        rows[index] = profileToRow(entity)
        writeRows(PROFILES, rows)
        return 1
    }

    fun deleteProfile(id: Long) {
        val rows = allProfilesRaw().toMutableList()
        rows.removeAll { it.optLong("id") == id }
        writeRows(PROFILES, rows)
        deleteRules(id)
    }

    fun deleteRules(profileId: Long) {
        val rows = allRulesRaw().toMutableList()
        rows.removeAll { it.optLong("route_profile_id") == profileId }
        writeRows(RULES, rows)
    }

    fun insertRules(rules: List<RouteRuleEntity>) {
        if (rules.isEmpty()) return
        val rows = allRulesRaw().toMutableList()
        val ids = rules.map { it.routeProfileId }.toSet()
        rows.removeAll { it.optLong("route_profile_id") in ids }
        rows.addAll(rules.map { ruleToRow(it) })
        writeRows(RULES, rows)
    }

    fun rulesOfRow(profileId: Long): List<RouteRuleEntity> = rulesOf(profileId)

    // --- field maps -----------------------------------------------------------

    private fun profileToRow(e: RouteProfileEntity) = JSONObject().apply {
        put("id", e.id)
        put("name", e.name)
        put("default_outbound_id", e.defaultOutboundId)
        put("is_remote", if (e.isRemote) 1 else 0)
        put("remote_url", e.remoteUrl)
        put("auto_update", if (e.autoUpdate) 1 else 0)
        put("remote_last_update", e.remoteLastUpdate)
        put("is_raw", if (e.isRaw) 1 else 0)
        put("raw_route", e.rawRoute)
        put("prevent_modifications", if (e.preventModifications) 1 else 0)
        put("endpoint_profile_ids", e.endpointProfileIds)
        put("inner_hop_endpoint_ids", e.innerHopEndpointIds)
        put("dns_json", e.dnsJson)
        put("custom_dns", if (e.customDns) 1 else 0)
        put("source_gid", e.sourceGid)
        put("disabled_global_rule_json", e.disabledGlobalRuleJson)
    }

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

    private fun ruleToRow(e: RouteRuleEntity): JSONObject = JSONObject().apply {
        put("route_profile_id", e.routeProfileId)
        put("rule_order", e.ruleOrder)
        put("name", e.name)
        put("type", e.type)
        put("ip_version", e.ipVersion)
        put("network", e.network)
        put("protocol", e.protocol)
        put("inbound_json", e.inboundJson)
        put("domain_json", e.domainJson)
        put("domain_suffix_json", e.domainSuffixJson)
        put("domain_keyword_json", e.domainKeywordJson)
        put("domain_regex_json", e.domainRegexJson)
        put("source_ip_cidr_json", e.sourceIpCidrJson)
        put("source_ip_is_private", if (e.sourceIpIsPrivate) 1 else 0)
        put("ip_cidr_json", e.ipCidrJson)
        put("ip_is_private", if (e.ipIsPrivate) 1 else 0)
        put("source_port_json", e.sourcePortJson)
        put("source_port_range_json", e.sourcePortRangeJson)
        put("port_json", e.portJson)
        put("port_range_json", e.portRangeJson)
        put("process_name_json", e.processNameJson)
        put("process_path_json", e.processPathJson)
        put("process_path_regex_json", e.processPathRegexJson)
        put("package_name_json", e.packageNameJson)
        put("package_name_regex_json", e.packageNameRegexJson)
        put("network_type_json", e.networkTypeJson)
        put("wifi_ssid_json", e.wifiSsidJson)
        put("wifi_bssid_json", e.wifiBssidJson)
        put("rule_set_json", e.ruleSetJson)
        put("sniffers_json", e.sniffersJson)
        put("action", e.action)
        put("outbound_id", e.outboundId)
        put("reject_method", e.rejectMethod)
        put("override_address", e.overrideAddress)
        put("override_port", e.overridePort)
        put("tls_fragment", if (e.tlsFragment) 1 else 0)
        put("tls_fragment_fallback_delay", e.tlsFragmentFallbackDelay)
        put("tls_record_fragment", if (e.tlsRecordFragment) 1 else 0)
        put("tls_spoof", e.tlsSpoof)
        put("tls_spoof_method", e.tlsSpoofMethod)
        put("strategy", e.strategy)
        put("disabled", if (e.disabled) 1 else 0)
        put("invert", if (e.invert) 1 else 0)
        put("no_drop", if (e.noDrop) 1 else 0)
        put("sniff_override_dest", if (e.sniffOverrideDest) 1 else 0)
        put("network_is_expensive", if (e.networkIsExpensive) 1 else 0)
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

    // --- file IO --------------------------------------------------------------

    private fun profileToRows(list: List<RouteProfileEntity>): JSONArray =
        JSONArray().also { array -> list.forEach { array.put(profileToRow(it)) } }

    private fun allProfilesRaw(): List<JSONObject> = readRows(PROFILES).orEmpty()
    private fun allRulesRaw(): List<JSONObject> = readRows(RULES).orEmpty()

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

    private fun writeRows(name: String, rows: List<JSONObject>) {
        val dir = directory ?: return
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", name)
            put("rows", JSONArray().also { array -> rows.forEach { array.put(it) } })
        }.toString()
        try {
            if (!dir.isDirectory) dir.mkdirs()
            val target = File(dir, "$name.json")
            val temp = File(dir, "$name.json.${System.nanoTime()}.tmp")
            temp.writeText(payload)
            if (!temp.renameTo(target)) {
                target.writeText(payload)
                temp.delete()
            }
        } catch (e: Exception) {
            logger("could not write $name.json", e)
        }
    }
}
