package uk.co.maybeitsadam.takt.core.theme

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

// Port of Sources/TaktCore/Theming/ThemeFile.swift.

/**
 * A theme as a user writes one: a JSON document, every field optional. This is
 * the *file*, not the theme: everything in it is a partial override of the
 * theme it `extends`. [ThemeFileLoader] merges and resolves it.
 *
 * Enumerated values (appearances, designs, weights, roles) are carried as
 * strings so that one typo is one reported issue rather than a file that
 * fails to read. The format is `docs/themes.md`.
 */
data class ThemeFile(
    val identifier: String? = null,
    val name: String? = null,
    val summary: String? = null,
    val lockedAppearance: Lock = Lock.Inherit,
    val extends: Base = Base.DefaultTheme,
    /**
     * A few colours per appearance the palette is grown from; see
     * [ThemeSeeds]. Laid under [palette], which still wins role by role.
     */
    val seeds: Palette? = null,
    val palette: Palette? = null,
    val structure: Structure? = null,
    /** Per-platform structure, laid over [structure] on that platform only. */
    val platforms: Platforms? = null,
) {
    /** What the file inherits every value it does not state from. */
    sealed interface Base {
        /** Key absent: the default theme, Priority. */
        data object DefaultTheme : Base

        /** `"extends": "<identifier>"`. */
        data class Theme(val identifier: String) : Base

        /** `"extends": null`: no colours inherited. Structure still falls back to the default's. */
        data object Nothing : Base
    }

    /** `lockedAppearance`: absent inherits, `null` clears, a string sets (or is reported). */
    sealed interface Lock {
        data object Inherit : Lock
        data object Unlocked : Lock
        data class Locked(val raw: String) : Lock
    }

    /**
     * Name → hex, per appearance: a role name under `palette`, a seed name
     * under `seeds`.
     */
    data class Palette(val light: Map<String, String>? = null, val dark: Map<String, String>? = null) {
        fun of(appearance: ThemeAppearance): Map<String, String>? =
            if (appearance == ThemeAppearance.LIGHT) light else dark
    }

    data class Radius(
        val panel: Double? = null,
        val row: Double? = null,
        val control: Double? = null,
        val pill: Double? = null,
        val shell: Double? = null,
    )

    data class Border(val hairline: Double? = null, val emphasis: Double? = null, val focusRing: Double? = null)

    data class Spacing(
        val xxs: Double? = null,
        val xs: Double? = null,
        val sm: Double? = null,
        val md: Double? = null,
        val lg: Double? = null,
        val xl: Double? = null,
    )

    data class Face(val families: List<String>? = null, val design: String? = null)

    data class TypeScale(
        val caption: Double? = null,
        val body: Double? = null,
        val title: Double? = null,
        val display: Double? = null,
        val hero: Double? = null,
    )

    data class MicroLabel(
        val size: Double? = null,
        val weight: String? = null,
        val tracking: Double? = null,
        val uppercase: Boolean? = null,
        val role: String? = null,
    )

    data class Typography(
        val display: Face? = null,
        val body: Face? = null,
        val mono: Face? = null,
        val bodySize: Double? = null,
        val scale: TypeScale? = null,
        val microLabel: MicroLabel? = null,
    )

    data class Structure(
        val radius: Radius? = null,
        val border: Border? = null,
        val spacing: Spacing? = null,
        val typography: Typography? = null,
        val touchTarget: Double? = null,
        val usesShadows: Boolean? = null,
        val usesGradientsOnChrome: Boolean? = null,
    )

    /** One platform's override. A `palette` here is read only to be reported and ignored. */
    data class PlatformOverride(val structure: Structure? = null)

    data class Platforms(
        val macos: PlatformOverride? = null,
        val ios: PlatformOverride? = null,
        val android: PlatformOverride? = null,
    ) {
        fun of(platform: ThemePlatform): PlatformOverride? = when (platform) {
            ThemePlatform.MACOS -> macos
            ThemePlatform.IOS -> ios
            ThemePlatform.ANDROID -> android
        }
    }

    // MARK: - Encoding

    /** The file as a JSON object, keys sorted, absent fields left out. */
    fun toJson(): JsonObject = obj(
        "identifier" to identifier?.let(::JsonPrimitive),
        "name" to name?.let(::JsonPrimitive),
        "summary" to summary?.let(::JsonPrimitive),
        "seeds" to seeds?.let { p ->
            obj("light" to p.light?.let(::stringTable), "dark" to p.dark?.let(::stringTable))
        },
        "palette" to palette?.let { p ->
            obj("light" to p.light?.let(::stringTable), "dark" to p.dark?.let(::stringTable))
        },
        "structure" to structure?.let(::structureJson),
        "platforms" to platforms?.let { p ->
            fun one(o: PlatformOverride?) = o?.let { obj("structure" to it.structure?.let(::structureJson)) }
            obj("macos" to one(p.macos), "ios" to one(p.ios), "android" to one(p.android))
        },
        "extends" to when (val base = extends) {
            Base.DefaultTheme -> null
            is Base.Theme -> JsonPrimitive(base.identifier)
            Base.Nothing -> JsonNull
        },
        "lockedAppearance" to when (val lock = lockedAppearance) {
            Lock.Inherit -> null
            Lock.Unlocked -> JsonNull
            is Lock.Locked -> JsonPrimitive(lock.raw)
        },
    )

    /** Pretty-printed with sorted keys, in the layout Swift's `JSONEncoder` writes, so an export diffs cleanly. */
    fun encoded(): String = ThemeJsonWriter.pretty(toJson())

    companion object {
        /**
         * Every value of [specification], stated explicitly: what "export" writes.
         * It still extends the default theme, so a role added later inherits
         * rather than going missing from an old export.
         */
        fun of(specification: ThemeSpecification): ThemeFile {
            fun table(values: Map<ThemeColorRole, ThemeColorValue>) =
                values.entries.associate { it.key.raw to it.value.hexString.lowercase() }
            fun face(face: ThemeFontFace) = Face(face.families, face.design.raw)
            val structure = specification.structure
            val type = structure.typography
            return ThemeFile(
                identifier = specification.identifier,
                name = specification.name,
                summary = specification.summary,
                lockedAppearance = specification.lockedAppearance?.let { Lock.Locked(it.raw) } ?: Lock.Unlocked,
                extends = Base.DefaultTheme,
                palette = Palette(table(specification.palette.light), table(specification.palette.dark)),
                structure = Structure(
                    radius = structure.radius.let { Radius(it.panel, it.row, it.control, it.pill, it.shell) },
                    border = structure.border.let { Border(it.hairline, it.emphasis, it.focusRing) },
                    spacing = structure.spacing.let { Spacing(it.xxs, it.xs, it.sm, it.md, it.lg, it.xl) },
                    typography = Typography(
                        display = face(type.display),
                        body = face(type.body),
                        mono = face(type.mono),
                        bodySize = type.bodySize,
                        scale = type.scale.let { TypeScale(it.caption, it.body, it.title, it.display, it.hero) },
                        microLabel = type.microLabel.let {
                            MicroLabel(it.size, it.weight.raw, it.tracking, it.isUppercased, it.role.raw)
                        },
                    ),
                    touchTarget = structure.touchTarget,
                    usesShadows = structure.usesShadows,
                    usesGradientsOnChrome = structure.usesGradientsOnChrome,
                ),
            )
        }

        private fun obj(vararg entries: Pair<String, JsonElement?>): JsonObject =
            JsonObject(entries.filter { it.second != null }.sortedBy { it.first }.associate { it.first to it.second!! })

        private fun num(value: Double?): JsonElement? = value?.let { JsonPrimitive(it) }

        private fun stringTable(table: Map<String, String>) =
            JsonObject(table.toSortedMap().mapValues { JsonPrimitive(it.value) })

        private fun structureJson(s: Structure): JsonObject = obj(
            "radius" to s.radius?.let {
                obj("panel" to num(it.panel), "row" to num(it.row), "control" to num(it.control),
                    "pill" to num(it.pill), "shell" to num(it.shell))
            },
            "border" to s.border?.let {
                obj("hairline" to num(it.hairline), "emphasis" to num(it.emphasis), "focusRing" to num(it.focusRing))
            },
            "spacing" to s.spacing?.let {
                obj("xxs" to num(it.xxs), "xs" to num(it.xs), "sm" to num(it.sm),
                    "md" to num(it.md), "lg" to num(it.lg), "xl" to num(it.xl))
            },
            "typography" to s.typography?.let { t ->
                fun face(f: Face?) = f?.let {
                    obj("families" to it.families?.let { list -> JsonArray(list.map(::JsonPrimitive)) },
                        "design" to it.design?.let(::JsonPrimitive))
                }
                obj(
                    "display" to face(t.display), "body" to face(t.body), "mono" to face(t.mono),
                    "bodySize" to num(t.bodySize),
                    "scale" to t.scale?.let {
                        obj("caption" to num(it.caption), "body" to num(it.body), "title" to num(it.title),
                            "display" to num(it.display), "hero" to num(it.hero))
                    },
                    "microLabel" to t.microLabel?.let {
                        obj("size" to num(it.size), "weight" to it.weight?.let(::JsonPrimitive),
                            "tracking" to num(it.tracking), "uppercase" to it.uppercase?.let(::JsonPrimitive),
                            "role" to it.role?.let(::JsonPrimitive))
                    },
                )
            },
            "touchTarget" to num(s.touchTarget),
            "usesShadows" to s.usesShadows?.let(::JsonPrimitive),
            "usesGradientsOnChrome" to s.usesGradientsOnChrome?.let(::JsonPrimitive),
        )
    }
}

