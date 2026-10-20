# TskViewer

[Polski](README.pl.md)

A native macOS 15+ menu bar app for the [tsk](https://gettsk.sh) task board, with no Dock icon. The “waiting for me” view collects `blocked` and `review` tasks from every project and the desk, grouped by project. The icon shows their count (just the symbol at zero). The “all” toggle shows the other live statuses too; there you can only move an `open` task to `ready` or close a task. Details show the notes with basic markdown and the steps, read-only.

Decisions go back to the agent: after you agree, accept or reply, TskViewer pastes a one-line `tsk:` message into the [Herdr](https://herdr.dev) pane of the agent working in that project.

When the agent signs its notes with a `Herdr: <pane>` line, the reply defaults to exactly that agent while it is reachable. Right-click the menu bar icon → “Name agents” to see every Herdr agent with its terminal title and give them all names in one go.

![TskViewer: an agent asks, you answer from the menu bar, the reply lands in the agent's terminal](docs/demo.gif)

22 s demo, also in [full quality MP4](docs/demo.mp4).

SwiftPM with no external dependencies: `TskCore` holds the CLI clients and logic, `TskViewer` the SwiftUI/AppKit interface.

## Install as a Herdr plugin

This repository is a [Herdr plugin](https://herdr.dev/plugins/) (`herdr-plugin.toml`). Installing builds the app (`scripts/build-app.sh`, needs Swift/Xcode), and every Herdr server start launches it through `scripts/herdr-start.sh` unless it is already running. The script copies the `.app` into the plugin state directory and hands the app the `herdr` (`HERDR_PATH`) and `tsk` (`TSK_PATH`) paths from your PATH. The “Start TskViewer” action does the same on demand.

```sh
herdr plugin install Nikospy/tsk-viewer
# or locally, after scripts/build-app.sh:
herdr plugin link .
```

Requires macOS, Swift/Xcode tools, a local `tsk` (CLI contract 0.11.6) and Herdr 0.9.3 or newer.

## Build and run

```sh
swift build
swift test
scripts/build-app.sh
open build/TskViewer.app
```

`TskCore` tests use a fake CLI executor, not a real board. The script can run from any directory: it builds release, replaces the previous `build/TskViewer.app` and signs the bundle ad hoc. `.build/` and `build/` are ignored by git.

This is a local bundle without notarization or a Developer ID signature. An ad hoc signature gives no Gatekeeper trust; macOS may ask you to allow the app in Privacy & Security. Do not turn off system protection. Notifications work only when the `.app` bundle runs, not the bare SwiftPM executable.

## Settings

The gear opens settings for the shortcut, the `tsk` path, the polling interval and the language. The `tsk` program is picked in this order: a non-empty app setting → the `TSK_PATH` environment variable → `/opt/homebrew/bin/tsk`. To run with a custom path (quit the running instance first):

```sh
TSK_PATH=/full/path/tsk build/TskViewer.app/Contents/MacOS/TskViewer
```

An app opened from Finder does not inherit the terminal environment; there, saving the path in settings is simplest. An empty field falls back to `TSK_PATH` or the default path. **Changing the program drops local draft replies and closes the details.** Settings persist between launches.

The language setting (system, English, polski) switches the interface at once. It also picks the language of the agent contract: the reply prefix in notes (`Reply:` or `Odp:`) and the `tsk:` messages. “System” means Polish only when Polish is the first system language, English otherwise.

Polling runs in the background, every 10 s by default (2–3600 s). Manual refresh: the arrow button or Cmd+R. Esc closes the panel; Cmd+Return sends the reply from the open editor. The ellipsis menu holds “Quit TskViewer”.

## Decisions and replies

| Status | Button | Effect |
| --- | --- | --- |
| `blocked` | Agree | → `ready` |
| `blocked` | Reply | append `Reply: …`, then → `ready` |
| `review` | Accept | → `done` |
| `review` | Send back with notes | append `Reply: …`, then → `ready` |
| `open` | To do | → `ready` |
| any live status | Close | `tsk archive` (status kept) |

Accept and Close ask “sure?” and act on the second click. Close archives the task: it leaves every list, its status stays, and it can come back with `tsk unarchive T#`. To do and Close send no message to any agent. `done` and unknown statuses have no actions. The app never sets `started`, `open`, `blocked` or `review`; it does not change steps or delete tasks.

Close reads the task fresh first and stops on a changed status or notes, like the other actions. After `archive` the app confirms the close in `tsk list --all --archived` (a direct lookup still finds archived tasks). `tsk archive` is idempotent, so an unconfirmed close can safely be repeated.

A reply cannot be empty after trimming whitespace. Its newlines become spaces, and one `Reply: <text>` line goes at the end of the notes; the existing text stays untouched. The CLI runs through `Process` with an argument array, never a shell; notes go as a single `--notes=…` argument, even when the text starts with `-`.

Saving a reply runs **`edit` → confirming read → fresh read of the preconditions → `status`**. A refused or failed `edit` leaves the status alone and keeps the text. When the reply is saved but the status did not change, the panel shows “reply saved, status unchanged” and a “retry status” button. The retry checks the current state and changes only the status — it never appends the reply twice.

After a write with exit 0 the state is confirmed by a read. Exit 3 means an unknown outcome: the app reads the task (also with `--done` if it left the live list) instead of retrying blindly. It compares notes or status with the original and expected ones; an ambiguous result asks the user to check the fresh state. Read errors show in the panel.

### Concurrent changes — remaining risk

Right before `edit` and before the status change the app reads the task fresh. Diverging notes or status stop the write, show the fresh state, keep the typed text and ask for confirmation again.

**This is not an atomic write nor full overwrite protection.** `tsk edit --notes` replaces the notes in full. An agent can change them between the app's last read and its write; that change is then lost. Reading after the write does not remove this risk.

## Messages to agents

After a decision the app pastes one line starting with `tsk:` into the chosen agent's Herdr pane. When the message does not arrive (no agent picked, the agent is gone or waiting for a decision, a dialog on its screen…), the panel says so: “saved, but not delivered to the agent: <reason>. The agent will see it on the board.” The “discuss” button sends the open or checked tasks without changing their status. A message goes out only when the agent is idle or working and its screen shows its plain input box (Claude Code, Codex, omp and Grok are recognized); decision dialogs block the send.

Tell your agents what these messages mean, for example in `CLAUDE.md` or `AGENTS.md`:

| `tsk:` message | What the agent does |
| --- | --- |
| `approved, status ready` | takes the recommendation from the notes, `tsk status T# start`, does the work |
| `reply added to notes (last Reply: line)` | `tsk list T# --json`, acts on the last `Reply:` line |
| `changes requested in notes (last Reply: line)` | fixes per `Reply:`, then `review` again |
| `accepted, status done` | the task is closed; leave the status |
| `user asks to discuss and carry out: …` | reads the tasks and proposes a plan before changing any status |

For this loop to work, agents ask their questions as `blocked` tasks (title = the question, options and a recommendation in the notes) and hand finished work back as `review`. Scripts that relay replies to agents must read the **last** reply line, not the first: replies are appended at the end of the notes.

## Notifications

The app asks the system for notification permission. Refusing does not block anything. The first successful read after launch is silent; later ones report transitions to `blocked` or `review`, including a new task appearing in such a status. No change, no duplicate notification, and a read error does not reset the comparison. A notification holds the task number, title, project and status; clicking it opens the panel on that task.

## Verification scope

Looks, the menu bar icon and notifications are **not verified automatically**. They need a manual check of the running `.app`, including notification permissions. Build, core tests, bundle assembly, plist validity and the ad hoc signature can be checked with the commands above plus `plutil -lint Support/Info.plist` and `codesign --verify build/TskViewer.app`.
