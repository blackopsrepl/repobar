# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [2.1.0](https://github.com/blackopsrepl/repobar/compare/v2.0.2...v2.1.0) (2026-09-30)


### Features

* **threads:** fetch complete conversations through daemon-owned state 90abf51
* **triage:** show full conversations with author avatars 557c129


### Bug Fixes

* **ci:** syntax-check every Ruby file, not just the first c9cc5ac
* **release:** resolve bare-version changelog headings in release notes 48969a6

## [2.0.2](https://github.com/blackopsrepl/repobar/compare/v2.0.1...v2.0.2) (2026-09-30)


### Bug Fixes

* **release:** install jq in the Forgejo publish job b99b4e7

## [2.0.1](https://github.com/blackopsrepl/repobar/compare/v2.0.0...v2.0.1) (2026-09-30)


### Features

* **release:** publish releases from tags on both targets b6e578e

## [2.0.0](https://github.com/blackopsrepl/repobar/compare/v1.1.0...v2.0.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* drop Forgejo support and make triage a scored work queue

### Features

* drop Forgejo support and make triage a scored work queue d4d55f4

## [1.1.0](https://github.com/blackopsrepl/repobar/compare/v1.0.1...v1.1.0) (2026-09-30)


### Features

* **build:** add install-user target for a ~/.local install 175b1e4
* **omarchy:** mount the Waybar chip as an Omarchy shell bar module 948ce39
* **triage:** add a visual cross-repo triage mode 487c965
* **ui:** follow the active Omarchy theme 5c013a6


### Bug Fixes

* **omarchy:** embed the selected config in the bar module 6b56f8f
* **omarchy:** reject an index past the section end 5603b41
* **runtime:** coalesce bar refresh through the daemon action f7cffef

## [1.0.1](///compare/v1.0.0...v1.0.1) (2026-08-26)


### Bug Fixes

* **quickshell:** accelerate repository wheel scrolling 65a100f
* **quickshell:** accumulate repository wheel velocity 0782ac7
* **quickshell:** bind wheel speed to repository list d0e1864
* **quickshell:** use a native repository list d308191
* **runtime:** retain repositories on transient refresh failures 22346ae

## [1.0.0](///compare/v0.1.1...v1.0.0) (2026-05-16)


### Features

* **runtime:** preserve refresh state and pinned ordering a00bf28
* **ui:** center modal and drag pinned repos 8711f86

## 1.0.0 (2026-05-16)

### Features

* center the QuickShell UI as a taller modal overlay
* remove the pinned repository cap and preserve configured pinned order
* add drag and CLI reordering for pinned repositories
* preserve provider caches when refreshes overlap provider switches or same-provider pin changes

### Documentation

* align README, AGENTS, wireframe, PRD, architecture, and CLI docs to the current runtime
* refresh README screenshots for the modal overlay and pinned repo drag controls

## 0.1.1 (2026-05-16)


### Features

* add RepoBar Linux runtime 3b8d0ad
* add single-path runtime store 2af7a90
* make QuickShell panel state-driven 0e4b708
* route runtime actions through daemon 589be3e
* **runtime:** expose activity and work item views b13c4a8
* **ui:** add spiffy repo action controls b564c7f


### Bug Fixes

* show commit activity heatmap 5447615
