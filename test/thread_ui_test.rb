# frozen_string_literal: true

require_relative "test_helper"

class ThreadUiTest < Minitest::Test
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
