# frozen_string_literal: true

require_relative "test_helper"

class RuntimeTest < Minitest::Test
  def test_snapshot_contains_view_and_waybar_work_classes
    config = build_config
    repos = [
      sample_repo(name: "openclaw/openclaw", prs: 2, issues: 1, ci: "failing", dirty: true),
      sample_repo(name: "solverforge/solverforge-rs", prs: 0, issues: 0, ci: "passing")
    ]
    account = { authenticated: true, login: "blackopsrepl", rateLimit: { remaining: 4, limit: 5000 } }

    snapshot = RepoBar::Runtime::State.build_snapshot(config, repos, [], account, Time.now.utc)
    payload = RepoBar::Runtime::Waybar.payload(config, snapshot, Time.now)

    assert_equal 2, snapshot.dig(:view, :summary, :repoCount)
    assert_equal "blackopsrepl", snapshot.dig(:view, :summary, :account)
    assert_equal "2 PR 1 issue", payload[:text]
    assert_includes payload[:class], "has-work"
    assert_includes payload[:class], "has-ci-failures"
    assert_includes payload[:class], "local-dirty"
    assert_includes payload[:class], "rate-limited"
    assert_includes payload[:tooltip], "RepoBar (GitHub)"
  end

  def test_waybar_payload_reports_loading_without_snapshot
    config = build_config
    payload = RepoBar::Runtime::Waybar.payload(config, nil, Time.now)

    assert_equal "...", payload[:text]
    assert_includes payload[:class], "loading"
    assert_includes payload[:tooltip], "cached GitHub data"
  end

  def test_repo_view_always_exposes_heatmap_track
    view = RepoBar::Runtime::Presenter.repo_view(build_config, sample_repo, Time.now.utc)

    assert_equal 42, view.dig(:heatmap, :cells).length
  end

  def test_snapshot_view_exposes_account_heatmap_track
    config = build_config
    start = Date.today - 370
    weeks = (0...53).map do |week|
      {
        cells: (0...7).map do |day|
          date = start + (week * 7) + day
          { date: date.iso8601, count: date == Date.today ? 2 : 0 }
        end
      }
    end
    account = {
      authenticated: true,
      login: "blackopsrepl",
      provider: "github",
      heatmap: {
        available: true,
        total: 2,
        max: 2,
        weeks: weeks
      }
    }

    snapshot = RepoBar::Runtime::State.build_snapshot(config, [sample_repo], [], account, Time.now.utc)

    assert_equal true, snapshot.dig(:view, :accountHeatmap, :available)
    assert_equal 2, snapshot.dig(:view, :accountHeatmap, :total)
    assert_equal 53, snapshot.dig(:view, :accountHeatmap, :weeks).length
    assert_equal 7, snapshot.dig(:view, :accountHeatmap, :rows).length
    assert_equal [53], snapshot.dig(:view, :accountHeatmap, :rows).map { |row| row[:cells].length }.uniq
    assert_equal 371, snapshot.dig(:view, :accountHeatmap, :cells).length
    assert_equal 1, snapshot.dig(:view, :accountHeatmap, :stats, :activeDays)
    assert_equal 1, snapshot.dig(:view, :accountHeatmap, :stats, :currentStreak)
    assert_equal 2, snapshot.dig(:view, :accountHeatmap, :stats, :bestCount)
    assert_equal Date.today.iso8601, snapshot.dig(:view, :accountHeatmap, :stats, :bestDay)
  end

  def test_repo_view_exposes_readable_issue_and_pull_items
    repo = sample_repo.merge(
      issues: [
        {
          number: 7,
          title: "Readable issue",
          author: "pvd",
          body: "Line one\nline two",
          updatedAt: Time.now.utc.iso8601,
          labels: ["bug"]
        }
      ],
      pulls: [
        {
          number: 8,
          title: "Readable PR",
          author: "pvd",
          body: "Pull body",
          updatedAt: Time.now.utc.iso8601,
          draft: true
        }
      ]
    )

    view = RepoBar::Runtime::Presenter.repo_view(build_config, repo, Time.now.utc)

    assert_equal "Line one line two", view.dig(:issues, 0, :body)
    assert_equal ["bug"], view.dig(:issues, 0, :labels)
    assert_equal true, view.dig(:pulls, 0, :draft)
    assert_equal "Pull body", view.dig(:pulls, 0, :body)
  end

  def test_repo_view_exposes_pinned_state
    config = build_config
    config[:repoList][:pinnedRepositories] = ["openclaw/openclaw"]
    view = RepoBar::Runtime::Presenter.repo_view(config, sample_repo(name: "OpenClaw/OpenClaw"), Time.now.utc)

    assert_equal true, view[:pinned]
  end

  def test_state_event_file_keeps_stable_inode_across_snapshot_writes
    config = build_config
    snapshot = RepoBar::Runtime::State.build_snapshot(config, [sample_repo], [], {}, Time.now.utc)

    RepoBar::Runtime::State.write_snapshot(config, snapshot)
    event_path = RepoBar::Runtime::State.state_event_path(config)
    first_inode = File.stat(event_path).ino

    RepoBar::Runtime::State.write_snapshot(config, snapshot.merge(generatedAt: Time.now.utc.iso8601))

    assert_equal first_inode, File.stat(event_path).ino
    assert_match(/updatedAt/, File.read(event_path))
  end

  def test_shell_qml_wires_triage_mode
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    # Mode is driven by ui.json, not ad hoc UI state.
    assert_match(/uiAdapter\.mode === "triage"/, qml)
    assert_match(/runRepobar\(\["ui", "mode", "triage"\]\)/, qml)
    assert_match(/runRepobar\(\["ui", "mode", "overview"\]\)/, qml)

    # The inbox list exists and is selection-driven.
    assert_match(/id: inboxList/, qml)
    assert_match(/function moveTriageSelection\(/, qml)
    assert_match(/function filteredTriageItems\(/, qml)

    # The reader renders the full body from the snapshot projection.
    assert_match(/bodyFull/, qml)

    # Overview-only blocks disappear in triage mode.
    assert_match(/visible: !root\.triageMode\(\)/, qml)
  end

  # qmllint cannot resolve the Quickshell `ShellRoot` type in CI, so CI cannot
  # lint the panel. These structural assertions run everywhere Ruby runs and
  # catch the panel defects that actually shipped this iteration.
  def test_shell_qml_structural_contract
    path = File.expand_path("../frontend/quickshell/shell.qml", __dir__)
    qml = File.read(path)

    # Balanced braces and parens: catches a mistyped handler or a dropped block
    # in a 2800-line panel without needing a QML toolchain.
    assert_equal qml.count("{"), qml.count("}"), "unbalanced braces in shell.qml"
    assert_equal qml.count("("), qml.count(")"), "unbalanced parens in shell.qml"

    # Repeater delegates must be Items; Shortcut is a QtObject, so generated
    # numbered shortcuts require Instantiator.
    qml.scan(/Repeater\s*\{(.*?)\n    \}/m).each do |block|
      refute_match(/^\s*Shortcut\s*\{/m, block.first.to_s, "Repeater must not delegate a Shortcut")
    end
    assert_match(/Instantiator\s*\{\s*\n\s*model:\s*9/, qml)

    # The triage filter field must not bind its own text to the property its
    # edit handler writes, which re-resolves the binding mid-edit.
    filter_block = qml[/id:\s*triageSearchInput.*?\n                            \}/m].to_s
    refute_empty filter_block, "triage search field not found"
    refute_match(/^\s*text:\s*root\.triageQuery/, filter_block)
    assert_match(/onTextEdited:\s*root\.setTriageQuery\(text\)/, filter_block)

    # Every single-letter triage shortcut stands down while the filter is focused.
    %w[j k g f s].each do |key|
      block = qml[/sequence:\s*"#{key}"\n(?:.*\n){0,4}?\s*enabled:\s*([^\n]+)/, 1].to_s
      refute_empty block, "shortcut #{key} not found"
      assert_includes block, "triageShortcutLive()", "shortcut #{key} is not gated on triageShortcutLive()"
    end

    # Triage panes and repo cards must not render at the same time.
    assert_match(/visible:\s*!root\.triageMode\(\)/, qml)
    %w[triageSplit repoRailCol inboxCol readerCol].each do |id|
      assert_match(/id:\s*#{id}/, qml, "missing triage element #{id}")
    end
  end
end
