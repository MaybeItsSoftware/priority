# Local installation

After every change, supersede the local Takt installation before finishing the task. Run `bash scripts/install_local.sh` from the repository root to build Release, back up the existing `/Applications/Takt.app`, replace it with the updated app, and relaunch it (an old `/Applications/Priority.app` is quit and moved into `build/backup.noindex/`). Verify that installation succeeded and report any failure. Do not treat a successful build alone as completion.

The user has authorized this local installation workflow; do not ask for confirmation again. Request sandbox escalation when needed to write to `/Applications` and launch the app.
