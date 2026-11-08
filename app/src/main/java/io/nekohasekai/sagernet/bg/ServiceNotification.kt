package io.nekohasekai.sagernet.bg

import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
import android.os.Build
import android.text.format.Formatter
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.nekohasekai.sagernet.Action
import io.nekohasekai.sagernet.Key
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.aidl.SpeedDisplayData
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProfileOrder
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.ktx.getColorAttr
import io.nekohasekai.sagernet.ktx.runOnMainDispatcher
import io.nekohasekai.sagernet.ui.SwitchActivity
import io.nekohasekai.sagernet.utils.Theme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * User can customize visibility of notification since Android 8.
 * The default visibility:
 *
 * Android 8.x: always visible due to system limitations
 * VPN:         always invisible because of VPN notification/icon
 * Other:       always visible
 *
 * See also: https://github.com/aosp-mirror/platform_frameworks_base/commit/070d142993403cc2c42eca808ff3fafcee220ac4
 */
class ServiceNotification(
    private val service: BaseService.Interface, title: String,
    channel: String, visible: Boolean = false,
) : BroadcastReceiver() {
    companion object {
        const val notificationId = 1
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        // notificationActions entries; the template shows at most three buttons, in this order.
        const val ACTION_STOP = "stop"
        const val ACTION_PREVIOUS = "previous"
        const val ACTION_NEXT = "next"
        const val ACTION_SWITCH = "switch"
        const val ACTION_RESET = "reset"
        val DEFAULT_ACTIONS = listOf(ACTION_STOP, ACTION_NEXT, ACTION_SWITCH)
        private val ACTION_ORDER = listOf(ACTION_STOP, ACTION_PREVIOUS, ACTION_NEXT, ACTION_SWITCH, ACTION_RESET)

        fun notificationActions(): List<String> {
            // null = never configured (defaults); an empty list is "every button deselected" and is honoured.
            val stored = DataStore.configurationStore.getStringList(Key.NOTIFICATION_ACTIONS) ?: return DEFAULT_ACTIONS
            return ACTION_ORDER.filter { it in stored }.take(3)
        }

        // Template rendering lives in NotificationTemplate: no Android types, so
        // it is unit-testable, and a bad pattern cannot fail this class's <clinit>.
        fun genTitle(ent: ProxyEntity): String {
            val gn = if (DataStore.showGroupInNotification)
                SagerDatabase.groupDao.getById(ent.groupId)?.displayName() else null
            return if (gn == null) ent.displayName() else "[$gn] ${ent.displayName()}"
        }
    }

    var listenPostSpeed = SagerNet.power.isInteractive

    /** Whether the screen is on; the traffic looper stops polling the core while it is off. */
    val screenOn = MutableStateFlow(SagerNet.power.isInteractive)

    suspend fun postNotificationSpeedUpdate(stats: SpeedDisplayData) {
        // A content template owns the body outright: the speed toggles below only shape the
        // built-in line, so a user who wrote their own text is never second-guessed.
        val customBody = if (contentTemplate.isEmpty()) null else render(contentTemplate, contentValues(stats))
        useBuilder {
            // Re-render the title too: a template change reaches the notification on this same
            // update, without waiting for the next profile switch.
            it.setContentTitle(displayTitle(currentTitle))
            if (customBody != null) {
                it.setContentText(customBody)
                it.setStyle(if ('\n' in customBody) NotificationCompat.BigTextStyle().bigText(customBody) else null)
                it.setSubText(null)
            } else {
                when {
                    !showProxySpeed -> {
                        it.setContentText(null)
                        it.setStyle(null)
                    }
                    showDirectSpeed -> {
                        val speedDetail = ctx.getString(
                            R.string.speed_detail, speed(stats.txRateProxy), speed(stats.rxRateProxy),
                            speed(stats.txRateDirect), speed(stats.rxRateDirect)
                        )
                        it.setStyle(NotificationCompat.BigTextStyle().bigText(speedDetail))
                        it.setContentText(speedDetail)
                    }
                    else -> {
                        val speedSimple = ctx.getString(
                            R.string.traffic, speed(stats.txRateProxy), speed(stats.rxRateProxy)
                        )
                        it.setContentText(speedSimple)
                        it.setStyle(null)
                    }
                }
                // The cumulative total under the rate line is optional: a minimal notification
                // (rate only) reads cleaner on a lock screen that already shows a clock.
                if (showTrafficTotal) it.setSubText(
                    ctx.getString(
                        R.string.traffic,
                        Formatter.formatFileSize(ctx, stats.txTotal),
                        Formatter.formatFileSize(ctx, stats.rxTotal)
                    )
                ) else it.setSubText(null)
            }
        }
        update()
    }

    suspend fun postNotificationTitle(newTitle: String) {
        currentTitle = newTitle
        useBuilder {
            it.setContentTitle(displayTitle(newTitle))
        }
        update()
    }

    /** A restart in place: the new profile's title and buttons, and no speed of the old one. */
    suspend fun refresh(newTitle: String) {
        currentTitle = newTitle
        updateActions()
        useBuilder {
            it.setContentTitle(displayTitle(newTitle))
            it.setContentText(null)
            it.setSubText(null)
            it.setStyle(null)
        }
        update()
    }

    /** What a start waits for (an Xray geo asset download) under the title, [percent] -1 while unknown; null clears it. */
    suspend fun postStartProgress(text: String?, percent: Int) {
        useBuilder {
            it.setContentText(text)
            if (text == null) it.setProgress(0, 0, false) else it.setProgress(100, percent.coerceAtLeast(0), percent < 0)
        }
        update()
    }

    suspend fun postConnected() {
        updateActions()
        useBuilder { it.priority = NotificationCompat.PRIORITY_LOW }
        update()
    }

    // Read through on every update rather than captured at construction: the General page
    // promises these apply on the service's next notification update, with no restart.
    private val showProxySpeed get() = DataStore.showProxySpeed
    private val showDirectSpeed get() = DataStore.showDirectSpeed

    /** Whether the cumulative up/down total shows as the notification's sub text. */
    private val showTrafficTotal get() = DataStore.showTrafficTotal

    /**
     * The title template. `{title}` is the profile name (or "Switching…"); everything else is
     * literal, so "🚀 {title}" reads "🚀 Tokyo 01". Empty falls back to `{title}`, and an older
     * build's `notificationTitlePrefix` is folded in as "<prefix> {title}" so an upgrade keeps it.
     */
    private val titleTemplate: String
        get() = DataStore.notificationTitleTemplate.trim().ifEmpty {
            val legacy = DataStore.notificationTitlePrefix.trim()
            if (legacy.isEmpty()) "{title}" else "$legacy {title}"
        }

    /** A full body template; empty keeps the built-in rate/detail lines and the speed toggles. */
    private val contentTemplate get() = DataStore.notificationContentTemplate.trim()

    /** The latest title, so a content template can echo it while the rates update. */
    private var currentTitle: String = title

    /** [title] through [titleTemplate]. */
    private fun displayTitle(title: String): String = render(titleTemplate, mapOf("title" to title))

    /** Replaces every `{key}` in [template]; unknown placeholders stay as written. */
    private fun render(template: String, values: Map<String, String>): String {
        // One pass, and no second scan of substituted values; see NotificationTemplate.
        return NotificationTemplate.render(template, values)
    }

    /** The service as a Context; `Interface` is not one, so every formatter call goes through here. */
    private val ctx: Context get() = service as Context

    private fun speed(rate: Long): String =
        ctx.getString(R.string.speed, Formatter.formatFileSize(ctx, rate))

    private fun contentValues(stats: SpeedDisplayData) = mapOf(
        "title" to currentTitle,
        "up" to speed(stats.txRateProxy),
        "down" to speed(stats.rxRateProxy),
        "directUp" to speed(stats.txRateDirect),
        "directDown" to speed(stats.rxRateDirect),
        "totalUp" to Formatter.formatFileSize(ctx, stats.txTotal),
        "totalDown" to Formatter.formatFileSize(ctx, stats.rxTotal),
    )

    private val builder = NotificationCompat.Builder(service as Context, channel)
        .setWhen(0)
        .setTicker(service.getString(R.string.forward_success))
        .setContentTitle(displayTitle(title))
        .setOnlyAlertOnce(true)
        .setContentIntent(SagerNet.configureIntent(service))
        .setSmallIcon(R.drawable.ic_throne_tile)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .setPriority(if (visible) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_MIN)

    private val buildLock = Mutex()

    private suspend fun useBuilder(f: (NotificationCompat.Builder) -> Unit) {
        buildLock.withLock {
            f(builder)
        }
    }

    init {
        service as Context

        Theme.apply(app)
        Theme.apply(service)
        builder.color = service.getColorAttr(R.attr.colorPrimary)

        service.registerReceiver(this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        })

        runOnMainDispatcher {
            updateActions()
            show()
        }
    }

    private suspend fun updateActions() {
        service as Context
        val actions = notificationActions()
        val profileId = service.data.proxy?.profile?.id ?: DataStore.selectedProxy
        val canCycle = (ACTION_NEXT in actions || ACTION_PREVIOUS in actions) && ProfileOrder.canCycle(profileId)
        useBuilder {
            it.clearActions()
            for (action in actions) when (action) {
                ACTION_STOP -> it.addAction(
                    broadcastAction(R.drawable.ic_notification_stop, service.getText(R.string.stop), Action.CLOSE, 1)
                )

                ACTION_PREVIOUS -> if (canCycle) it.addAction(
                    broadcastAction(
                        R.drawable.ic_notification_previous, service.getText(R.string.notification_previous),
                        Action.SWITCH_PREVIOUS, 2,
                    )
                )

                ACTION_NEXT -> if (canCycle) it.addAction(
                    broadcastAction(
                        R.drawable.ic_notification_next, service.getText(R.string.notification_next),
                        Action.SWITCH_NEXT, 3,
                    )
                )

                ACTION_SWITCH -> it.addAction(
                    NotificationCompat.Action.Builder(
                        R.drawable.ic_notification_switch, service.getText(R.string.notification_switch),
                        PendingIntent.getActivity(
                            service, 4,
                            Intent(service, SwitchActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            flags,
                        )
                    ).setShowsUserInterface(true).build()
                )

                ACTION_RESET -> it.addAction(
                    broadcastAction(
                        R.drawable.ic_notification_reset, service.getText(R.string.reset_connections),
                        Action.RESET_UPSTREAM_CONNECTIONS, 5,
                    )
                )
            }
        }
    }

    private fun broadcastAction(icon: Int, title: CharSequence, action: String, requestCode: Int) =
        NotificationCompat.Action.Builder(
            icon, title, PendingIntent.getBroadcast(
                service as Context, requestCode, Intent(action).setPackage(service.packageName), flags
            )
        ).setShowsUserInterface(false).build()

    override fun onReceive(context: Context, intent: Intent) {
        val on = intent.action == Intent.ACTION_SCREEN_ON
        screenOn.value = on
        listenPostSpeed = on
    }


    private suspend fun show() =
        useBuilder {
            try {
                if (Build.VERSION.SDK_INT >= 34) {
                    (service as Service).startForeground(
                        notificationId,
                        it.build(),
                        FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
                    )
                } else {
                    (service as Service).startForeground(notificationId, it.build())
                }
            } catch (e: Exception) {
                Toast.makeText(
                    SagerNet.application,
                    "startForeground: $e",
                    Toast.LENGTH_LONG
                ).show()
            }
        }

    private suspend fun update() = useBuilder {
        NotificationManagerCompat.from(service as Service).notify(notificationId, it.build())
    }

    fun destroy() {
        listenPostSpeed = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            (service as Service).stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            (service as Service).stopForeground(true)
        }
        service.unregisterReceiver(this)
    }
}
