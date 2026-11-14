package io.throne.bbox.corehost

import android.os.SystemClock
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.test.TestEngine
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SettingsMapper
import io.nekohasekai.sagernet.group.SubscriptionQueue
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.throne.bbox.bridge.BboxMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import moe.matsuri.nb4a.utils.CoreLog
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * The FlClash Core protocol (`core/protocol.go` wire names) implemented by
 * Throne's real profile repository, config generator and sing-box/Xray
 * runtime. No Dart BoxController and no parallel presentation-state store
 * participate: a FlClash profile id is the matching Throne group id, and
 * proxy names map to native [ProxyEntity] display names.
 *
 * Clash-only Core features (MITM, provider/rule-set tables, connection
 * tracker) answer with an explicit `unsupported_capability` error instead of
 * fabricated empty data, so the UI can never mistake "not supported" for
 * "supported and empty".
 */
object ThroneCore {
    /**
     * The Dart enum NAME of a selector group, not the Clash YAML token: `buildGroups`
     * filters raw group types against `GroupTypeExtension.valueList`.
     */
    private const val GROUP_TYPE_SELECTOR = "Selector"

    /** Bounds one event payload; a startup log flush may hold thousands of lines. */
    private const val MAX_EVENTS_PER_MESSAGE = 200

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private val eventCallbacks = ConcurrentHashMap.newKeySet<(ByteArray) -> Unit>()
    private val pendingCallbacks = ConcurrentHashMap<String, (ByteArray) -> Unit>()
    private val logOffset = java.util.concurrent.atomic.AtomicLong(-1)
    private var logsEnabled = false
    private var initialized = false

    /** The running log pump, so close() can cancel it instead of leaving it polling forever. */
    private var logJob: Job? = null

    /**
     * The previous `traffic.current` reading of one direction: the cumulative total then and
     * when it was taken, so the delta can be divided by the elapsed wall time.
     */
    private class TrafficSample(var total: Long = 0L, var at: Long = 0L)

    private val trafficSamples = ConcurrentHashMap<String, TrafficSample>()

    private val groupListener = object : GroupRepo.Listener {
        override suspend fun groupAdd(group: ProxyGroup) = announceGroups()
        override suspend fun groupUpdated(group: ProxyGroup) = announceGroups()
        override suspend fun groupRemoved(groupId: Long) = announceGroups()
        override suspend fun groupUpdated(groupId: Long) = announceGroups()
        override suspend fun groupsReordered() = announceGroups()
    }

    @Synchronized
    fun initialize() {
        if (initialized) return
        initialized = true
        GroupRepo.addListener(groupListener)
        logJob = scope.launch { pumpLogs() }
        announceGroups()
    }

    @Synchronized
    fun close() {
        // A later "init" must re-register the group listener and restart the pump, so every
        // resource this takes in initialize() is released here and `initialized` goes back to
        // false. Listener removal is idempotent (the repo removes the instance).
        if (initialized) {
            GroupRepo.removeListener(groupListener)
            initialized = false
        }
        logJob?.cancel()
        logJob = null
        logOffset.set(-1)
        trafficSamples.clear()
        eventCallbacks.clear()
        logsEnabled = false
        // Answer with the id each request carried, so a caller that inspects the echoed id still
        // sees its own request fail; drained first so the replies run outside the monitor.
        val abandoned = ArrayList(pendingCallbacks.entries)
        pendingCallbacks.clear()
        for ((id, callback) in abandoned) {
            runCatching { callback(response(id, null, "transport_disconnected", "Core host closed")) }
        }
    }

    fun setEventListener(callback: ((ByteArray) -> Unit)?) {
        eventCallbacks.clear()
        callback?.let(eventCallbacks::add)
    }

