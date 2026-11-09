package io.flrone.bridge

import android.content.Intent
import android.net.Uri
import io.nekohasekai.sagernet.Action
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.bg.test.TestSpec
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProfileOrder
import io.nekohasekai.sagernet.group.SubscriptionQueue
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ui.test.TestSessionClient
import io.flrone.model.BboxActions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The write half of the bridge: every gesture the ported UI can make, expressed in Throne's terms.
 *
 * The UI never touches `SagerNet`, the database or broadcasts itself; it calls these methods, which run the blocking
 * parts on IO and hand the resulting change back through [BboxBridge]'s state flow.
 */
object BboxCommands : BboxActions {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The session watcher that turns a test's results into catalog refreshes; one at a time. */
    private var testWatcher: Job? = null

    /** A URL test's timeout plus its bind, stop and catalog-refresh allowance. */
    private const val TEST_NODE_TIMEOUT_MS = 45_000L

    /**
     * A test writes its results from the service process ([TestSessionClient]), whose profile updates the catalog's
     * in-process listeners never hear — the cards would keep their old latency until the next cold start. The session
     * reports back here, because this is the process that started it, so each landed result re-reads the catalog.
     */
    private fun watchTestSession() {
        if (testWatcher?.isActive == true) return
        testWatcher = scope.launch {
            var seen = -1
            TestSessionClient.state.collect { state ->
                if (state.done != seen) {
                    seen = state.done
                    if (seen > 0) BboxBridge.scheduleRefresh()
                }
                // Cancel when the session is no longer running and we have seen at least
                // one state emission (seen >= 0 covers sessions that end with 0 results).
                if (!state.running && seen >= 0) {
                    BboxBridge.scheduleRefresh(immediate = true)
                    testWatcher?.cancel()
                    testWatcher = null
                }
            }
        }
    }

    override fun toggleService() {
        val state = DataStore.serviceState
        when {
            state.canStop -> SagerNet.stopService()
            DataStore.selectedProxy <= 0L -> Logs.w("bbox: start asked with no profile selected")
            else -> SagerNet.startService()
        }
    }

    override fun setMode(mode: String) {
        BboxMode.set(BboxMode.Mode.of(mode))
        if (DataStore.serviceState.canStop) SagerNet.reloadService()
        BboxBridge.scheduleRefresh(immediate = true)
    }

    override fun selectProxy(group: String, tag: String) {
        scope.launch { selectProxyAwait(group, tag) }
    }

    /** Awaitable variant: completes after the selection is persisted. */
    suspend fun selectProxyAwait(group: String, tag: String) {
        val profile = withContext(Dispatchers.IO) {
            val target = GroupRepo.all().firstOrNull { it.displayName() == group } ?: return@withContext null
            ProfileManager.members(target.id).firstOrNull { it.displayName() == tag }
        } ?: return
        selectSuspend(profile.id)
    }

    /** Makes [profileId] the selection; a running service switches to it instead of restarting from scratch. */
    fun select(profileId: Long) {
        val previous = applySelection(profileId) ?: return
        scope.launch { postSelectionUpdate(profileId, previous) }
    }

    /**
     * Writes the selection and asks a running service to switch to it. Returns the profile that
     * was selected before, or null when [profileId] is not a usable selection, so the caller can
     * post the row updates for both sides of the change.
     */
    private fun applySelection(profileId: Long): Long? {
        if (profileId <= 0L) return null
        val previous = DataStore.selectedProxy
        DataStore.selectedProxy = profileId
        DataStore.currentProfile = profileId
        if (DataStore.serviceState.canStop && previous != profileId) {
            app.sendBroadcast(
                Intent(Action.SWITCH_PROFILE)
                    .setPackage(app.packageName)
                    .putExtra(Action.EXTRA_PROFILE_ID, profileId)
            )
        }
        return previous
    }

    /** Refreshes both affected profile rows and the catalog; IO-bound, so it hops off the caller. */
    private suspend fun postSelectionUpdate(profileId: Long, previous: Long) {
        withContext(Dispatchers.IO) {
            runCatching {
                ProfileManager.getProfile(previous)?.let { ProfileManager.postUpdate(it.id, true) }
                ProfileManager.postUpdate(profileId, true)
            }
        }
        BboxBridge.scheduleRefresh(immediate = true)
    }

