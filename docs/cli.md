# RepoBar CLI

## Global Flags

- `--config PATH`
- `--format json|text`
- `--json`, `--json-output`, `-j`
- `--pretty`
- `--limit N`
- `--repo owner/name`
- `--plain`
- `--no-color`

## Provider And Config

- `repobar auth status`
- `repobar status`
- `repobar login`
- `repobar logout`
- `repobar config init`
- `repobar config validate`

RepoBar is GitHub-only: the GitHub.com REST/GraphQL API is the single source. It uses `gh auth token`, `REPOBAR_GITHUB_TOKEN`, or `GITHUB_TOKEN`. There is no second provider and no `config github|forgejo` or `provider` command; a non-https host or a leftover provider key in `config.json` normalizes back to the GitHub defaults instead of loading a dead endpoint.

## Repository Lists

- `repobar repos`
- `repobar repos --limit N`
- `repobar repos --scope pinned`
- `repobar repos --scope hidden`
- `repobar repos --pinned-only`
- `repobar repos --filter work|issues|prs`
- `repobar repos --only-with work|issues|prs`
- `repobar repos --sort issues|prs|stars|repo`
- `repobar repos --owner LOGIN`
- `repobar repos --mine`
- `repobar repos --age DAYS`
- `repobar repos --forks`
- `repobar repos --archived`

Default `repos` output comes from the cached snapshot, refreshing only when no snapshot exists. Pinned and hidden scopes hydrate the named repositories directly. Activity ordering is the default fetch/menu order rather than a separate CLI sort mode.

## Repository Details

- `repobar repo owner/name`
- `repobar issues owner/name`
- `repobar pulls owner/name`
- `repobar releases owner/name`
- `repobar ci owner/name`
- `repobar discussions owner/name`
- `repobar tags owner/name`
- `repobar branches owner/name`
- `repobar contributors owner/name`
- `repobar commits owner/name`
- `repobar activity owner/name`
- `repobar commits LOGIN`
- `repobar activity LOGIN`
- `repobar contributions [LOGIN]`

`discussions` and `contributions` are GitHub-only surfaces; `contributions` prints the GitHub contribution-chart image URL for a login.

## Conversations

- `repobar thread owner/name --number N --kind issue|pr --json`
- `repobar thread fetch owner/name#N --repo owner/name --number N --kind issue|pr`

`thread` reads the complete paginated conversation through the existing REST cache. Issues include comments; PRs include comments, reviews and inline review notes, merged chronologically with author avatars. An explicit `--limit N` keeps the newest N entries. `thread fetch` dispatches a daemon-owned async transaction to `thread.json`; the reader watches loading/ready/error state and rejects late results for older selections.

## Search

- `repobar search query`
- `repobar search query --limit N`
- `repobar search select owner/name`

Search is daemon-owned and async. `search query` writes `search.json` as `loading`, starts a search thread, then writes `ready` or `error`. The QuickShell panel renders search state from the watched file.

## Repo Visibility

- `repobar pin owner/name`
- `repobar pin move owner/name POSITION`
- `repobar unpin owner/name`
- `repobar hide owner/name`
- `repobar show owner/name`

Visibility commands mutate `repoList.pinnedRepositories` and `repoList.hiddenRepositories` through the daemon. They project cached state immediately and request a coalesced async refresh. Pinning a search result inserts a pending row until the next refresh hydrates it. Pinned repositories are uncapped by `repoList.displayLimit`; the limit applies only to unpinned extras after all pins are selected.

`repobar pin move owner/name POSITION` reorders an existing pinned repository to a zero-based non-negative position, clamps positions beyond the end to the last valid slot, updates cached projection immediately, and does not force a network refresh.

## Local Git

- `repobar local`
- `repobar local --root PATH`
- `repobar local --depth N`
- `repobar local --sync`
- `repobar local sync <path|owner/name>`
- `repobar local rebase <path|owner/name>`
- `repobar local branches <path|owner/name>`
- `repobar local reset <path|owner/name> --yes`
- `repobar worktrees <path|owner/name>`
- `repobar checkout owner/name`
- `repobar checkout owner/name --destination PATH`
- `repobar checkout owner/name --open`
- `repobar open finder <path|owner/name>`
- `repobar open terminal <path|owner/name>`

`local reset` refuses to hard-reset without `--yes`.

## Runtime And UI