    fun invokeMethod(data: String, callback: (ByteArray) -> Unit) {
        val call = runCatching { JsonParser.parseString(data).asJsonObject }.getOrNull()
        if (call == null) {
            callback(response("", null, "invalid_request", "Invalid Core request"))
            return
        }
        // An id keys the pending callback: "" or a duplicate would overwrite a live request whose
        // answer would then never arrive (the caller only ever sees a timeout).
        val id = call["id"]?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
        if (id.isEmpty()) {
            callback(response("", null, "invalid_request", "Core request needs a non-empty id"))
            return
        }
        val method = call["method"]?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
        val arguments = call["arguments"] ?: JsonObject()
        // Never drop a callback: whichever request a duplicate id displaces is answered with a
        // core_error rather than left hanging until its timeout.
        val displaced = pendingCallbacks.put(id, callback)
        if (displaced != null) {
            displaced(response(id, null, "core_error", "Core request id \"$id\" was reused"))
        }
        scope.launch {
            try {
                answer(id, callback, dispatch(method, arguments))
            } catch (error: CapabilityException) {
                answer(id, callback, null, "unsupported_capability", error.message ?: error.capability)
            } catch (error: Throwable) {
                Logs.w(error)
                answer(id, callback, null, "core_error", error.message ?: error.javaClass.simpleName)
            }
        }
    }

    /**
     * Answers [callback] only if it is still the pending one: when a reused id displaced it,
     * this request's late result must not be delivered to the request that took its place.
     */
    private fun answer(
        id: String,
        callback: (ByteArray) -> Unit,
        result: Any?,
        code: String? = null,
        message: String? = null,
    ) {
        if (!pendingCallbacks.remove(id, callback)) return
        callback(response(id, result, code, message))
    }

    private fun response(id: String, result: Any?, code: String? = null, message: String? = null): ByteArray {
        val root = JSONObject().put("id", id)
        if (code == null) {
            root.put("result", result ?: JSONObject.NULL)
        } else {
            root.put("error", JSONObject().put("code", code).put("message", message ?: code))
        }
        return root.toString().toByteArray(StandardCharsets.UTF_8)
    }

    private fun event(type: String, data: Any?) {
        eventBatch(listOf(JSONObject().put("type", type).put("data", data ?: JSONObject.NULL)))
    }

    /**
     * One `message` call carrying [events]; `coreEventsFromData` accepts either a single
     * object or a list of `{type, data}`, so a burst (a startup log flush) crosses the
     * channel — and Flutter's main thread — as one message instead of one per line.
     * A list longer than [MAX_EVENTS_PER_MESSAGE] is split: a single unbounded payload
     * would be its own stall (and one huge JSON string to parse).
     */
    private fun eventBatch(events: List<JSONObject>) {
        if (events.isEmpty()) return
        for (chunk in events.chunked(MAX_EVENTS_PER_MESSAGE)) {
            val callbacks = eventCallbacks
            if (callbacks.isEmpty()) return
            val arguments = JSONArray()
            for (item in chunk) arguments.put(item)
            val payload = JSONObject()
                .put("method", "message")
                .put("arguments", arguments)
                .toString()
                .toByteArray(StandardCharsets.UTF_8)
            for (callback in callbacks) runCatching { callback(payload) }
        }
    }

    class CapabilityException(val capability: String) :
        Exception("$capability is a Clash-only feature Throne does not implement")

    private fun unsupported(method: String): Nothing = throw CapabilityException(method)

    // ---------------------------------------------------------------------------- dispatch

