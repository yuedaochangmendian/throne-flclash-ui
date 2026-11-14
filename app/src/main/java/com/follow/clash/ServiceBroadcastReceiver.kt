package com.follow.clash

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.follow.clash.common.BroadcastAction
import com.follow.clash.common.BroadcastLease
import com.follow.clash.common.GlobalState
import com.follow.clash.common.action
import io.throne.bbox.corehost.ThroneServiceController
import kotlinx.coroutines.launch

/**
 * Upstream FlClash's in-app service broadcasts (`<package>.intent.action.VPN_START_REQUESTED` and
 * `VPN_REVOKED`). The sender is a foreground [android.app.Service] that noticed the VPN went away or
 * that a start is wanted without an activity; here the requests go straight to
 * [ThroneServiceController], which owns the tunnel.
 *
 * The receiver is declared `exported` behind the signature-level
 * `<package>.permission.RECEIVE_BROADCASTS`, the same pair upstream's common manifest declares, so
 * only this app (or one signed with the same key) can toggle the tunnel.
 */
class ServiceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val action = intent?.action ?: return
        val pendingResult = goAsync()
        val lease = BroadcastLease { pendingResult.finish() }
        val timeout = Runnable {
            lease.release { GlobalState.log("Broadcast handling timed out: $action") }
        }
        mainHandler.postDelayed(timeout, BROADCAST_TIMEOUT_MILLIS)
        GlobalState.launch {
            try {
                handleAction(action)
            } catch (error: Exception) {
                GlobalState.log("Unable to handle service broadcast $action: $error")
            } finally {
                mainHandler.removeCallbacks(timeout)
                lease.release()
            }
        }
    }

    private fun handleAction(action: String) {
        when (action) {
            BroadcastAction.VPN_START_REQUESTED.action -> ThroneServiceController.requestStart()

            BroadcastAction.VPN_REVOKED.action -> ThroneServiceController.requestStop()
        }
    }

    private companion object {
        private const val BROADCAST_TIMEOUT_MILLIS = 9_000L
        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
