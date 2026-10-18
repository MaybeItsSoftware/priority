package uk.co.maybeitsadam.takt.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uk.co.maybeitsadam.takt.R
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/*
 * The two sign-in buttons that set the theme aside: their colours, marks and
 * type are the brands', because the marks aren't ours to recolour. The shape
 * is Takt's — flat, at the theme's control radius, a hairline instead of a
 * shadow — and the appearance is the theme's, so a dark theme gets the dark
 * buttons. The Mac and the iPhone draw the same (`SyncProviderButton`).
 */

/** Google Sans Medium, subset to "Sign in with Google" (`res/font`, OFL). */
private val GoogleSans = FontFamily(Font(R.font.google_sans_sign_in_medium, FontWeight.Medium))

/**
 * "Sign in with Google", to Google's branding guidelines
 * (developers.google.com/identity/branding-guidelines): the standard-colour
 * "G" from Google's download kit at 20dp, Google Sans Medium 14/20, 12dp to
 * the logo and 10dp to the words, and the light (#FFFFFF, #747775 hairline,
 * #1F1F1F text) or dark (#131314, #8E918F, #E3E3E3) button.
 */
@Composable
fun SignInWithGoogleButton(modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val dark = TaktTheme.colors.isDark
    BrandButton(
        label = "Sign in with Google",
        fill = if (dark) Color(0xFF131314) else Color.White,
        border = if (dark) Color(0xFF8E918F) else Color(0xFF747775),
        text = if (dark) Color(0xFFE3E3E3) else Color(0xFF1F1F1F),
        style = TextStyle(fontFamily = GoogleSans, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
        gap = 10.dp,
        padding = PaddingValues(horizontal = 12.dp),
        modifier = modifier,
        enabled = enabled,
        onClick = onClick,
    ) {
        Image(painterResource(R.drawable.ic_google_g), contentDescription = null, modifier = Modifier.size(20.dp))
    }
}

/**
 * "Sign in with Apple", to Apple's guidelines for a custom button: black
 * with white in a light appearance, white with black in a dark one, the
 * Apple logo from Apple's own artwork, and the system font.
 */
@Composable
fun SignInWithAppleButton(modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val dark = TaktTheme.colors.isDark
    val ink = if (dark) Color.Black else Color.White
    BrandButton(
        label = "Sign in with Apple",
        fill = if (dark) Color.White else Color.Black,
        border = if (dark) Color.White else Color.Black,
        text = ink,
        style = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Medium, fontSize = 16.sp),
        gap = 6.dp,
        padding = PaddingValues(horizontal = 16.dp),
        modifier = modifier,
        enabled = enabled,
        onClick = onClick,
    ) {
        Icon(painterResource(R.drawable.ic_apple_logo), contentDescription = null, tint = ink, modifier = Modifier.size(14.dp, 17.dp))
    }
}

@Composable
private fun BrandButton(
    label: String,
    fill: Color,
    border: Color,
    text: Color,
    style: TextStyle,
    gap: Dp,
    padding: PaddingValues,
    modifier: Modifier,
    enabled: Boolean,
    onClick: () -> Unit,
    mark: @Composable () -> Unit,
) {
    val shape = Metrics.control
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Row(
        modifier
            .heightIn(min = 48.dp)
            .clip(shape)
            .background(fill)
            // Material's pressed state layer, the text colour at 12%.
            .background(if (pressed) text.copy(alpha = 0.12f) else Color.Transparent)
            .border(BorderStroke(Metrics.hairline, if (enabled) border else border.copy(alpha = 0.12f)), shape)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .padding(padding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(gap, Alignment.CenterHorizontally),
    ) {
        // Material's disabled state, which Google's buttons follow: 38%.
        Row(
            Modifier.alpha(if (enabled) 1f else 0.38f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(gap),
        ) {
            mark()
            Text(label, style = style, color = text, maxLines = 1)
        }
    }
}
