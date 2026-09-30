# RepoBar Repo Wireframe

## Product Boundary

RepoBar Linux is a repository-pressure companion for SolverForge Linux. The product surface is a Waybar chip plus one QuickShell panel. The backend is Ruby, cache-backed, and daemon-owned.

No UI layer fetches hosted repository data directly. GitHub.com calls stay in `lib/repobar/core/github.rb`; local checkout inspection stays in `lib/repobar/core/local_git.rb`.

## High-Level Shape

1. `bin/repobar` starts the CLI.
2. `lib/repobar/cli.rb` parses commands and dispatches either read-only work or daemon-owned actions.
3. `lib/repobar/core/config.rb` normalizes config and settings.
4. `lib/repobar/core/cache.rb` stores REST responses, GraphQL responses, and rate-limit observations.
5. `lib/repobar/core/github.rb` fetches GitHub.com repository/account data (the only provider).
6. `lib/repobar/core/local_git.rb` scans local checkouts and maps them to hosted repos.
7. `lib/repobar/runtime/daemon.rb` owns the action socket, refresh loop, refresh request coalescing, search jobs, and async effects.
8. `lib/repobar/runtime/store.rb` mutates runtime/config state for visibility changes, search state, and projections.
9. `lib/repobar/runtime/state.rb` reads and writes cached JSON state.
10. `lib/repobar/runtime/presenter.rb` converts raw data into UI-ready `view` state.
11. `lib/repobar/runtime/waybar.rb` renders compact Waybar JSON from cached state.
12. `lib/repobar/runtime/quickshell.rb` opens, closes, toggles, and launches the QuickShell shell.
13. `frontend/quickshell/shell.qml` renders the human UI from watched JSON files.

## Runtime Files

All runtime files default to `~/.local/state/repobar/`.

- `snapshot.json`: canonical cached snapshot plus presenter `view` (including `view.triage`).
- `ui.json`: panel open state, focused repo, request timestamp.
- `search.json`: async search status, query, request id, selection, results, error, timestamp.
- `state-event.json`: stable watched reload signal for QuickShell.
- `daemon.lock`: daemon singleton lock.
- `daemon.sock`: daemon action socket.
- `refresh.lock`: refresh serialization lock.
- `cache/rest.json`: REST cache keyed by request URI.
- `cache/graphql.json`: GraphQL cache keyed by query and variables.
- `cache/rate_limits.json`: observed rate-limit state.

## Refresh Flow

1. `repobar daemon`, `repobar daemon --once`, or `repobar refresh` loads config.
2. `Runtime::State.with_refresh_lock` serializes refresh work.
3. `Core::GitHub.auth_status` checks GitHub auth.
4. If authenticated and `settings.showContributionHeader` is enabled, `Core::GitHub.account_heatmap` fetches the account activity calendar.
5. `Core::GitHub.fetch_repositories` loads all pinned repositories first, then visible/recent user repositories up to `repoList.displayLimit`, filters hidden/fork/archive rows, sorts them, and hydrates selected rows. The limit applies only to unpinned extras.
6. Hydration adds open issue/PR counts, issue/PR preview items, latest release, CI status, recent activity, traffic where available, and per-repo activity heatmap.
7. `Core::LocalGit.scan` scans configured roots and `Core::LocalGit.match_repositories` attaches local branch/dirty/ahead/behind state.
8. `Runtime::Presenter.build_snapshot_view` creates summary, chip, account heatmap, repo views, local repo views, and the triage projection.
9. If the config identity still matches the refresh start identity, `Runtime::State.write_snapshot` writes `snapshot.json` and updates `state-event.json`.
10. If the user changed visibility or pinned order while the refresh was running, the completed refresh re-projects the refreshed rows through the newer pinned/hidden config before writing, so a mid-refresh hide or pin move survives.
12. `Runtime::Store.signal_waybar` sends the configured RTMIN signal to Waybar.

## Action Flow

1. CLI commands and QuickShell call `Runtime::Daemon.dispatch_action`.
2. `Runtime::Daemon.ensure_running` starts `repobar daemon` if no action socket is ready.
3. The daemon handles actions on `daemon.sock` and returns JSON results.
4. Actions that change repo visibility request a daemon refresh.
5. Action-triggered refresh requests are coalesced: while one refresh is running, additional action requests mark one pending follow-up instead of spawning unbounded refresh threads.
6. Scheduled timer refresh requests skip queuing pending follow-ups while a refresh is already alive, so slow network refreshes do not collapse into back-to-back timer refreshes.

Daemon-owned actions:

- `open_panel`
- `close_panel`
- `pin`
- `unpin`
- `pin_move`
- `hide`
- `show`
- `search_start`
- `search_select`
- `ping`

## Triage Flow

