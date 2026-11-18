# Janitor: where work stopped (paused 2026-11-14 ~12:50 for a Mac restart)

## State

- **Installed app** (`/Applications/Janitor.app`) is still the OLD build from Nov 10. It has none of the cleanup work.
- **Source** in `Janitor/` contains the new cleanup feature and compiles (`BUILD SUCCEEDED` at 11:52).
- **launchd agent** `com.janitor.app.cleanup` is NOT installed. Nothing runs on a schedule yet.
- **Nothing real has been deleted.** The cleaner has only ever been pointed at a fake test tree.

## Written, compiled, not yet verified

- `Cleanup.swift`: discovery of the cleanup locations, age limits (2 days / 1 day, 6 hours under 30 GB free),
  in-use check (ps command lines + kernel open-file listing, then `lsof +D` per folder right before deleting),
  guarded `rm -rf --`, df-based before/after, log in `~/Library/Logs/Janitor/cleanup.log`, run lock.
- `CleanupCLI.swift` + `main.swift`: `Janitor --cleanup [--dry-run] [--no-sizes] [--test-root DIR] [--assume-free-gb N]`,
  `--install-agent`, `--uninstall-agent`, `--agent-status`, `--erase-simulator UDID`; launchd agent (every 2 h);
  low-disk notification with a Clean Now action.
- `CleanupView.swift`: Disk Cleanup window (preview, Clean Now, schedule toggle, Erase Idle Simulators, Open Log)
  and the free disk / swap / xcodebuild-count bar.
- `Monitor.swift`, `ProcessSampler.swift`: per-simulator idle timer (in use = installed app using CPU, tests running,
  xcodebuild targeting it, or Simulator app in front); auto shutdown after 30 min, now on by default.

## Known problems to pick up first

1. **Dry run is far too slow under load.** First version (whole-machine `lsof -F n`) timed out after 7.5 min and
   correctly kept everything. Second version (kernel listing via libproc) had printed nothing after 8 min when
   paused. Machine load average was 500 to 900 with 2,587 processes, so it may just be the machine; re-time it
   after the restart and profile with `sample` if still slow. Suspects: `/bin/ps -A`, the per-fd
   `proc_pidfdinfo` loop, `realpath`.
2. **Old Janitor uses too much CPU with many processes** (about 5% average, 16% with 2,587 processes). Profile the
   new build after install.

## Verification still owed

Test tree is in the session scratchpad under `/private/tmp`, which a restart wipes. Recreate it, then run
`scripts/cleanup-test-run.sh <scratch dir>` (it expects `<scratch dir>/jtest`). Cases the tree needs:

- DerivedData: old (delete), new (keep), `Hearth-build` old (keep), old with a file held open (keep),
  old named in a running command line (keep), old that is a process's working directory (keep), `Thing.app` (keep),
  old folder with one fresh deep file (keep), 30 h old (keep normally, delete in low-disk mode), 3 h old (keep),
  a symlink pointing outside (ignored, target survives).
- Scratch: `dd-1` old (delete) while a process references `dd-10` (keep), `dd_old` (delete), 30 h old (delete),
  `notdd` (untouched); `/private/tmp/other/dd_x` (delete), `dd-y` (untouched).
- `~/Builds/App1/DerivedData` old (delete), `App1/Sources` (untouched), `App2/DerivedData` new (keep).
- Confirm the dry run leaves the tree checksum unchanged.

Then: dry run on the real folders and show the list, install to /Applications, install the launchd agent,
check the notification, click-test the Disk Cleanup window. `--erase-simulator` only on a throwaway device.

## Build

```
xcodegen generate
xcodebuild -project Janitor.xcodeproj -scheme Janitor -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Janitor-build build
```

Building inside `~/Documents` fails at code signing, hence the DerivedData path. `xcodebuild` goes through the
build queue wrapper in `~/.local/bin`.
