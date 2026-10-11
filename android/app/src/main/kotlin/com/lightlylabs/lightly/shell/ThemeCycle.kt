package com.lightlylabs.lightly.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.prefs.Appearance

/**
 * Owner amendment 2026-10-11 (mockup `theme-cycle`): a double tap on empty space cycles the theme System → Light → Dark →
 * System. It is the same persisted preference as More › Appearance; a toast names the new theme. Empty space is the
 * editor's stage outside the photo, the Welcome background and the More page background, never the photo (a double tap
 * there keeps inspection zoom) and never a control (controls consume their own taps first).
 */
object ThemeCycle {
    fun next(current: Appearance): Appearance = when (current) {
        Appearance.SYSTEM -> Appearance.LIGHT
        Appearance.LIGHT -> Appearance.DARK
        Appearance.DARK -> Appearance.SYSTEM
    }

    /** The toast's approved text for the theme just chosen. */
    fun toast(appearance: Appearance): String = when (appearance) {
        Appearance.SYSTEM -> "System theme"
        Appearance.LIGHT -> "Light theme"
        Appearance.DARK -> "Dark theme"
    }
}

/**
 * Double taps on this element's own empty area call [onDoubleTap]. Children that handle taps (buttons, rows, switches)
 * consume them first in the main pass, so a double tap on a control never reaches this.
 */
fun Modifier.doubleTapEmptySpace(onDoubleTap: (() -> Unit)?): Modifier =
    if (onDoubleTap == null) this else pointerInput(onDoubleTap) { detectTapGestures(onDoubleTap = { onDoubleTap() }) }

/**
 * The editor's toast (Lightly 2 `toast`), for screens without a photo stage: 9/14 dp padding, 14 dp corners,
 * rgba(14,15,17,.88), 13 sp semibold #F2F3F0, one line. The caller places it (top centre, under the status bar).
 */
@Composable
fun ShellToast(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = l2TextStyle(13.sp, FontWeight.SemiBold, Color(0xFFF2F3F0)),
        maxLines = 1,
        // On a dark page the editor's near-black toast vanishes into the background, so dark lifts it to a raised grey.
        modifier = modifier.background(if (lightlyColors.isDark) Color(0xFF2B2D31) else Color(0xE00E0F11), RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 9.dp)
            .testTagResource("shell-toast"),
    )
}
