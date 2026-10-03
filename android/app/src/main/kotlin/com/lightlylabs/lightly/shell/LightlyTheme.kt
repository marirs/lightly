package com.lightlylabs.lightly.shell

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import com.lightlylabs.lightly.prefs.Appearance

/** The approved colour tokens (docs/ui/app/styles.css `.dv.light` / `.dv.dark`), verbatim. */
@Immutable
data class LightlyColors(
    val bg: Color,
    val bg2: Color,
    val canvas: Color,
    val ink: Color,
    val ink2: Color,
    val ink3: Color,
    val hair: Color,
    val track: Color,
    /** Ruler ticks (`--tick`) and every tenth tick (`--tickM`). */
    val tick: Color,
    val tickMajor: Color,
    val sel: Color,
    val selSoft: Color,
    val scrim: Color,
    val sheet: Color,
    val danger: Color,
    /** The selected segment's fill (`.seg .on`): bg in light, #3A3A3F in dark. */
    val segmentOn: Color,
    val isDark: Boolean,
) {
    companion object {
        val Light = LightlyColors(
            bg = Color(0xFFFFFFFF), bg2 = Color(0xFFF6F6F7), canvas = Color(0xFFEEEEF0),
            ink = Color(0xFF121214), ink2 = Color(0xFF55555C), ink3 = Color(0xFF6C6C74), hair = Color(0xFFE3E3E6),
            track = Color(0xFFDEDEE2), tick = Color(0xFFC6C6CC), tickMajor = Color(0xFF8A8A92), sel = Color(0xFF2257D2), selSoft = Color(0x142257D2),
            scrim = Color(0x52000000), sheet = Color(0xFFFFFFFF), danger = Color(0xFFC2342B),
            segmentOn = Color(0xFFFFFFFF), isDark = false,
        )
        val Dark = LightlyColors(
            bg = Color(0xFF1C1C1E), bg2 = Color(0xFF232326), canvas = Color(0xFF111113),
            ink = Color(0xFFF2F2F4), ink2 = Color(0xFFAEAEB4), ink3 = Color(0xFF94949C), hair = Color(0xFF2E2E32),
            track = Color(0xFF38383D), tick = Color(0xFF45454B), tickMajor = Color(0xFF85858D), sel = Color(0xFF7AA2FF), selSoft = Color(0x247AA2FF),
            scrim = Color(0x80000000), sheet = Color(0xFF26262A), danger = Color(0xFFFF6B5E),
            segmentOn = Color(0xFF3A3A3F), isDark = true,
        )
    }
}

val LocalLightlyColors = staticCompositionLocalOf { LightlyColors.Light }

/** Shorthand used by the shell composables. */
val lightlyColors: LightlyColors
    @Composable get() = LocalLightlyColors.current

/** Appearance › System follows the device; Light and Dark override it app-wide. */
@Composable
fun isDarkAppearance(appearance: Appearance): Boolean = when (appearance) {
    Appearance.SYSTEM -> isSystemInDarkTheme()
    Appearance.LIGHT -> false
    Appearance.DARK -> true
}

/**
 * Provides the Lightly tokens, and maps them onto Material 3 so the existing editor (slice 2
 * replaces it) uses the same neutral palette and follows Appearance too.
 */
@Composable
fun LightlyTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors = if (dark) LightlyColors.Dark else LightlyColors.Light
    val scheme = if (dark) {
        darkColorScheme(
            primary = colors.ink, onPrimary = colors.bg, secondary = colors.sel, background = colors.bg, onBackground = colors.ink,
            surface = colors.bg, onSurface = colors.ink, surfaceVariant = colors.bg2, onSurfaceVariant = colors.ink2,
            outline = colors.hair, error = colors.danger,
        )
    } else {
        lightColorScheme(
            primary = colors.ink, onPrimary = colors.bg, secondary = colors.sel, background = colors.bg, onBackground = colors.ink,
            surface = colors.bg, onSurface = colors.ink, surfaceVariant = colors.bg2, onSurfaceVariant = colors.ink2,
            outline = colors.hair, error = colors.danger,
        )
    }
    CompositionLocalProvider(LocalLightlyColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
