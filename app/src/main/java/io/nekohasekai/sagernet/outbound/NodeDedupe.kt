package io.nekohasekai.sagernet.outbound

/**
 * Drops repeated nodes from one import batch, before any row is written.
 *
 * The key is the desktop's duplicate key (Profile.cpp:87-90): the JSON link without its tag, so two
 * entries that differ only by name are the same server and the first one wins — the rule
 * ProfileFilter::Uniq applies with keep_last=false. A subscription body that lists a server twice, a
 * pasted list with the same node under two remarks, and a link imported again all collapse to one row.
 *
 * This is per-batch only. Duplicates already stored in a group across updates are the subscription's
 * `removeDuplicates` option's job; deleting those here would fight the reconcile that keeps ids.
 */
fun List<Outbound>.distinctNodes(): List<Outbound> {
    if (size < 2) return this
    val seen = HashSet<String>(size * 2)
    return filter { outbound ->
        // A node the exporter cannot serialise cannot be compared; keeping it is safer than dropping it.
        val key = runCatching { outbound.exportJsonLink(stripMetadata = true) }.getOrNull()
        key == null || seen.add(key)
    }
}
