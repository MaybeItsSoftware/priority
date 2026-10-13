//! Ported from `MatrixQuadrantIndexTests` (Swift), `ListsShapingTest`'s board
//! cases (Kotlin) and the column editors' slug, with the cross-column rule's
//! edges.

use super::*;

#[test]
fn an_unfiled_subtask_follows_its_parent_and_a_filed_one_elsewhere_stands_alone() {
    // a (card, filed 1), a1 (unfiled), a2 (filed 2), a2x (filed 2), b (card).
    let parents = vec![-1, 0, 0, 2, -1];
    let filed = vec![1, -1, 2, 2, -1];
    let eligible = vec![false, true, true, true, false];
    assert_eq!(board_cross_column(parents, filed, eligible, 0), [2]);
}

#[test]
fn a_subtask_filed_in_its_parents_column_is_not_a_card() {
    // a unfiled (so the fallback, 0); a1 filed 0; a2 filed 3.
    let parents = vec![-1, 0, 0];
    let filed = vec![-1, 0, 3];
    let eligible = vec![false, true, true];
    assert_eq!(board_cross_column(parents, filed, eligible, 0), [2]);
}

#[test]
fn an_unfiled_parent_takes_its_own_parents_column() {
    // a filed 1; a1 unfiled under it; a1x filed 1 under a1: same column.
    let parents = vec![-1, 0, 1, 1];
    let filed = vec![1, -1, 1, 2];
    let eligible = vec![false, true, true, true];
    assert_eq!(board_cross_column(parents, filed, eligible, 0), [3]);
}

#[test]
fn an_ineligible_row_is_never_a_card_and_a_cycle_ends() {
    let parents = vec![1, 0];
    let filed = vec![-1, 2];
    assert_eq!(
        board_cross_column(parents.clone(), filed.clone(), vec![false, false], 0),
        Vec::<u32>::new()
    );
    // Each is the other's parent: row 1's parent climbs back to row 1's own
    // column, so nothing stands alone, and the walk ends.
    assert_eq!(
        board_cross_column(parents, filed, vec![true, true], 0),
        Vec::<u32>::new()
    );
}

#[test]
fn a_column_id_is_a_slug_unique_among_the_taken() {
    assert_eq!(board_column_id("Waiting on".into(), vec![]), "waiting-on");
    assert_eq!(
        board_column_id(
            "Waiting on!".into(),
            vec!["waiting-on".into(), "waiting-on-2".into()]
        ),
        "waiting-on-3"
    );
    assert_eq!(board_column_id("  ¿Qué?  ".into(), vec![]), "qu");
    assert_eq!(board_column_id("!!!".into(), vec![]), "column");
    assert_eq!(board_column_id("Ünïcode 2".into(), vec![]), "n-code-2");
    assert_eq!(board_column_id("--A--B--".into(), vec![]), "a-b");
}

#[test]
fn quadrants_read_each_axis_by_its_sign() {
    assert_eq!(matrix_quadrant(Some(1), Some(1)), Some(0));
    assert_eq!(matrix_quadrant(Some(0), Some(1)), Some(1));
    assert_eq!(matrix_quadrant(Some(1), Some(0)), Some(2));
    assert_eq!(matrix_quadrant(Some(0), Some(0)), Some(3));
    // The inspectors' pickers write -5 and 5.
    assert_eq!(matrix_quadrant(Some(5), Some(5)), Some(0));
    assert_eq!(matrix_quadrant(Some(-5), Some(5)), Some(1));
    assert_eq!(matrix_quadrant(Some(-5), Some(-5)), Some(3));
    assert_eq!(matrix_quadrant(None, Some(1)), None);
}

#[test]
fn it_sorts_as_the_filters_did() {
    // Items 0..5: (1,1), (nil,0), (0,1), (1,1), (1,nil), (0,0).
    let urgency = vec![Some(1), None, Some(0), Some(1), Some(1), Some(0)];
    let importance = vec![Some(1), Some(0), Some(1), Some(1), None, Some(0)];
    let arrangement = matrix_arrangement(urgency, importance, vec![None; 6]);
    assert_eq!(arrangement.unplaced, [1, 4]);
    assert_eq!(
        arrangement.quadrants,
        vec![vec![0, 3], vec![2], vec![], vec![5]]
    );
}

#[test]
fn a_quadrant_reads_ranked_cards_first_then_the_rest_in_order() {
    let mut rank = vec![None; 6];
    rank[4] = Some(0);
    rank[2] = Some(1);
    rank[5] = Some(1);
    let arrangement = matrix_arrangement(vec![Some(1); 6], vec![Some(1); 6], rank);
    assert_eq!(arrangement.quadrants[0], [4, 2, 5, 0, 1, 3]);
}