    private suspend fun dispatch(method: String, args: JsonElement): Any? = when (method) {
        "core.init" -> {
            initialize()
            null
        }

        "core.initialized" -> initialized
        "core.gc" -> {
            System.gc()
            null
        }

        "core.memory" -> memory()
        "config.setup" -> setup(args.asJsonObject)
        "config.update" -> update(args.asJsonObject)
        "config.validate" -> validate(args.asJsonObject)
        "config.read" -> read(args.asJsonObject)
        "profile.base" -> profileBase(args.asJsonObject)
        "profile.outbounds" -> profileOutbounds(args.asJsonObject)
        "profile.build" -> buildProfile(args.asJsonObject)
        "profile.clearEffect" -> null
        "throne.profile.list" -> profileList()
        "throne.profile.save" -> saveProfile(args.asJsonObject)
        "throne.profile.delete" -> deleteProfile(args.asJsonObject)
        "throne.profile.update" -> updateProfile(args.asJsonObject)
        "proxy.list" -> proxies()
        "proxy.select" -> select(args.asJsonObject)
        "proxy.definition" -> definition(args.asJsonObject)
        "proxy.testDelay" -> testDelay(args.asJsonObject)
        "proxy.validate" -> JSONArray()
        "proxy.convert" -> convert(args.asJsonObject)
        "shareLink.encode" -> encodeLinks(args.asJsonObject)
        "shareLink.decode" -> decodeLinks(args.asJsonObject)
        "filter.validate" -> JSONArray()
        "traffic.current" -> traffic(total = false)
        "traffic.total" -> traffic(total = true)
        "traffic.reset" -> null
        "network.changed" -> {
            DataStore.baseService?.data?.proxy?.boxOrNull?.resetNetwork()
            null
        }

        "log.start" -> {
            logsEnabled = true
            null
        }

        "log.stop" -> {
            logsEnabled = false
            null
        }

        "listener.start" -> {
            ThroneServiceController.requestStart()
            null
        }

        "listener.stop" -> {
            ThroneServiceController.requestStop()
            null
        }

        "probe.outboundIp" -> outboundIp()

        // Throne has no Clash provider / connection-tracker / geo-resource
        // entities. These are not failures: "no rows" is the truth, and the
        // UI polls them on every refresh. Returning unsupported_capability
        // here floods the banner and makes the pages look broken.
        // `getExternalProviders` decodes a List; `getConnectionCount` an int;
        // `getConnections` uses the `connections` key or an empty List.
        "provider.list" -> JSONArray()
        "provider.get" -> JSONObject.NULL
        "provider.update", "provider.sideLoad" -> null
        "connection.list" -> JSONObject().put("connections", JSONArray())
        "connection.count" -> 0
        "connection.close", "connection.closeAll", "connection.reset" -> null
        "geo.update" -> null
        "dns.clearCache" -> null
        // `route.watch(true/false)` is polled by route_state.dart; a stable
        // snapshot (no version changes) keeps the tracker quiet.
        "route.watch" -> JSONObject()
            .put("core-epoch", 0)
            .put("route-version", 0)

        // Features that genuinely cannot be mapped onto sing-box/Throne.
        "config.decrypt", "ruleSet.dump", "ruleSet.compile",
        "route.check", "probe.services", "mitm.certificate",
        "mitm.generateCertificate", "mitm.validate", "mitm.issueCertificate", "mitm.runScript",
        "mitm.exchanges", "mitm.exchange", "mitm.body" -> unsupported(method)

        else -> unsupported("Unknown method $method")
    }

    // ---------------------------------------------------------------------------- profiles

    private suspend fun profileList(): JSONArray = withContext(Dispatchers.IO) {
        JSONArray(GroupRepo.all().map { groupDoc(it) })
    }

    private suspend fun groupDoc(group: ProxyGroup): JSONObject {
        val info = group.subInfo
        return JSONObject()
            .put("id", group.id)
            .put("name", group.displayName())
            .put("url", group.url)
            .put("subscription", group.isSubscription)
            .put("autoUpdate", !group.skipAutoUpdate)
            .put("interval", group.subOptions.updateInterval)
            .put("lastUpdate", group.subLastUpdate * 1000)
            .put(
                "subscriptionInfo",
                JSONObject()
                    .put("upload", info.upload)
                    .put("download", info.download)
                    .put("total", info.total)
                    .put("expire", info.expire),
            )
    }

