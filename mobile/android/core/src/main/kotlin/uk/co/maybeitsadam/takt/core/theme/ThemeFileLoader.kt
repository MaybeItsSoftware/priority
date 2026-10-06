package uk.co.maybeitsadam.takt.core.theme

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Port of Sources/TaktCore/Theming/ThemeFileLoader.swift.

/**
 * Something a theme file got wrong, in a sentence someone editing it can act
 * on. Never fatal: a bad value is skipped and the value it would have
 * replaced stays; only a theme that cannot paint every role is dropped.
 */
data class ThemeFileIssue(
    val source: String,
    val severity: ThemeIssueSeverity,
    val message: String,
    /**
     * A finding of the `validate()` audit of the theme the file produced, as
     * opposed to something the file says. Audit findings depend on the
     * platform the theme was resolved for; everything else does not.
     */
    val isAudit: Boolean = false,
) {
    override fun toString(): String = "$source: $message"
}

/** One file's text, named (`dusk.json`). */
data class ThemeFileSource(val name: String, val text: String)

/** What became of one file. */
data class ThemeFileOutcome(
    val source: String,
    /** Null when the theme was skipped; [skippedReason] says why. */
    val specification: ThemeSpecification?,
    val skippedReason: String?,
    /** Everything reported about this file, worst first, including the audit of the theme it produced. */
    val issues: List<ThemeFileIssue>,
)

/** A folder (or table) of theme files, loaded. */
data class ThemeFileLibrary(val outcomes: List<ThemeFileOutcome>) {
    /** The themes that loaded, in file-name order. */
    val themes: List<ThemeSpecification> get() = outcomes.mapNotNull { it.specification }

    val issues: List<ThemeFileIssue> get() = outcomes.flatMap { it.issues }

    companion object {
        val EMPTY = ThemeFileLibrary(emptyList())
    }
}

/** Turns theme files into [ThemeSpecification]s for one platform: decodes, follows `extends`, merges, audits. */
object ThemeFileLoader {
    const val FILE_EXTENSION = "json"

    /** A theme with no `identifier` is named after its file under this prefix. */
    const val DERIVED_IDENTIFIER_PREFIX = "user."

    private val json = Json

    /**
     * Decodes one file. A document that is not a theme is null plus the
     * reason; keys the format does not have are warnings.
     */
    fun decode(text: String, source: String): Pair<ThemeFile?, List<ThemeFileIssue>> {
        val element: JsonElement = try {
            json.parseToJsonElement(text)
        } catch (_: Exception) {
            return null to listOf(ThemeFileIssue(source, ThemeIssueSeverity.ERROR, "not valid JSON"))
        }
        val file = try {
            ThemeFileReader.read(element)
        } catch (error: ThemeFileReadException) {
            return null to listOf(ThemeFileIssue(source, ThemeIssueSeverity.ERROR, error.message ?: "not a theme file"))
        }
        val issues = ThemeFileSchema.unknownKeys(element).map { path ->
            ThemeFileIssue(
                source, ThemeIssueSeverity.WARNING,
                if (ThemeFileSchema.isPlatformPalette(path)) {
                    "$path is not allowed: colour is the same on every platform; ignored"
                } else {
                    "$path is not a theme setting; ignored"
                },
            )
        }
        return file to issues
    }

    /**
     * Lays a partial [overrides] over [base] exactly as a theme file's own
     * `structure` is laid over its base: each bad value is reported and leaves
     * the base's value standing. Swift's `ThemeFileLoader.merge(_:over:)`.
     */
    fun merge(
        overrides: ThemeFile.Structure?,
        base: ThemeStructure,
        path: String = "structure",
        report: (ThemeIssueSeverity, String) -> Unit = { _, _ -> },
    ): ThemeStructure = ThemeFileMerger.mergeStructure(overrides, base, path, report)

