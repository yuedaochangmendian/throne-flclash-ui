package io.nekohasekai.sagernet.bg

import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import androidx.annotation.RequiresApi
import com.follow.clash.plugins.TilePlugin
import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.SagerNet
import io.nekohasekai.sagernet.aidl.ISagerNetService
import io.nekohasekai.sagernet.database.SagerDatabase
import android.service.quicksettings.TileService as BaseTileService

@RequiresApi(24)
class TileService : BaseTileService(), SagerConnection.Callback {
    private val tileIcon by lazy { Icon.createWithResource(this, R.drawable.ic_throne_tile) }
    private var tapPending = false

    private val connection = SagerConnection(SagerConnection.CONNECTION_ID_TILE)
    override fun stateChanged(state: BaseService.State, profileName: String?, msg: String?) =
        updateTile(state, profileName)

    override fun onServiceConnected(service: ISagerNetService) {
        updateTile(BaseService.State.values()[service.state], service.profileName)
        if (tapPending) {
            tapPending = false
            onClick()
        }
    }

    override fun cbSelectorUpdate(id: Long) {
        val profile = SagerDatabase.proxyDao.getById(id) ?: return
        updateTile(BaseService.State.Connected, profile.displayName())
    }

    override fun onStartListening() {
        super.onStartListening()
        connection.connect(this, this)
    }

    override fun onStopListening() {
        connection.disconnect(this)
        super.onStopListening()
    }

    override fun onClick() {
        if (isLocked) unlockAndRun(this::toggle) else toggle()
    }

    private fun updateTile(serviceState: BaseService.State, profileName: String?) {
        qsTile?.apply {
            label = null
            icon = tileIcon
            when (serviceState) {
                BaseService.State.Idle -> state = Tile.STATE_INACTIVE
                BaseService.State.Connecting -> state = Tile.STATE_ACTIVE
                BaseService.State.Connected -> {
                    label = profileName
                    state = Tile.STATE_ACTIVE
                }

                BaseService.State.Stopping -> state = Tile.STATE_UNAVAILABLE
                BaseService.State.Stopped -> state = Tile.STATE_INACTIVE
            }
            label = label ?: getString(R.string.app_name)
            updateTile()
        }
    }

    private fun toggle() {
        val service = connection.service
        if (service == null) tapPending =
            true else BaseService.State.values()[service.state].let { state ->
            when {
                state.canStop -> SagerNet.stopService()
                state == BaseService.State.Stopped -> start()
            }
        }
    }

    /**
     * The start branch tells the Flutter side first (upstream's tile did the same): its listener
     * marks the UI running and starts through ThroneServiceController, which resolves the selected
     * profile the way every other screen does. Starting SagerNet directly here would run whatever
     * profile the stored id happened to name and leave the dashboard showing "disconnected". The
     * direct call stays as the fallback for a tap with no engine attached (the process can be alive
     * only to serve this tile).
     */
    private fun start() {
        if (!TilePlugin.notifyStart()) SagerNet.startService()
    }
}