    private suspend fun saveProfile(args: JsonObject): JSONObject = lock.withLock {
        val id = args.long("id")
        val name = args.string("name").trim()
        val url = args.string("url").trim()
        val content = args.string("content")
        val existing = if (id > 0) GroupRepo.get(id) else null
        val group = existing ?: ProxyGroup().also {
            it.name = name
            it.url = url
            it.skipAutoUpdate = !args.bool("autoUpdate", true)
            it.subOptions.updateInterval = args.int("interval", 1440)
        }
        if (existing != null) {
            if (name.isNotBlank()) group.name = name
            if (url != group.url) group.url = url
            group.skipAutoUpdate = !args.bool("autoUpdate", true)
            group.subOptions.updateInterval = args.int("interval", 1440)
        }
        val saved = if (existing != null) {
            GroupRepo.save(group)
            group
        } else {
            GroupRepo.add(group)
        }
        if (content.isNotBlank()) {
            val parsed = ProfileImport.parse(
                content,
                SettingsMapper.xrayVlessPreference(),
                SettingsMapper.buildContext(),
            )
            if (parsed.outbounds.isEmpty()) {
                error(parsed.messages.joinToString("\n").ifBlank { "No supported proxy node found" })
            }
            ProfileManager.addProfileBatch(parsed.outbounds.distinctBy { it.dedup }, saved.id)
        }
        if (saved.isSubscription && saved.url.isNotBlank()) {
            runCatching { SubscriptionQueue.refreshGroup(saved.id, showDiff = false) }
        }
        groupDoc(saved)
    }

    private suspend fun deleteProfile(args: JsonObject) {
        val id = args.long("id")
        if (id > 0) GroupRepo.delete(id)
    }

    private suspend fun updateProfile(args: JsonObject) = lock.withLock {
        val id = args.long("id")
        val group = GroupRepo.get(id) ?: error("No such Throne group")
        args.stringOrNull("url")?.let { group.url = it.trim() }
        args.stringOrNull("name")?.takeIf { it.isNotBlank() }?.let { group.name = it }
        GroupRepo.save(group)
        if (group.isSubscription && group.url.isNotBlank()) {
            runCatching { SubscriptionQueue.refreshGroup(group.id, showDiff = true) }
        }
        groupDoc(group)
    }

    // ---------------------------------------------------------------------------- config

    private suspend fun setup(params: JsonObject): Any? = lock.withLock {
        initialize()
        params.getAsJsonObject("options")?.let { options ->
            options.stringOrNull("test-url")?.takeIf { it.isNotBlank() }?.let { DataStore.testUrl = it }
            options.takeIf { it.has("delay-test-timeout") }?.let { DataStore.urlTestTimeoutMs = it.get("delay-test-timeout").asInt }
        }
        params.getAsJsonObject("selected-map")?.entrySet()?.forEach { (groupName, proxyName) ->
            runCatching { selectByName(groupName, proxyName.asString, reload = false) }
        }
        params.getAsJsonObject("base")?.let { base ->
            runCatching { GroupRepo.setCurrent(groupIdOfPath(base.get("path").asString)) }
        }
        null
    }

    private suspend fun update(params: JsonObject): Any? = lock.withLock {
        params.stringOrNull("mode")?.let { mode ->
            if (mode != BboxMode.get().id) {
                BboxMode.set(BboxMode.Mode.of(mode))
            }
        }
        params.takeIf { it.has("mixed-port") }?.get("mixed-port")?.asInt?.takeIf { it > 0 }?.let {
            DataStore.inboundSocksPort = it
        }
        params.takeIf { it.has("allow-lan") }?.get("allow-lan")?.asBoolean?.let {
            DataStore.inboundAddress = if (it) "0.0.0.0" else "127.0.0.1"
        }
        params.stringOrNull("log-level")?.let { DataStore.logLevel = it }
        params.getAsJsonObject("tun")?.takeIf { it.has("enable") }?.let {
            DataStore.serviceMode = if (it.get("enable").asBoolean) "vpn" else "proxy"
        }
        if (DataStore.serviceState.canStop) SagerNet.reloadService()
        null
    }

    private suspend fun validate(args: JsonObject): Any? = withContext(Dispatchers.IO) {
        val text = File(args.string("path")).readText()
        val result = ProfileImport.parse(text, SettingsMapper.xrayVlessPreference(), SettingsMapper.buildContext())
        if (result.outbounds.isEmpty()) {
            result.messages.joinToString("\n").ifBlank { "No supported proxy node found" }
        } else {
            null
        }
    }

    private fun groupIdOfPath(path: String): Long =
        File(path).nameWithoutExtension.toLongOrNull() ?: error("Unknown Throne profile: $path")