    /**
     * Loads every source for [platform], resolving `extends` against
     * [builtIns] and against each other. Sources are taken in name order; an
     * identifier that is a built-in's, or already taken, is skipped.
     */
    fun load(
        sources: List<ThemeFileSource>,
        platform: ThemePlatform,
        builtIns: List<ThemeSpecification> = BuiltInThemeSpecifications.all(platform),
        defaultBase: ThemeSpecification = builtIns.firstOrNull {
            it.identifier == BuiltInThemeSpecifications.DEFAULT_IDENTIFIER
        } ?: BuiltInThemeSpecifications.defaultTheme(platform),
    ): ThemeFileLibrary {
        val ordered = sources.sortedBy { it.name }
        val builtInsByIdentifier = LinkedHashMap<String, ThemeSpecification>()
        for (builtIn in builtIns) builtInsByIdentifier.putIfAbsent(builtIn.identifier, builtIn)

        data class Candidate(val source: String, val file: ThemeFile, val issues: List<ThemeFileIssue>)

        val outcomes = HashMap<String, ThemeFileOutcome>()
        val candidates = HashMap<String, Candidate>()

        for (source in ordered) {
            val (file, issues) = decode(source.text, source.name)
            if (file == null) {
                outcomes[source.name] = skipped(source.name, "could not be read", issues)
                continue
            }
            val identifier = identifier(file, source.name)
            val earlier = candidates[identifier]
            when {
                builtInsByIdentifier.containsKey(identifier) -> outcomes[source.name] = skipped(
                    source.name, "identifier \"$identifier\" is a built-in theme's; give it one of its own", issues,
                )
                earlier != null -> outcomes[source.name] = skipped(
                    source.name, "identifier \"$identifier\" is already used by ${earlier.source}", issues,
                )
                else -> candidates[identifier] = Candidate(source.name, file, issues)
            }
        }

        // Depth-first, so a theme can extend another whatever the file order.
        // `resolved` memoises (a present null is "settled, did not load");
        // `inProgress` catches a cycle.
        val resolved = HashMap<String, ThemeSpecification?>()
        val inProgress = HashSet<String>()

        fun resolve(identifier: String): ThemeSpecification? {
            if (resolved.containsKey(identifier)) return resolved[identifier]
            val candidate = candidates[identifier] ?: return null
            if (identifier in inProgress) {
                outcomes[candidate.source] =
                    skipped(candidate.source, "its extends chain comes back round to itself", candidate.issues)
                resolved[identifier] = null
                return null
            }
            inProgress += identifier
            try {
                val base: ThemeSpecification? = when (val extends = candidate.file.extends) {
                    ThemeFile.Base.DefaultTheme -> defaultBase
                    ThemeFile.Base.Nothing -> null
                    is ThemeFile.Base.Theme -> {
                        val parent = extends.identifier
                        val builtIn = builtInsByIdentifier[parent]
                        when {
                            builtIn != null -> builtIn
                            candidates.containsKey(parent) -> resolve(parent) ?: run {
                                // A cycle may already have recorded this file's own outcome.
                                if (!resolved.containsKey(identifier)) {
                                    outcomes[candidate.source] = skipped(
                                        candidate.source, "it extends \"$parent\", which did not load", candidate.issues,
                                    )
                                    resolved[identifier] = null
                                }
                                return null
                            }
                            else -> {
                                outcomes[candidate.source] = skipped(
                                    candidate.source, "it extends \"$parent\", which is not a theme", candidate.issues,
                                )
                                resolved[identifier] = null
                                return null
                            }
                        }
                    }
                }
                if (resolved.containsKey(identifier)) return resolved[identifier] // Settled by a cycle below us.

                val outcome = ThemeFileMerger.merge(
                    candidate.file, identifier, candidate.source, base, defaultBase.structure, platform,
                )
                outcomes[candidate.source] = outcome.copy(issues = sorted(candidate.issues + outcome.issues))
                resolved[identifier] = outcome.specification
                return outcome.specification
            } finally {
                inProgress -= identifier
            }
        }

        for (identifier in candidates.keys.sorted()) resolve(identifier)

        return ThemeFileLibrary(ordered.mapNotNull { outcomes[it.name] })
    }