- `repobar refresh`
- `repobar refresh --format json`
- `repobar daemon`
- `repobar daemon --once`
- `repobar panel`
- `repobar ui open`
- `repobar ui triage`
- `repobar ui mode overview|triage`
- `repobar ui close`
- `repobar ui toggle`
- `repobar ui status`
- `repobar waybar render`
- `repobar waybar refresh`
- `repobar waybar panel`
- `repobar waybar open`
- `repobar omarchy install`
- `repobar omarchy status`
- `repobar omarchy remove`
- `repobar open URL`

`waybar render` reads cached state only. `waybar refresh` calls the daemon refresh path. Daemon-triggered refresh requests are coalesced so repeated UI actions can leave one active refresh and one pending follow-up, not one thread per click. `panel`, `ui open`, and `waybar panel` open the QuickShell panel.

`ui triage` opens the panel straight into triage mode: a cross-repository inbox of cached open pull requests and issues beside a full-body reader, fed by the presenter's triage projection. Each item carries an attention score, a bucket (`Needs attention` first, then `Today` / `This week` / `This month` / `Older`), an action line, a repo context block, and signals such as CI failing, local dirty, priority/blocked/bug/needs-review labels, unanswered issues, draft state, and staleness.

Triage keys: `j`/`k` move, `n`/`p` jump to the next/previous flagged item, `1`-`9` jump to the nth item, `/` focuses the filter field, `f` toggles the flagged-only filter, `s` toggles the quiet-only filter, `g` toggles age grouping, `[`/`]` cycle the repo scope, `A` clears the repo scope, `o` opens the selected item on GitHub, `t` refreshes its automatically loaded conversation, `r` refreshes. Clicking a repo-rail row scopes the inbox to that repo; middle-clicking it opens the repo. Filtering remains a snapshot projection; selecting an item automatically schedules its conversation asynchronously through the daemon and existing REST cache. The Conversation tab shows the full avatar timeline; Context holds repo facts and explained signals. Overview's read control opens a work-item list beside the same in-panel reader. Single-letter triage keys are disabled while the triage filter field has focus, so typing a query never triggers a shortcut.

`omarchy install` mounts the Waybar chip as an Omarchy shell bar command module in `~/.config/omarchy/shell.json`, by default after `omarchy.weather`; it seeds the user file from the Omarchy defaults when missing. Flags: `--after ID`, `--section left|center|right`, `--index N`, `--interval SECONDS` (default 5), `--exec PATH`. `omarchy status` reports the installed module, and `omarchy remove` drops it.

## Verification Targets

- `make test` — the Ruby suite
- `make syntax` — `ruby -wc` over `bin`, `lib` and `test` (requires `rg`)
- `make lint` — `qmllint` on the QuickShell panel (requires Quickshell)
- `make check` — `syntax`, the suite, and `config validate`
- `bin/release-check` — the full local gate: syntax, suite, QML lint, CLI smoke,
  archive import, live GitHub refresh when `gh` is authenticated, and a
  QuickShell load when `quickshell` is present

## Settings

- `repobar settings show`
- `repobar settings set refresh-interval 5m`
- `repobar settings set repo-limit 8`
- `repobar settings set show-forks true`
- `repobar settings set show-archived false`
- `repobar settings set menu-sort prs`
- `repobar settings set show-contribution-header true`
- `repobar settings set show-rate-limit-meter true`
- `repobar settings set card-density comfortable`
- `repobar settings set accent-tone github-green`
- `repobar settings set activity-scope all`
- `repobar settings set heatmap-display inline`
- `repobar settings set heatmap-span 6m`
- `repobar settings set launch-at-login true`
- `repobar settings set local-root /srv/lab/tools`
- `repobar settings set local-auto-sync false`
- `repobar settings set local-fetch-interval 5m`
- `repobar settings set local-worktree-folder .work`
- `repobar settings set local-preferred-terminal kitty`
- `repobar settings set local-ghostty-mode new-window`
- `repobar settings set local-show-dirty-files true`

Unknown setting keys are stored under `settings` as custom values.

## Cache And Archives

- `repobar cache status`
- `repobar cache clear`
- `repobar rate-limits`
- `repobar archives list`
- `repobar archives add NAME --repo PATH --db PATH`
- `repobar archives add NAME --remote URL --branch main --db PATH`
- `repobar archives remove NAME`
- `repobar archives enable NAME`
- `repobar archives disable NAME`
- `repobar archives status [NAME]`
- `repobar archives validate [NAME]`
- `repobar archives update NAME`

Archives import Discrawl-style snapshot repositories into SQLite through the `sqlite3` CLI.

## Utility Commands

- `repobar changelog [path]`
- `repobar changelog [path] --release VERSION`
- `repobar markdown path`

`markdown` strips front matter and basic Markdown markup for plain-text display.
