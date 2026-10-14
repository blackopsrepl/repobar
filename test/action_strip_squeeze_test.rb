# frozen_string_literal: true

require_relative "test_helper"

# The pinned repo card's action row must survive the modal's narrowest layout:
# at the 320px width floor the card interior is ~268px, and a strip that keeps
# its implicit width pushes later buttons past the card edge where the parent
# clip cuts them. The strip must declare an explicit squeeze against the card
# interior so Flow wraps instead of overflowing.
class ActionStripSqueezeTest < Minitest::Test
  def qml_source
    File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__), encoding: Encoding::UTF_8)
  end

  def test_repo_action_strip_declares_a_width_squeeze_inside_the_heatmap_row
    strip = qml_source[/id: repoActionStrip.*?DragHandle \{/m]
    refute_nil strip, "the action strip must exist inside the pinned card"

    assert_match(/Layout\.minimumWidth:/, strip,
                 "the strip needs an explicit minimumWidth so the row can shrink it instead of trusting implicit width")
    assert_match(/Layout\.maximumWidth:\s*repoCard\.width/, strip,
                 "the strip must cap its width at the card interior so wrapped buttons stay inside the card")
    assert_match(/id: repoCard/, qml_source, "the card id the strip caps against must exist")
  end

  def test_card_height_grows_with_measured_flow_rows
    body = qml_source[/id: repoCard.*?\n\s*\}/m]
    assert_match(/repoActionStrip\.flowRows/, body,
                 "the card must grow a line for each measured wrap row, or the wrapped controls clip")
  end

  def test_wrapped_action_rows_are_visible_not_clipped
    strip = qml_source[/id: repoActionStrip.*?DragHandle \{/m]
    assert_match(/Layout\.preferredHeight:.*?flowRows/, strip,
                 "the strip's height must follow its measured row count or the wrapped buttons are invisible")
    strip_at = qml_source.index("id: repoActionStrip")
    refute_nil strip_at, "the strip must exist"
    row = qml_source[0...strip_at][/RowLayout \{[\s\S]*?Layout\.preferredHeight: repoActionStrip/m]
    refute_nil row, "the strip must live inside the height-carrying heatmap row"
    assert_includes row, "Layout.preferredHeight: repoActionStrip",
                    "the hosting row must grow with the strip or the second action band clips inside the card"
  end
end
