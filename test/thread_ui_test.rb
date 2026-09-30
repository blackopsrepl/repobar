# frozen_string_literal: true

require_relative "test_helper"

class ThreadUiTest < Minitest::Test
  def test_selected_item_automatically_loads_the_conversation
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    assert qml.include?("onConversationKeyChanged: conversationLoad.restart()"), "selecting an item must schedule its thread"
    assert qml.include?("onTriggered: root.ensureConversation()"), "automatic loading must use daemon state"
    refute qml.include?("Load thread"), "the reader must not require a separate load step"
  end

  def test_watched_thread_identity_reconciles_the_selected_conversation
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    adapter = qml.split("id: threadAdapter", 2).last.split("Component.onCompleted", 2).first
    assert_match(/onItemIdChanged:\s*\{(.*?)\n\s*\}/m, adapter, "incoming thread identity must reconcile the reader")
    handler = adapter.match(/onItemIdChanged:\s*\{(.*?)\n\s*\}/m)[1]
    assert_includes handler, "root.conversationKey &&", "a closed reader must not dispatch"
    assert_includes handler, "itemId !== root.conversationKey", "matched ready/loading/error state must not schedule retries"
    assert_includes handler, "root.threadRequestedId !== root.conversationKey", "an already dispatched selection must not be duplicated"
    assert_includes handler, "conversationLoad.restart()", "reconciliation must use the existing debounce and ensureConversation guard"
    refute_includes handler, "loadThread(", "watched updates must not bypass the debounce"
  end

  def test_acknowledged_dispatch_no_longer_suppresses_reconciliation
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    process = qml.split("id: threadFetchFactory", 2).last.split("id: actionRunner", 2).first
    assert_includes process, "if (root.threadRequestedId === itemId)"
    assert_includes process, "exitCode === 0 && root.conversationKey === itemId"
    assert_operator process.index('root.threadRequestedId = ""'), :<, process.index("exitCode === 0"), "failed superseded dispatches must also release the pending marker"
    assert_includes process, 'root.threadRequestedId = ""'
    assert_includes process, "threadAdapter.itemId !== itemId", "an acknowledged dispatch must reconcile late state too"
    assert_includes process, "conversationLoad.restart()"
  end

  def test_automatic_conversation_guard_preserves_ready_and_loading_threads
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    ensure_body = qml.split("function ensureConversation() {", 2).last.split("component RepoActionButton", 2).first
    assert_includes ensure_body, "if (!root.conversationKey || !item) { return }"
    assert_includes ensure_body, "if (root.threadRequestedId === item.id) { return }", "selection bounce must not duplicate an unacknowledged dispatch"
    assert_includes ensure_body, 'thread.status === "ready" || thread.status === "loading"'
    assert_includes ensure_body, "root.loadThread(item)"
  end

  def test_overview_and_triage_share_an_inline_conversation_reader
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    assert qml.include?("component ConversationView: ColumnLayout"), "one timeline must serve both readers"
    assert_equal 2, qml.scan(/ConversationView \{/).length
    assert qml.include?("entry: root.descriptionEntry(conversation.item)"), "the original post belongs in the timeline"
    refute qml.include?("firstItems(root.selectedRepository.pulls, 3)"), "overview must not be a three-item browser launcher"
    refute qml.include?("firstItems(root.selectedRepository.issues, 3)")
  end

  def test_automatic_thread_dispatch_does_not_cancel_other_panel_actions
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    refute_match(/runRepobar\(\[\s*"thread"/, qml, "automatic fetches must not kill the shared action runner")
    assert qml.include?("threadFetchFactory.createObject(root"), "thread dispatch must have its own short-lived process"
    assert qml.include?("threadDispatchError"), "dispatch failures must be visible, not an endless spinner"
  end

  def test_panel_thread_shortcut_and_avatar_have_one_image
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
    assert_match(/sequence: "t".*?enabled: root.triageShortcutLive\(\).*?onActivated: root.loadSelectedThread\(\)/m, qml)
    avatar = qml.split("component ThreadAvatarBox:", 2).last.split("// Compact labelled toggle", 2).first
    assert_equal 1, avatar.scan(/\bImage \{/).length
    entry = qml.split("component ThreadEntry:", 2).last.split("component ThreadAvatarBox:", 2).first
    refute_includes entry, "TriageSignalChip {"
    assert_includes entry, "textFormat: Text.PlainText"
    refute_includes qml, "newest 20 kept"
  end
end
