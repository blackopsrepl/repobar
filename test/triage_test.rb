# frozen_string_literal: true

require_relative "test_helper"

class TriageTest < Minitest::Test
  def sample_item(number, age_seconds, overrides = {})
    {
      number: number,
      title: "Item #{number}",
      author: "pvd",
      body: "Body for item #{number}",
      state: "open",
      updatedAt: (Time.now.utc - age_seconds).iso8601,
      url: "https://github.com/openclaw/openclaw/pull/#{number}",
      labels: [],
      draft: false,
      comments: 1,
      reviewComments: 0
    }.merge(overrides)
  end

  def build_view(repos, config = nil)
    now = Time.now.utc
    config ||= build_config
    snapshot = RepoBar::Runtime::State.build_snapshot(config, repos, [], { login: "pvd" }, now)
    snapshot[:view][:triage]
  end

  def sample_repo_with_items
    repo = sample_repo(name: "openclaw/openclaw", prs: 2, issues: 3)
    repo.merge(
      pulls: [sample_item(1, 3600, reviewComments: 2), sample_item(2, 3 * 86_400, draft: true)],
      issues: [
        sample_item(10, 20 * 86_400, comments: 0),
        sample_item(11, 30 * 86_400, comments: 2),
        sample_item(12, 45 * 86_400, comments: 4)
      ]
    )
  end

  def test_triage_flattens_across_kinds_and_keeps_item_payload
    triage = build_view([sample_repo_with_items])

    assert_equal 5, triage[:total]
    assert_equal 2, triage[:pullCount]
    assert_equal 3, triage[:issueCount]

    first = triage[:items].first
    assert_equal "pr", first[:kind]
    assert_equal "openclaw/openclaw", first[:repoFullName]
    assert_equal "openclaw/openclaw#1", first[:id]
    assert_equal "Body for item 1", first[:bodyFull]

    ids = triage[:items].map { |item| item[:id] }
    assert_equal %w[openclaw/openclaw#1 openclaw/openclaw#2 openclaw/openclaw#10 openclaw/openclaw#11 openclaw/openclaw#12], ids
  end

  def test_triage_orders_newest_first_across_repositories
    newer = sample_repo(name: "one/one").merge(
      pulls: [sample_item(1, 60, url: "https://github.com/one/one/pull/1")],
      issues: []
    )
    older = sample_repo(name: "two/two").merge(
      pulls: [],
      issues: [sample_item(2, 86_400, url: "https://github.com/two/two/issues/2")]
    )

    items = build_view([older, newer])[:items]

    assert_equal "one/one#1", items.first[:id]
    assert_equal "two/two#2", items.last[:id]
    newest_first = items.map { |item| item[:updatedAt] }.sort.reverse
    assert_equal newest_first, items.map { |item| item[:updatedAt] }
  end

  def test_triage_preserves_full_bodies_and_keeps_teaser_truncated
    long_text = (Array.new(60) { |index| "paragraph #{index} lorem ipsum dolor sit amet" } * 8).join(" ")
    repo = sample_repo(name: "openclaw/openclaw").merge(pulls: [], issues: [sample_item(7, 60, body: long_text)])

    item = build_view([repo])[:items].first

    assert_operator long_text.length, :>, 8000
    assert_equal 8000, item[:bodyFull].length
    assert_equal "#{long_text[0, 7997]}...", item[:bodyFull]
    assert_operator item[:body].length, :<=, 220
  end

  def test_triage_age_and_staleness_are_projected
    repo = sample_repo(name: "openclaw/openclaw").merge(
      pulls: [sample_item(1, 5 * 86_400)],
      issues: [sample_item(2, 40 * 86_400)]
    )

    fresh, stale = build_view([repo])[:items]

    assert_equal 5, fresh[:ageDays]
    assert_equal false, fresh[:stale]
    assert_equal 40, stale[:ageDays]
    assert_equal true, stale[:stale]
  end

  def test_triage_signals_are_label_driven
    repo = sample_repo(name: "openclaw/openclaw").merge(
      pulls: [],
      issues: [
        sample_item(1, 60, labels: ["priority", "bug"]),
        sample_item(2, 60, labels: ["help wanted"]),
        sample_item(3, 60, labels: ["blocked", "on hold"])
      ]
    )

    by_number = build_view([repo])[:items].to_h { |item| [item[:number], item] }

    assert_equal %w[priority bug], by_number[1][:signals].map { |signal| signal[:id] }.first(2)
    assert_equal true, by_number[1][:flagged]
    assert_equal 6, by_number[1][:attention]
    assert_includes by_number[1][:action], "priority"

    assert_equal %w[help fresh], by_number[2][:signals].map { |signal| signal[:id] }
    assert_equal false, by_number[2][:flagged]

    assert_equal %w[blocked], by_number[3][:signals].map { |signal| signal[:id] }.first(1)
    assert_equal true, by_number[3][:flagged]
  end

  def test_triage_signals_cover_ci_dirty_review_and_unanswered
    repo = sample_repo(name: "openclaw/openclaw", ci: "failing", dirty: true).merge(
      pulls: [sample_item(1, 60, reviewComments: 3)],
      issues: [sample_item(2, 60, comments: 0)]
    )

    triage = build_view([repo])
    by_number = triage[:items].to_h { |item| [item[:number], item] }

    assert_equal %w[ci dirty reviewing fresh], by_number[1][:signals].map { |signal| signal[:id] }
    assert_equal true, by_number[1][:flagged]
    assert_equal %w[ci ci dirty dirty fresh fresh reviewing unanswered], triage[:items].flat_map { |item| item[:signals].map { |signal| signal[:id] } }.sort
    assert_equal 1, triage[:unansweredCount]

    # An unanswered issue is flagged even when the repo has no red CI.
    assert_equal true, by_number[2][:flagged]
    assert_includes by_number[2][:signals].map { |signal| signal[:id] }, "unanswered"
  end

  def test_triage_unanswered_issue_gets_the_reply_action_on_a_quiet_repo
    repo = sample_repo(name: "one/one", ci: "passing").merge(
      pulls: [],
      issues: [sample_item(1, 60, comments: 0)]
    )

    item = build_view([repo])[:items].first

    assert_equal true, item[:flagged]
    assert_includes item[:action], "No replies yet"
  end

  def test_triage_drafts_are_calmed_down_and_not_flagged
    repo = sample_repo(name: "openclaw/openclaw").merge(
      pulls: [sample_item(1, 60, draft: true)],
      issues: []
    )

    item = build_view([repo])[:items].first

    assert_equal true, item[:draft]
    assert_equal false, item[:flagged]
    assert_includes item[:signals].map { |signal| signal[:id] }, "draft"
    assert_includes item[:action], "Draft"
  end

  def test_triage_buckets_flagged_items_first_then_by_age
    repo = sample_repo(name: "openclaw/openclaw").merge(
      pulls: [sample_item(1, 30 * 86_400, reviewComments: 1)],
      issues: [
        sample_item(2, 40 * 86_400, labels: ["bug"]),
        sample_item(3, 60, comments: 3),
        sample_item(4, 3 * 86_400, comments: 2)
      ]
    )

    triage = build_view([repo])
    buckets = triage[:items].to_h { |item| [item[:number], item[:bucket]] }

    assert_equal "flagged", buckets[2]
    assert_equal "today", buckets[3]
    assert_equal "week", buckets[4]
    assert_equal "older", buckets[1]
    assert_equal "Needs attention", triage[:items].find { |item| item[:number] == 2 }[:bucketLabel]
  end

  def test_triage_rollup_counts_and_ordering
    flagged_repo = sample_repo(name: "two/two", prs: 1, issues: 1).merge(
      pulls: [sample_item(1, 60, labels: ["bug"])],
      issues: [sample_item(2, 20 * 86_400)]
    )
    quiet_repo = sample_repo(name: "one/one", prs: 0, issues: 1).merge(
      pulls: [],
      issues: [sample_item(3, 9 * 86_400, comments: 2)]
    )

    triage = build_view([quiet_repo, flagged_repo])

    assert_equal 3, triage[:total]
    assert_equal 1, triage[:flaggedCount]
    assert_equal 2, triage[:repoCount]
    assert_equal "two/two", triage[:repos].first[:fullName]
    assert_equal ["two/two", "one/one"], triage[:repos].map { |repo| repo[:fullName] }
    assert_equal 2, triage[:repos].first[:total]
    assert_equal "two/two#1", triage[:nextUpId]
    assert_includes triage[:ageSpanText], "oldest"
  end

  def test_triage_repo_context_carries_ci_stars_and_release
    repo = sample_repo(name: "openclaw/openclaw", ci: "failing").merge(
      stars: 12,
      latestRelease: { tag: "v2.0.0", url: "https://github.com/openclaw/openclaw/releases/tag/v2.0.0" },
      pulls: [sample_item(1, 60)],
      issues: []
    )

    context = build_view([repo])[:items].first[:repo]

    assert_equal "failing", context[:ciStatus]
    assert_equal 10, context[:stars]
    assert_equal "v2.0.0", context[:releaseTag]
    assert_equal "ci-failing", context[:status]
    assert_equal 2, context[:openPulls]
    assert_equal 3, context[:openIssues]
  end

  def test_triage_label_chips_tone_known_labels
    repo = sample_repo(name: "openclaw/openclaw").merge(
      pulls: [],
      issues: [sample_item(1, 60, labels: ["bug", "documentation", "priority"])]
    )

    chips = build_view([repo])[:items].first[:labelChips].to_h { |chip| [chip[:name], chip[:tone]] }

    assert_equal "bad", chips["bug"]
    assert_equal "bad", chips["priority"]
    assert_equal "muted", chips["documentation"]
  end

  def test_triage_empty_snapshot_projects_empty_state
    triage = build_view([])

    assert_equal 0, triage[:total]
    assert_equal 0, triage[:flaggedCount]
    assert_equal 0, triage[:repoCount]
    assert_empty triage[:repos]
    assert_empty triage[:items]
    assert_equal "", triage[:ageSpanText]
    assert_nil triage[:nextUpId]
  end

  def test_open_panel_defaults_to_overview_and_accepts_triage
    config_path = write_test_config
    state = RepoBar::Runtime::Store.open_panel(config_path)
    assert_equal "overview", state[:mode]

    triage_state = RepoBar::Runtime::Store.open_panel(config_path, "openclaw/openclaw", mode: "triage")
    assert_equal "triage", triage_state[:mode]
    assert_equal "openclaw/openclaw", triage_state[:focusRepository]
    assert_equal true, triage_state[:open]

    reread = RepoBar::Runtime::State.read_ui_state(RepoBar::Core::Config.load_config(config_path))
    assert_equal "triage", reread[:mode]
  end

  def test_open_panel_rejects_unknown_modes
    config_path = write_test_config
    RepoBar::Runtime::Store.open_panel(config_path, nil, mode: "banana")

    reread = RepoBar::Runtime::State.read_ui_state(RepoBar::Core::Config.load_config(config_path))
    assert_equal "overview", reread[:mode]
  end

  def test_ui_state_survives_unknown_mode_in_file
    config_path = write_test_config
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_ui_state(config, mode: "banana", open: true)

    state = RepoBar::Runtime::State.read_ui_state(config)
    assert_equal "overview", state[:mode]
  end

  # RepoBar is GitHub-only. Forgejo support was removed outright; a later commit
  # must not quietly reintroduce a second provider across the shipped surfaces.
  def test_shipped_code_has_no_forgejo_or_provider_switching
    root = File.expand_path("..", __dir__)
    offenders = []
    %w[lib bin frontend].each do |dir|
      Dir.glob(File.join(root, dir, "**", "*")).each do |path|
        next unless File.file?(path)
        next unless path.end_with?(".rb", ".qml", ".sh") || File.basename(path) == "repobar"

        text = File.read(path)
        %w[forgejo gitea SetProvider set_provider providerActive].each do |needle|
          offenders << "#{path}:#{needle}" if text.include?(needle) && !text.include?("rejects removed")
        end
      end
    end

    assert_empty offenders, "Forgejo/provider switching leaked back into shipped code"
  end
end