    /** Resolves one decoded file against a base (null inherits no colours). The single-file path, for tests and tooling. */
    fun resolve(
        file: ThemeFile,
        source: String,
        base: ThemeSpecification?,
        platform: ThemePlatform,
    ): ThemeFileOutcome = ThemeFileMerger.merge(
        file, identifier(file, source), source, base, BuiltInThemeSpecifications.defaultTheme(platform).structure,
        platform,
    )

    /** The file's own identifier, or one derived from its name. */
    fun identifier(file: ThemeFile, source: String): String {
        val stated = file.identifier?.trim()
        return if (!stated.isNullOrEmpty()) stated else DERIVED_IDENTIFIER_PREFIX + stem(source)
    }

    /** `dusk.json` → `dusk`. */
    fun stem(source: String): String = source.removeSuffix(".$FILE_EXTENSION")

    private fun skipped(source: String, reason: String, issues: List<ThemeFileIssue>) = ThemeFileOutcome(
        source = source, specification = null, skippedReason = reason,
        issues = sorted(listOf(ThemeFileIssue(source, ThemeIssueSeverity.ERROR, "not loaded: $reason")) + issues),
    )

    /** Worst first, stable within a severity. */
    internal fun sorted(issues: List<ThemeFileIssue>): List<ThemeFileIssue> =
        issues.sortedByDescending { it.severity.rank }
}

/** Lays one file over its base. Each bad value is one issue and leaves the base's value standing. */
internal object ThemeFileMerger {
    private typealias Report = (ThemeIssueSeverity, String) -> Unit

