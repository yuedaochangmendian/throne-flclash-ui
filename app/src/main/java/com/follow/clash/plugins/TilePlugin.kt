package com.follow.clash.plugins

import com.follow.clash.common.Components
import com.follow.clash.invokeMethodOnMainThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The `flutter/lib/plugins/tile.dart` channel. Upstream's QS tile called [handleStart] so the Dart
 * side could put its UI into the running state before the service came up; this host's tile is
 * Throne's own service, which owns no plugin reference. [notifyStart] gives it back the same entry
 * point and reports whether an engine was there to take it.
 */
class TilePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "${Components.PACKAGE_NAME}/tile")
        channel.setMethodCallHandler(this)
        attached = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        if (attached === this) attached = null
    }

    fun handleStart() {
        channel.invokeMethodOnMainThread("start")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        result.notImplemented()
    }

    companion object {
        /** The live plugin, or null while no engine is attached. */
        @Volatile
        private var attached: TilePlugin? = null

        /**
         * Asks the Dart side to start the tunnel, which is the path the tile took upstream: the
         * listener there sets the running state and then asks for the start. Returns false when no
         * engine is attached, so the caller can decide how to start without one.
         */
        fun notifyStart(): Boolean {
            val plugin = attached ?: return false
            plugin.handleStart()
            return true
        }
    }
}