/** A type error while reading a file, carrying the message Swift's decoder would give. */
internal class ThemeFileReadException(message: String) : Exception(message)

/**
 * Reads a [ThemeFile] out of parsed JSON with the semantics of Swift's
 * `Codable` decode: an absent or `null` optional is nil, and the first value
 * of the wrong type fails the whole file with its dotted path.
 */
internal object ThemeFileReader {
    fun read(root: JsonElement): ThemeFile {
        val o = root as? JsonObject ?: throw mismatch("", "an object")
        // Swift's decoder reads in this order, so the first bad value reported is the same one.
        return ThemeFile(
            identifier = string(o, "identifier", ""),
            name = string(o, "name", ""),
            summary = string(o, "summary", ""),
            seeds = child(o, "seeds", "")?.let { (p, path) ->
                ThemeFile.Palette(light = stringMap(p, "light", path), dark = stringMap(p, "dark", path))
            },
            palette = child(o, "palette", "")?.let { (p, path) ->
                ThemeFile.Palette(light = stringMap(p, "light", path), dark = stringMap(p, "dark", path))
            },
            structure = child(o, "structure", "")?.let { (s, path) -> structure(s, path) },
            platforms = child(o, "platforms", "")?.let { (p, path) ->
                fun one(key: String) = child(p, key, path)?.let { (entry, entryPath) ->
                    // `palette` here is never read; the schema walk reports it.
                    ThemeFile.PlatformOverride(
                        structure = child(entry, "structure", entryPath)?.let { (s, sp) -> structure(s, sp) },
                    )
                }
                ThemeFile.Platforms(macos = one("macos"), ios = one("ios"), android = one("android"))
            },
            extends = when {
                "extends" !in o -> ThemeFile.Base.DefaultTheme
                o["extends"] is JsonNull -> ThemeFile.Base.Nothing
                else -> ThemeFile.Base.Theme(string(o, "extends", "")!!)
            },
            lockedAppearance = when {
                "lockedAppearance" !in o -> ThemeFile.Lock.Inherit
                o["lockedAppearance"] is JsonNull -> ThemeFile.Lock.Unlocked
                else -> ThemeFile.Lock.Locked(string(o, "lockedAppearance", "")!!)
            },
        )
    }

