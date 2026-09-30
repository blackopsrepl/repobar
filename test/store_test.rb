# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class StoreTest < Minitest::Test
  def test_pin_projects_cached_repo_immediately
    config_path = write_test_config
    config = RepoBar::Core::Config.load_config(config_path)
    snapshot = RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "openclaw/openclaw")], [], { login: "pvd" }, Time.now.utc)
    RepoBar::Runtime::State.write_snapshot(config, snapshot)

    RepoBar::Runtime::Store.pin_repo(config_path, "OpenClaw/OpenClaw")

    saved = RepoBar::Core::Config.load_config(config_path)
    view = RepoBar::Runtime::State.read_snapshot(saved).dig(:view, :repositories).first
    assert_includes saved.dig(:repoList, :pinnedRepositories), "openclaw/openclaw"
    assert_equal true, view[:pinned]
  end

  def test_unpin_projects_cached_repo_immediately
    config_path = write_test_config(repoList: { pinnedRepositories: ["openclaw/openclaw"] })
    config = RepoBar::Core::Config.load_config(config_path)
    snapshot = RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "openclaw/openclaw")], [], { login: "pvd" }, Time.now.utc)
    RepoBar::Runtime::State.write_snapshot(config, snapshot)

    RepoBar::Runtime::Store.unpin_repo(config_path, "openclaw/openclaw")

    saved = RepoBar::Core::Config.load_config(config_path)
    view = RepoBar::Runtime::State.read_snapshot(saved).dig(:view, :repositories).first
    refute_includes saved.dig(:repoList, :pinnedRepositories), "openclaw/openclaw"
    assert_equal false, view[:pinned]
  end

  def test_move_pinned_repo_reorders_config_and_projected_snapshot
    names = ["one/one", "two/two", "three/three"]
    config_path = write_test_config(repoList: { pinnedRepositories: names })
    config = RepoBar::Core::Config.load_config(config_path)
    snapshot = RepoBar::Runtime::State.build_snapshot(
      config,
      names.map { |name| sample_repo(name: name) },
      [],
      { login: "pvd" },
      Time.now.utc
    )
    RepoBar::Runtime::State.write_snapshot(config, snapshot)

    RepoBar::Runtime::Store.move_pinned_repo(config_path, "three/three", 0)

    saved = RepoBar::Core::Config.load_config(config_path)
    view_names = RepoBar::Runtime::State.read_snapshot(saved).dig(:view, :repositories).map { |repo| repo[:fullName] }
    assert_equal ["three/three", "one/one", "two/two"], saved.dig(:repoList, :pinnedRepositories)
    assert_equal ["three/three", "one/one", "two/two"], view_names
  end

  def test_hide_removes_repo_from_projected_view
    config_path = write_test_config(repoList: { pinnedRepositories: ["openclaw/openclaw"] })
    config = RepoBar::Core::Config.load_config(config_path)
    snapshot = RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "openclaw/openclaw")], [], { login: "pvd" }, Time.now.utc)
    RepoBar::Runtime::State.write_snapshot(config, snapshot)

    RepoBar::Runtime::Store.hide_repo(config_path, "openclaw/openclaw")

    saved = RepoBar::Core::Config.load_config(config_path)
    view_repos = RepoBar::Runtime::State.read_snapshot(saved).dig(:view, :repositories)
    assert_empty view_repos
    assert_includes saved.dig(:repoList, :hiddenRepositories), "openclaw/openclaw"
  end

  def test_pin_search_result_inserts_pending_repo
    config_path = write_test_config
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_snapshot(config, RepoBar::Runtime::State.build_snapshot(config, [], [], { login: "pvd" }, Time.now.utc))
    search = RepoBar::Runtime::Store.start_search(config_path, "solverforge", limit: 5)
    RepoBar::Runtime::Store.finish_search(config_path, search[:requestId], "solverforge", results: [sample_repo(name: "solverforge/solverforge")])

    RepoBar::Runtime::Store.pin_repo(config_path, "solverforge/solverforge")

    saved = RepoBar::Core::Config.load_config(config_path)
    repo = RepoBar::Runtime::State.read_snapshot(saved).dig(:view, :repositories).first
    assert_equal "solverforge/solverforge", repo[:fullName]
    assert_equal true, repo[:pinned]
    assert_equal true, repo[:pending]
  end

  def test_late_refresh_reprojects_through_newer_pinned_order
    config_path = write_test_config(
      settings: { showContributionHeader: false },
      repoList: { pinnedRepositories: ["one/one", "two/two", "three/three"] }
    )
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_snapshot(
      config,
      RepoBar::Runtime::State.build_snapshot(
        config,
        ["one/one", "two/two", "three/three"].map { |name| sample_repo(name: name) },
        [],
        { login: "pvd" },
        Time.now.utc
      )
    )

    RepoBar::Core::GitHub.stub(:auth_status, ->(*) { { authenticated: true, login: "pvd" } }) do
      RepoBar::Core::GitHub.stub(:fetch_repositories, ->(*) {
        RepoBar::Runtime::Store.move_pinned_repo(config_path, "three/three", 0)
        ["one/one", "two/two", "three/three"].map { |name| sample_repo(name: name) }
      }) do
        RepoBar::Core::LocalGit.stub(:scan, ->(*) { [] }) do
          RepoBar::Runtime::Store.refresh_effect(config_path)
        end
      end
    end

    current = RepoBar::Core::Config.load_config(config_path)
    names = RepoBar::Runtime::State.read_snapshot(current).dig(:view, :repositories).map { |repo| repo[:fullName] }
    assert_equal ["three/three", "one/one", "two/two"], names
  end

  def test_late_refresh_does_not_resurrect_repositories_hidden_mid_refresh
    config_path = write_test_config(settings: { showContributionHeader: false })
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_snapshot(
      config,
      RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "one/one"), sample_repo(name: "two/two")], [], { login: "pvd" }, Time.now.utc)
    )

    RepoBar::Core::GitHub.stub(:auth_status, ->(*) { { authenticated: true, login: "pvd" } }) do
      RepoBar::Core::GitHub.stub(:fetch_repositories, ->(*) {
        RepoBar::Runtime::Store.hide_repo(config_path, "two/two")
        [sample_repo(name: "one/one"), sample_repo(name: "two/two")]
      }) do
        RepoBar::Core::LocalGit.stub(:scan, ->(*) { [] }) do
          RepoBar::Runtime::Store.refresh_effect(config_path)
        end
      end
    end

    current = RepoBar::Core::Config.load_config(config_path)
    snapshot = RepoBar::Runtime::State.read_snapshot(current)
    assert_equal ["one/one"], snapshot.dig(:view, :repositories).map { |repo| repo[:fullName] }
    assert_includes current.dig(:repoList, :hiddenRepositories), "two/two"
  end

  def test_late_refresh_keeps_newer_pinned_repo_that_is_absent_from_fresh_rows
    config_path = write_test_config(settings: { showContributionHeader: false })
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_snapshot(
      config,
      RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "one/one")], [], { login: "pvd" }, Time.now.utc)
    )

    RepoBar::Core::GitHub.stub(:auth_status, ->(*) { { authenticated: true, login: "pvd" } }) do
      RepoBar::Core::GitHub.stub(:fetch_repositories, ->(*) {
        RepoBar::Runtime::Store.pin_repo(config_path, "late/late")
        [sample_repo(name: "one/one")]
      }) do
        RepoBar::Core::LocalGit.stub(:scan, ->(*) { [] }) do
          RepoBar::Runtime::Store.refresh_effect(config_path)
        end
      end
    end

    current = RepoBar::Core::Config.load_config(config_path)
    repos = RepoBar::Runtime::State.read_snapshot(current).dig(:view, :repositories)
    assert_equal ["late/late", "one/one"], repos.map { |repo| repo[:fullName] }
    assert_equal true, repos.first[:pending]
  end

  def test_failed_refresh_keeps_the_last_confirmed_repository_snapshot
    config_path = write_test_config(settings: { showContributionHeader: false })
    config = RepoBar::Core::Config.load_config(config_path)
    RepoBar::Runtime::State.write_snapshot(
      config,
      RepoBar::Runtime::State.build_snapshot(config, [sample_repo(name: "stable/repository")], [], { login: "pvd" }, Time.now.utc)
    )

    RepoBar::Core::GitHub.stub(:auth_status, ->(*) { { authenticated: true, login: "pvd" } }) do
      RepoBar::Core::GitHub.stub(:fetch_repositories, ->(*) { raise "GitHub HTTP 503: service unavailable" }) do
        assert_raises(RuntimeError) { RepoBar::Runtime::Store.refresh_effect(config_path) }
      end
    end

    snapshot = RepoBar::Runtime::State.read_snapshot(config)
    assert_equal ["stable/repository"], snapshot.dig(:view, :repositories).map { |repo| repo[:fullName] }
  end

  def test_refresh_writes_only_the_single_snapshot_file
    config_path = write_test_config(settings: { showContributionHeader: false })
    RepoBar::Core::GitHub.stub(:auth_status, ->(*) { { authenticated: true, login: "pvd" } }) do
      RepoBar::Core::GitHub.stub(:fetch_repositories, ->(*) { [sample_repo(name: "one/one")] }) do
        RepoBar::Core::LocalGit.stub(:scan, ->(*) { [] }) do
          RepoBar::Runtime::Store.refresh_effect(config_path)
        end
      end
    end

    config = RepoBar::Core::Config.load_config(config_path)
    state_dir = RepoBar::Runtime::State.state_dir(config)
    refute Dir.exist?(File.join(state_dir, "providers")), "GitHub-only state has no provider snapshot directory"
    assert_equal ["snapshot.json", "state-event.json"], Dir.children(state_dir).sort
  end

  def test_daemon_refresh_requests_coalesce_while_refresh_is_running
    config_path = write_test_config
    refresh_state = { thread: nil, pending: false, mutex: Mutex.new }
    started = Queue.new
    release = Queue.new
    call_count = 0
    count_mutex = Mutex.new

    RepoBar::Runtime::Daemon.stub(:refresh, ->(_path) {
      current = count_mutex.synchronize do
        call_count += 1
      end
      started << current
      release.pop
    }) do
      thread = RepoBar::Runtime::Daemon.request_refresh(config_path, refresh_state)
      assert_equal 1, Timeout.timeout(1) { started.pop }

      3.times { RepoBar::Runtime::Daemon.request_refresh(config_path, refresh_state) }
      release << true
      assert_equal 2, Timeout.timeout(1) { started.pop }
      release << true
      thread.join(1)
    end

    assert_equal 2, call_count
    assert_nil refresh_state[:thread]
    assert_equal false, refresh_state[:pending]
  end

  def test_timer_refresh_requests_do_not_queue_pending_refresh
    config_path = write_test_config
    refresh_state = { thread: nil, pending: false, mutex: Mutex.new }
    started = Queue.new
    release = Queue.new
    call_count = 0
    count_mutex = Mutex.new

    RepoBar::Runtime::Daemon.stub(:refresh, ->(_path) {
      count_mutex.synchronize do
        call_count += 1
      end
      started << true
      release.pop
    }) do
      thread = RepoBar::Runtime::Daemon.request_refresh(config_path, refresh_state)
      Timeout.timeout(1) { started.pop }

      3.times { RepoBar::Runtime::Daemon.request_refresh(config_path, refresh_state, queue_pending: false) }
      release << true
      thread.join(1)
    end

    assert_equal 1, call_count
    assert_nil refresh_state[:thread]
    assert_equal false, refresh_state[:pending]
  end

  def test_search_start_and_finish_are_state_transactions
    config_path = write_test_config

    state = RepoBar::Runtime::Store.start_search(config_path, "solverforge", limit: 5)
    assert_equal "loading", state[:status]
    assert_equal "solverforge", state[:query]

    finished = RepoBar::Runtime::Store.finish_search(config_path, state[:requestId], "solverforge", results: [sample_repo(name: "solverforge/solverforge")])
    assert_equal "ready", finished[:status]
    assert_equal ["solverforge/solverforge"], finished[:results].map { |repo| repo[:fullName] }
  end

  def test_cli_visibility_commands_do_not_refresh_synchronously
    config_path = write_test_config

    RepoBar::Runtime::Daemon.stub(:dispatch_action, ->(_path, action) { { action: action[:type], pinnedRepositories: ["openclaw/openclaw"] } }) do
      RepoBar::Runtime::Daemon.stub(:refresh, ->(*) { raise "refresh should be an effect" }) do
        _out, _err = capture_io do
          assert_equal 0, RepoBar::CLI.run(["pin", "openclaw/openclaw", "--config", config_path])
        end
      end
    end
  end

  def test_cli_rejects_removed_provider_command
    config_path = write_test_config

    _out, err = capture_io do
      assert_equal 1, RepoBar::CLI.run(["provider", "github", "--config", config_path])
    end

    assert_match(/Unknown command: provider/, err)
  end

  def test_daemon_refresh_action_requests_a_coalesced_refresh
    config_path = write_test_config
    refresh_state = { thread: nil, pending: false, mutex: Mutex.new }
    calls = []

    RepoBar::Runtime::Daemon.stub(:request_refresh, ->(path, state) { calls << [path, state] }) do
      result = RepoBar::Runtime::Daemon.handle_action(config_path, { type: "refresh" }, Mutex.new, [], refresh_state)
      assert_equal "refresh_requested", result[:status]
    end

    assert_equal [[config_path, refresh_state]], calls
  end

  def test_daemon_rejects_removed_set_provider_action
    config_path = write_test_config
    refresh_state = { thread: nil, pending: false, mutex: Mutex.new }

    error = assert_raises(ArgumentError) do
      RepoBar::Runtime::Daemon.handle_action(config_path, { type: "set_provider", provider: "forgejo" }, Mutex.new, [], refresh_state)
    end

    assert_match(/Unknown daemon action: set_provider/, error.message)
  end

  def test_waybar_refresh_dispatches_the_daemon_action
    config_path = write_test_config
    captured = nil

    RepoBar::Runtime::Daemon.stub(:dispatch_action, ->(_path, action) { captured = action; { status: "refresh_requested" } }) do
      RepoBar::Runtime::Daemon.stub(:refresh, ->(*) { raise "refresh should be a daemon action" }) do
        _out, _err = capture_io do
          assert_equal 0, RepoBar::CLI.run(["waybar", "refresh", "--config", config_path])
        end
      end
    end

    assert_equal "refresh", captured[:type]
  end
end
