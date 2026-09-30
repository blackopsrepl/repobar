# frozen_string_literal: true

require_relative "test_helper"

class GitHubTest < Minitest::Test
  def test_maps_github_repository_shape
    config = build_config
    repo = RepoBar::Core::GitHub.map_repo_item(
      {
        owner: { login: "blackopsrepl", avatar_url: "https://avatars.githubusercontent.com/u/1" },
        name: "repobar",
        full_name: "blackopsrepl/repobar",
        html_url: "https://github.com/blackopsrepl/repobar",
        private: false,
        fork: false,
        archived: false,
        stargazers_count: 7,
        forks_count: 2,
        pushed_at: "2026-05-06T10:00:00Z",
        updated_at: "2026-05-06T10:00:00Z"
      },
      {}
    )

    assert_equal "blackopsrepl/repobar", repo[:fullName]
    assert_equal "https://avatars.githubusercontent.com/u/1", repo[:ownerAvatarUrl]
    assert_equal "https://github.com/blackopsrepl/repobar", repo[:url]
    assert_equal 7, repo.dig(:stats, :stars)
    assert_equal 2, repo.dig(:stats, :forks)
    assert_equal "2026-05-06T10:00:00Z", repo.dig(:stats, :pushedAt)
    assert_equal 0, repo.dig(:stats, :openIssues)
  end

  def test_fetch_repositories_does_not_cap_pinned_repositories
    config = build_config
    config[:repoList][:displayLimit] = 1
    config[:repoList][:pinnedRepositories] = ["one/one", "two/two", "three/three"]
    config[:repoList][:visibleRepositories] = ["extra/extra"]

    RepoBar::Core::GitHub.stub(:access_token, "token") do
      RepoBar::Core::GitHub.stub(:repository, ->(_config, _token, full_name) { sample_repo(name: full_name) }) do
        RepoBar::Core::GitHub.stub(:hydrate_repository, ->(_config, _token, repo) { repo }) do
          repos = RepoBar::Core::GitHub.fetch_repositories(config)

          assert_equal ["one/one", "two/two", "three/three", "extra/extra"], repos.map { |repo| repo[:fullName] }
        end
      end
    end
  end

  def test_fetch_repositories_propagates_transient_pinned_lookup_failures
    config = build_config
    config[:repoList][:pinnedRepositories] = ["one/one"]

    RepoBar::Core::GitHub.stub(:access_token, "token") do
      RepoBar::Core::GitHub.stub(:request, ->(*) { raise "GitHub HTTP 503: service unavailable" }) do
        error = assert_raises(RuntimeError) { RepoBar::Core::GitHub.fetch_repositories(config) }

        assert_match "HTTP 503", error.message
      end
    end
  end

  def test_repository_lookup_treats_404_as_removal_and_raises_other_failures
    config = build_config

    RepoBar::Core::GitHub.stub(:request, ->(*) { raise "GitHub HTTP 404: Not Found" }) do
      assert_nil RepoBar::Core::GitHub.repository(config, "token", "gone/gone")
    end

    RepoBar::Core::GitHub.stub(:request, ->(*) { raise "GitHub HTTP 503: service unavailable" }) do
      assert_raises(RuntimeError) { RepoBar::Core::GitHub.repository(config, "token", "flaky/flaky") }
    end
  end

  def test_github_heatmap_uses_recent_commit_activity
    config = build_config
    today = Date.today.iso8601
    yesterday = (Date.today - 1).iso8601
    commits = [
      { date: "#{today}T08:00:00Z" },
      { date: "#{today}T10:00:00Z" },
      { date: "#{yesterday}T10:00:00Z" }
    ]

    RepoBar::Core::GitHub.stub(:commits, commits) do
      heatmap = RepoBar::Core::GitHub.heatmap(config, "token", "openclaw", "openclaw")
      counts = heatmap[:cells].to_h { |cell| [cell[:date], cell[:count]] }

      assert_equal 3, heatmap[:total]
      assert_equal 2, counts[today]
      assert_equal 1, counts[yesterday]
    end
  end

  def test_account_heatmap_uses_github_contribution_calendar
    config = build_config
    today = Date.today.iso8601
    data = {
      data: {
        user: {
          contributionsCollection: {
            contributionCalendar: {
              totalContributions: 4,
              weeks: [
                {
                  contributionDays: [
                    { date: today, contributionCount: 4 }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    RepoBar::Core::GitHub.stub(:graphql_request, data) do
      heatmap = RepoBar::Core::GitHub.account_heatmap(config, "token", "blackopsrepl")
      counts = heatmap[:cells].to_h { |cell| [cell[:date], cell[:count]] }

      assert_equal true, heatmap[:available]
      assert_equal 4, heatmap[:total]
      assert_equal 4, heatmap[:max]
      assert_equal 4, counts[today]
      assert_equal 1, heatmap[:weeks].length
      assert_equal 1, heatmap.dig(:weeks, 0, :cells).length
    end
  end

  def test_account_heatmap_without_token_is_unavailable
    config = build_config

    heatmap = RepoBar::Core::GitHub.account_heatmap(config, nil, "blackopsrepl")

    assert_equal false, heatmap[:available]
    assert_empty heatmap[:cells]
  end

  def test_access_token_prefers_repobar_env_then_github_env
    config = build_config
    previous = ENV.to_h.slice("REPOBAR_GITHUB_TOKEN", "GITHUB_TOKEN")

    ENV["GITHUB_TOKEN"] = "fallback"
    ENV["REPOBAR_GITHUB_TOKEN"] = "primary"
    assert_equal "primary", RepoBar::Core::GitHub.access_token(config)

    ENV.delete("REPOBAR_GITHUB_TOKEN")
    assert_equal "fallback", RepoBar::Core::GitHub.access_token(config)
  ensure
    %w[REPOBAR_GITHUB_TOKEN GITHUB_TOKEN].each { |key| ENV.delete(key) }
    previous.each { |key, value| ENV[key] = value }
  end

  def test_latest_release_is_nil_for_empty_payload
    config = build_config

    RepoBar::Core::GitHub.stub(:request, ->(*) { RepoBar::Core::GitHub::Response.new(data: {}, headers: {}, status: 200) }) do
      assert_nil RepoBar::Core::GitHub.latest_release(config, "token", "one", "one")
    end
  end

  def test_workflow_status_maps_conclusions
    cases = {
      { conclusion: "success" } => "passing",
      { conclusion: "failure" } => "failing",
      { conclusion: "timed_out" } => "failing",
      { conclusion: "cancelled" } => "failing",
      { conclusion: "action_required" } => "failing",
      { conclusion: nil, status: "in_progress" } => "pending",
      { conclusion: "skipped" } => "unknown"
    }

    cases.each do |payload, expected|
      assert_equal expected, RepoBar::Core::GitHub.workflow_status(payload)
    end
  end

  def test_issue_and_pull_items_keep_readable_body_data
    issue = RepoBar::Core::GitHub.map_issue_item(
      number: 12,
      title: "Fix panel",
      body: "Panel body",
      comments: 3,
      user: { login: "pvd" },
      labels: [{ name: "bug" }]
    )
    pull = RepoBar::Core::GitHub.map_pull_item(
      number: 13,
      title: "Add reader",
      body: "Pull body",
      comments: 1,
      review_comments: 2,
      user: { login: "pvd" }
    )

    assert_equal "Panel body", issue[:body]
    assert_equal 3, issue[:comments]
    assert_equal ["bug"], issue[:labels]
    assert_equal "Pull body", pull[:body]
    assert_equal 2, pull[:reviewComments]
  end

  def test_fresh_rest_cache_short_circuits_network
    config = build_config
    uri = URI("https://api.github.com/repos/openclaw/openclaw")
    RepoBar::Core::Cache.write_rest_entry(
      config,
      uri,
      status: 200,
      headers: { "etag" => "cached" },
      body: JSON.generate(full_name: "openclaw/openclaw", name: "openclaw", owner: { login: "openclaw" })
    )

    Net::HTTP.stub(:start, ->(*) { raise "network should not be used for fresh cache" }) do
      response = RepoBar::Core::GitHub.request(config, "/repos/openclaw/openclaw", token: "token")
      assert_equal 200, response.status
      assert_equal "openclaw/openclaw", response.data[:full_name]
    end
  end

  def test_stale_rest_cache_uses_network
    config = build_config
    uri = URI("https://api.github.com/repos/openclaw/openclaw")
    RepoBar::Core::Cache.write_rest_entry(
      config,
      uri,
      status: 200,
      headers: { "etag" => "stale" },
      body: JSON.generate(full_name: "stale/repo")
    )
    path = RepoBar::Core::Cache.rest_path(config)
    data = JSON.parse(File.read(path))
    data.values.first["fetchedAt"] = (Time.now.utc - 3600).iso8601
    File.write(path, "#{JSON.pretty_generate(data)}\n")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, JSON.generate(full_name: "openclaw/openclaw"))
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }

    Net::HTTP.stub(:start, lambda { |*_, &block| block.call(http) }) do
      result = RepoBar::Core::GitHub.request(config, "/repos/openclaw/openclaw", token: "token")
      assert_equal "openclaw/openclaw", result.data[:full_name]
    end
  end
end
