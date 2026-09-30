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

  def test_reloading_same_item_preserves_entries_while_loading
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    cached = store.finish_thread(path, first[:requestId], entries: [{ body: "cached conversation" }], truncated: true)

    loading = store.start_thread(path, "ONE/ONE#12", "one/one", 12, "pr")

    assert_equal "loading", loading[:status]
    refute_equal first[:requestId], loading[:requestId]
    assert_equal cached[:entries], loading[:entries]
    assert loading[:truncated]
    assert_empty loading[:error]
    repeated = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    assert_equal cached[:entries], repeated[:entries]
    assert_equal repeated, store.finish_thread(path, loading[:requestId], entries: [{ body: "stale refresh" }])

    changed = store.start_thread(path, "two/two#12", "two/two", 12, "pr")
    assert_empty changed[:entries]
    refute changed[:truncated]
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

  def test_github_error_preserves_same_item_conversation
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    cached = store.finish_thread(path, first[:requestId], entries: [{ body: "cached conversation" }], truncated: true)
    loading = store.start_thread(path, "one/one#12", "one/one", 12, "pr")

    RepoBar::Core::GitHub.stub(:access_token, "test") do
      RepoBar::Core::GitHub.stub(:item_thread, ->(*) { raise "GitHub unavailable" }) do
        store.thread_effect(path, loading[:itemId], "one/one", 12, "pr", loading[:requestId], nil)
      end
    end

    state = RepoBar::Runtime::State.read_thread_state(RepoBar::Core::Config.load_config(path))
    assert_equal "error", state[:status]
    assert_equal "GitHub unavailable", state[:error]
    assert_equal loading[:requestId], state[:requestId]
    assert_equal cached[:entries], state[:entries]
    assert state[:truncated]
    retrying = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    assert_equal cached[:entries], retrying[:entries]
    assert_empty retrying[:error]
    recovered = store.finish_thread(path, retrying[:requestId], entries: [])
    assert_equal "ready", recovered[:status]
    assert_empty recovered[:entries]
    refute recovered[:truncated]
  end

  def test_github_error_after_selection_change_never_crosses_items
    path = write_test_config
    store = RepoBar::Runtime::Store
    first = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    store.finish_thread(path, first[:requestId], entries: [{ body: "first conversation" }])
    old_reload = store.start_thread(path, "one/one#12", "one/one", 12, "pr")
    selected = store.start_thread(path, "two/two#12", "two/two", 12, "issue")

    RepoBar::Core::GitHub.stub(:access_token, "test") do
      RepoBar::Core::GitHub.stub(:item_thread, ->(*) { raise "GitHub unavailable" }) do
        late = store.thread_effect(path, old_reload[:itemId], "one/one", 12, "pr", old_reload[:requestId], nil)
        assert_equal selected, late
        store.thread_effect(path, selected[:itemId], "two/two", 12, "issue", selected[:requestId], nil)
      end
    end

    state = RepoBar::Runtime::State.read_thread_state(RepoBar::Core::Config.load_config(path))
    assert_equal "two/two#12", state[:itemId]
    assert_equal selected[:requestId], state[:requestId]
    assert_equal "error", state[:status]
    assert_equal "GitHub unavailable", state[:error]
    assert_empty state[:entries]
    refute state[:truncated]
  end

  def test_reader_original_bodies_are_complete_while_previews_stay_bounded
    body = ("paragraph with original formatting\r\n\r\n" * 300) + "final paragraph"
    repo = sample_repo(name: "one/one").merge(
      pulls: [{ number: 12, body: body }],
      issues: [{ number: 13, body: body }]
    )
    view = RepoBar::Runtime::State.build_snapshot(build_config, [repo], [], {})[:view]
    expected = body.gsub(/\r\n?/, "\n")
    assert_operator expected.length, :>, 8000
    overview_items = view[:repositories].first.values_at(:pulls, :issues).flatten
    triage_items = view[:triage][:items]
    assert_equal 2, overview_items.length
    assert_equal 2, triage_items.length
    (overview_items + triage_items).each do |item|
      assert_equal expected.length, item[:bodyFull].length
      assert_equal expected, item[:bodyFull]
      assert_equal RepoBar::Runtime::Presenter.readable_body(body), item[:body]
      assert_operator item[:body].length, :<=, 220
    end
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
