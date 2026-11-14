package io.throne.bbox.flutter

import android.app.ActivityManager
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ui.FirstStartPrompts
import io.nekohasekai.sagernet.ui.WifiPermissionFlow
import io.nekohasekai.sagernet.utils.CrashHandler
import io.nekohasekai.sagernet.utils.PlatformNotifications

/**
 * The app's entry point: FlClash's interface hosted on Throne's runtime.
 *
 * The four FlClash platform plugins are registered here — the same contract
 * upstream MainActivity registers — and every Core method they carry is served
 * by Throne's own profile repository and sing-box/Xray runtime through the
 * CoreHandlerInterface implementation. No page-level bridge participates.
 *
 * This activity is also the leanback launcher, so a TV boots into the same
 * interface; Flutter routes D-pad keys through its own focus tree.
 */
class BboxFlutterActivity : FlutterFragmentActivity() {

    // The first-start prompts and the Wi-Fi walk-through register their launchers at
    // construction, which is what the framework requires.
    private val firstStart = FirstStartPrompts(this)
    private val wifiFlow = WifiPermissionFlow(this)
    private var wifiWaiting = false

    /**
     * The task this activity lives in, kept because an excluded task drops out of
     * [ActivityManager.getAppTasks]: once hidden, only this reference can put it back.
     */
    private var recentsTask: ActivityManager.AppTask? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            firstStart.start()
            if (intent?.getBooleanExtra(PlatformNotifications.EXTRA_WIFI_PERMISSION, false) == true) startWifiFlow()
        }
    }

    override fun onResume() {
        super.onResume()
        applyHideFromRecentApps(DataStore.hideFromRecentApps)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(PlatformNotifications.EXTRA_WIFI_PERMISSION, false)) startWifiFlow()
    }

    /**
     * Turns the "hide from recent tasks" switch into the task flag Android reads.
     * Applied on resume as well as on change, so a value stored by an earlier run
     * still holds on the first frame.
     */
    private fun applyHideFromRecentApps(hide: Boolean) {
        val task = runCatching {
            getSystemService(ActivityManager::class.java).appTasks
                .firstOrNull { it.taskInfo?.taskId == taskId }
                ?.also { recentsTask = it }
        }.getOrNull() ?: recentsTask
        runCatching { task?.setExcludeFromRecents(hide) }
            .onFailure { Logs.w("Failed to set excludeFromRecents: ${it.message}") }
    }

    /**
     * The Wi-Fi walk-through the warning notification asks for. A tap on it while
     * the UI is already up lands in [onNewIntent] and never in [onCreate], so both
     * entry points call this.
     */
    private fun startWifiFlow() {
        if (wifiWaiting) return
        wifiWaiting = true
        if (!wifiFlow.run(onDone = { wifiWaiting = false })) wifiWaiting = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(BatteryPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        // The UI really came up: give the next crash its full restart budget back,
        // so a startup crash that always recurs cannot restart the app forever.
        CrashHandler.noteStarted()
    }
}
