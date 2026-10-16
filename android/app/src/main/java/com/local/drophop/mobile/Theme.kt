package com.local.drophop.mobile

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

// Same palette as the iPhone app: warm black, cream, one orange accent.
object Palette {
    val Backdrop = Color(0.075f, 0.065f, 0.06f)
    val BackdropTop = Color(0.18f, 0.10f, 0.08f)
    val Cream = Color(0.96f, 0.93f, 0.87f)
    val CreamInk = Color(0.12f, 0.10f, 0.09f)
    val Tile = Color(0.94f, 0.90f, 0.83f)
    val TileIcon = Color(0.28f, 0.23f, 0.20f)
    val Accent = Color(1.0f, 0.36f, 0.17f)
    val Online = Color(0.42f, 0.83f, 0.58f)
    val Error = Color(1.0f, 0.27f, 0.23f)

    val ShelfGradient = Brush.linearGradient(
        colors = listOf(BackdropTop, Backdrop, Color.Black),
        start = androidx.compose.ui.geometry.Offset(0f, 0f),
        end = androidx.compose.ui.geometry.Offset(1400f, 2800f),
    )
}

fun White(alpha: Float) = Color.White.copy(alpha = alpha)

/** Small spaced-out monospaced label, like "ON THE SHELF". */
fun mono(size: Int, weight: FontWeight = FontWeight.Bold, spacing: Float = 1.2f, color: Color = Color.White): TextStyle =
    TextStyle(
        fontFamily = FontFamily.Monospace,
        fontSize = size.sp,
        fontWeight = weight,
        letterSpacing = spacing.sp,
        color = color,
    )

@Composable
fun DropHopTheme(content: @Composable () -> Unit) {
    // The iPhone shelf is always dark, so the whole app is.
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.Accent,
            onPrimary = Color.White,
            background = Palette.Backdrop,
            surface = Palette.Backdrop,
            onSurface = Color.White,
            onBackground = Color.White,
            surfaceContainerHigh = Color(0.12f, 0.105f, 0.095f),
            surfaceContainerLow = Color(0.10f, 0.09f, 0.082f),
            error = Palette.Error,
        ),
        content = content,
    )
}