    /**
     * The proxy page's card and group actions need the call to live for as long
     * as the spinner should. Resolve the target, start one session, and answer
     * once that session has finished.
     */
    suspend fun testNodeAwait(tag: String): Boolean {
        val target = withContext(Dispatchers.IO) {
            val groups = GroupRepo.all()
            val group = groups.firstOrNull { it.displayName() == tag }
            if (group != null) {
                val ids = ProfileManager.memberIds(group.id)
                return@withContext if (ids.isEmpty()) null else {
                    TestSpec(
                        kind = TestSpec.KIND_URL,
                        profileIds = ids.toLongArray(),
                        scopeLabel = group.displayName(),
                    ) to group.id
                }
            }
            val owner = groups.firstOrNull { candidate ->
                ProfileManager.members(candidate.id).any { it.displayName() == tag }
            } ?: return@withContext null
            val profile = ProfileManager.members(owner.id).firstOrNull { it.displayName() == tag }
                ?: return@withContext null
            TestSpec(
                kind = TestSpec.KIND_URL,
                profileIds = longArrayOf(profile.id),
                scopeLabel = profile.displayName(),
            ) to profile.groupId
        } ?: return false
        val before = TestSessionClient.state.value
        if (!TestSessionClient.start(target.first, target.second)) return false
        watchTestSession()
        val finished = withTimeoutOrNull(TEST_NODE_TIMEOUT_MS) {
            TestSessionClient.state.first { state ->
                !state.running && (state.startedAt > before.startedAt || state.session != before.session)
            }
        }
        if (finished != null) return true
        TestSessionClient.stop()
        delay(500)
        BboxBridge.scheduleRefresh(immediate = true)
        return false
    }

    override fun refreshEgress() {
        BboxBridge.requestEgress(force = true)
    }

    override fun selectProfile(id: Long) {
        scope.launch { selectProfileAwait(id) }
    }

    /** Awaitable variant: completes after the selection is persisted, so the caller can
     *  safely rebuild the core config without racing the DB write. */
    suspend fun selectProfileAwait(id: Long) {
        val member = withContext(Dispatchers.IO) {
            val group = GroupRepo.get(id) ?: return@withContext null
            GroupRepo.setCurrent(group.id)
            // The selection moves even while the service runs (switchProfile hot-switches it):
            // the profile card, the proxies screen and the running config all follow the same
            // selected member. A group that already holds it keeps it; another gets its first.
            val ids = ProfileManager.memberIds(group.id)
            ids.firstOrNull { it == DataStore.selectedProxy } ?: ids.firstOrNull()
        }
        member?.let { selectSuspend(it) }
        BboxBridge.scheduleRefresh(immediate = true)
    }

    /** Awaitable variant of [select]: returns after the selection is written and the
     *  profile-update notifications are dispatched. */
    suspend fun selectSuspend(profileId: Long) {
        val previous = applySelection(profileId) ?: return
        postSelectionUpdate(profileId, previous)
    }

    override fun updateSubscription(id: Long) {
        if (id <= 0L) return
        runCatching { SubscriptionQueue.refreshGroup(id, showDiff = true) }
            .onFailure { Logs.w(it) }
    }

    /**
     * Previous / next server, the television's way of changing profiles (TvControls.switchServer):
     * a running service hot-switches through the same broadcast its notification buttons send, a
     * stopped one just moves the selection inside the current group.
     */
    override fun switchServer(step: Int) {
        if (step == 0) return
        if (DataStore.serviceState.canStop) {
            app.sendBroadcast(
                Intent(if (step > 0) Action.SWITCH_NEXT else Action.SWITCH_PREVIOUS)
                    .setPackage(app.packageName)
            )
            return
        }
        scope.launch {
            val moved = withContext(Dispatchers.IO) {
                val old = DataStore.selectedProxy
                val target = ProfileOrder.neighbour(old, step) ?: return@withContext null
                DataStore.selectedProxy = target.id
                old to target.id
            } ?: return@launch
            withContext(Dispatchers.IO) {
                runCatching {
                    ProfileManager.postUpdate(moved.first, true)
                    ProfileManager.postUpdate(moved.second, true)
                }
            }
            BboxBridge.scheduleRefresh(immediate = true)
        }
    }

    override fun deleteProfile(id: Long) {
        if (id <= 0L) return
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { GroupRepo.delete(id) } }
            BboxBridge.scheduleRefresh(immediate = true)
        }
    }

    override fun openUrl(url: String) {
        if (url.isBlank()) return
        runCatching {
            app.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure { Logs.w(it) }
    }
}