    private fun structure(s: JsonObject, path: String) = ThemeFile.Structure(
        radius = child(s, "radius", path)?.let { (r, p) ->
            ThemeFile.Radius(number(r, "panel", p), number(r, "row", p), number(r, "control", p),
                number(r, "pill", p), number(r, "shell", p))
        },
        border = child(s, "border", path)?.let { (b, p) ->
            ThemeFile.Border(number(b, "hairline", p), number(b, "emphasis", p), number(b, "focusRing", p))
        },
        spacing = child(s, "spacing", path)?.let { (sp, p) ->
            ThemeFile.Spacing(number(sp, "xxs", p), number(sp, "xs", p), number(sp, "sm", p),
                number(sp, "md", p), number(sp, "lg", p), number(sp, "xl", p))
        },
        typography = child(s, "typography", path)?.let { (t, p) ->
            fun face(key: String) = child(t, key, p)?.let { (f, fp) ->
                ThemeFile.Face(families = stringList(f, "families", fp), design = string(f, "design", fp))
            }
            ThemeFile.Typography(
                display = face("display"),
                body = face("body"),
                mono = face("mono"),
                bodySize = number(t, "bodySize", p),
                scale = child(t, "scale", p)?.let { (sc, scp) ->
                    ThemeFile.TypeScale(number(sc, "caption", scp), number(sc, "body", scp), number(sc, "title", scp),
                        number(sc, "display", scp), number(sc, "hero", scp))
                },
                microLabel = child(t, "microLabel", p)?.let { (m, mp) ->
                    ThemeFile.MicroLabel(number(m, "size", mp), string(m, "weight", mp), number(m, "tracking", mp),
                        bool(m, "uppercase", mp), string(m, "role", mp))
                },
            )
        },
        touchTarget = number(s, "touchTarget", path),
        usesShadows = bool(s, "usesShadows", path),
        usesGradientsOnChrome = bool(s, "usesGradientsOnChrome", path),
    )

