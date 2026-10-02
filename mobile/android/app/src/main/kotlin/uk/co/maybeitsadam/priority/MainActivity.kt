package uk.co.maybeitsadam.priority

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.emitAll
import uk.co.maybeitsadam.priority.data.workspace.TaskCounts

/** Stage 1 placeholder: proves the repository opens, bootstraps and streams counts. Stage 2 replaces it. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val repository = (application as PriorityApplication).repository
        setContent {
            val state by remember {
                flow {
                    repository.bootstrapIfNeeded()
                    emitAll(repository.observeTaskCounts())
                }
            }.collectAsState(initial = null)
            Placeholder(state)
        }
    }
}

private val plexSans = FontFamily(
    Font(R.font.ibmplexsans_regular, FontWeight.Normal),
    Font(R.font.ibmplexsans_semibold, FontWeight.SemiBold),
)
private val lilex = FontFamily(Font(R.font.lilex_regular, FontWeight.Normal))

@Composable
private fun Placeholder(counts: TaskCounts?) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Priority", fontFamily = plexSans, fontWeight = FontWeight.SemiBold, fontSize = 28.sp)
                Text(
                    text = if (counts == null) "Opening workspace…" else "${counts.open} open · ${counts.completed} done",
                    fontFamily = lilex,
                    fontSize = 14.sp,
                )
            }
        }
    }
}
