package com.follow.clash

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.core.content.pm.ShortcutManagerCompat
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import com.follow.clash.common.shortcutId
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.database.DataStore
import io.throne.bbox.corehost.ThroneServiceController

/**
 * The launcher's Start / Stop / Toggle shortcuts, upstream FlClash's entry point.
 *
 * Upstream routed these into its ServiceStateMachine, which owned a service of its own. Here the
 * tunnel belongs to Throne's foreground service, so each action is the same request the Flutter UI
 * sends over the Service channel: [ThroneServiceController] resolves the profile and starts or stops
 * SagerNet. The activity owns no state and finishes as soon as the request is handed over — the
 * shortcut is the whole UI.
 *
 * The intents are explicit (Components.quickActionActivity) and carry the action strings Ext.kt
 * builds, so a launcher tap resolves to this class. Without the manifest entry, every tap was an
 * ActivityNotFoundException and the shortcut silently did nothing.
 */
class QuickActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
    }

    // A caller that repeats an action before this instance is gone reaches it here, not onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        val action = QuickAction.entries.firstOrNull { it.action == intent.action }
        if (action == null) {
            finish()
            return
        }
        // Ranking is a nicety; a shortcut that is no longer registered must not stop the action.
        runCatching { ShortcutManagerCompat.reportShortcutUsed(this, action.shortcutId) }
        when (action) {
            QuickAction.START -> requestStart()
            QuickAction.STOP -> {
                ThroneServiceController.requestStop()
                finish()
            }

            QuickAction.TOGGLE -> {
                if (ThroneServiceController.isRunRequested || ThroneServiceController.isRunning()) {
                    ThroneServiceController.requestStop()
                    finish()
                } else {
                    requestStart()
                }
            }
        }
    }

    /**
     * A shortcut can be the first thing tapped after a fresh install, before the UI ever asked for
     * VPN consent. The consent dialog belongs to an activity, so it is requested here and the start
     * is replayed once the answer arrives; without this the tap would be dropped by the service's
     * own `prepare()` path (it stops the run it just started).
     */
    private fun requestStart() {
        val consent = if (DataStore.serviceMode == Key.MODE_VPN) VpnService.prepare(this) else null
        if (consent == null) {
            ThroneServiceController.requestStart()
            finish()
            return
        }
        @Suppress("DEPRECATION")
        startActivityForResult(consent, VPN_PERMISSION_REQUEST_CODE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) return
        if (resultCode == RESULT_OK) ThroneServiceController.requestStart()
        finish()
    }

    private companion object {
        const val VPN_PERMISSION_REQUEST_CODE = 1001
    }
}
