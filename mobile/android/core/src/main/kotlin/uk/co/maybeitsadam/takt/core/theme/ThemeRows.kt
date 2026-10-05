package uk.co.maybeitsadam.takt.core.theme

/**
 * Theme rows (the synced `themes` table: identifier → file text) as theme
 * files. A row is loaded under the file name the Mac would give it
 * (`ThemeFolderMirror.fileName` in Swift), so a file with no `identifier` of
 * its own resolves back to its row's identifier: `user.dusk` is `dusk.json`.
 */
object ThemeRows {
    fun fileName(identifier: String, json: String): String {
        val stated = ThemeFileLoader.decode(json, "synced.json").first?.identifier?.trim().orEmpty()
        val stem = if (stated.isEmpty() && identifier.startsWith(ThemeFileLoader.DERIVED_IDENTIFIER_PREFIX)) {
            identifier.removePrefix(ThemeFileLoader.DERIVED_IDENTIFIER_PREFIX)
        } else {
            identifier
        }
        return stem.map { if (it == '/' || it == ':') '-' else it }.joinToString("") + "." + ThemeFileLoader.FILE_EXTENSION
    }

    /** The rows as sources for [ThemeFileLoader.load]. */
    fun sources(rows: Map<String, String>): List<ThemeFileSource> =
        rows.map { (identifier, json) -> ThemeFileSource(fileName(identifier, json), json) }

    /** The identifier an imported file is stored under: its own, or one from its file name. */
    fun identifier(fileName: String, json: String): String {
        val name = if (fileName.endsWith(".${ThemeFileLoader.FILE_EXTENSION}")) fileName else "$fileName.${ThemeFileLoader.FILE_EXTENSION}"
        val file = ThemeFileLoader.decode(json, name).first
        return file?.let { ThemeFileLoader.identifier(it, name) } ?: (ThemeFileLoader.DERIVED_IDENTIFIER_PREFIX + ThemeFileLoader.stem(name))
    }
}
