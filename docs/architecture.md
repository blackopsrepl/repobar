# Architecture

RepoBar Linux has five active layers:

1. Ruby CLI in `bin/repobar`.
2. Core Ruby services for config, hosted APIs, cache, local git, formatting, and process execution.
3. Daemon-owned runtime actions and cached JSON state.
4. Presenter output for Waybar and QuickShell.
5. QuickShell panel plus Waybar chip.

## Boundaries

The hosted-repository boundary lives in `lib/repobar/core/github.rb`. It speaks the GitHub.com REST and GraphQL APIs only — RepoBar has no second provider. It also owns REST caching, GraphQL contribution calendar calls, issue/PR/release/CI/activity hydration, and account/repo heatmaps.

The local checkout boundary lives in `lib/repobar/core/local_git.rb`. It scans configured roots, resolves repo targets, reports branch/dirty/ahead/behind state, and performs explicit sync/rebase/reset/clone operations.

The runtime boundary lives in `lib/repobar/runtime/daemon.rb`, `store.rb`, and `state.rb`. The daemon owns the action socket, refresh loop, refresh request coalescing, async search jobs, visibility mutations, pinned repo moves, and state projection.

`Runtime::Store.refresh_effect` records the config identity it started with. If that identity changed before the refresh finished (pinned order, hidden/visible repositories, local roots, state dir), the fresh rows are re-projected through the newer config before writeback, so a pin move or hide made mid-refresh cannot be overwritten by the refresh's older order — and a repository hidden mid-refresh is not resurrected. There is one snapshot: no per-provider cache layer.

Pinned repositories are selected and ordered independently of the normal display limit. `repoList.displayLimit` caps only unpinned extras, while `repoList.pinnedRepositories` controls every pinned row and its order. `repobar pin move owner/name POSITION` and the QuickShell drag handle both update that order through daemon-owned state.

The presentation boundary lives in `lib/repobar/runtime/presenter.rb`. It converts raw snapshots into summary state, Waybar chip state, account heatmap rows, repo cards, readable issue/PR previews, pinned state, normalized heatmap cells, and the triage projection.

The triage projection is where cross-repository pressure is scored. Each open issue/PR becomes a triage item carrying an age, a staleness flag, an attention score, a bucket, an action line, a repo context block, and a set of signals (CI failing, local dirty, priority/blocked/bug/review/help-wanted labels, review state, unanswered, hot thread, draft, stale/fresh). Weights live in `Presenter::TRIAGE_LABEL_RULES` and `triage_signals`; the clamped sum is the score, and a score at or above `TRIAGE_FLAGGED_SCORE` puts the item in the `Needs attention` bucket. The inbox, the repo rail, and the reader all read that one projection, so they cannot disagree.

The frontend boundary is `frontend/quickshell/shell.qml`. It watches JSON files, dispatches CLI commands, and renders the UI. It does not call GitHub.com or `git`.

## State

Runtime state defaults to `~/.local/state/repobar/`.

- `snapshot.json`: the canonical snapshot (repositories, local checkouts, account) plus presenter `view`, including `view.triage`.
- `ui.json`: panel state (`open`, `mode` = `overview|triage`, `focusRepository`, `requestedAt`).
- `search.json`: async search state.
- `thread.json`: the selected conversation transaction, with loading/ready/error state, request identity and presenter-shaped entries. API responses stay in the existing REST cache.
- `state-event.json`: stable watched reload signal.
- `daemon.sock`: daemon action socket.
- `cache/rest.json`, `cache/graphql.json`, and `cache/rate_limits.json`: network cache and rate-limit records.

## UI

QuickShell renders a transparent full-screen modal overlay whose frame is centered vertically and horizontally with small screen margins. The content includes a header, optional account activity heatmap, search results, an issue/PR reader, and repo cards. Repo cards use compact controls for pinned drag, open, read, refresh, pin/unpin, and hide. The repo heatmap track is clipped inside the card so controls cannot force the row outside the panel.

Triage mode replaces the repo list with three panes: a repo rail (per-repository pressure, click to scope, middle-click to open the repo), a filterable inbox (kind chips, flagged/quiet/repo/grouping chips, `/` text filter, attention-ordered with `Needs attention` first), and a conversation reader. Selecting an issue or PR automatically schedules its complete conversation through a debounced daemon action; QuickShell never calls GitHub directly. The reader shows the original post and untruncated comments, reviews and inline replies in an avatar timeline. A separate Context tab holds the explained signals, repo fact grid and toned labels from the triage projection. Overview's read control opens a repository work-item list beside the same conversation component, rather than browser-opening previews. Both readers watch selection-safe `thread.json` state and use the existing paginated REST cache. Refresh preserves already displayed entries for the same item; selecting a different item clears them. Single-letter triage shortcuts stand down while the triage search field has focus.

Waybar reads cached presenter state only. It never refreshes network data directly; refresh is a daemon action. Action-triggered refreshes may queue one pending follow-up, while scheduled timer ticks skip pending queueing when a refresh is already alive.
