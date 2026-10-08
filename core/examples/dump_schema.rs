//! Migrates a workspace database and prints its schema as the fixture
//! `cli/src/fixtures/workspace_schema.sql` holds it. With no argument it
//! migrates a new in-memory database, which is how
//! `scripts/dump_workspace_schema.sh` regenerates the fixture.
//!
//!     cargo run -q --example dump_schema [path/to/workspace.sqlite]

use rusqlite::Connection;
use takt_core::schema::{dump_schema, migrate};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut connection = match std::env::args().nth(1) {
        Some(path) => Connection::open(path)?,
        None => Connection::open_in_memory()?,
    };
    migrate(&mut connection)?;
    print!("{}", dump_schema(&connection)?);
    Ok(())
}