    private suspend fun read(args: JsonObject): JSONObject {
        val id = groupIdOfPath(args.string("path"))
        val group = GroupRepo.get(id) ?: error("No such Throne group")
        val members = ProfileManager.members(id)
        val rules: JSONArray = JSONArray()
        return JSONObject()
            .put("name", group.displayName())
            .put("proxies", JSONArray(members.map { nodeDoc(it) }))
            .put(
                "proxy-groups",
                JSONArray().put(
                    JSONObject()
                        .put("name", "GLOBAL")
                        .put("type", "select")
                        .put("proxies", JSONArray(members.map { it.displayName() })),
                ),
            )
            .put("rules", rules)
            .put("rule", rules)
    }

    private suspend fun profileBase(args: JsonObject): JSONObject {
        val document = read(args)
        val nodes = document.getJSONArray("proxies")
        return JSONObject()
            .put("config", document)
            .put("digest", sha256(document.toString()))
            .put("match-rules", JSONArray())
            .put("proxies", nodes.length())
            .put("proxy-groups", 1)
            .put("rules", 0)
    }

    private suspend fun profileOutbounds(args: JsonObject): JSONObject {
        val document = read(args)
        return JSONObject()
            .put("proxies", document.get("proxies"))
            .put("proxy-groups", document.get("proxy-groups"))
    }

    private suspend fun buildProfile(args: JsonObject): String = lock.withLock {
        val base = args.getAsJsonObject("base") ?: error("profile.build needs a base")
        val id = groupIdOfPath(base.get("path").asString)
        val group = GroupRepo.get(id) ?: error("No such Throne group")
        GroupRepo.setCurrent(id)
        ProfileManager.memberIds(id).firstOrNull()?.let { DataStore.selectedProxy = it }
        JSONObject().put("name", group.displayName()).put("id", id).toString()
    }

    private fun nodeDoc(node: ProxyEntity): JSONObject = JSONObject()
        .put("name", node.displayName())
        .put("type", node.displayType())

    // ---------------------------------------------------------------------------- proxies

    /**
     * Every group becomes a selector; member names are made globally unique.
     *
     * The `type` is the Dart enum NAME (`Selector`), not the Clash YAML token (`select`):
     * `buildGroups` in `flutter/lib/common/task.dart` filters on
     * `GroupTypeExtension.valueList`, which holds `GroupType.values` names, so a `select`
     * group is dropped and the Proxies page stays empty. `Group.fromJson` then parses it
     * through `GroupType.parse`, which accepts `selector` case-insensitively.
     */
    private suspend fun proxies(): JSONObject = withContext(Dispatchers.IO) {
        val groups = GroupRepo.all()
        val proxiesJson = JSONObject()
        val allNames = JSONArray()
        val groupNames = mutableSetOf<String>()
        val usedNames = mutableSetOf<String>()
        val selected = DataStore.selectedProxy
        for (group in groups) {
            val groupName = uniqueName(group.displayName().ifBlank { "#" + group.id }, groupNames)
            val members = ProfileManager.members(group.id)
            val memberNames = JSONArray()
            for (member in members) {
                val name = uniqueName(member.displayName(), usedNames)
                memberNames.put(name)
                proxiesJson.put(name, JSONObject().put("name", name).put("type", member.displayType()))
            }
            val now = members.firstOrNull { it.id == selected }?.let { uniqueName(it.displayName(), usedNames) }
            proxiesJson.put(
                groupName,
                JSONObject()
                    .put("name", groupName)
                    .put("type", GROUP_TYPE_SELECTOR)
                    .put("now", now ?: JSONObject.NULL)
                    .put("all", memberNames),
            )
            allNames.put(groupName)
        }
        JSONObject().put("proxies", proxiesJson).put("all", allNames)
    }

    private fun uniqueName(base: String, used: MutableSet<String>): String {
        var name = base.ifBlank { "proxy" }
        var index = 2
        while (!used.add(name)) {
            name = "$base (${index++})"
        }
        return name
    }

