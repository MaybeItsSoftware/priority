package uk.co.maybeitsadam.priority.core.theme

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject

/**
 * One conformance case: theme files in, the resolved theme out per platform
 * and appearance.
 *
 * ```
 * { "files": { "dusk.json": { …a theme file… } },
 *   "expected": { "android": { "dark": { "dusk.json": { …snapshot… } } } } }
 * ```
 *
 * A snapshot is [snapshot]'s shape, or `{ "skipped": "<reason>" }`. Only the
 * keys a case states are compared, so a case can pin as much as it means to.
 */
object ThemeConformance {
    fun check(caseName: String, text: String): List<String> {
        val case = Json.parseToJsonElement(text).jsonObject
        val files = case["files"] as? JsonObject ?: return listOf("$caseName: no \"files\"")
        val sources = files.map { (name, body) ->
            ThemeFileSource(name, if (body is JsonPrimitive && body.isString) body.content else body.toString())
        }
        val expected = case["expected"] as? JsonObject ?: return listOf("$caseName: no \"expected\"")
        val failures = mutableListOf<String>()
        for ((platformKey, byAppearance) in expected) {
            val platform = ThemePlatform.of(platformKey)
                ?: run { failures += "$caseName: unknown platform $platformKey"; null } ?: continue
            val library = ThemeFileLoader.load(sources, platform)
            for ((appearanceKey, bySource) in byAppearance.jsonObject) {
                val appearance = ThemeAppearance.of(appearanceKey)
                    ?: run { failures += "$caseName: unknown appearance $appearanceKey"; null } ?: continue
                for ((sourceName, want) in bySource.jsonObject) {
                    val outcome = library.outcomes.firstOrNull { it.source == sourceName }
                    val actual = when {
                        outcome == null -> JsonObject(mapOf("skipped" to JsonPrimitive("no such file")))
                        outcome.specification == null -> JsonObject(mapOf("skipped" to JsonPrimitive(outcome.skippedReason)))
                        else -> snapshot(outcome.specification, appearance, outcome.issues)
                    }
                    compare(want, actual, "$caseName $platformKey/$appearanceKey $sourceName", failures)
                }
            }
        }
        return failures
    }

    /** A resolved theme as one appearance draws it. */
    fun snapshot(spec: ThemeSpecification, appearance: ThemeAppearance, issues: List<ThemeFileIssue>): JsonObject {
        val effective = spec.lockedAppearance ?: appearance
        val file = ThemeFile.of(spec).toJson()
        return JsonObject(
            mapOf(
                "identifier" to JsonPrimitive(spec.identifier),
                "name" to JsonPrimitive(spec.name),
                "summary" to JsonPrimitive(spec.summary),
                "lockedAppearance" to (spec.lockedAppearance?.let { JsonPrimitive(it.raw) } ?: JsonNull),
                "appearance" to JsonPrimitive(effective.raw),
                "colors" to JsonObject(ThemeColorRole.entries.associate { it.raw to JsonPrimitive(spec.color(it, effective).hexString) }),
                "structure" to file["structure"]!!,
                "issues" to JsonArray(issues.map { JsonPrimitive(it.message) }),
            ),
        )
    }

    private fun compare(want: JsonElement, actual: JsonElement?, path: String, failures: MutableList<String>) {
        when (want) {
            is JsonObject -> {
                val got = actual as? JsonObject ?: run { failures += "$path: expected an object, got $actual"; return }
                for ((key, value) in want) compare(value, got[key], "$path.$key", failures)
            }
            is JsonArray -> {
                val got = actual as? JsonArray
                if (got == null || got.size != want.size) { failures += "$path: expected $want, got $actual"; return }
                want.forEachIndexed { index, value -> compare(value, got[index], "$path.$index", failures) }
            }
            is JsonNull -> if (actual != null && actual !is JsonNull) failures += "$path: expected null, got $actual"
            is JsonPrimitive -> {
                val got = actual as? JsonPrimitive
                val same = when {
                    got == null -> false
                    !want.isString && want.booleanOrNull == null && want.doubleOrNull != null ->
                        got.doubleOrNull != null && kotlin.math.abs(got.doubleOrNull!! - want.doubleOrNull!!) < 1e-9
                    want.isString && want.content.startsWith("#") -> got.content.equals(want.content, ignoreCase = true)
                    else -> got.content == want.content
                }
                if (!same) failures += "$path: expected $want, got $actual"
            }
        }
    }
}
