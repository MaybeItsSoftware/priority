package uk.co.maybeitsadam.takt.data

/**
 * `cli/src/fixtures/workspace_schema.sql`, which the Rust core generates
 * (scripts/dump_workspace_schema.sh) and is held to. The build copies it into
 * the unit tests' resources.
 */
object SchemaFixture {
    const val RESOURCE = "uk/co/maybeitsadam/takt/data/workspace_schema.sql"

    fun sql(): String {
        val loader = SchemaFixture::class.java.classLoader ?: ClassLoader.getSystemClassLoader()
        val stream = loader.getResourceAsStream(RESOURCE)
            ?: error("The schema fixture $RESOURCE is missing from the test resources")
        return stream.bufferedReader().use { it.readText() }
    }

    /**
     * Splits a SQL script into statements the way `sqlite3_complete` would:
     * semicolons inside quotes, comments and trigger bodies do not end one.
     */
    fun splitStatements(script: String): List<String> {
        val statements = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var i = 0
        while (i < script.length) {
            val c = script[i]
            if (quote != null) {
                current.append(c)
                if (c == quote) quote = null
                i++
                continue
            }
            when {
                c == '-' && i + 1 < script.length && script[i + 1] == '-' -> {
                    while (i < script.length && script[i] != '\n') i++
                    continue
                }
                c == '\'' || c == '"' || c == '`' -> {
                    quote = c
                    current.append(c)
                }
                c == '[' -> {
                    quote = ']'
                    current.append(c)
                }
                c == ';' -> {
                    val text = current.toString().trim()
                    val isTrigger = Regex("^CREATE\\s+(TEMP\\s+|TEMPORARY\\s+)?TRIGGER", RegexOption.IGNORE_CASE)
                        .containsMatchIn(text)
                    if (isTrigger && !Regex("\\bEND$", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
                        current.append(c)
                    } else {
                        if (text.isNotEmpty()) statements += text
                        current.clear()
                    }
                }
                else -> current.append(c)
            }
            i++
        }
        current.toString().trim().takeIf { it.isNotEmpty() }?.let { statements += it }
        return statements
    }
}
