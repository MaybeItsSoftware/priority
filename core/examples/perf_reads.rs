//! Times the core's hot reads on an existing workspace file, with no FFI in
//! the way, so the Swift benchmark's numbers can be split into "the core's
//! work" and "the crossing".
//!
//!     cargo run --release --manifest-path core/Cargo.toml --example perf_reads -- <path.sqlite>
//!
//! `workspace-tests/WorkspacePerformanceBenchmarks.swift` seeds such a file.
use std::time::Instant;
use takt_core::focus::FocusContext;
use takt_core::workspace::CoreWorkspace;

fn time<T>(label: &str, runs: usize, mut body: impl FnMut() -> T) {
    body();
    let mut samples: Vec<f64> = (0..runs)
        .map(|_| {
            let start = Instant::now();
            std::hint::black_box(body());
            start.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "PERF-RS {label:<50} median {:8.2} ms  min {:8.2} ms",
        samples[runs / 2],
        samples[0]
    );
}

fn main() {
    let path = std::env::args().nth(1).expect("path to a workspace file");
    let core = CoreWorkspace::open(path).expect("open");
    let workspace = core.workspaces().unwrap()[0].id.clone();
    let lists: Vec<String> = core
        .lists(workspace, false)
        .unwrap()
        .into_iter()
        .map(|l| l.id)
        .collect();
    let now = chrono::Utc::now().timestamp_millis();
    let zone = "Europe/London".to_string();
    time("tasks_in_lists(all)", 9, || {
        core.tasks_in_lists(lists.clone()).unwrap().len()
    });
    time("tasks_in_lists(one)", 9, || {
        core.tasks_in_lists(vec![lists[5].clone()]).unwrap().len()
    });
    // Where tasks_in_lists' time goes, on a connection of the example's own.
    let raw = rusqlite::Connection::open(std::env::args().nth(1).unwrap()).unwrap();
    let sql = "SELECT * FROM tasks ORDER BY listId, sortOrder, createdAt";
    time("  sqlite step only (SELECT * all tasks)", 9, || {
        let mut s = raw.prepare_cached(sql).unwrap();
        let mut rows = s.query([]).unwrap();
        let mut n = 0;
        while rows.next().unwrap().is_some() {
            n += 1;
        }
        n
    });
    time("  + read 13 columns by name", 9, || {
        let mut s = raw.prepare_cached(sql).unwrap();
        let mut rows = s.query([]).unwrap();
        let mut n = 0usize;
        while let Some(row) = rows.next().unwrap() {
            for c in [
                "id",
                "listId",
                "parentTaskId",
                "title",
                "notes",
                "status",
                "sourceSystem",
                "sourceId",
                "itemKind",
            ] {
                let v: Option<String> = row.get(c).unwrap();
                n += v.map_or(0, |s| s.len());
            }
            for c in ["sortOrder", "estimateSeconds", "isPromoted"] {
                let v: Option<i64> = row.get(c).unwrap();
                n += v.unwrap_or(0) as usize;
            }
        }
        n
    });
    time("  + parse 4 stored dates per row", 9, || {
        let mut s = raw
            .prepare_cached(
                "SELECT dueAt, archivedAt, completedAt, createdAt, updatedAt FROM tasks",
            )
            .unwrap();
        let mut rows = s.query([]).unwrap();
        let mut n = 0i64;
        while let Some(row) = rows.next().unwrap() {
            for i in 0..5 {
                let v: Option<String> = row.get(i).unwrap();
                if let Some(at) = v.as_deref().and_then(takt_core::time::parse_stored) {
                    n += at.timestamp_millis() & 1;
                }
            }
        }
        n
    });
    // What a core-side sidebar index would cost: the four columns it needs,
    // per-list counts, and the nested lists picked out. Only the nested
    // lists and the counts would cross.
    time("  sidebar index estimate (narrow read + walk)", 9, || {
        let mut s = raw
            .prepare_cached(
                "SELECT id, listId, parentTaskId, itemKind = 'list', archivedAt IS NOT NULL \
                 FROM tasks ORDER BY listId, sortOrder, createdAt",
            )
            .unwrap();
        let mut rows = s.query([]).unwrap();
        let mut counts: std::collections::HashMap<String, i64> = Default::default();
        let mut nested: Vec<(String, Option<String>, bool)> = Vec::new();
        while let Some(row) = rows.next().unwrap() {
            let list: String = row.get(1).unwrap();
            *counts.entry(list).or_default() += 1;
            if row.get::<_, Option<bool>>(3).unwrap() == Some(true) {
                nested.push((
                    row.get(0).unwrap(),
                    row.get(2).unwrap(),
                    row.get(4).unwrap(),
                ));
            }
        }
        (counts.len(), nested.len())
    });
    time("all_metadata", 9, || core.all_metadata().unwrap().len());
    time("next_up_candidates", 9, || {
        core.next_up_candidates(now, zone.clone()).unwrap().len()
    });
    let candidates = core.next_up_candidates(now, zone.clone()).unwrap();
    time("ranking::evaluate (pure, no crossing)", 9, || {
        takt_core::ranking::evaluate(&candidates, now, &zone, &FocusContext::default())
            .ranked
            .len()
    });
}
