package uk.co.maybeitsadam.priority.ui.inspector

import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** Icons the inspector needs that neither material-icons-core nor PIcons has. */
object InspectorIcons {
    val Minus by lazy { PIcons.icon("Minus", "M19,13H5v-2h14v2z") }
    val OpenLink by lazy {
        PIcons.icon(
            "OpenLink",
            "M19,19H5V5h7V3H5c-1.11,0 -2,0.9 -2,2v14c0,1.1 0.89,2 2,2h14c1.1,0 2,-0.9 2,-2v-7h-2v7zM14,3v2h3.59l-9.83,9.83 1.41,1.41L19,6.41V10h2V3h-7z",
        )
    }
}
