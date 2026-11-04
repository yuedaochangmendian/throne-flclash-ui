package io.nekohasekai.sagernet.ui.json.engine

/**
 * Root pointers into the bundled sing-box schema (`assets/schema/sing-box.json`) that a profile is checked against.
 * The loading and validation machinery that used to live here went with the schema editor; [io.nekohasekai.sagernet.ui.json.ProfileJson]
 * only needs these two roots.
 */
object SchemaStore {

    const val OUTBOUND = "#/\$defs/Outbound"
    const val ENDPOINT = "#/\$defs/Endpoint"
}
