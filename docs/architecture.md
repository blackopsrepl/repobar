# Architecture

RepoBar Linux has five active layers:

1. Ruby CLI in `bin/repobar`.
2. Core Ruby services for config, hosted APIs, cache, local git, formatting, and process execution.
3. Daemon-owned runtime actions and cached JSON state.
4. Presenter output for Waybar and QuickShell.
5. QuickShell panel plus Waybar chip.

## Boundaries

The hosted-repository boundary lives in `lib/repobar/core/github.rb`; despite the historical filename, it handles both GitHub.com and the local Forgejo API at `http://vigilance:3002/api/v1`. It also owns REST caching, GraphQL contribution calendar calls, issue/PR/release/CI/activity hydration, and account/repo heatmaps.

The local checkout boundary lives in `lib/repobar/core/local_git.rb`. It scans configured roots, resolves repo targets, reports branch/dirty/ahead/behind state, and performs explicit sync/rebase/reset/clone operations.

The runtime boundary lives in `lib/repobar/runtime/daemon.rb`, `store.rb`, and `state.rb`. The daemon owns the action socket, refresh loop, refresh request coalescing, async search jobs, provider switches, visibility mutations, pinned repo moves, and state projection.

Provider switching is cache-first. `Runtime::Store.set_provider` preserves the current provider snapshot, rewrites config, resets search state, restores a cached target-provider snapshot when one exists, and then asks the daemon for a background refresh. `Runtime::Store.refresh_effect` records the provider/config identity it started with; if that identity changed before the refresh finishes, a provider switch result updates only the original provider cache and does not replace active UI state. Same-provider stale refreshes are re-projected through the current pinned/hidden config before provider-cache writeback, so a pin move made during a refresh cannot be overwritten by the refresh's older order.

Pinned repositories are selected and ordered independently of the normal display limit. `repoList.displayLimit` caps only unpinned extras, while `repoList.pinnedRepositories` controls every pinned row and its order. `repobar pin move owner/name POSITION` and the QuickShell drag handle both update that order through daemon-owned state.

The presentation boundary lives in `lib/repobar/runtime/presenter.rb`. It converts raw snapshots into summary state, Waybar chip state, account heatmap rows, repo cards, readable issue/PR previews, pinned state, and normalized heatmap cells.

The frontend boundary is `frontend/quickshell/shell.qml`. It watches JSON files, dispatches CLI commands, and renders the UI. It does not call GitHub.com, Forgejo, or `git`.

## State

Runtime state defaults to `~/.local/state/repobar/`.

- `snapshot.json`: canonical current provider snapshot plus presenter `view`.
- `providers/github.json` and `providers/forgejo.json`: provider-specific snapshots for instant provider switching.
- `ui.json`: panel state (`open`, `mode` = `overview|triage`, `focusRepository`, `requestedAt`).
- `search.json`: async search state.
- `state-event.json`: stable watched reload signal.
- `daemon.sock`: daemon action socket.
- `cache/rest.json`, `cache/graphql.json`, and `cache/rate_limits.json`: network cache and rate-limit records.

## UI

QuickShell renders a transparent full-screen modal overlay whose frame is centered vertically and horizontally with small screen margins. The content includes a header, optional account activity heatmap, search results, an issue/PR reader, and repo cards. Repo cards use compact controls for pinned drag, open, read, refresh, pin/unpin, and hide. The repo heatmap track is clipped inside the card so controls cannot force the row outside the panel.

Waybar reads cached presenter state only. It never refreshes network data directly; refresh is a daemon action. Action-triggered refreshes may queue one pending follow-up, while scheduled timer ticks skip pending queueing when a refresh is already alive.
