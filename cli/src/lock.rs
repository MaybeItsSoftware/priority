use crate::error::{Result, ToolError};
use std::fs::{File, OpenOptions};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

// Declared directly rather than pulling in `libc` for two constants and one
// call. `flock` is POSIX and stable; the operation values are from
// <sys/file.h>.
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

const LOCK_EX: i32 = 2;
const LOCK_UN: i32 = 8;

/// A cross-process advisory lock, via `flock(2)`.
///
/// The same protocol, and the same lock file, as Swift's `FileLock`
/// (`Takt/CoreLogic/FileLock.swift`) and the Python server's
/// `_exclusive_lock`, so all three writers genuinely exclude each other. Getting
/// the path wrong here would not fail loudly — it would simply stop excluding
/// anything, and show up much later as a daily that vanished.
///
/// The lock is taken on a sibling `.lock` file rather than the data file, and
/// that detail is load-bearing: `dailies.json` is saved atomically (write a
/// temporary, then rename over the target), which replaces the inode. A lock
/// held on the old inode guards nothing.
pub struct FileLock {
    lock_path: PathBuf,
}

impl FileLock {
    pub fn protecting(path: &Path) -> Self {
        // Append, never `set_extension`, which would replace `.json` and leave
        // this locking a different file from the other two implementations.
        let mut name = path.as_os_str().to_os_string();
        name.push(".lock");
        FileLock {
            lock_path: PathBuf::from(name),
        }
    }

    /// Runs `body` with the lock held, releasing it however `body` exits.
    ///
    /// Blocks until the lock is available. No timeout, for the same reason as
    /// the Swift original: the critical section is a small read/modify/write on
    /// a file measured in kilobytes.
    pub fn with_exclusive<T>(&self, body: impl FnOnce() -> Result<T>) -> Result<T> {
        if let Some(parent) = self.lock_path.parent() {
            std::fs::create_dir_all(parent).map_err(|err| {
                ToolError::new(format!("Could not create {}: {err}", parent.display()))
            })?;
        }

        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&self.lock_path)
            .map_err(|err| {
                ToolError::new(format!(
                    "Could not open the lock file at {}: {err}",
                    self.lock_path.display()
                ))
            })?;

        let _guard = Guard::acquire(file, &self.lock_path)?;
        body()
    }
}

/// Holds the descriptor open for the critical section. Dropping it unlocks and
/// then closes, in that order — releasing a lock on an already-closed
/// descriptor is a silent no-op that would leave the next process blocked.
struct Guard {
    file: File,
}

impl Guard {
    fn acquire(file: File, path: &Path) -> Result<Self> {
        // SAFETY: `file` owns a valid descriptor for the whole call, and
        // `LOCK_EX` is a valid operation.
        let status = unsafe { flock(file.as_raw_fd(), LOCK_EX) };
        if status != 0 {
            return Err(ToolError::new(format!(
                "Could not lock {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            )));
        }
        Ok(Guard { file })
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        // SAFETY: the descriptor is still open — `file` is dropped after this.
        unsafe { flock(self.file.as_raw_fd(), LOCK_UN) };
    }
}
