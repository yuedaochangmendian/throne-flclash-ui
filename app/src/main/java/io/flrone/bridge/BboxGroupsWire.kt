package io.flrone.bridge

import io.flrone.model.ProxyGroup
import io.flrone.model.ProxyNode

/**
 * The group rows the Flutter host renders, kept out of the bridge so the wire contract can be
 * tested without an Activity.
 *
 * Two shapes, one decision: `ready` and the one-second pump send **counts** (`nodeCount`,
 * `timeouts`) and no rows, because the rows are the largest payload the bridge carries — 134 B per
 * node on the wire, and three copies alive while they are built — and only the Proxies screen
 * renders them. That screen asks for them with `groups.visible`, and the rule editor's outbound
 * picker asks for [nodes] (id and tag only) instead of pulling the whole catalog through an event.
 */
internal object BboxGroupsWire {

    /** The catalog with counts only, or with the node rows when the Proxies screen is open. */
    fun groups(groups: List<ProxyGroup>, withItems: Boolean): List<Map<String, Any?>> = groups.map { group ->
        mapOf(
            "id" to group.id.toInt(),
            "tag" to group.tag,
            "type" to group.type,
            "selected" to group.selected,
            "selectedId" to group.selectedId.toInt(),
            "selectable" to group.selectable,
            "nodeCount" to group.nodes.size,
            // Tested and did not answer. The dashboard chip used to walk every node row for this.
            "timeouts" to group.nodes.count { node -> node.testedAt > 0 && node.delay <= 0 },
            "items" to if (withItems) group.nodes.map(::node) else emptyList<Map<String, Any?>>(),
        )
    }

    /**
     * Every node of every group, the outbound picker's list. `isSelector` and `type` ride along
     * because the proxy-chain picker has to skip the rows a hop may not be — a selector resolves
     * to a different member over time and the generator refuses chain-in-chain — and it cannot ask
     * for the full catalogue just to find that out.
     */
    fun nodes(groups: List<ProxyGroup>): List<Map<String, Any?>> = groups.flatMap { group ->
        group.nodes.map { node ->
            mapOf("id" to node.id.toInt(), "tag" to node.tag, "type" to node.type, "isSelector" to node.isSelector)
        }
    }

    private fun node(node: ProxyNode): Map<String, Any?> = mapOf(
        "id" to node.id.toInt(),
        "tag" to node.tag,
        "type" to node.type,
        "delay" to node.delay,
        "testedAt" to node.testedAt,
        "isSelector" to node.isSelector,
    )
}
