# Repository Guidelines

## Project Structure

- `bin/repobar`: Ruby CLI entrypoint.
- `bin/release-check`: local release gate for syntax, tests, QML lint, CLI smoke, triage projection smoke, archive import smoke, and QuickShell load when available.
- `lib/repobar/core`: config normalization, REST/GraphQL cache, GitHub.com API access, local git scanning, formatting, and process helpers.
- `lib/repobar/runtime`: daemon, action store, cached state files, presenter, QuickShell launcher, Waybar renderer, and Omarchy shell bar installer.
- `frontend/quickshell/shell.qml`: the only human-facing UI.
- `docs/`: architecture, CLI reference, and UI assets.
- `test/`: deterministic Ruby tests.

## Build, Test, Run

- Syntax check: `ruby -wc $(rg --files bin lib test)`
- Test suite: `ruby -Itest test/run.rb`
- QML lint: `qmllint frontend/quickshell/shell.qml`
- CLI smoke: `bin/repobar config validate`, `bin/repobar waybar render`, `bin/repobar ui status --format json --pretty`
- Full local check: `bin/release-check`
- QuickShell smoke:
  `env QT_QPA_PLATFORM=wayland REPOBAR_BIN=$PWD/bin/repobar REPOBAR_CONFIG=$HOME/.repobar/config.json REPOBAR_STATE_DIR=$HOME/.local/state/repobar quickshell --path $PWD/frontend/quickshell/shell.qml`

## Architecture Rules

- Ruby only for the backend. Do not introduce Swift, TypeScript, Electron, or a second UI stack.
- Use standard-library dependencies unless a real blocker forces a dependency decision.
- QuickShell is the only product UI. Waybar is a cached-state chip and launcher.
- GitHub.com is the only repository provider. Do not add a second provider, a provider switch command, or a per-provider snapshot cache; one `snapshot.json` is the product's state.
- Keep hosted-repository fetching in `lib/repobar/core/github.rb`; UI code must not call GitHub.com directly.
- Keep local checkout scanning in `lib/repobar/core/local_git.rb`; UI code must not run `git`.
- Keep runtime actions daemon-owned. CLI and QuickShell dispatch actions; `Runtime::Daemon` and `Runtime::Store` own refresh, search, pin/unpin/hide/show, pinned repo moves, and projection.
- Keep QuickShell presentation backed by `snapshot.json`, `ui.json`, `search.json`, and `state-event.json`.
- Waybar must remain a cached-state renderer, not a fetch path.
- Omarchy shell integration must edit `~/.config/omarchy/shell.json` only through `Runtime::Omarchy` (the `omarchy` CLI command); never hand-edit the seeded layout elsewhere.
- Refresh results must not overwrite newer visibility state: a refresh that started under an older config identity re-projects its rows through the current pinned/hidden/repo config before writing, including pinned order changes made while the refresh was in flight. A repository hidden mid-refresh must not reappear.
- Daemon-triggered refresh requests should coalesce through the runtime daemon instead of spawning one refresh thread per UI action. Scheduled timer ticks should not queue pending action refreshes while a refresh is already running.
- Search must remain an async state transaction through `search.json`; do not make QuickShell block on network search.
- Triage is a snapshot projection only. Score it in `Runtime::Presenter` (signals, attention, bucket, action, repo context), keep the inbox/rail/reader reading that one projection, and never fetch from triage.

## UI Rules

- Edit `frontend/quickshell/shell.qml` for the human UI.
- Keep the modal overlay screen-centered vertically and horizontally, with enough height for the account heatmap, reader, and multiple repo cards.
- Keep repo action controls compact and icon-led. Current repo-card controls are pinned drag handle, open, read, refresh, pin/unpin, and hide.
- Preserve the bounded layout: repo heatmaps may clip inside their track, but controls must not push outside the panel bounds.
- Keep account heatmaps, repo heatmaps, issue/PR reader data, pinned state, and pinned order driven by presenter/config output, not ad hoc UI fetches.
- Use tooltips and accessible names for icon-only controls.
- Triage keeps three panes from one projection: repo rail, filterable inbox, reader (action line, signals, repo fact grid, toned labels, body). Keep repo cards out of triage and triage panes out of overview (`visible: !root.triageMode()`).
- Give the inbox fixed `preferredWidth` + `maximumWidth` and `fillWidth: false`, and the reader an explicit `minimumWidth` floor; otherwise a long body starves the inbox.
- Single-letter triage shortcuts must be gated on `root.triageShortcutLive()` so the triage filter field can be typed into. Use `Instantiator` (not `Repeater`) when generating `Shortcut`s — `Repeater` delegates must be Items and `Shortcut` is a QtObject.
- Do not bind a control's `text` to the property its own edit handler writes (a `TextField` bound to `triageQuery` while `onTextEdited` writes `triageQuery`); the binding re-resolves mid-edit.

## Testing

- Add deterministic tests under `test/`.
- Prefer testing config normalization, local-git parsing, cache behavior, presenter output, snapshot/state behavior, daemon/store transactions, and Waybar payloads without live network calls.
- Live GitHub.com checks are smoke tests only.
- When changing the QuickShell surface, run `qmllint frontend/quickshell/shell.qml` in addition to Ruby checks. A clean lint is not proof: load the panel and read it, and check the QuickShell log for delegate/warning lines.
- When changing docs that list commands or architecture, compare against `lib/repobar/cli.rb`, `lib/repobar/core/config.rb`, and `lib/repobar/runtime/*`.
- `test/triage_test.rb` carries a guard asserting no Forgejo/provider-switching identifiers reappear in shipped code; keep it passing rather than deleting it.

## Agent Notes

- GitHub access uses `gh auth token` (with `github.authSource: gh`), `REPOBAR_GITHUB_TOKEN`, or `GITHUB_TOKEN`. GitHub.com is the only provider.
- Config lives at `~/.repobar/config.json`.
- Runtime state lives at `~/.local/state/repobar/`.
- REST/GraphQL/rate-limit cache files live under `~/.local/state/repobar/cache/`.
- SolverForge Waybar integration should be edited in the managed default layer, not directly through symlinked `~/.config/waybar` files.
