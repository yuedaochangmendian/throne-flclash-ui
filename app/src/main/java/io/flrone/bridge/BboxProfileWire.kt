package io.flrone.bridge

import io.flrone.model.ProfileInfo

/** Wire shape shared by `ready` and `profiles.list`. */
object BboxProfileWire {
    fun profiles(profiles: List<ProfileInfo>): List<Map<String, Any?>> = profiles.map { profile ->
        mapOf(
            "id" to profile.id.toInt(),
            "name" to profile.name,
            "type" to profile.type,
            "remote" to (profile.type == "subscription"),
            "url" to profile.url,
            "traffic" to profile.traffic,
            "expiry" to profile.expiry,
            "selected" to profile.selected,
            "updatedAt" to profile.updatedAt,
            "autoUpdate" to profile.autoUpdate,
            "interval" to profile.interval,
        )
    }
}
