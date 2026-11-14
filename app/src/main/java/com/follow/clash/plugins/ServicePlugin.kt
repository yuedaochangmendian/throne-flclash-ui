package com.follow.clash.plugins

import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.models.SharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.throne.bbox.corehost.ThroneCore
import io.throne.bbox.corehost.ThroneServiceController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * FlClash's service protocol on Throne's runtime. The two channels are exactly
 * the upstream contract (`packageName/service`, `packageName/core`); the
 * methods answer through [ThroneCore] and [ThroneServiceController] instead of
 * mihomo, so no page-level bridge or second state store is involved.
 */
class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var messenger: BinaryMessenger
    private lateinit var channel: MethodChannel
    private lateinit var coreChannel: MethodChannel
    private lateinit var scope: CoroutineScope
    private val gson = Gson()

    // Read on the platform thread, where "start"/"stop" arrive and where notifyStopped replies;
    // the controller reports a stop from a background coroutine, so the value is shared.
    @Volatile
    private var commandRevision = 0

    // One stable reference: the controller clears exactly this listener on detach, so a later
    // engine that already registered its own is left alone.
    private val stoppedReport: () -> Unit = ::notifyStopped

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        messenger = binding.binaryMessenger
        channel = MethodChannel(messenger, SERVICE_CHANNEL)
        channel.setMethodCallHandler(this)
        coreChannel = MethodChannel(
            messenger,
            CORE_CHANNEL,
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        )
        coreChannel.setMethodCallHandler(::onCoreMethodCall)
        // A tunnel the system, the notification or the OS stopped is reported here too — the
        // Dart side only ever hears about the stops it asked for otherwise.
        ThroneServiceController.setStoppedListener(stoppedReport)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        coreChannel.setMethodCallHandler(null)
        scope.cancel()
        ThroneServiceController.clearStoppedListener(stoppedReport)
        ThroneCore.setEventListener(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                ThroneCore.setEventListener(::sendEvent)
                ThroneCore.initialize()
                // Seeds the running state and drops a VpnService left over from a previous
                // process; nothing else called it, so it never ran at all.
                ThroneServiceController.initialize()
                result.success("")
            }

            "shutdown" -> {
                ThroneCore.setEventListener(null)
                // Releases the group listener and the log pump so the next "init" can register
                // them again; without this a shutdown -> init cycle left both dead.
                ThroneCore.close()
                result.success(true)
            }

            "getRunTime" -> {
                scope.launch { result.success(ThroneServiceController.awaitRunTime()) }
            }

            "syncState" -> {
                val data = call.arguments as? String
                scope.launch {
                    val state = runCatching {
                        gson.fromJson(data, SharedState::class.java)
                    }.getOrNull()
                    if (state == null) {
                        result.success("Invalid shared state")
                        return@launch
                    }
                    result.success(ThroneServiceController.syncState(data ?: "{}"))
                }
            }

            "start" -> {
                commandRevision = call.arguments as? Int ?: commandRevision
                ThroneServiceController.requestStart()
                result.success(true)
            }

            "stop" -> {
                commandRevision = call.arguments as? Int ?: commandRevision
                ThroneServiceController.requestStop()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun onCoreMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "invokeMethod" -> invokeMethod(call, result)
            else -> result.notImplemented()
        }
    }

    private fun invokeMethod(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        if (data == null) {
            result.error("INVALID_ARGUMENT", "Method call payload must be a string", null)
            return
        }
        ThroneCore.invokeMethod(data) { response ->
            result.success(response)
        }
    }

    private fun sendEvent(value: ByteArray) {
        val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("event", value))
        scope.launch(Dispatchers.Main) {
            messenger.send(SERVICE_CHANNEL, message)
        }
    }

    /**
     * Upstream's `stopped` report, which Dart's Service channel handles by clearing its running
     * state (`onServiceStopped` -> setRunning(false)). Emission is gated exactly as upstream gated
     * it: only a stop the user did not request is announced, and the payload is the revision that
     * was current when that request was made, so a stop report that races a newer start is dropped
     * by the Dart side's `commandRevision` check instead of cancelling it.
     */
    fun notifyStopped() {
        val revision = commandRevision
        scope.launch(Dispatchers.Main) {
            if (!ThroneServiceController.isRunRequested) {
                channel.invokeMethod("stopped", revision)
            }
        }
    }

    private companion object {
        val SERVICE_CHANNEL = "${Components.PACKAGE_NAME}/service"
        val CORE_CHANNEL = "${Components.PACKAGE_NAME}/core"
    }
}
