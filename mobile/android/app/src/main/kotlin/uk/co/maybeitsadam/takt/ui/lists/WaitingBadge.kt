package uk.co.maybeitsadam.takt.ui.lists

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.Text
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.WaitingFollowUp
import uk.co.maybeitsadam.takt.data.workspace.TaskWaitingDetails
import uk.co.maybeitsadam.takt.ui.components.Tag
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/**
 * What a task in Waiting on says beside its title: who or what it waits on,
 * and `↻ Thu 14:00` while it is open and has a time to chase it. The rows'
 * `RowMarkers` decoration, for the surfaces that are not an outline.
 */
@Immutable
data class WaitingBadge(val waitingOn: String?, val followUp: String?) {
    companion object {
        /** The badge for a task filed in Waiting on, or null. */
        fun of(
            column: String?,
            waitingOn: String?,
            followUpAt: Instant?,
            chase: String?,
            isOpen: Boolean,
            today: LocalDate,
            zone: ZoneId,
        ): WaitingBadge? {
            if (column != WaitingFollowUp.WAITING_COLUMN_ID) return null
            val followUp = followUpAt?.takeIf { isOpen }?.let { WaitingFollowUp.label(it, today, zone, chase) }
            if (waitingOn == null && followUp == null) return null
            return WaitingBadge(waitingOn, followUp)
        }

        fun of(details: TaskWaitingDetails?, isOpen: Boolean, today: LocalDate, zone: ZoneId): WaitingBadge? =
            details?.let { of(it.column, it.waitingOn, it.followUpAt, it.chase, isOpen, today, zone) }
    }
}

/** The badge as the outline draws it: the who as a tag, the follow-up in mono after it. */
@Composable
fun WaitingMarkers(badge: WaitingBadge?, modifier: Modifier = Modifier) {
    if (badge == null) return
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(Metrics.xs + Metrics.xxs), verticalAlignment = Alignment.CenterVertically) {
        badge.waitingOn?.let { Tag(it, Modifier.semantics { contentDescription = "Waiting on $it" }) }
        badge.followUp?.let { Text(it, style = TaktTheme.type.monoSmall, color = TaktTheme.colors.mutedText, maxLines = 1) }
    }
}
