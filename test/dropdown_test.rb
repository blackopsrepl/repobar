# frozen_string_literal: true

require_relative "test_helper"

# Bounded bar drop-down contract for the QuickShell panel.
#
# The panel used to be a full-screen PanelWindow (screen-sized surface, centered
# frame, a screen-wide outside-click catcher). A covering modal is the wrong
# shape for a bar companion: the PanelWindow surface itself must be exactly the
# card's rect (bar-edge anchored strip: top + left + right anchors, no bottom
# anchor), the height counted from laid-out parts, the dismissal carried by Esc
# and a strip catcher inside the now-bounded surface instead of a whole-screen
# catcher. A bounded Wayland surface is opaque to input, so the desktop-level
# outside-click dismissal can no longer exist; that trade is documented in the
# repo's UI docs and asserted here so docs and pixels stay in agreement.
#
# qmllint cannot validate this file (the Quickshell ShellRoot type only exists
# where Quickshell is installed), so the panel's load-bearing shape is asserted
# here by source contract, complementing the headless render proof.
class DropDownTest < Minitest::Test
  PANEL = File.expand_path("../frontend/quickshell/shell.qml", __dir__)

  def panel_source
    @panel_source ||= File.read(PANEL)
  end

  def panel_window_block
    panel_source[/PanelWindow \{(.*?)\n    \}\n/m, 1].to_s
  end

  def test_panelwindow_surface_is_bounded_to_the_bar_edge_strip
    block = panel_window_block
    refute_empty block, "PanelWindow block not found"

    anchors = block[/anchors \{(.*?)\}/m, 1].to_s
    # Exactly one screen edge is anchored: top. (left/right anchors would pin
    # the strip to the full screen width, and bottom is what made the old
    # surface cover the whole screen.) Horizontal placement comes from the
    # side margins.
    assert_match(/anchors\s*\{\s*top: true\s*\}/m, block)
    refute_match(/bottom:\s*true/, block)
    refute_match(/left:\s*true/, block)
    refute_match(/right:\s*true/, block)

    # The surface must size itself from the card geometry (plus the top margin
    # above the bar), never from the full screen; the horizontal extent is
    # centered through side margins, not edge anchors.
    assert_match(/implicitWidth:\s*panel\.cardGeometry\.width/, block)
    assert_match(/implicitHeight:\s*panel\.cardGeometry\.height \+ root\.panelTopMargin/, block)
    assert_match(/anchors\s*\{[^}]*top: true(?![^}]*bottom)/, block)
    assert_match(/left: Math\.max\(0, \(screen\.width - panel\.cardGeometry\.width\) \/ 2\)/, block)
    refute_match(/anchors\s*\{[^}]*bottom: true/, block)

    # The old screen-wide input mask was the full-surface catcher; with a
    # bounded surface the input mask is the whole point and must be gone.
    refute_includes block, "mask: Region { item: modalFrame"
  end

  def test_modal_frame_hangs_from_the_bar_edge_instead_of_floating_centered
    source = panel_source
    frame_block = source[/id: modalFrame(.*?)Keys\.onEscapePressed/m, 1].to_s
    refute_empty frame_block, "modalFrame not found"
    refute_includes frame_block, "anchors.centerIn: parent"
    refute_includes frame_block, "anchors.horizontalCenter: parent"

    # The card reads the same counted geometry that sizes the bounded surface —
    # the window's own top margin hangs it from the bar — so the card always
    # fills its window exactly.
    frame_block = source[/id: modalFrame(.*?)Keys\.onEscapePressed/m, 1].to_s
    assert_includes frame_block, "width: panel.cardGeometry.width"
    assert_includes frame_block, "height: panel.cardGeometry.height"
    assert_match(/anchors\s*\{\s*top: parent\.top\s+horizontalCenter: parent\.horizontalCenter\s*\}/m, frame_block)
    assert_match(/id: panel\s+visible: uiAdapter\.open[\s\S]*?readonly property var cardGeometry: root\.modalGeometry\(\)/m, source)
  end

  def test_height_is_counted_from_laid_out_parts_and_never_overlaps_the_bar_or_screen
    source = panel_source
    assert_match(/property int panelTopMargin: 52/, source)
    assert_match(/property int popupMaxWidth: 920/, source)

    geometry = source[/function modalGeometry\(\) \{(.*?)\n    \}\n/m, 1].to_s
    refute_empty geometry, "modalGeometry() not found"

    # Counted, not measured: a declared chrome constant plus visible rows at
    # their card pitch, with the card count capped at what the viewport can
    # show via a named helper — never an implicit-size sum, never a content
    # blind fixed floor.
    assert_match(/var chromeCounted = \d+/, geometry)
    assert_match(/var repoRows = Math\.max\(1, root\.repositories\.length\)/, geometry)
    assert_match(/var rowsHeight = Math\.min\(repoRows, root\.visibleRows\(\)\) \* 204/, geometry)
    assert_match(/var listCountedHeight = chromeCounted \+ rowsHeight/, geometry)
    # One app, one size: every mode lives in the same constant window. The
    # counted height is the LARGER of the two mode contents — never a
    # per-mode resize — and the height is a single constant, not a max taken
    # at window level.
    assert_match(/var triageCountedHeight = 816/, geometry)
    assert_match(/listCountedHeight, triageCountedHeight/, geometry)
    assert_match(/var topMargin = root\.panelTopMargin/, geometry)
    # The cap reads the SCREEN (read-only input), never the panel's own
    # derived height — sizing the surface from a value that depends on the
    # surface is the binding loop the headless render caught.
    assert_match(/var screen = root\.panelScreen\(\)/, geometry)
    assert_match(/screen\.height - topMargin - 12/, geometry)
    assert_match(/function panelScreen\(\)/, source)
    assert_match(/var contentHeight = topMargin \+ Math\.max\(listCountedHeight, triageCountedHeight\)/, geometry)
    assert_match(/var height = Math\.min\(contentHeight, screen\.height - topMargin - 12\)/, geometry)
    refute_match(/Math\.max\(420, contentHeight\)/, geometry,
                 "the per-mode floor resize must not come back: the window is one size")

    # The counted height is the window's height; the screen clamp (line above)
    # is the only shrink, and it never differs per mode.
    # The old content-blind 18px floor must not come back.
    refute_match(/root\.popupMinHeight/, geometry)

    # Rows visible below the fold need their count printed at the list header.
    assert_match(/function visibleRows\(\)/, source)
    assert_match(/\(root\.repositories\.length - Math\.min\(repoList\.count, root\.visibleRows\(\)\)\).*?more repos.*?scroll/m, source)
  end

  def test_visible_rows_come_from_a_declared_breakpoint_not_a_hardcoded_split
    source = panel_source
    assert_match(/property bool shortViewport: root\.screenBoxHeight < \d+/, source,
      "shortViewport must read the screen box: the bounded surface's own height participates in its sizing")
    assert_match(/function visibleRows\(\) \{\s*return root\.shortViewport \? 3 : 6\s*\}/m, source)
    # The counted height consumes the helper, so a second row-count split
    # cannot drift from it.
    assert_includes panel_source[/function modalGeometry\(\) \{(.*?)\n    \}\n/m, 1], "root.visibleRows()"
  end

  def test_width_is_content_fit_with_a_floor_and_never_the_full_screen
    geometry = panel_source[/function modalGeometry\(\) \{(.*?)\n    \}\n/m, 1].to_s
    # Content-fit: triage/detail needs the wide band, plain overview the narrow
    # one; the 360px absolute floor only survives on tiny screens, and the
    # side margins are always real so the card never touches the screen edge.
    # One width for every mode and repo state — never a triage-only reskin
    # size. The screen-room clamp stays for tiny screens only.
    assert_match(/Math\.min\(1280, Math\.max\(360, screen\.width - 36\)\)/, geometry)
    refute_match(/root\.triageMode\(\).*\? 1280 : 960/, geometry)
  end

  def test_dismissal_is_the_esc_shortcut_and_the_strip_catcher_not_a_screen_wide_catcher
    source = panel_source
    # The full-screen shape (a catch-all MouseArea binding the whole viewport
    # to closePanel) must not come back.
    refute_match(/MouseArea\s*\{\s*anchors\.fill: parent\s+onClicked: root\.closePanel\(\)/m, source)

    # The surface between the bar and the card carries the strip catcher: a
    # click inside the bounded window but outside the card radius dismisses.
    assert_match(/Rectangle\s*\{\s*id: stripCatcher\s+anchors\.fill: parent\s+color: "transparent"\s+MouseArea\s*\{\s*anchors\.fill: parent\s+z: -1\s+onClicked: root\.closePanel\(\)/m, source)

    # Dead space inside the card stays inert (clicks must not fall through to
    # the strip catcher beneath the card).
    assert_match(/id: cardCatcher\s+anchors\.fill: parent\s+z: -1/m, source)

    # Esc keeps two paths: the window Shortcut and the card-level key handler.
    assert_match(/sequence: "Esc"\s+context: Qt\.WindowShortcut\s+onActivated: root\.closePanel\(\)/m, source)
    assert_includes source, "Keys.onEscapePressed: root.closePanel()"
  end

  def test_frame_carries_the_shadow_drop_separation
    source = panel_source
    assert_match(/id: frameShadow/m, source)
    assert_match(/anchors\.topMargin: 5/, source)
    assert_match(/color: Qt\.rgba\(0, 0, 0, 0\.35\)/, source)
    assert_match(/id: frameShadow[^}]*width: modalFrame\.width\s+height: modalFrame\.height[^}]*visible: modalFrame\.visible/m, source)
  end

  def test_header_carries_the_live_dot_and_family_styled_buttons
    source = panel_source
    assert_match(/id: liveDot/m, source)
    # Amber while any work is in flight, red on a failed repo, green otherwise.
    assert_match(/id: liveDot.*?actionRunner\.running.*?viewData\.summary\.errorCount \|\| 0\) > 0 \? root\.theme\.bad : root\.theme\.goodSoft/m, source)
    assert_match(/id: liveDot.*?root\.threadRequestedId\.length > 0/m, source)

    # The ActionButton component is the family-styled button (tone + tooltip +
    # Accessible name + 10px label), used by both header variants.
    assert_match(/component ActionButton: Button \{/, source)
    assert_match(/property string tone: "info"/, source)
    source.scan(/ActionButton\s*\{\s*label: "Refresh"\s+tone: "info"/m).length.then do |count|
      assert_operator count, :>=, 2, "both header variants need the Refresh ActionButton (got #{count})"
    end
    refute_match(/ActionButton\s*\{\s*label: "Close"\s+tone: "bad"/, source)
    source.scan(/ActionButton\s*\{\s*label: "Close"\s+tone: "muted"/m).length.then do |count|
      assert_operator count, :>=, 2, "both header variants need the Close ActionButton (got #{count})"
    end
    assert_includes source, 'tooltip: "Re-scan repositories and rebuild the cached snapshot"'
    assert_includes source, 'tooltip: "Close the panel (Esc)"'
  end

  def test_cards_and_frame_take_the_family_radius_drop
    # The family aesthetic is square-cornered: the modal frame — like
    # every card, button and badge in the panel — must not round its
    # corners. The block extract stops at the frame's next statement so
    # the assertion stays scoped to the element itself.
    frame_block = panel_source[/id: modalFrame(.*?)Keys\.onEscapePressed/m, 1].to_s
    refute_empty frame_block, "modal frame block not found"
    assert_match(/id: modalFrame(?:(?!\{)[^{}])*(\{(?:[^{}]*)\})?(?:(?!\{)[^{}])*radius: 0/m, panel_source)

    # No old rounded-corner value may survive on the modal frame.
    refute_match(/radius:[ \t]*(?!0\b|3\.5|1\.5|1\b|2\b)[0-9]/, frame_block)
  end

  def test_ui_docs_describe_the_bounded_drop_down_and_its_dismissal_trade
    readme = File.read(File.expand_path("../README.md", __dir__))
    architecture = File.read(File.expand_path("../docs/architecture.md", __dir__))
    wireframe = File.read(File.expand_path("../WIREFRAME.md", __dir__))

    # The bar-edge drop-down phrasing with the honest dismissal contract, named
    # in the README and at least one doc.
    [readme, architecture].each do |body|
      assert_includes body, "drops below the bar edge on the same side as its Waybar chip"
      assert_includes body, "click inside the popover to interact, Esc or the Close button to dismiss"
    end
    assert_includes architecture, "bounded PanelWindow surface"

    # The old covering-modal phrasing must be gone everywhere docs describe
    # the live surface: the centered modal screen is no longer the truth.
    [readme, architecture, wireframe].each do |body|
      refute_includes body, "centered vertically and horizontally"
      refute_match(/dimmed backdrop/i, body)
      refute_includes body, "Full-screen layer surface: modalGeometry() clamps the centered"
    end
  end
end
