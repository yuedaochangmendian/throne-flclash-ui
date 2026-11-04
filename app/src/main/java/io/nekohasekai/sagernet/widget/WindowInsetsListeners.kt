package io.nekohasekai.sagernet.widget

import android.view.View
import android.view.ViewGroup
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.appbar.AppBarLayout
import io.nekohasekai.sagernet.R
import kotlin.math.max

/*
 * Window insets added to a view's own padding. The values the view had before the first call are kept in a tag and
 * every dispatch starts from them, so the listeners can run any number of times. Insets are never consumed: before
 * API 30 siblings only see what the previous sibling returned.
 */

private const val TOP = 1
private const val BOTTOM = 2
private const val HORIZONTAL = 4
private const val IME = 8

/** System bars and display cutout: what content stays clear of. */
fun WindowInsetsCompat.bars(): Insets =
    getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())

private class InsetBase(var start: Int, var top: Int, var end: Int, var bottom: Int) {
    var sides = 0
    var insets: WindowInsetsCompat? = null
}

private fun flags(top: Boolean, bottom: Boolean, horizontal: Boolean, ime: Boolean) =
    (if (top) TOP else 0) or (if (bottom) BOTTOM else 0) or (if (horizontal) HORIZONTAL else 0) or (if (ime) IME else 0)

private fun View.paddingBase(): InsetBase = getTag(R.id.inset_padding_base) as? InsetBase
    ?: InsetBase(paddingStart, paddingTop, paddingEnd, paddingBottom).also { setTag(R.id.inset_padding_base, it) }

private fun View.applyBase(base: InsetBase) {
    val insets = base.insets
    val bars = insets?.bars() ?: Insets.NONE
    val sides = base.sides
    val rtl = layoutDirection == View.LAYOUT_DIRECTION_RTL
    val horizontal = sides and HORIZONTAL != 0
    val start = base.start + if (!horizontal) 0 else if (rtl) bars.right else bars.left
    val end = base.end + if (!horizontal) 0 else if (rtl) bars.left else bars.right
    val top = base.top + if (sides and TOP != 0) bars.top else 0
    var bottomInset = if (sides and BOTTOM != 0) bars.bottom else 0
    if (sides and IME != 0 && insets != null) {
        bottomInset = max(bottomInset, insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
    }
    val bottom = base.bottom + bottomInset
    if (paddingStart != start || paddingTop != top || paddingEnd != end || paddingBottom != bottom) {
        setPaddingRelative(start, top, end, bottom)
    }
}

private fun View.install(base: InsetBase, sides: Int) {
    base.sides = sides
    ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
        base.insets = insets
        view.applyBase(base)
        insets
    }
    if (isAttachedToWindow) {
        ViewCompat.requestApplyInsets(this)
    } else {
        addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {
                v.removeOnAttachStateChangeListener(this)
                ViewCompat.requestApplyInsets(v)
            }

            override fun onViewDetachedFromWindow(v: View) = Unit
        })
    }
}

/** Pads the given sides by the system bars and cutout (bottom: also the keyboard with [ime]). Replaces the listener. */
fun View.applyInsetPadding(
    top: Boolean = false,
    bottom: Boolean = false,
    horizontal: Boolean = false,
    ime: Boolean = false,
) = install(paddingBase(), flags(top, bottom, horizontal, ime))

/**
 * The app bar under the status bar and the cutout, its toolbar clear of side navigation bars; the background stays
 * edge to edge. App bars that fit system windows (collapsing ones with a status bar foreground) handle it themselves.
 */
fun AppBarLayout.applyTopInset() {
    if (!fitsSystemWindows) applyInsetPadding(top = true, horizontal = true)
}
