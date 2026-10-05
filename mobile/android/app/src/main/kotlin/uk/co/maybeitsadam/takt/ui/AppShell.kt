package uk.co.maybeitsadam.takt.ui

import android.content.Intent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteItemColors
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.app.QuickAddRequest
import uk.co.maybeitsadam.takt.ui.commands.Chord
import uk.co.maybeitsadam.takt.ui.commands.CommandPalette
import uk.co.maybeitsadam.takt.ui.commands.CommandRegistry
import uk.co.maybeitsadam.takt.ui.commands.KeyCommand
import uk.co.maybeitsadam.takt.ui.commands.LocalCommandRegistry
import uk.co.maybeitsadam.takt.ui.commands.PaletteCommand
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.components.VerticalHairline
import uk.co.maybeitsadam.takt.ui.focus.FocusScreen
import uk.co.maybeitsadam.takt.ui.history.HistorySheet
import uk.co.maybeitsadam.takt.ui.inspector.TaskInspector
import uk.co.maybeitsadam.takt.ui.lists.ListScreen
import uk.co.maybeitsadam.takt.ui.lists.ListsScreen
import uk.co.maybeitsadam.takt.ui.navigation.AppNavigator
import uk.co.maybeitsadam.takt.ui.navigation.FocusRoute
import uk.co.maybeitsadam.takt.ui.navigation.ListRoute
import uk.co.maybeitsadam.takt.ui.navigation.ListsRoute
import uk.co.maybeitsadam.takt.ui.navigation.LocalShell
import uk.co.maybeitsadam.takt.ui.navigation.ReviewRoute
import uk.co.maybeitsadam.takt.ui.navigation.SearchRoute
import uk.co.maybeitsadam.takt.ui.navigation.SettingsRoute
import uk.co.maybeitsadam.takt.ui.navigation.Shell
import uk.co.maybeitsadam.takt.ui.navigation.Tab
import uk.co.maybeitsadam.takt.ui.navigation.TodayRoute
import uk.co.maybeitsadam.takt.ui.navigation.WindowLayout
import uk.co.maybeitsadam.takt.ui.quickadd.QuickAddSheet
import uk.co.maybeitsadam.takt.ui.review.ReviewScreen
import uk.co.maybeitsadam.takt.ui.search.SearchScreen
import uk.co.maybeitsadam.takt.settings.SupabaseAccounts
import uk.co.maybeitsadam.takt.ui.settings.SettingsScreen
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.today.TodayScreen
import uk.co.maybeitsadam.takt.ui.undo.SnackAction

/**
 * Intents the shell understands: quick add (tile, launcher shortcut), a tab
 * to open, and the browser coming back from a sign-in (`takt://auth-callback`).
 */
object ShellIntents {
    const val ACTION_QUICK_ADD = "uk.co.maybeitsadam.priority.QUICK_ADD"
    const val EXTRA_TAB = "uk.co.maybeitsadam.priority.TAB"
    const val EXTRA_TASK_ID = "uk.co.maybeitsadam.priority.TASK_ID"
}