    fun merge(
        file: ThemeFile,
        identifier: String,
        source: String,
        base: ThemeSpecification?,
        structureFallback: ThemeStructure,
        platform: ThemePlatform,
    ): ThemeFileOutcome {
        val issues = mutableListOf<ThemeFileIssue>()
        val report: Report = { severity, message -> issues += ThemeFileIssue(source, severity, message) }

        // Seeds, then palette: the base's table, the roles grown from the
        // seeds this file gives for the appearance (over the seeds the base
        // implies), then the roles the file states outright.
        fun seeded(
            appearance: ThemeAppearance,
            table: Map<ThemeColorRole, ThemeColorValue>,
        ): Map<ThemeColorRole, ThemeColorValue> {
            val raw = file.seeds?.of(appearance) ?: return table
            var stated = ThemeSeeds()
            for (key in raw.keys.sorted()) {
                val value = raw[key] ?: ""
                val seed = ThemeSeeds.Key.of(key)
                if (seed == null) {
                    report(
                        ThemeIssueSeverity.WARNING,
                        "seeds.${appearance.raw}.$key is not a seed " +
                            "(background, foreground, accent, success, danger or warning); ignored",
                    )
                    continue
                }
                val color = ThemeColorValue.hex(value)
                if (color == null) {
                    report(
                        ThemeIssueSeverity.ERROR,
                        "seeds.${appearance.raw}.$key \"$value\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)",
                    )
                    continue
                }
                stated = stated.with(seed, color)
            }
            val seeds = ThemeSeeds.implicitIn(table).overlaid(stated)
            val roles = seeds.roles(appearance)
            if (roles == null) {
                report(ThemeIssueSeverity.ERROR, "seeds.${appearance.raw} needs a background and a foreground; ignored")
                return table
            }
            return LinkedHashMap(table).apply { putAll(roles) }
        }

        fun table(appearance: ThemeAppearance, overrides: Map<String, String>?): Map<ThemeColorRole, ThemeColorValue> {
            val table = LinkedHashMap(seeded(appearance, base?.palette?.table(appearance) ?: emptyMap()))
            for (key in (overrides ?: emptyMap()).keys.sorted()) {
                val raw = overrides?.get(key) ?: ""
                val role = ThemeColorRole.of(key)
                if (role == null) {
                    report(ThemeIssueSeverity.WARNING, "palette.${appearance.raw}.$key is not a colour role; ignored")
                    continue
                }
                val value = ThemeColorValue.hex(raw)
                if (value == null) {
                    report(
                        ThemeIssueSeverity.ERROR,
                        "palette.${appearance.raw}.$key \"$raw\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)",
                    )
                    continue
                }
                table[role] = value
            }
            return table
        }
        val palette = ThemePalette(
            light = table(ThemeAppearance.LIGHT, file.palette?.light),
            dark = table(ThemeAppearance.DARK, file.palette?.dark),
        )

        // A role in neither table would paint magenta: the one thing that stops a theme loading.
        val unpainted = ThemeColorRole.entries.filter { palette.light[it] == null && palette.dark[it] == null }
        if (unpainted.isNotEmpty()) {
            val reason = "no colour for ${unpainted.joinToString(", ") { it.raw }}"
            return ThemeFileOutcome(
                source, null, reason,
                ThemeFileLoader.sorted(listOf(ThemeFileIssue(source, ThemeIssueSeverity.ERROR, "not loaded: $reason")) + issues),
            )
        }

        var lockedAppearance = base?.lockedAppearance
        when (val lock = file.lockedAppearance) {
            ThemeFile.Lock.Inherit -> Unit
            ThemeFile.Lock.Unlocked -> lockedAppearance = null
            is ThemeFile.Lock.Locked -> {
                val appearance = ThemeAppearance.of(lock.raw)
                if (appearance != null) {
                    lockedAppearance = appearance
                } else {
                    report(ThemeIssueSeverity.ERROR, "lockedAppearance \"${lock.raw}\" should be \"light\", \"dark\" or null")
                }
            }
        }

        // The base (already resolved for this platform), then the theme's
        // structure, then its entry for this platform. Every platform's entry
        // is checked, so a bad value for the phone is reported on the Mac too,
        // but only this platform's is used.
        var structure = mergeStructure(file.structure, base?.structure ?: structureFallback, "structure", report)
        for (candidate in ThemePlatform.entries) {
            val entry = file.platforms?.of(candidate)?.structure ?: continue
            val merged = mergeStructure(entry, structure, "platforms.${candidate.raw}.structure", report)
            if (candidate == platform) structure = merged
        }

        val specification = ThemeSpecification(
            identifier = identifier,
            name = nonEmpty(file.name) ?: ThemeFileLoader.stem(source),
            summary = nonEmpty(file.summary) ?: "Your theme, from $source.",
            lockedAppearance = lockedAppearance,
            palette = palette,
            structure = structure,
        )
        for (finding in specification.validate()) {
            // A missing role is a fact about the file; the rest is the audit.
            issues += ThemeFileIssue(source, finding.severity, finding.message, isAudit = finding !is ThemeIssue.MissingRole)
        }
        return ThemeFileOutcome(source, specification, null, ThemeFileLoader.sorted(issues))
    }

