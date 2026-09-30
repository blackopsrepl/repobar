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
      labels: ["bug"],
      draft: false,
      comments: 1,
      reviewComments: 0
    }.merge(overrides)
  end

  def build_view(repos)
    config = build_config
    snapshot = RepoBar::Runtime::State.build_snapshot(config, repos, [], { provider: "github" }, Time.now.utc)
    snapshot[:view]
  end

  def sample_repo_with_items
    repo = sample_repo(name: "openclaw/openclaw", prs: 2, issues: 3)
    repo.merge(
      pulls: [sample_item(1, 3600), sample_item(2, 3 * 86400, draft: true)],
      issues: [sample_item(10, 6 * 86400), sample_item(11, 20 * 86400), sample_item(12, 45 * 86400)]
    )
  end

  def test_triage_flattens_across_kinds_and_keeps_item_payload
    view = build_view([sample_repo_with_items])

    triage = view[:triage]
    assert_equal 5, triage[:total]
    assert_equal 2, triage[:pullCount]
    assert_equal 3, triage[:issueCount]

    first = triage[:items].first
    assert_equal "pr", first[:kind]
    assert_equal "openclaw/openclaw", first[:repoFullName]
    assert_equal "openclaw/openclaw#1", first[:id]
    assert_equal "Body for item 1", first[:bodyFull]
    assert_equal ["bug"], first[:labels]

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

    items = build_view([older, newer])[:triage][:items]

    assert_equal "one/one#1", items.first[:id]
    assert_equal "two/two#2", items.last[:id]
    newest_first = items.map { |item| item[:updatedAt] }.sort.reverse
    assert_equal newest_first, items.map { |item| item[:updatedAt] }
  end

  def test_triage_preserves_full_bodies_and_keeps_teaser_truncated
    long_text = (Array.new(40) { |index| "paragraph #{index}" } * 6).join(" ")
    repo = sample_repo(name: "openclaw/openclaw").merge(pulls: [], issues: [sample_item(7, 60, body: long_text)])

    item = build_view([repo])[:triage][:items].first

    assert_operator long_text.length, :>, 1000
    assert_equal "#{long_text[0, 8000]}...", item[:bodyFull]
    assert_operator item[:body].length, :<=, 220
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
end
