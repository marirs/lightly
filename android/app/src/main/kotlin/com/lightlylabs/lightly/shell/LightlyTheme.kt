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

/**
 * The Lightly 2 colour tokens (docs/ui/directions/lightly-2-concept/index.html `.t-light` / `.t-dark`, approved
 * 2026-10-10), verbatim; rgba() values keep their alpha. Field names of the earlier palette stay for call sites:
 * bg2 is `--card`, canvas is `--stage`, hair is `--line`, track is `--off`, sel is `--accent-ink`, segmentOn is
 * `--on-bg` (the ink fill of selected chips, segments and tabs).
 */
@Immutable
data class LightlyColors(
    val bg: Color,
    val surface: Color,
    val bg2: Color,
    val canvas: Color,
    val ink: Color,
    val ink2: Color,
    val ink3: Color,
    val onInk: Color,
    val hair: Color,
    val track: Color,
    val chip: Color,
    val knob: Color,
    val glass: Color,
    val glassInk: Color,
    val glassLine: Color,
    val accent: Color,
    val onAccent: Color,
    val accentEdge: Color,
    /** Ruler ticks (no longer drawn in Lightly 2; kept for the remaining debug views). */
    val tick: Color,
    val tickMajor: Color,
    val sel: Color,
    val selSoft: Color,
    val browse: Color,
    val edited: Color,
    val scrim: Color,
    val sheet: Color,
    val danger: Color,
    val segmentOn: Color,
    /** `--pill` / `--pill-ink`: the selected tab's translucent lime pill and its label (owner amendment 2026-10-11). */
    val pill: Color,
    val pillInk: Color,
    val isDark: Boolean,
) {
    companion object {
        // Owner, 2026-10-12: ink3 (and the ruler's major tick, which shares it) is #6C7068 light / #80857D dark so
        // the grey hint text reaches 4.5:1 on every surface (was the mockup's #7D8179 / #7E837B).
        val Light = LightlyColors(
            bg = Color(0xFFF3F3F0), surface = Color(0xFFFFFFFF), bg2 = Color(0xFFF4F4F1), canvas = Color(0xFFE6E6E2),
            ink = Color(0xFF141513), ink2 = Color(0xFF5A5E57), ink3 = Color(0xFF6C7068), onInk = Color(0xFFFFFFFF),
            hair = Color(0x17141513), track = Color(0x2E141513), chip = Color(0x0E141513), knob = Color(0xFFFFFFFF),
            glass = Color(0xC7FFFFFF), glassInk = Color(0xFF141513), glassLine = Color(0x1A141513),
            accent = Color(0xFFCFF26B), onAccent = Color(0xFF121408), accentEdge = Color(0xFF8FAE2E),
            tick = Color(0x2E141513), tickMajor = Color(0xFF6C7068), sel = Color(0xFF557311), selSoft = Color(0x14557311),
            browse = Color(0xFFC25E00), edited = Color(0xFFC25E00),
            scrim = Color(0x520A0A0A), sheet = Color(0xFFFFFFFF), danger = Color(0xFFC7362B),
            segmentOn = Color(0xFF141513),
            // rgba(207,242,107,0.45): 0.45 × 255 = 114.75 → 0x73.
            pill = Color(0x73CFF26B), pillInk = Color(0xFF141513), isDark = false,
        )
        val Dark = LightlyColors(
            bg = Color(0xFF0D0E10), surface = Color(0xFF131518), bg2 = Color(0xFF1A1C20), canvas = Color(0xFF0A0B0C),
            ink = Color(0xFFF2F3F0), ink2 = Color(0xFFA6ABA3), ink3 = Color(0xFF80857D), onInk = Color(0xFF121408),
            hair = Color(0x14FFFFFF), track = Color(0x2EFFFFFF), chip = Color(0x12FFFFFF), knob = Color(0xFFF2F3F0),
            glass = Color(0xA30E0F11), glassInk = Color(0xFFF2F3F0), glassLine = Color(0x1AFFFFFF),
            accent = Color(0xFFCFF26B), onAccent = Color(0xFF121408), accentEdge = Color(0xFFE4FF9A),
            tick = Color(0x2EFFFFFF), tickMajor = Color(0xFF80857D), sel = Color(0xFFCFF26B), selSoft = Color(0x24CFF26B),
            browse = Color(0xFFFF9F43), edited = Color(0xFFFF9F43),
            scrim = Color(0x8C000000), sheet = Color(0xFF17191C), danger = Color(0xFFFF8A7A),
            segmentOn = Color(0xFFF2F3F0),
            // rgba(207,242,107,0.17): 0.17 × 255 = 43.35 → 0x2B.
            pill = Color(0x2BCFF26B), pillInk = Color(0xFFE2F99F), isDark = true,
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
            primary = colors.ink, onPrimary = colors.onInk, secondary = colors.sel, background = colors.bg, onBackground = colors.ink,
            surface = colors.bg, onSurface = colors.ink, surfaceVariant = colors.bg2, onSurfaceVariant = colors.ink2,
            outline = colors.hair, error = colors.danger,
        )
    } else {
        lightColorScheme(
            primary = colors.ink, onPrimary = colors.onInk, secondary = colors.sel, background = colors.bg, onBackground = colors.ink,
            surface = colors.bg, onSurface = colors.ink, surfaceVariant = colors.bg2, onSurfaceVariant = colors.ink2,
            outline = colors.hair, error = colors.danger,
        )
    }
    CompositionLocalProvider(LocalLightlyColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