    fun mergeStructure(
        overrides: ThemeFile.Structure?,
        base: ThemeStructure,
        prefix: String,
        report: Report,
    ): ThemeStructure {
        if (overrides == null) return base

        fun length(value: Double?, fallback: Double, path: String, positive: Boolean = false): Double {
            if (value == null) return fallback
            val ok = value.isFinite() && if (positive) value > 0 else value >= 0
            if (!ok) {
                report(ThemeIssueSeverity.ERROR, "$prefix.$path ${number(value)} should be ${if (positive) "above zero" else "zero or more"}")
                return fallback
            }
            return value
        }

        val radius = overrides.radius?.let { f ->
            ThemeRadiusScale(
                panel = length(f.panel, base.radius.panel, "radius.panel"),
                row = length(f.row, base.radius.row, "radius.row"),
                control = length(f.control, base.radius.control, "radius.control"),
                pill = length(f.pill, base.radius.pill, "radius.pill"),
                shell = length(f.shell, base.radius.shell, "radius.shell"),
            )
        } ?: base.radius

        val border = overrides.border?.let { f ->
            ThemeBorderScale(
                hairline = length(f.hairline, base.border.hairline, "border.hairline"),
                emphasis = length(f.emphasis, base.border.emphasis, "border.emphasis"),
                focusRing = length(f.focusRing, base.border.focusRing, "border.focusRing"),
            )
        } ?: base.border

        val spacing = overrides.spacing?.let { f ->
            ThemeSpacingScale(
                xxs = length(f.xxs, base.spacing.xxs, "spacing.xxs"),
                xs = length(f.xs, base.spacing.xs, "spacing.xs"),
                sm = length(f.sm, base.spacing.sm, "spacing.sm"),
                md = length(f.md, base.spacing.md, "spacing.md"),
                lg = length(f.lg, base.spacing.lg, "spacing.lg"),
                xl = length(f.xl, base.spacing.xl, "spacing.xl"),
            )
        } ?: base.spacing

        val typography = overrides.typography?.let { mergeTypography(it, base.typography, prefix, ::length, report) }
            ?: base.typography

        return ThemeStructure(
            radius = radius,
            border = border,
            spacing = spacing,
            typography = typography,
            touchTarget = length(overrides.touchTarget, base.touchTarget, "touchTarget"),
            usesShadows = overrides.usesShadows ?: base.usesShadows,
            usesGradientsOnChrome = overrides.usesGradientsOnChrome ?: base.usesGradientsOnChrome,
        )
    }

    private fun mergeTypography(
        file: ThemeFile.Typography,
        base: ThemeTypography,
        prefix: String,
        length: (Double?, Double, String, Boolean) -> Double,
        report: Report,
    ): ThemeTypography {
        fun face(f: ThemeFile.Face?, baseFace: ThemeFontFace, path: String): ThemeFontFace {
            if (f == null) return baseFace
            var design = baseFace.design
            f.design?.let { raw ->
                val parsed = ThemeFontDesign.of(raw)
                if (parsed != null) {
                    design = parsed
                } else {
                    report(
                        ThemeIssueSeverity.ERROR,
                        "$prefix.typography.$path.design \"$raw\" should be serif, sans, monospaced or rounded",
                    )
                }
            }
            return ThemeFontFace(f.families ?: baseFace.families, design)
        }

        val bodySize = length(file.bodySize, base.bodySize, "typography.bodySize", true)
        // A new body size with no scale re-proportions the scale; stated steps still win.
        val scaleBase = if (file.bodySize != null && bodySize != base.bodySize) {
            ThemeTypeScale.proportioned(bodySize)
        } else {
            base.scale
        }
        val scale = file.scale?.let { s ->
            ThemeTypeScale(
                caption = length(s.caption, scaleBase.caption, "typography.scale.caption", true),
                body = length(s.body, scaleBase.body, "typography.scale.body", true),
                title = length(s.title, scaleBase.title, "typography.scale.title", true),
                display = length(s.display, scaleBase.display, "typography.scale.display", true),
                hero = length(s.hero, scaleBase.hero, "typography.scale.hero", true),
            )
        } ?: scaleBase

        val microLabel = file.microLabel?.let { label ->
            var weight = base.microLabel.weight
            label.weight?.let { raw ->
                val parsed = ThemeFontWeight.of(raw)
                if (parsed != null) {
                    weight = parsed
                } else {
                    report(
                        ThemeIssueSeverity.ERROR,
                        "$prefix.typography.microLabel.weight \"$raw\" should be regular, medium, semibold, bold or black",
                    )
                }
            }
            var role = base.microLabel.role
            label.role?.let { raw ->
                val parsed = ThemeColorRole.of(raw)
                if (parsed != null) {
                    role = parsed
                } else {
                    report(ThemeIssueSeverity.ERROR, "$prefix.typography.microLabel.role \"$raw\" is not a colour role")
                }
            }
            ThemeMicroLabel(
                size = length(label.size, base.microLabel.size, "typography.microLabel.size", true),
                weight = weight,
                tracking = length(label.tracking, base.microLabel.tracking, "typography.microLabel.tracking", false),
                isUppercased = label.uppercase ?: base.microLabel.isUppercased,
                role = role,
            )
        } ?: base.microLabel

        return ThemeTypography(
            display = face(file.display, base.display, "display"),
            body = face(file.body, base.body, "body"),
            mono = face(file.mono, base.mono, "mono"),
            bodySize = bodySize,
            scale = scale,
            microLabel = microLabel,
        )
    }