    private suspend fun resolveMember(groupName: String, proxyName: String): Triple<ProxyGroup, ProxyEntity, String> =
        withContext(Dispatchers.IO) {
            val groupNames = mutableSetOf<String>()
            val usedNames = mutableSetOf<String>()
            for (group in GroupRepo.all()) {
                val uniqueGroupName = uniqueName(group.displayName().ifBlank { "#" + group.id }, groupNames)
                val members = ProfileManager.members(group.id)
                val nameToMember = LinkedHashMap<String, ProxyEntity>()
                for (member in members) {
                    nameToMember[uniqueName(member.displayName(), usedNames)] = member
                }
                if (uniqueGroupName == groupName) {
                    val member = nameToMember[proxyName] ?: error("No proxy named $proxyName in $groupName")
                    return@withContext Triple(group, member, proxyName)
                }
            }
            error("No proxy group named $groupName")
        }

    private suspend fun select(args: JsonObject): JSONObject = lock.withLock {
        val (group, member, _) = resolveMember(args.string("group-name"), args.string("proxy-name"))
        val previous = DataStore.selectedProxy
        GroupRepo.setCurrent(group.id)
        DataStore.selectedProxy = member.id
        DataStore.currentProfile = member.id
        DataStore.baseService?.switchProfile(member.id)
        if (previous != member.id && DataStore.serviceState.canStop) SagerNet.reloadService()
        JSONObject().put("changed", previous != member.id).put("message", "")
    }

    private suspend fun selectByName(groupName: String, proxyName: String, reload: Boolean) {
        val (group, member, _) = resolveMember(groupName, proxyName)
        GroupRepo.setCurrent(group.id)
        DataStore.selectedProxy = member.id
        DataStore.currentProfile = member.id
        DataStore.baseService?.switchProfile(member.id)
        if (reload && DataStore.serviceState.canStop) SagerNet.reloadService()
    }

    private suspend fun definition(args: JsonObject): JSONObject? = withContext(Dispatchers.IO) {
        val name = args.string("name")
        ProfileManager.members(GroupRepo.currentId()).firstOrNull { it.displayName() == name }?.let(::nodeDoc)
    }

    private suspend fun testDelay(args: JsonObject): JSONObject = withContext(Dispatchers.IO) {
        val name = args.string("proxy-name")
        val url = args.stringOrNull("test-url")?.takeIf { it.isNotBlank() } ?: DataStore.testUrl
        val timeout = args.takeIf { it.has("timeout") }?.get("timeout")?.asInt ?: DataStore.urlTestTimeoutMs
        val (_, member, _) = resolveMember(groupNameOfProxy(name), name)
        DataStore.testUrl = url
        DataStore.urlTestTimeoutMs = timeout
        TestEngine.queueUrlTests(listOf(member.id))
        val result = ProfileManager.getProfile(member.id) ?: member
        val value = result.latency.takeIf { it > 0 }
        val delay = JSONObject().put("name", name).put("url", url).put("value", value ?: JSONObject.NULL)
        event("delay", delay)
        delay
    }

    /** The group that owns a proxy name as FlClash displays it: the last proxies() mapping. */
    private suspend fun groupNameOfProxy(proxyName: String): String {
        val groupNames = mutableSetOf<String>()
        val usedNames = mutableSetOf<String>()
        for (group in GroupRepo.all()) {
            val uniqueGroupName = uniqueName(group.displayName().ifBlank { "#" + group.id }, groupNames)
            for (member in ProfileManager.members(group.id)) {
                if (uniqueName(member.displayName(), usedNames) == proxyName) return uniqueGroupName
            }
        }
        error("No proxy named $proxyName")
    }

    private suspend fun convert(args: JsonObject): JSONArray = withContext(Dispatchers.IO) {
        val parsed = ProfileImport.parse(
            File(args.string("path")).readText(),
            SettingsMapper.xrayVlessPreference(),
            SettingsMapper.buildContext(),
        )
        JSONArray(parsed.outbounds.map { proxyJson(it) })
    }

