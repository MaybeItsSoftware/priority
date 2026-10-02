package uk.co.maybeitsadam.priority.ui.theme

import androidx.compose.runtime.Immutable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/** Whether the app follows the system, or holds one appearance. */
enum class ThemeMode(val raw: String, val title: String) {
    SYSTEM("system", "System"),
    LIGHT("light", "Light"),
    DARK("dark", "Dark");

    companion object {
        fun of(raw: String?): ThemeMode = entries.firstOrNull { it.raw == raw } ?: SYSTEM
    }
}

/**
 * A theme: a name and a palette for each appearance. Built-ins are Chalk and
 * Chalk Dark; imported files are read by [ThemeJson] in the `docs/themes.md`
 * format, where every field is optional and missing ones come from Chalk.
 */
@Immutable
data class ThemeSpec(
    val identifier: String,
    val name: String,
    val light: ChalkPalette,
    val dark: ChalkPalette,
    /** "light" or "dark" when the theme only has one appearance. */
    val lockedAppearance: String? = null,
) {
    companion object {
        val Chalk = ThemeSpec("native.theme.chalk", "Chalk", ChalkPalette.ChalkLight, ChalkPalette.ChalkDark)
        val ChalkDark = ThemeSpec(
            "native.theme.chalk.dark", "Chalk Dark", ChalkPalette.ChalkDark, ChalkPalette.ChalkDark, "dark",
        )
        val builtIns = listOf(Chalk, ChalkDark)
    }
}

class ThemeImportException(message: String) : Exception(message)

/** Reads a theme file. Unknown keys are ignored; a bad colour is an error, so a typo is not silently Chalk. */
object ThemeJson {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun parse(text: String): ThemeSpec {
        val root = try {
            json.parseToJsonElement(text) as? JsonObject
        } catch (error: Exception) {
            throw ThemeImportException("That file is not JSON: ${error.message}")
        } ?: throw ThemeImportException("A theme file is a JSON object.")
        fun string(key: String) = (root[key] as? JsonPrimitive)?.contentOrNull
        val base = ThemeSpec.builtIns.firstOrNull { it.identifier == string("extends") } ?: ThemeSpec.Chalk
        val palette = root["palette"] as? JsonObject
        fun apply(start: ChalkPalette, key: String): ChalkPalette {
            val overrides = palette?.get(key)?.jsonObject ?: return start
            var result = start
            for ((role, value) in overrides) {
                val hex = (value as? JsonPrimitive)?.contentOrNull ?: continue
                val color = parseHexColor(hex) ?: throw ThemeImportException("\"$hex\" for $key.$role is not a colour.")
                result = result.with(role, color)
            }
            return result
        }
        val name = string("name")?.takeIf { it.isNotBlank() } ?: throw ThemeImportException("A theme needs a name.")
        return ThemeSpec(
            identifier = string("identifier") ?: "user.${name.lowercase().replace(Regex("[^a-z0-9]+"), "-")}",
            name = name,
            light = apply(base.light, "light"),
            dark = apply(base.dark, "dark"),
            lockedAppearance = string("lockedAppearance") ?: base.lockedAppearance,
        )
    }
}