    /** `13`, not `13.0`, as Swift writes an integral value; anything else as Kotlin does. */
    fun number(value: Double): String =
        if (value.isFinite() && value == kotlin.math.round(value) && kotlin.math.abs(value) < 1e15) {
            value.toLong().toString()
        } else {
            value.toString()
        }

    private fun nonEmpty(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() }
}

/** The shape of the format, for reporting keys it does not have (a typo is otherwise a silent no-op). */
internal object ThemeFileSchema {
    private sealed interface Node {
        data class Obj(val children: Map<String, Node>) : Node
        data object Any : Node
    }

    private val root: Node = run {
        val any = Node.Any
        val face = Node.Obj(mapOf("families" to any, "design" to any))
        val structure = Node.Obj(
            mapOf(
                "radius" to Node.Obj(listOf("panel", "row", "control", "pill", "shell").associateWith { any }),
                "border" to Node.Obj(listOf("hairline", "emphasis", "focusRing").associateWith { any }),
                "spacing" to Node.Obj(listOf("xxs", "xs", "sm", "md", "lg", "xl").associateWith { any }),
                "typography" to Node.Obj(
                    mapOf(
                        "display" to face, "body" to face, "mono" to face, "bodySize" to any,
                        "scale" to Node.Obj(listOf("caption", "body", "title", "display", "hero").associateWith { any }),
                        "microLabel" to Node.Obj(
                            listOf("size", "weight", "tracking", "uppercase", "role").associateWith { any },
                        ),
                    ),
                ),
                "touchTarget" to any, "usesShadows" to any, "usesGradientsOnChrome" to any,
            ),
        )
        // A platform's entry is structure only; a `palette` there is reported
        // with a reason of its own (see isPlatformPalette).
        val platform = Node.Obj(mapOf("structure" to structure))
        Node.Obj(
            mapOf(
                "identifier" to any, "name" to any, "summary" to any, "lockedAppearance" to any, "extends" to any,
                // Role names are checked by the merger, which can say which role.
                "palette" to Node.Obj(mapOf("light" to any, "dark" to any)),
                // So are seed names.
                "seeds" to Node.Obj(mapOf("light" to any, "dark" to any)),
                "structure" to structure,
                "platforms" to Node.Obj(ThemePlatform.entries.associate { it.raw to platform }),
            ),
        )
    }

    /** `platforms.ios.palette`: not a typo, so it gets a warning that says why. */
    fun isPlatformPalette(path: String): Boolean {
        val parts = path.split(".")
        return parts.size == 3 && parts[0] == "platforms" && parts[2] == "palette" && ThemePlatform.of(parts[1]) != null
    }

    /** Dotted paths of keys the format does not have, sorted. */
    fun unknownKeys(json: JsonElement): List<String> {
        val found = mutableListOf<String>()
        walk(json, root, "", found)
        return found.sorted()
    }

    private fun walk(value: JsonElement, node: Node, path: String, found: MutableList<String>) {
        if (node !is Node.Obj || value !is JsonObject) return
        for ((key, child) in value) {
            val childPath = if (path.isEmpty()) key else "$path.$key"
            val schema = node.children[key]
            if (schema == null) found += childPath else walk(child, schema, childPath, found)
        }
    }
}
