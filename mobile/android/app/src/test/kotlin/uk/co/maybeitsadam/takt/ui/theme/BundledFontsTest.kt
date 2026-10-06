package uk.co.maybeitsadam.takt.ui.theme

import java.io.File
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.theme.BuiltInThemeSpecifications
import uk.co.maybeitsadam.takt.core.theme.ThemePlatform

/**
 * The default theme ("Takt", `priority.json`) names Inter and Geist Mono.
 * They must resolve to the bundled faces, not the system fallback, and the
 * files they come from must be in `res/font`, or the default theme quietly
 * renders in Roboto.
 */
class BundledFontsTest {
    private val typography = BuiltInThemeSpecifications.defaultTheme(ThemePlatform.ANDROID).structure.typography

    @Test fun theDefaultThemeResolvesToTheBundledInterAndGeistMono() {
        assertSame(Fonts.inter, Fonts.resolve(typography.body))
        assertSame(Fonts.inter, Fonts.resolve(typography.display))
        assertSame(Fonts.geistMono, Fonts.resolve(typography.mono))
    }

    @Test fun theFaceFilesAreBundled() {
        val fonts = File("src/main/res/font")
        for (name in listOf("inter_regular", "inter_medium", "inter_semibold", "inter_bold", "inter_italic",
            "geistmono_regular", "geistmono_medium", "geistmono_bold")) {
            val file = File(fonts, "$name.ttf")
            assertTrue("$file is missing", file.isFile && file.length() > 10_000)
        }
    }
}
