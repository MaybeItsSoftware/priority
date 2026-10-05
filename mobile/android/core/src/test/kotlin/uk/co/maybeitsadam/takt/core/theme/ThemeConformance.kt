package uk.co.maybeitsadam.takt.core.theme

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Runs one case from `shared/themes/conformance/` the way
 * `shared/themes/README.md` describes, and says how Kotlin differs from it.
 */
object ThemeConformance {
    /** Every way Kotlin's resolution differs from the case; empty when it conforms. */
    fun check(name: String, text: String): List<String> {
        val case = Json.parseToJsonElement(text).jsonObject
        val files = case["files"]?.jsonArray ?: return listOf("$name: no \"files\"")
        val sources = files.map {
            val file = it.jsonObject
            ThemeFileSource(file.getValue("name").jsonPrimitive.content, file.getValue("json").jsonPrimitive.content)
        }
        val selected = case["selected"]?.jsonPrimitive?.content
        val failures = mutableListOf<String>()

        val expectedIssues = case["issues"]?.jsonArray.orEmpty().map { it.jsonObject }
        for (platform in ThemePlatform.entries) {
            val library = ThemeFileLoader.load(sources, platform)
            val chosen = library.themes.firstOrNull { it.identifier == selected }
                ?: BuiltInThemeSpecifications.all(platform).firstOrNull { it.identifier == selected }
                ?: BuiltInThemeSpecifications.defaultTheme(platform)

            // The file's own issues, the audit left out, the same on every platform.
            val issues = library.issues.filterNot { it.isAudit }
            val shape = { i: ThemeFileIssue -> "${i.source} ${i.severity.raw}" }
            val expectedShape = expectedIssues.map { "${it.str("source")} ${it.str("severity")}" }
            if (issues.map(shape) != expectedShape) {
                failures += "$name ${platform.raw}: issues ${issues.map { "${shape(it)}: ${it.message}" }} " +
                    "but Swift reported ${expectedIssues.map { "${it.str("source")} ${it.str("severity")}: ${it.str("message")}" }}"
            } else {
                issues.zip(expectedIssues).forEach { (actual, expected) ->
                    if (actual.message != expected.str("message")) {
                        failures += "$name ${platform.raw}: \"${actual.message}\" is worded \"${expected.str("message")}\" in Swift"
                    }
                }
            }

            val byAppearance = case["expected"]?.jsonObject?.get(platform.raw)?.jsonObject ?: continue
            for ((appearanceRaw, expected) in byAppearance) {
                val appearance = ThemeAppearance.of(appearanceRaw) ?: continue
                val actual = snapshot(chosen, appearance)
                failures += compare(actual, expected, "$name ${platform.raw}.$appearanceRaw")
            }
        }
        return failures
    }

    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.content

    /** The canonical resolved theme of `shared/themes/README.md`. */
    fun snapshot(theme: ThemeSpecification, requested: ThemeAppearance): JsonElement {
        val appearance = theme.lockedAppearance ?: requested
        val s = theme.structure
        val t = s.typography
        fun face(face: ThemeFontFace) = buildJsonObject {
            put("families", JsonArray(face.families.map(::JsonPrimitive)))
            put("design", face.design.raw)
        }
        return buildJsonObject {
            put("identifier", theme.identifier)
            put("name", theme.name)
            put("lockedAppearance", theme.lockedAppearance?.raw?.let(::JsonPrimitive) ?: JsonNull)
            put("appearance", appearance.raw)
            put(
                "colors",
                JsonObject(ThemeColorRole.entries.associate { it.raw to JsonPrimitive(theme.color(it, appearance).hexString.lowercase()) }),
            )
            put(
                "structure",
                buildJsonObject {
                    put("radius", buildJsonObject {
                        put("panel", s.radius.panel); put("row", s.radius.row); put("control", s.radius.control)
                        put("pill", s.radius.pill); put("shell", s.radius.shell)
                    })
                    put("border", buildJsonObject {
                        put("hairline", s.border.hairline); put("emphasis", s.border.emphasis); put("focusRing", s.border.focusRing)
                    })
                    put("spacing", buildJsonObject {
                        put("xxs", s.spacing.xxs); put("xs", s.spacing.xs); put("sm", s.spacing.sm)
                        put("md", s.spacing.md); put("lg", s.spacing.lg); put("xl", s.spacing.xl)
                    })
                    put("typography", buildJsonObject {
                        put("display", face(t.display)); put("body", face(t.body)); put("mono", face(t.mono))
                        put("bodySize", t.bodySize)
                        put("scale", buildJsonObject {
                            put("caption", t.scale.caption); put("body", t.scale.body); put("title", t.scale.title)
                            put("display", t.scale.display); put("hero", t.scale.hero)
                        })
                        put("microLabel", buildJsonObject {
                            put("size", t.microLabel.size); put("weight", t.microLabel.weight.raw)
                            put("tracking", t.microLabel.tracking); put("uppercase", t.microLabel.isUppercased)
                            put("role", t.microLabel.role.raw)
                        })
                    })
                    put("touchTarget", s.touchTarget)
                    put("usesShadows", s.usesShadows)
                    put("usesGradientsOnChrome", s.usesGradientsOnChrome)
                },
            )
        }
    }

    /** Parsed-JSON comparison, numbers compared numerically, naming the path of each difference. */
    fun compare(actual: JsonElement, expected: JsonElement, path: String): List<String> = when {
        expected is JsonObject && actual is JsonObject -> (expected.keys + actual.keys).sorted().flatMap { key ->
            val a = actual[key]
            val e = expected[key]
            when {
                a == null -> listOf("$path.$key: missing from Kotlin's resolution")
                e == null -> listOf("$path.$key: Kotlin has it, Swift does not")
                else -> compare(a, e, "$path.$key")
            }
        }
        expected is JsonArray && actual is JsonArray ->
            if (expected.size != actual.size) {
                listOf("$path: $actual, expected $expected")
            } else {
                expected.indices.flatMap { compare(actual[it], expected[it], "$path[$it]") }
            }
        expected is JsonPrimitive && actual is JsonPrimitive -> {
            val en = if (expected.isString) null else expected.doubleOrNull
            val an = if (actual.isString) null else actual.doubleOrNull
            val same = if (en != null && an != null) en == an else expected == actual
            if (same) emptyList() else listOf("$path: $actual, expected $expected")
        }
        else -> if (actual == expected) emptyList() else listOf("$path: $actual, expected $expected")
    }
}
