package app.smallthingz.dict

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

val Editorial = FontFamily(Font(R.font.newsreader))
private val Paper = lightColorScheme(
    primary = Color(0xFF855332), onPrimary = Color(0xFFFFF8ED),
    primaryContainer = Color(0xFFE9D6BE), onPrimaryContainer = Color(0xFF402715),
    background = Color(0xFFF4F0E7), surface = Color(0xFFF4F0E7), onSurface = Color(0xFF283B34),
    onBackground = Color(0xFF283B34), onSurfaceVariant = Color(0xFF627169),
    surfaceContainerLow = Color(0xFFEDE8DD), surfaceContainer = Color(0xFFE7E2D6),
    surfaceContainerHigh = Color(0xFFDDD8CA), outline = Color(0xFF7B8176), outlineVariant = Color(0xFFCBCDBF),
    secondaryContainer = Color(0xFFDCE4D4), onSecondaryContainer = Color(0xFF283B34),
)
private val Ink = darkColorScheme(
    primary = Color(0xFFE5B58C), onPrimary = Color(0xFF382417),
    primaryContainer = Color(0xFF493B2D), onPrimaryContainer = Color(0xFFF4D7B8),
    background = Color(0xFF18221E), surface = Color(0xFF18221E), onSurface = Color(0xFFE8E5D7),
    onBackground = Color(0xFFE8E5D7), onSurfaceVariant = Color(0xFFA5B2A7),
    surfaceContainerLow = Color(0xFF202D26), surfaceContainer = Color(0xFF29352C),
    surfaceContainerHigh = Color(0xFF354036), outline = Color(0xFF929E90), outlineVariant = Color(0xFF465348),
    secondaryContainer = Color(0xFF354738), onSecondaryContainer = Color(0xFFE8E5D7),
)
private val Type = Typography(
    displayMedium = TextStyle(fontFamily = Editorial, fontSize = 68.sp, lineHeight = 70.sp, letterSpacing = (-2).sp),
    headlineMedium = TextStyle(fontFamily = Editorial, fontSize = 38.sp, lineHeight = 42.sp),
    titleLarge = TextStyle(fontFamily = Editorial, fontSize = 27.sp, lineHeight = 32.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.Medium, fontSize = 17.sp, lineHeight = 23.sp),
    bodyLarge = TextStyle(fontFamily = Editorial, fontSize = 20.sp, lineHeight = 27.sp),
    bodyMedium = TextStyle(fontSize = 15.sp, lineHeight = 22.sp),
    bodySmall = TextStyle(fontSize = 13.sp, lineHeight = 19.sp),
    labelSmall = TextStyle(fontSize = 11.sp, lineHeight = 16.sp, letterSpacing = 1.4.sp),
)
@Composable
fun DictTheme(mode: String, content: @Composable () -> Unit) {
    val dark = when (mode) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
    val view = LocalView.current
    SideEffect {
        (view.context as? Activity)?.window?.let { window ->
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    MaterialTheme(colorScheme = if (dark) Ink else Paper, typography = Type, content = content)
}