private class NavControllerNavigator(private val nav: NavHostController) : AppNavigator {
    override fun openTab(tab: Tab) {
        nav.navigate(tab.route) {
            popUpTo(nav.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    }

    override fun openList(listId: String?, revealTaskId: String?) {
        nav.navigate(ListRoute(listId, revealTaskId)) { launchSingleTop = true }
    }

    override fun openSettings() {
        nav.navigate(SettingsRoute) { launchSingleTop = true }
    }

    override fun back() {
        nav.popBackStack()
    }
}

/**
 * The window: navigation (a bottom bar on phones, a rail on wide screens),
 * the screens, and the shared surfaces over them — the inspector, quick add,
 * the history sheet, the command palette and the undo snackbar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppShell(container: AppContainer, pendingIntent: Intent?, onIntentHandled: () -> Unit) {
    val nav = rememberNavController()
    val navigator = remember(nav) { NavControllerNavigator(nav) }
    val registry = remember { CommandRegistry() }
    var historyOpen by remember { mutableStateOf(false) }
    var paletteOpen by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    val inspectorTaskId by container.inspector.taskId.collectAsStateWithLifecycle()
    val quickAdd by container.quickAdd.request.collectAsStateWithLifecycle()

    LaunchedEffect(container) {
        container.undo.messages.collect { message ->
            val result = snackbar.showSnackbar(
                message = message.text,
                actionLabel = message.action?.label,
                withDismissAction = false,
                duration = if (message.action != null) SnackbarDuration.Short else SnackbarDuration.Short,
            )
            if (result == SnackbarResult.ActionPerformed) {
                when (message.action) {
                    SnackAction.UNDO -> container.undo.undo()
                    SnackAction.REDO -> container.undo.redo()
                    null -> Unit
                }
            }
        }
    }

    LaunchedEffect(pendingIntent) {
        val intent = pendingIntent ?: return@LaunchedEffect
        when {
            intent.action == ShellIntents.ACTION_QUICK_ADD -> container.quickAdd.open(QuickAddRequest())
            SupabaseAccounts.isRedirect(intent.data) -> {
                container.sync.handleAuthRedirect(intent.data!!)
                navigator.openSettings()
            }
            else -> {
                intent.getStringExtra(ShellIntents.EXTRA_TAB)?.let { name ->
                    Tab.entries.firstOrNull { it.name.equals(name, ignoreCase = true) }?.let(navigator::openTab)
                }
                intent.getStringExtra(ShellIntents.EXTRA_TASK_ID)?.let(container.inspector::open)
            }
        }
        onIntentHandled()
    }

    val globalCommands = remember(container, navigator) {
        listOf(
            KeyCommand.GO_TODAY.palette { navigator.openTab(Tab.TODAY) },
            KeyCommand.GO_EVERYTHING.palette { navigator.openList(null) },
            KeyCommand.GO_FOCUS.palette { navigator.openTab(Tab.FOCUS) },
            KeyCommand.GO_TIMELINE.palette { navigator.openTab(Tab.REVIEW) },
            KeyCommand.GO_SEARCH.palette { navigator.openTab(Tab.SEARCH) },
            PaletteCommand("goLists", "Go to Lists", "Go", "") { navigator.openTab(Tab.LISTS) },
            KeyCommand.TASK_NEW.palette { container.quickAdd.open(QuickAddRequest(listId = container.quickAdd.contextListId.value)) },
            KeyCommand.WINDOW_UNDO.palette { container.undo.undo() },
            KeyCommand.WINDOW_REDO.palette { container.undo.redo() },
            KeyCommand.WINDOW_HISTORY.palette { historyOpen = true },
            KeyCommand.WINDOW_SETTINGS.palette { navigator.openSettings() },
        )
    }

    val chords = remember(container, navigator) {
        listOf<Pair<Chord, () -> Unit>>(
            Chord(Key.Z, ctrl = true) to { container.undo.undo() },
            Chord(Key.Z, ctrl = true, shift = true) to { container.undo.redo() },
            Chord(Key.Y, ctrl = true) to { container.undo.redo() },
            Chord(Key.K, ctrl = true) to { paletteOpen = true },
            Chord(Key.P, ctrl = true, shift = true) to { paletteOpen = true },
            Chord(Key.N, ctrl = true) to { container.quickAdd.open(QuickAddRequest(listId = container.quickAdd.contextListId.value)) },
            Chord(Key.F, ctrl = true) to { navigator.openTab(Tab.SEARCH) },
            Chord(Key.One, ctrl = true) to { navigator.openTab(Tab.TODAY) },
            Chord(Key.Zero, ctrl = true) to { navigator.openList(null) },
            Chord(Key.Eight, ctrl = true) to { navigator.openTab(Tab.FOCUS) },
            Chord(Key.Nine, ctrl = true) to { navigator.openTab(Tab.REVIEW) },
            Chord(Key.Comma, ctrl = true) to { navigator.openSettings() },
        )
    }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .semantics { testTagsAsResourceId = true }
            .background(TaktTheme.colors.paper)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val match = chords.firstOrNull { it.first.matches(event) } ?: return@onPreviewKeyEvent false
                match.second()
                true
            },
    ) {
        val layout = WindowLayout(maxWidth.value.toInt())
        val shell = remember(container, navigator, layout) {
            Shell(container, navigator, layout, showHistory = { historyOpen = true }, showPalette = { paletteOpen = true })
        }
        CompositionLocalProvider(LocalShell provides shell, LocalCommandRegistry provides registry) {
            val backStack by nav.currentBackStackEntryAsState()
            val destination = backStack?.destination
            val currentTab = Tab.entries.firstOrNull { tab -> destination?.hasRoute(tab.route::class) == true }
                ?: if (destination?.hasRoute(ListRoute::class) == true) Tab.LISTS else null
            val showFab = currentTab == Tab.TODAY || currentTab == Tab.LISTS

            val content: @Composable (Modifier) -> Unit = { modifier ->
                Row(modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        AppNavHost(nav)
                        if (showFab && !layout.isWide) {
                            QuickAddFab(
                                Modifier.align(Alignment.BottomEnd).padding(Metrics.lg),
                            ) { container.quickAdd.open(QuickAddRequest(listId = container.quickAdd.contextListId.value)) }
                        }
                    }
                    val taskId = inspectorTaskId
                    if (layout.inspectorAsPane && taskId != null) {
                        VerticalHairline()
                        Box(Modifier.width(Metrics.inspectorWidth).fillMaxHeight().background(TaktTheme.colors.paper)) {
                            TaskInspector(taskId = taskId, asSheet = false, onClose = container.inspector::close)
                        }
                    }
                }
            }

            if (layout.isWide) {
                val itemColors = navItemColors()
                NavigationSuiteScaffold(
                    layoutType = NavigationSuiteType.NavigationRail,
                    containerColor = TaktTheme.colors.paper,
                    contentColor = TaktTheme.colors.ink,
                    navigationSuiteColors = NavigationSuiteDefaults.colors(
                        navigationRailContainerColor = TaktTheme.colors.paper,
                        navigationRailContentColor = TaktTheme.colors.mutedText,
                    ),
                    navigationSuiteItems = {
                        Tab.entries.forEach { tab ->
                            item(
                                selected = tab == currentTab,
                                onClick = { navigator.openTab(tab) },
                                icon = { Icon(tab.icon, null) },
                                label = { Text(tab.title, style = TaktTheme.type.small) },
                                colors = itemColors,
                                modifier = Modifier.testTag("tab_${tab.name}"),
                            )
                        }
                    },
                ) {
                    Row(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.navigationBars)) {
                        VerticalHairline()
                        content(Modifier.weight(1f))
                    }
                }
            } else {
                Column(Modifier.fillMaxSize()) {
                    content(Modifier.weight(1f))
                    PhoneNavBar(currentTab, onSelect = navigator::openTab)
                }
            }

            SnackbarHost(
                snackbar,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(bottom = if (layout.isWide) Metrics.lg else 64.dp, start = Metrics.md, end = Metrics.md),
            ) { data ->
                Snackbar(
                    snackbarData = data,
                    shape = Metrics.control,
                    containerColor = TaktTheme.colors.ink,
                    contentColor = TaktTheme.colors.paper,
                    actionColor = if (TaktTheme.colors.isDark) TaktTheme.colors.primary else TaktTheme.colors.dimText,
                )
            }

            val taskId = inspectorTaskId
            if (!layout.inspectorAsPane && taskId != null) {
                val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
                ModalBottomSheet(
                    onDismissRequest = container.inspector::close,
                    sheetState = sheetState,
                    containerColor = TaktTheme.colors.paper,
                    tonalElevation = 0.dp,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(topStart = Metrics.cardRadius, topEnd = Metrics.cardRadius),
                    dragHandle = { SheetHandle() },
                ) {
                    TaskInspector(taskId = taskId, asSheet = true, onClose = container.inspector::close)
                }
            }

            quickAdd?.let { request ->
                QuickAddSheet(request = request, onDismiss = container.quickAdd::close)
            }

            if (historyOpen) HistorySheet(onDismiss = { historyOpen = false })

            if (paletteOpen) {
                CommandPalette(
                    commands = globalCommands + registry.commands,
                    onDismiss = { paletteOpen = false },
                )
            }
        }
    }
}

@Composable
private fun AppNavHost(nav: NavHostController) {
    NavHost(
        navController = nav,
        startDestination = TodayRoute,
        enterTransition = { fadeIn() },
        exitTransition = { fadeOut() },
        popEnterTransition = { EnterTransition.None },
        popExitTransition = { ExitTransition.None },
    ) {
        composable<TodayRoute> { TodayScreen() }
        composable<ListsRoute> { ListsScreen() }
        composable<ListRoute> { entry -> ListScreen(route = entry.toRoute()) }
        composable<FocusRoute> { FocusScreen() }
        composable<ReviewRoute> { ReviewScreen() }
        composable<SearchRoute> { SearchScreen() }
        composable<SettingsRoute> { SettingsScreen() }
    }
}

@Composable
private fun navItemColors(): NavigationSuiteItemColors = NavigationSuiteDefaults.itemColors(
    navigationBarItemColors = NavigationBarItemDefaults.colors(
        selectedIconColor = TaktTheme.colors.primary, selectedTextColor = TaktTheme.colors.ink,
        indicatorColor = TaktTheme.colors.well, unselectedIconColor = TaktTheme.colors.mutedText,
        unselectedTextColor = TaktTheme.colors.mutedText,
    ),
    navigationRailItemColors = NavigationRailItemDefaults.colors(
        selectedIconColor = TaktTheme.colors.primary, selectedTextColor = TaktTheme.colors.ink,
        indicatorColor = TaktTheme.colors.well, unselectedIconColor = TaktTheme.colors.mutedText,
        unselectedTextColor = TaktTheme.colors.mutedText,
    ),
    navigationDrawerItemColors = NavigationDrawerItemDefaults.colors(),
)

/** The phone's bottom bar: five flat items over a hairline, padded above the gesture bar. */
@Composable
private fun PhoneNavBar(current: Tab?, onSelect: (Tab) -> Unit) {
    Column(Modifier.fillMaxWidth().background(TaktTheme.colors.paper)) {
        Hairline()
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).height(56.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            Tab.entries.forEach { tab ->
                val selected = tab == current
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clickable(role = Role.Tab) { onSelect(tab) }
                        .semantics { contentDescription = tab.title }
                        .testTag("tab_${tab.name}"),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        tab.icon, null,
                        tint = if (selected) TaktTheme.colors.primary else TaktTheme.colors.mutedText,
                        modifier = Modifier.size(22.dp),
                    )
                    Text(
                        tab.title,
                        style = TaktTheme.type.small.copy(fontSize = TaktTheme.type.monoSmall.fontSize),
                        color = if (selected) TaktTheme.colors.ink else TaktTheme.colors.mutedText,
                    )
                }
            }
        }
    }
}

/** The quick-add button: a square-ish 6dp azure tile, flat. */
@Composable
private fun QuickAddFab(modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .size(52.dp)
            .clip(Metrics.control)
            .background(TaktTheme.colors.primary)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Add a task" }
            .testTag("quick_add_fab"),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Add, null, tint = TaktTheme.colors.onAccent)
    }
}

/** The bottom sheet's grabber: a short dim rule. */
@Composable
fun SheetHandle() {
    Box(Modifier.fillMaxWidth().padding(vertical = Metrics.sm + Metrics.xxs), contentAlignment = Alignment.Center) {
        Box(Modifier.width(36.dp).height(4.dp).clip(Metrics.control).background(TaktTheme.colors.dimText))
    }
}
