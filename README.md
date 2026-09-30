# RepoBar Linux

<p align="center">
  <img src="docs/assets/repobar-mascot.png" alt="RepoBar Linux mascot" width="240">
</p>

RepoBar Linux is a SolverForge Linux companion for watching GitHub.com repository pressure from Waybar. It keeps the product idea from [steipete](https://github.com/steipete)'s original [RepoBar](https://github.com/steipete/RepoBar), but the implementation is native to this desktop stack: Ruby backend, cached JSON state, a resident action daemon, a compact Waybar chip, and one QuickShell panel.

## Screenshots

### Centered QuickShell Modal

![RepoBar Linux QuickShell modal centered vertically with repository pressure, account activity, repo cards, and pinned repo controls](docs/assets/repobar-panel-screenshot.png)

### Pinned Repo Reordering

![RepoBar Linux pinned repository card controls with the drag handle and compact icon actions](docs/assets/repobar-pinned-reorder-screenshot.png)

## Current Shape

- CLI entrypoint: `bin/repobar`
- Current release: `v2.0.0`
- Backend code: `lib/repobar/core`
- Runtime code: `lib/repobar/runtime`
- Human UI: `frontend/quickshell/shell.qml`
- Config: `~/.repobar/config.json`
- Runtime state: `~/.local/state/repobar/`
- Local release gate: `bin/release-check`

RepoBar has one product UI: QuickShell. Waybar is only a launcher and cached-state renderer. The QuickShell panel reads `snapshot.json`, `ui.json`, `search.json`, and `state-event.json`; it never calls GitHub.com or `git` directly.

## What It Shows

- GitHub account, repository count, PR count, issue count, and stale/loading state.
- GitHub account activity heatmap when `settings.showContributionHeader` is enabled.
- Repository cards with avatar, description, CI state, open PRs, open issues, stars, last push, release/activity summary, local branch state, dirty count, and activity heatmap.
- A reader panel for cached PR and issue previews, including body excerpts, authors, update age, labels, draft state, and links.
- Search results that can be opened or pinned without a full refresh round trip.
- Icon controls for open, read, refresh, pin/unpin, and hide, plus a drag handle on pinned repo cards. Pinned repos are uncapped, preserve the configured order, project into cached state immediately, and are later hydrated by the daemon.
- A triage mode: a cross-repo inbox of every cached open PR and issue with an attention score, an action line, explained signals (CI failing, local dirty, priority/blocked/bug/needs-review labels, unanswered, draft, staleness), a repo rail, toned label chips, and a full-body reader, plus a repo fact grid per item. Nothing in triage fetches.
- Waybar classes for `healthy`, `loading`, `stale`, `error`, `has-work`, `has-ci-failures`, `local-dirty`, and `rate-limited`.

## Runtime Flow

`repobar daemon` owns effects and state transitions. CLI commands and QuickShell actions dispatch to the daemon over `daemon.sock`; the daemon performs refreshes, search jobs, pin/unpin/hide/show mutations, pinned repo moves, and state projection.

RepoBar is GitHub-only: one REST/GraphQL client, one snapshot, no provider cache layer. A refresh that started under an older config identity (pinned order, hidden/visible repositories, local roots, state dir) is re-projected through the newer config before it is written, so a pin move or hide made mid-refresh cannot be overwritten — and a repository hidden mid-refresh is not resurrected.

`repoList.displayLimit` caps only unpinned repository extras. Every configured pinned repository is selected ahead of that limit, ordered by `repoList.pinnedRepositories`, and can be reordered with either the QuickShell drag handle or `repobar pin move`.

Refresh writes:

- `snapshot.json`: raw repositories, local checkouts, account data, and presenter-ready `view`.
- `state-event.json`: stable watched file that tells QuickShell to reload state.

UI commands write:

- `ui.json`: panel open/closed state and focus request.
- `search.json`: async search status, query, selection, results, errors, and timestamp.

Network cache files live under `~/.local/state/repobar/cache/`:

- `rest.json`
- `graphql.json`
- `rate_limits.json`

## GitHub Access

RepoBar speaks the GitHub.com REST and GraphQL APIs and nothing else. It uses `gh auth token`, `REPOBAR_GITHUB_TOKEN`, or `GITHUB_TOKEN` (`github.authSource` = `gh` or `env`). No second provider exists, and a leftover non-https host or provider key in `config.json` normalizes back to the GitHub defaults rather than loading a dead endpoint.

## Desktop Autostart

RepoBar has two separate runtime pieces:

- `repobar daemon --config ~/.repobar/config.json` refreshes repository state, serves actions, and writes cached snapshots.
- `repobar waybar render --config ~/.repobar/config.json` reads cached state and returns Waybar JSON.

Waybar does not fetch GitHub or local repository state by itself. If the daemon is not running after login or reboot, the Waybar chip can still render stale cached state. A desktop integration should start and supervise the daemon at session startup.

On SolverForge Linux, the managed Waybar integration starts companion daemons through `solverforge-waybar-companions-start`, launched from Sway `exec_always` beside Waybar. Edit that managed default layer, not symlinked files under `~/.config/waybar`.

## Hyprland + Omarchy

On a Hyprland desktop running the Omarchy shell, the Waybar chip mounts as a bar command module:

```bash
bin/repobar omarchy install   # adds the repobar module next to omarchy.weather
bin/repobar omarchy status
bin/repobar omarchy remove
```

`omarchy install` seeds `~/.config/omarchy/shell.json` from the Omarchy defaults when the user file does not exist yet, inserts a `type: command` module (default placement: `--after omarchy.weather`), and asks the running shell to reload its config. The module polls `repobar waybar render` on an interval (`--interval`, default 5), opens the QuickShell panel on left click, and triggers the daemon refresh path on middle click. The daemon itself is not started by the module; launch it at session startup, for example from Hyprland:

```ini
exec-once = repobar daemon
```

The `waybar` chip contract is unchanged: Waybar on sway and the Omarchy shell on Hyprland both render the same cached-state JSON. The QuickShell panel follows the active Omarchy theme (live, via `theme/colors.toml`); outside Omarchy it keeps the built-in palette.

## Commands

```bash
bin/repobar auth status
bin/repobar status
bin/repobar login
bin/repobar logout
bin/repobar config init
bin/repobar config validate
bin/repobar refresh
bin/repobar daemon
bin/repobar daemon --once
bin/repobar repos --filter work --sort prs
bin/repobar repos --scope pinned
bin/repobar repos --scope hidden
bin/repobar search fizzy
bin/repobar search select pvd/fizzy
bin/repobar repo openclaw/openclaw
bin/repobar issues openclaw/openclaw
bin/repobar pulls openclaw/openclaw
bin/repobar releases openclaw/openclaw
bin/repobar ci openclaw/openclaw
bin/repobar discussions openclaw/openclaw
bin/repobar tags openclaw/openclaw
bin/repobar branches openclaw/openclaw
bin/repobar contributors openclaw/openclaw
bin/repobar commits openclaw/openclaw
bin/repobar activity openclaw/openclaw
bin/repobar contributions blackopsrepl
bin/repobar local
bin/repobar local --root /srv/lab/tools --depth 2
bin/repobar local sync openclaw/openclaw
bin/repobar local rebase openclaw/openclaw
bin/repobar local branches openclaw/openclaw
bin/repobar local reset openclaw/openclaw --yes
bin/repobar worktrees openclaw/openclaw
bin/repobar checkout openclaw/openclaw
bin/repobar checkout openclaw/openclaw --destination ~/hack/openclaw
bin/repobar checkout openclaw/openclaw --open
bin/repobar pin openclaw/openclaw
bin/repobar pin move openclaw/openclaw 0
bin/repobar unpin openclaw/openclaw
bin/repobar hide openclaw/openclaw
bin/repobar show openclaw/openclaw
bin/repobar settings show
bin/repobar settings set repo-limit 8
bin/repobar cache status
bin/repobar cache clear
bin/repobar rate-limits
bin/repobar archives list
bin/repobar changelog README.md
bin/repobar markdown README.md
bin/repobar open https://github.com/openclaw/openclaw
bin/repobar open finder openclaw/openclaw
bin/repobar open terminal openclaw/openclaw
bin/repobar panel
bin/repobar ui open
bin/repobar ui triage
bin/repobar ui close
bin/repobar ui toggle
bin/repobar ui status --format json --pretty
bin/repobar waybar render
bin/repobar waybar refresh
bin/repobar waybar panel
bin/repobar waybar open
bin/repobar omarchy install
bin/repobar omarchy status
bin/repobar omarchy remove
bin/release-check
```

See [docs/cli.md](docs/cli.md) for the full CLI surface and flags.

## Continuous Integration And Releases

Both publication targets run the same gate. A push to `main` and every pull
request run `make check` plus the QuickShell contract test; a `v*` tag runs the
same checks and then publishes a release.

- GitHub Actions (`.github/workflows/`): `ci.yml` runs on main pushes and pull
  requests; `release.yml` runs on a `v*` tag, reuses `ci.yml`, checks the tag
  against the README version surface, and publishes a release whose notes are the
  generated changelog section for that tag.
- Forgejo Actions (`.forgejo/workflows/`): `ci.yml` runs on the local `ruby`
  runner; `release.yml` verifies the tag, builds a source tarball with
  `git archive`, and publishes a release with the tarball and its `sha256` as
  assets.

`README.md`'s `Current release` line is the version surface. `.versionrc.js`
owns it, so a release is always `commit-and-tag-version` plus a push — never a
hand edit. Both release workflows refuse a tag that does not match it.

The QuickShell panel is not linted in CI: `qmllint` cannot resolve the
Quickshell `ShellRoot` type off a Quickshell install and fails a clean panel.
`make lint` runs it where Quickshell exists, `bin/release-check` skips it loudly
when the imports are unresolvable, and `test/runtime_test.rb` asserts the panel's
structural contract on every run.

## Verification

```bash
ruby -wc $(rg --files bin lib test)
ruby -Itest test/run.rb
qmllint frontend/quickshell/shell.qml
bin/repobar config validate
bin/repobar waybar render
bin/repobar ui status --format json --pretty
bin/release-check
```

QuickShell smoke:

```bash
env QT_QPA_PLATFORM=wayland \
  REPOBAR_BIN=$PWD/bin/repobar \
  REPOBAR_CONFIG=$HOME/.repobar/config.json \
  REPOBAR_STATE_DIR=$HOME/.local/state/repobar \
  quickshell --path $PWD/frontend/quickshell/shell.qml
```
