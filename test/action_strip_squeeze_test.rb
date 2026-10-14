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
    assert_match(/Layout\.maximumWidth:[^\n]*repoCard\.width/, strip,
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

  # Measured at the 320px width floor (340px headless-Sway harness): the card
  # interior is 295px and the activity row's other members hold
  # 20 + 108 (narrow heatmap label) + 58 (heatmap track minimum) + 16
  # (two row spacings) = 202px before the strip gets anything. A strip capped
  # at the bare interior (repoCard.width - 20) keeps its 214px implicit width,
  # the row cannot shrink a non-fill item, and Qt lays the row out at 396px —
  # pushing the flow's right-aligned second half of buttons past the card and
  # the viewport edge where the list clip swallows them, with flowRows stuck
  # at 1 and the card never growing its wrap band.
  def test_strip_maximum_width_is_capped_to_the_rows_remaining_capacity
    strip = qml_source[/id: repoActionStrip.*?DragHandle \{/m]
    refute_nil strip, "the action strip must exist inside the pinned card"

    refute_match(/Layout\.maximumWidth:\s*repoCard\.width\s*-\s*20\b/, strip,
                 "the strip must not cap itself at the bare card interior: the activity row's heatmap label and track already hold 202px of it, so the non-fill strip keeps its implicit width and the row overflows instead of wrapping")
    assert_match(/Layout\.maximumWidth:\s*Math\.max\(72,\s*repoCard\.width\s*-\s*202\)/, strip,
                 "the strip must cap itself at the row's remaining width (interior minus margins, narrow heatmap label, track minimum and two spacings) so Flow wraps inside the card")
  end

  # The heatmap track only has spare width to grow into on roomy modals; at
  # the width floor its 58px minimum is all the row can spare, and a
  # zero-preferred fill item in the shrinking row absorbs width the strip
  # needs for its wrap decision (measured: the row held a +26px overflow with
  # a fill track but fit the interior exactly once the track was fixed).
  def test_heatmap_track_yields_its_fill_at_the_width_floor
    qml = qml_source
    track = qml[/id: heatmapTrack\n(.*?)\n\s*\}\n/m]
    refute_nil track, "heatmapTrack not found"
    assert_match(/Layout\.fillWidth:\s*!root\.narrowLayout/, track,
                 "the track must keep its fill only on roomy modals; at the width floor the strip needs the width to wrap")
    assert_match(/Layout\.preferredWidth:\s*58/, track,
                 "when the fill is released the track must fall back to its 58px minimum instead of an implicit 0 that collapses it")
  end

  # The modal header's four buttons (Overview, Triage, Refresh, Close) in one
  # horizontal row raise the header row's minimum to ~665px. At the 320px
  # width floor that minimum exceeds the 292px modal column and Qt lays every
  # fill child out past the frame — measured: the repo list rendered 479px
  # wide inside a 292px column, cards spilling off the screen, so none of the
  # strip fixes below could engage. The narrow branch must present the same
  # four controls in a compact 2x2 footprint instead.
  def test_header_buttons_fold_into_a_grid_at_the_narrow_breakpoint
    qml = qml_source
    narrow_grid = qml[/GridLayout \{\n\s*visible: root\.narrowLayout\n(?:\s*Layout\.alignment:[^\n]*\n)?\s*columns: 2\n[\s\S]*?\n\s*ActionButton \{\n\s*label: "Close"\n\s*tone: "muted"[\s\S]*?\n\s*\}\n\s*\}\n/m]
    refute_nil narrow_grid, "the narrow header button grid is missing"

    ["ModeTabButton", "\"Refresh\"", "\"Close\"", "root.showOverviewMode()", "root.closePanel()"].each do |needle|
      assert_includes narrow_grid, needle, "header control missing from the narrow grid: #{needle}"
    end

    # The two branches are exclusive: exactly one of the pair is visible per
    # breakpoint, so the deck never duplicates its buttons on screen.
    wides = qml.scan(/RowLayout \{\n\s*visible: !root\.narrowLayout\n(?:\s*Layout\.alignment:[^\n]*\n)?\s*spacing: 10\n\n\s*ModeTabButton \{/)
    narrow_grids = qml.scan(/GridLayout \{\n\s*visible: root\.narrowLayout\n/)
    assert_equal 1, narrow_grids.length, "the narrow header grid must be declared exactly once"
    assert_equal 1, wides.length, "the wide header button row must be declared exactly once"
  end
end
