# RepoBar Linux PRD

## Summary

RepoBar Linux is a SolverForge Linux implementation inspired by [steipete](https://github.com/steipete)'s original [RepoBar](https://github.com/steipete/RepoBar). It keeps the repository-pressure product idea, but implements it with the local companion architecture used across the SolverForge desktop:

- Ruby backend
- REST and GraphQL cache
- cached JSON runtime state
- resident daemon with an action socket
- QuickShell panel
- Waybar chip

## Goal

Make GitHub.com repository pressure visible without opening a browser:

- which repos have open PRs or issues
- which repos have failing, pending, or unknown CI
- which local checkouts are dirty, ahead, or behind
- whether GitHub rate limits are healthy when using GitHub.com
- when each repo last moved
- which repos are intentionally pinned, hidden, or pending hydration
- which pinned repos are intentionally ordered to the top
- whether the account has recent contribution/activity momentum

## Current Product Decisions

- Use the existing `gh` token, `REPOBAR_GITHUB_TOKEN`, or `GITHUB_TOKEN` for GitHub.com auth. GitHub.com is the only provider.
- Use standard-library Ruby and JSON cache/state.
- Do not implement GitHub App OAuth in this repo.
- Use RepoBar-owned JSON API cache files and import Discrawl-style archive snapshots into SQLite through the `sqlite3` CLI.
- Do not implement macOS Swift/AppKit, Sparkle, Keychain, or Homebrew paths.
- Use one human UI: QuickShell.
- Use Waybar only as a compact launcher/render surface.
- Keep hosted API calls out of QML.
- Keep search, refresh, repo visibility actions, and pinned repo moves daemon-owned.
- Keep pinned repositories uncapped by `repoList.displayLimit`; the limit applies only to unpinned extras after all pinned repositories are selected in configured order.
- Keep late refreshes from an older config identity from overwriting newer pinned/hidden state.
- Coalesce daemon-triggered refresh requests so rapid UI actions do not spawn unbounded refresh work.
- Do not let scheduled timer refresh ticks queue pending action refreshes while a refresh is already running.

## Runtime Contract

- CLI: `bin/repobar`
- Config: `~/.repobar/config.json`
- State directory: `~/.local/state/repobar/`
- Snapshot: `snapshot.json`
- UI state: `ui.json`
- Search state: `search.json`
- Reload event: `state-event.json`
- Daemon socket: `daemon.sock`
- Cache: `cache/rest.json`, `cache/graphql.json`, `cache/rate_limits.json`

The frontend reads files and sends mutations through CLI commands. It does not fetch repository-host data directly.

## UI Contract

The QuickShell panel should render:

- account/work summary
- optional account activity heatmap
- search input and async result list
- issue/PR reader panel for cached previews
- repo cards with status, avatar, description, metrics, local checkout state, release/activity summary, and per-repo activity heatmap
- compact controls for pinned drag, open, read, refresh, pin/unpin, and hide

The QuickShell panel is a modal overlay: it must open centered vertically and horizontally relative to the screen, with enough vertical space for account heatmap, reader, and multiple repo cards. Repo-card controls must remain inside the panel bounds at the minimum supported width.

## Success Criteria

- `repobar refresh` writes a usable snapshot from live GitHub.com data.
- `repobar waybar render` returns valid Waybar JSON from cached state.
- The QuickShell panel renders repo rows, account heatmap, search state, issue/PR previews, pinned state, status summaries, and the triage inbox/reader from watched JSON files.
- Local checkout state is matched to hosted repositories without mutating local repos.
- Pin/unpin/hide/show updates are visible immediately through projected cached state, then hydrated by daemon refresh.
- Pin move updates are visible immediately through projected cached state and preserve the configured pinned order.
- Pinned repositories are not capped by `repoList.displayLimit`.
- Late refreshes preserve newer pinned ordering and newer hidden state.
- Repeated refresh-triggering actions produce at most one active refresh and one pending daemon follow-up.
- Timer refresh ticks do not create immediate pending follow-ups while a refresh is already active.
- The SolverForge Waybar module opens the panel and refreshes on demand.
- `bin/release-check` passes on the local machine.