    private suspend fun decodeLinks(args: JsonObject): JSONArray = withContext(Dispatchers.IO) {
        val lines = args.getAsJsonArray("lines").map { it.asString }
        val perLine = JSONArray()
        for (line in lines) {
            val parsed = ProfileImport.parse(line, SettingsMapper.xrayVlessPreference(), SettingsMapper.buildContext())
            perLine.put(JSONArray(parsed.outbounds.map { proxyJson(it) }))
        }
        perLine
    }

    private fun proxyJson(outbound: Outbound): JSONObject = JSONObject()
        .put("name", outbound.displayName())
        .put("type", outbound.displayType())
        .put("throne-type", outbound.type)

    private suspend fun encodeLinks(args: JsonObject): JSONArray = withContext(Dispatchers.IO) {
        val encoded = JSONArray()
        val byName = ProfileManager.members(GroupRepo.currentId()).associateBy { it.displayName() }
        for (raw in args.getAsJsonArray("proxies")) {
            val obj = raw.asJsonObject
            val link = obj.stringOrNull("share-link")
                ?: byName[obj.stringOrNull("name").orEmpty()]?.exportLink()
                ?: ""
            if (link.isNotBlank()) encoded.put(link)
        }
        encoded
    }

    // ---------------------------------------------------------------------------- runtime

    /**
     * `traffic.current` answers a per-sample RATE (bytes per second): `Traffic` in
     * `flutter/lib/models/common.dart` is appended to one point of a speed series per tick and
     * rendered as `xx MB/s`, so cumulative bytes there would draw a permanently climbing line.
     *
     * The source is [io.throneproj.mobile.StatusMessage]'s cumulative up/download totals, not
     * `queryOutboundStats`: the latter hands out a delta and zeroes the tag's counters, so a
     * second reader would steal the bytes `TrafficLooper` counts into the profile totals (the
     * native looper polls the same tag every second). Cumulative totals are read without side
     * effects, and the rate is their difference over the elapsed wall time. `traffic.total`
     * stays cumulative, as the model's total figure expects.
     */
    private fun traffic(total: Boolean): JSONObject {
        if (total) {
            val up = ProfileManager.members(GroupRepo.currentId()).sumOf { it.tx }
            val down = ProfileManager.members(GroupRepo.currentId()).sumOf { it.rx }
            return JSONObject().put("up", up).put("down", down)
        }
        // A box whose handle is already released (a stop racing this poll) throws from the JNI
        // call instead of answering; a tick without data is a zero sample, not an error.
        val status = runCatching { DataStore.baseService?.data?.proxy?.boxOrNull?.status() }
            .getOrNull() ?: return JSONObject().put("up", 0).put("down", 0)
        val now = SystemClock.elapsedRealtime()
        return JSONObject()
            .put("up", rateOf("uplink", status.uplinkTotal, now))
            .put("down", rateOf("downlink", status.downlinkTotal, now))
    }

    /**
     * Bytes per second from the counter [cumulative] and the one this direction reported last
     * time. A counter that went backwards means the box restarted: that tick reports 0 instead
     * of a nonsense spike.
     */
    private fun rateOf(direction: String, cumulative: Long, now: Long): Long {
        val sample = trafficSamples.getOrPut(direction) { TrafficSample() }
        synchronized(sample) {
            val total = cumulative.coerceAtLeast(0)
            val elapsed = now - sample.at
            val delta = total - sample.total
            val rate = if (sample.at > 0L && elapsed > 0L && delta > 0L) delta * 1000 / elapsed else 0L
            sample.total = total
            sample.at = now
            return rate
        }
    }

