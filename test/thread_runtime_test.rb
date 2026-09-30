# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class ThreadRuntimeTest < Minitest::Test
  def test_fetch_cli_dispatches_daemon_action_without_network
    path = write_test_config
    dispatched = nil
    RepoBar::Runtime::Daemon.stub(:dispatch_action, ->(config_path, action) {
      assert_equal path, config_path
      dispatched = action
      { status: "loading", itemId: action[:itemId] }
    }) do
      out, err = capture_io do
        assert_equal 0, RepoBar::CLI.run(["thread", "fetch", "one/one#12", "--repo", "one/one", "--number", "12", "--kind", "pr", "--config", path, "--json"])
      end
      assert_empty err
      assert_equal "loading", JSON.parse(out)["status"]
    end
    assert_equal "thread_start", dispatched[:type]
    assert_equal "one/one#12", dispatched[:itemId]
    assert_nil dispatched[:limit]
  end

  def test_invalid_identity_cannot_replace_current_thread
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    assert_raises(ArgumentError) { store.start_thread(path, "one/one#12", "two/two", 12, "pr") }
    assert_raises(ArgumentError) { store.start_thread(path, "one/one#12", "one/one", 12, "banana") }
    config = RepoBar::Core::Config.load_config(path)
    assert_equal first[:requestId], RepoBar::Runtime::State.read_thread_state(config)[:requestId]
  end

  def test_late_thread_response_cannot_replace_new_selection
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    second = store.start_thread(path, "one/one#13", "one/one", 13, "issue")
    state = store.finish_thread(path, first[:requestId], entries: [{ body: "old" }])
    assert_equal second[:requestId], state[:requestId]
    assert_empty state[:entries]
  end

  def test_thread_completion_and_selection_are_one_locked_transaction
    path = write_test_config
    store = RepoBar::Runtime::Store
    state = RepoBar::Runtime::State
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    read = state.method(:read_thread_state)
    paused = Queue.new
    resume = Queue.new
    selected = Queue.new
    worker = nil
    selection = nil
    state.stub(:read_thread_state, ->(config) {
      current = read.call(config)
      if Thread.current[:pause_thread_completion]
        Thread.current[:pause_thread_completion] = false
        paused << true
        resume.pop
      end
      current
    }) do
      begin
        worker = Thread.new do
          Thread.current[:pause_thread_completion] = true
          store.finish_thread(path, first[:requestId], entries: [{ body: "old" }])
        end
        Timeout.timeout(1) { paused.pop }
        selection = Thread.new do
          store.start_thread(path, "one/one#13", "one/one", 13, "issue")
          selected << true
        end
        assert_raises(Timeout::Error) { Timeout.timeout(0.1) { selected.pop } }
      ensure
        resume << true
        worker&.join
        selection&.join
      end
    end
    current = read.call(RepoBar::Core::Config.load_config(path))
    assert_equal "one/one#13", current[:itemId]
    assert_empty current[:entries]
  end

  def test_effect_writes_presented_entries_and_preserves_full_body
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    entry = { id: 1, kind: "comment", author: "alice", authorAvatarUrl: "https://avatars.githubusercontent.com/u/1", body: "hello " * 2000, createdAt: Time.now.utc.iso8601 }
    RepoBar::Core::GitHub.stub(:access_token, "test") do
      RepoBar::Core::GitHub.stub(:item_thread, ->(*args) {
        assert_nil args.last
        [entry]
      }) do
        store.thread_effect(path, first[:itemId], "one/one", 12, "pr", first[:requestId], nil)
      end
    end
    state = RepoBar::Runtime::State.read_thread_state(RepoBar::Core::Config.load_config(path))
    assert_equal "ready", state[:status]
    assert_equal "0s ago", state[:entries].first[:createdText]
    assert_equal entry[:body].strip, state[:entries].first[:body]
    refute state[:truncated]
  end

  def test_explicit_limit_only_marks_actual_truncation
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    RepoBar::Core::GitHub.stub(:access_token, "test") do
      RepoBar::Core::GitHub.stub(:item_thread, ->(*args) { [{ id: 1, kind: "comment" }] }) do
        state = store.thread_effect(path, first[:itemId], "one/one", 12, "pr", first[:requestId], 1)
        refute state[:truncated]
      end
    end
  end

  def test_malformed_number_is_rejected_before_dispatch
    path = write_test_config
    out, err = capture_io do
      RepoBar::Runtime::Daemon.stub(:dispatch_action, { itemId: "one/one#12" }) do
        assert_equal 1, RepoBar::CLI.run(["thread", "fetch", "one/one#12", "--repo", "one/one", "--number", "12junk", "--kind", "pr", "--config", path])
      end
    end
    assert_empty out
    assert_includes err, "Positive --number required."
  end
end
