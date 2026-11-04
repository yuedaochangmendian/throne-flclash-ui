package io.nekohasekai.sagernet.ui.json

import android.os.Parcelable
import io.nekohasekai.sagernet.ui.json.engine.JsonType
import kotlinx.parcelize.Parcelize

/** Per-editor schema relaxations (the desktop's AllowExtraType plus what Throne's own stored forms need). */
@Parcelize
data class JsonRelaxations(
    /** Keys Throne writes that the sing-box schema does not know, by instance pointer ("" = root, "/tls"). */
    val extraKeys: List<ExtraKey> = emptyList(),
    /** An extra accepted type for a property name anywhere in the document (desktop AllowExtraType). */
    val extraTypes: List<ExtraType> = emptyList(),
    /** Throne type names of the root object mapped to the schema's (`openvpn` -> `openvpn-client`). */
    val typeAliases: Map<String, String> = emptyMap(),
    val unknownKeysAsWarnings: Boolean = false,
) : Parcelable {

    @Parcelize
    data class ExtraKey(val pointer: String, val key: String) : Parcelable

    @Parcelize
    data class ExtraType(val key: String, val type: JsonType) : Parcelable
}