1. `Runtime::Presenter.triage_view` flattens every cached open PR and issue into one list, newest first, and scores each item: signals (CI failing, local dirty, label rules, review state, unanswered, hot thread, draft, stale/fresh) sum to a clamped attention score.
2. Attention decides the bucket. A score at or above the flagged threshold puts the item in `Needs attention`; otherwise age decides (`Today` / `This week` / `This month` / `Older`).
3. Each item also carries an action line (the highest-weight blocker's hint), a repo context block, toned label chips, and its full body.
4. `triage_view` also rolls up per-repo counts (`repos`) and summary counts (pulls, issues, flagged, stale, unanswered, drafts).
5. The panel renders three panes from that one projection: repo rail, filterable inbox, reader. Filtering, selection, and reading are view-local and never fetch.

## Pinned Repo Flow

1. `repobar pin owner/name` normalizes the full name, removes it from hidden repos, appends it to `repoList.pinnedRepositories` if missing, projects the current snapshot immediately, and requests a coalesced refresh.
2. `repobar unpin owner/name` removes the full name from `repoList.pinnedRepositories`, projects the current snapshot immediately, and requests a coalesced refresh.
3. `repobar pin move owner/name POSITION` moves an existing pinned repo to the zero-based non-negative position, clamps positions beyond the end to the last valid slot, saves config, and projects the new order without forcing a network refresh.
4. In QuickShell, pinned repo cards show a drag handle. Dropping one pinned card onto another dispatches `repobar pin move` with the dropped card's target index.
5. Pinned repositories are not capped by `repoList.displayLimit`; the limit applies only to unpinned extras after all pins have been selected.

## Search Flow

1. QuickShell text input calls `repobar search <query> --limit 8`.
2. The daemon writes `search.json` as `loading` with a request id.
3. A search thread calls `Core::GitHub.search_repositories`.
4. The daemon writes `search.json` as `ready` or `error`.
5. QuickShell renders up to six results.
6. Search results can be selected, opened, or pinned.
7. Pinning a search result inserts a pending projected repo into `snapshot.json`; the next refresh hydrates it.

## QuickShell Layout

Modal overlay:

1. The QuickShell surface is a transparent full-screen `PanelWindow`.
2. The dim overlay covers the screen without claiming Waybar layout space.
3. The modal frame is centered vertically and horizontally relative to the screen.
4. The frame uses nearly the full screen height with small vertical margins, giving the account heatmap, reader, and repo list more vertical room.

Panel content:

1. Header with title, active account, repository/work counts, refresh, and close.
2. Optional account activity heatmap with summary stats.
3. Search input and result list.
4. Optional issue/PR reader panel for the selected repository.
5. Scrollable repository card list.
6. Triage mode replaces 3-5 with a repo rail, a filterable inbox, and a detailed reader.

Repo cards:

1. Status rail.
2. Owner avatar or fallback initial.
3. Repository name, description, CI/PR/issue/star/update line, local checkout line, release/activity line.
4. Activity heatmap text plus clipped heatmap track.
5. Icon action strip: drag handle when pinned, open, read, refresh, pin/unpin, hide.

Search results:

1. Owner avatar or fallback initial.
2. Repository name, description, stars.
3. Icon actions: open and pin/already-pinned.

Reader panel:

1. Selected repo title and work count.
2. Up to three cached PR previews.
3. Up to three cached issue previews.
4. Open buttons for preview URLs.

Triage panes:

1. Repo rail: one row per repo with open PR/issue counts and flagged/quiet counts; click scopes the inbox, middle-click opens the repo.
2. Inbox: kind chips, flagged/quiet/repo/grouping chips, a text filter, and rows carrying an attention rail, tone-coloured signal chips, an attention score, and an opened mark; `Needs attention` section first.
3. Reader: type/number/bucket/attention header, the action line, the full explained signal set, a repo fact grid (repo, CI, open work, stars, last push, release, local, heatmap), toned label chips, the full body, and Open item / Open repo.

## Waybar Flow

1. Waybar calls `repobar waybar render`.
2. `Runtime::Waybar.payload` reads the cached snapshot only.
3. If no snapshot exists, Waybar renders a loading chip.
4. If a snapshot exists, presenter chip text and classes become the Waybar JSON payload.
5. Middle click should route to `repobar waybar refresh`; left/right click should route to `repobar waybar panel` or equivalent wrapper.

## Canonical Files

- `README.md`
- `PRD.md`
- `WIREFRAME.md`
- `AGENTS.md`
- `docs/architecture.md`
- `docs/cli.md`
- `bin/repobar`
- `bin/release-check`
- `lib/repobar/core/config.rb`
- `lib/repobar/core/cache.rb`
- `lib/repobar/core/github.rb`
- `lib/repobar/core/local_git.rb`
- `lib/repobar/runtime/state.rb`
- `lib/repobar/runtime/store.rb`
- `lib/repobar/runtime/presenter.rb`
- `lib/repobar/runtime/daemon.rb`
- `lib/repobar/runtime/quickshell.rb`
- `lib/repobar/runtime/waybar.rb`
- `frontend/quickshell/shell.qml`
- `test/`