    private fun join(path: String, key: String) = if (path.isEmpty()) key else "$path.$key"

    private fun mismatch(path: String, expected: String) =
        ThemeFileReadException("${path.ifEmpty { "the file" }} should be $expected")

    /** A nested object under `key`, or null when absent or `null`. */
    private fun child(o: JsonObject, key: String, path: String): Pair<JsonObject, String>? {
        val value = o[key] ?: return null
        if (value is JsonNull) return null
        val childPath = join(path, key)
        return (value as? JsonObject ?: throw mismatch(childPath, "an object")) to childPath
    }

    private fun stringValue(value: JsonElement, path: String): String {
        if (value is JsonNull) throw ThemeFileReadException("$path should be a string, not null")
        val primitive = value as? JsonPrimitive
        if (primitive == null || !primitive.isString) throw mismatch(path, "a string")
        return primitive.content
    }

    private fun string(o: JsonObject, key: String, path: String): String? {
        val value = o[key] ?: return null
        if (value is JsonNull) return null
        return stringValue(value, join(path, key))
    }

    private fun number(o: JsonObject, key: String, path: String): Double? {
        val value = o[key] ?: return null
        if (value is JsonNull) return null
        val primitive = value as? JsonPrimitive
        val number = primitive?.takeIf { !it.isString && it.booleanOrNull == null }?.doubleOrNull
        return number ?: throw mismatch(join(path, key), "a number")
    }

    private fun bool(o: JsonObject, key: String, path: String): Boolean? {
        val value = o[key] ?: return null
        if (value is JsonNull) return null
        val primitive = value as? JsonPrimitive
        return primitive?.takeIf { !it.isString }?.booleanOrNull ?: throw mismatch(join(path, key), "true or false")
    }

    private fun stringMap(o: JsonObject, key: String, path: String): Map<String, String>? {
        val (table, tablePath) = child(o, key, path) ?: return null
        return table.mapValues { (role, value) -> stringValue(value, join(tablePath, role)) }
    }

    private fun stringList(o: JsonObject, key: String, path: String): List<String>? {
        val value = o[key] ?: return null
        if (value is JsonNull) return null
        val listPath = join(path, key)
        // Swift's decoder names the expectation `[Any]`, which its describer calls "an object".
        val array = value as? JsonArray ?: throw mismatch(listPath, "an object")
        return array.mapIndexed { index, element -> stringValue(element, "$listPath.$index") }
    }
}

/** Writes JSON the way `JSONEncoder` with `.prettyPrinted, .sortedKeys` does. */
internal object ThemeJsonWriter {
    fun pretty(element: JsonElement): String = StringBuilder().also { write(element, it, 0) }.toString()

    private fun write(element: JsonElement, out: StringBuilder, depth: Int) {
        val indent = "  ".repeat(depth + 1)
        val closing = "  ".repeat(depth)
        when (element) {
            is JsonObject -> {
                if (element.isEmpty()) { out.append("{\n\n").append(closing).append("}"); return }
                out.append("{\n")
                element.entries.sortedBy { it.key }.forEachIndexed { index, (key, value) ->
                    out.append(indent).append(JsonPrimitive(key).toString()).append(" : ")
                    write(value, out, depth + 1)
                    if (index < element.size - 1) out.append(",")
                    out.append("\n")
                }
                out.append(closing).append("}")
            }
            is JsonArray -> {
                if (element.isEmpty()) { out.append("[\n\n").append(closing).append("]"); return }
                out.append("[\n")
                element.forEachIndexed { index, value ->
                    out.append(indent)
                    write(value, out, depth + 1)
                    if (index < element.size - 1) out.append(",")
                    out.append("\n")
                }
                out.append(closing).append("]")
            }
            is JsonNull -> out.append("null")
            is JsonPrimitive -> out.append(
                if (!element.isString && element.doubleOrNull != null && element.booleanOrNull == null) {
                    number(element.content.toDouble())
                } else {
                    element.toString()
                },
            )
        }
    }

    /** `13`, not `13.0`; `0.15` as is. */
    fun number(value: Double): String =
        if (value == kotlin.math.floor(value) && kotlin.math.abs(value) < 1e15) value.toLong().toString() else value.toString()
}
