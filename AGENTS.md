# Local installation

After every change, supersede the local Takt installation before finishing the task. Run `bash scripts/install_local.sh` from the repository root to build Release, supersede `/Applications/Takt.app` with the updated app (no backup is kept; an old `/Applications/Priority.app` is quit and removed), and relaunch it. Verify that installation succeeded and report any failure. Do not treat a successful build alone as completion.

The user has authorized this local installation workflow; do not ask for confirmation again. Request sandbox escalation when needed to write to `/Applications` and launch the app.