    /**
     * What FlClash's memory panel shows. There is no separate Core process to measure — the Go
     * runtime shares this app process — so the numbers describe this process:
     * - `rss` is the resident size from `Debug.MemoryInfo.totalPss` (the figure the panel was
     *   really after; falls back to the heap in use when the kernel will not say).
     * - `heap-inuse` is the JVM heap in use and `heap-idle` the unused part of the *committed*
     *   heap (`totalMemory - inuse`), not `maxMemory - inuse`: `CoreMemoryStatsExt.runtimeTotal`
     *   sums inuse + idle, and with the committed heap that sum is the heap this process
     *   actually holds, so the panel's app + core adds up to `rss`. Reporting the headroom to
     *   `maxMemory` there made "core" equal the JVM's ceiling and drove "app" to zero.
     * - `stack-inuse`/`runtime-other` stay 0: there is no cheap, truthful source for them here,
     *   and a made-up number would be worse than a zero.
     */
    private fun memory(): JSONObject {
        val runtime = Runtime.getRuntime()
        val used = (runtime.totalMemory() - runtime.freeMemory()).coerceAtLeast(0)
        val committed = runtime.totalMemory().coerceAtLeast(used)
        val rss = runCatching {
            val info = android.os.Debug.MemoryInfo()
            android.os.Debug.getMemoryInfo(info)
            info.totalPss.toLong() * 1024
        }.getOrNull()?.takeIf { it > 0 } ?: used
        return JSONObject()
            .put("rss", rss)
            .put("heap-inuse", used)
            .put("heap-idle", (committed - used).coerceAtLeast(0))
            .put("stack-inuse", 0)
            .put("runtime-other", 0)
    }

    private fun outboundIp(): JSONObject {
        val node = DataStore.selectedProxy.let(ProfileManager::getProfile)
        val body = JSONObject()
            .put("ip", node?.ipOut ?: "")
            .put("country", node?.testCountry ?: "")
        return JSONObject()
            .put("url", "throne://egress")
            .put("body", body.toString())
            .put("delay", node?.latency?.coerceAtLeast(0) ?: 0)
            .put("chains", JSONArray().put(node?.displayName() ?: "direct"))
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    // ---------------------------------------------------------------------------- events

    private fun announceGroups() {
        event("loaded", GroupRepo.currentId().toString())
    }

    private suspend fun pumpLogs() {
        while (true) {
            delay(250)
            if (!logsEnabled) continue
            runCatching {
                val file = CoreLog.file
                if (!file.exists()) return@runCatching
                val text = file.readText(StandardCharsets.UTF_8)
                val offset = logOffset.updateAndGet { if (it < 0) text.length.toLong() else it }
                    .coerceAtMost(text.length.toLong()).toInt()
                if (offset >= text.length) return@runCatching
                val fresh = text.substring(offset)
                logOffset.set(text.length.toLong())
                val stamp = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.US)
                // One event per line used to mean one Main-thread post per line: a startup flush
                // of a few thousand lines starved the UI. Batched, the whole flush is one event.
                val batch = ArrayList<JSONObject>()
                for (line in fresh.lineSequence().filter { it.isNotBlank() }) {
                    val level = when {
                        line.contains("[error]", true) || line.contains("[fatal]", true) -> "error"
                        line.contains("[warn", true) -> "warning"
                        line.contains("[debug", true) || line.contains("[trace", true) -> "debug"
                        else -> "info"
                    }
                    batch.add(
                        JSONObject()
                            .put("type", "log")
                            .put(
                                "data",
                                JSONObject()
                                    .put("LogLevel", level)
                                    .put("Payload", line)
                                    .put("dateTime", stamp.format(Date())),
                            ),
                    )
                }
                eventBatch(batch)
            }.onFailure { Logs.w(it) }
        }
    }

    // ---------------------------------------------------------------------------- json helpers

    private fun JsonObject.string(key: String): String =
        get(key)?.takeIf { it.isJsonPrimitive }?.asString ?: ""

    private fun JsonObject.stringOrNull(key: String): String? =
        get(key)?.takeIf { it.isJsonPrimitive }?.asString

    private fun JsonObject.bool(key: String, fallback: Boolean): Boolean =
        get(key)?.takeIf { it.isJsonPrimitive }?.asBoolean ?: fallback

    private fun JsonObject.int(key: String, fallback: Int): Int =
        get(key)?.takeIf { it.isJsonPrimitive }?.asInt ?: fallback

    private fun JsonObject.long(key: String): Long =
        get(key)?.takeIf { it.isJsonPrimitive }?.asLong ?: 0L

    private val Outbound.dedup: String
        get() = exportToJson().toString()
}
