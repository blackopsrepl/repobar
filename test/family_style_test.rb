# frozen_string_literal: true

require_relative "test_helper"

# Family-wide visual uniformity contract for the QuickShell panel.
#
# The *-bar family renders with TokenMaxx's square-cornered mac-bar
# aesthetic: no rounded corner anywhere on a Rectangle that shapes a
# card, button, badge, chip, pane or frame. The only nonzero radii are
# pill/dot shapes that are not corner rounding: the 7px live dot
# (radius 3.5), thin attention rails (radius 1.5), heatmap cells
# (radius 1) and status stripes (radius 2). Fonts come from
# Switchyard's family scale. Asserted on the source so docs and pixels
# stay in agreement; the pixel proof is the headless render run, not
# this file.
class FamilyStyleTest < Minitest::Test
  PANEL = File.expand_path("../frontend/quickshell/shell.qml", __dir__)

  # Squared family corners: every corner-rounding radius is 0. The
  # survivors are geometrically dots/pills/stripe-cells, not roundings.
  ALLOWED_NONZERO_RADIUS = {
    "3.5" => 1,  # the 7px panel live dot
    "1.5" => 2,  # triage + repo-rail attention rails
    "1" => 2,    # account/repo heatmap cells
    "2" => 2     # selected-item status stripes
  }.freeze

  # The family font scale (Switchyard's): body 10, secondary/meta 9,
  # section/card labels 11, summary/metric values 12, detail view
  # header 15, panel title 21. Dot glyphs may stay tiny. Any nonnegative
  # literal outside {7, 9, 10, 11, 12, 15, 21} is off-scale. The avatar
  # initial's box-proportional fallback is the one computed exception.
  ALLOWED_FONT_SIZES = [7, 9, 10, 11, 12, 15, 21].freeze

  def panel_source
    @panel_source ||= File.read(PANEL, encoding: Encoding::UTF_8)
  end

  def radius_values
    panel_source.scan(/^[ \t]*radius:[ \t]*([0-9.]+)[ \t]*$/).flatten
  end

  def font_pixel_sizes
    panel_source.scan(/^[ \t]*font\.pixelSize:[ \t]*([0-9]+)[ \t]*$/).flatten.map(&:to_i)
  end

  def dims_are_pillish?(dims)
    return false if dims.empty?

    # Dot: width == height; rail/stripe/cell: thinnest extent <= 8.
    dims.uniq.length == 1 || dims.min <= 8
  end

  private :panel_source, :radius_values, :font_pixel_sizes, :dims_are_pillish?

  def test_every_corner_rounding_radius_is_zero
    offenders = []
    radius_values.tally.each do |value, count|
      next if value == "0"
      next if ALLOWED_NONZERO_RADIUS[value] == count

      offenders << "radius #{value} x#{count}"
    end
    assert_empty offenders,
      "non-family radii in shell.qml (only 0 plus #{ALLOWED_NONZERO_RADIUS.inspect} are allowed): #{offenders.join(', ')}"
  end

  def test_nonzero_radii_are_dot_or_thin_pill_shapes
    # Any radius other than 0 must sit on an element that is either a
    # dot (equal width/height <= 8), a thin rail/stripe/cell (width or
    # height <= 8), so a future rounded card cannot hide behind the
    # allowlist above.
    panel_source.lines.each_with_index do |line, offset|
      match = line.match(/^[ \t]*radius:[ \t]*([0-9.]+)[ \t]*$/)
      next unless match
      next if match[1] == "0"

      window = panel_source.lines[offset - 8, 12].join
      dimensions = window.scan(/^[ \t]*(?:[A-Za-z]+\.)?(?:width|height|preferredWidth|preferredHeight|implicitWidth|implicitHeight):[ \t]*([0-9]+)/)
        .flatten
        .map(&:to_i)
      assert dims_are_pillish?(dimensions),
        "radius #{match[1]} at shell.qml:#{offset + 1} is not on a dot/pill/stripe element: #{line.strip}"
    end
  end

  def test_font_scale_matches_family
    offenders = font_pixel_sizes.tally.select { |size, _| !ALLOWED_FONT_SIZES.include?(size) }
      .map { |size, count| "font #{size} x#{count}" }
    assert_empty offenders,
      "non-family font sizes in shell.qml (allowed scale: #{ALLOWED_FONT_SIZES.sort.inspect} plus a computed avatar fallback): #{offenders.join(', ')}"
  end

  def test_panel_title_uses_the_family_title_size
    title_at = panel_source.index('text: "RepoBar"')
    refute_nil title_at, 'the "RepoBar" title Text was not found'
    window = panel_source[title_at, 260]
    assert_match(/font\.pixelSize:[ \t]*21[ \t]*$/, window, "panel title must be 21 (family scale)")
    # One title element only: no other pixel size may sit inside it.
    refute_match(/pixelSize:[ \t]*(?!21\b)[0-9]/, window.split("font.bold:").first.to_s,
      "the title's own pixelSize lines must not carry another size")
  end

  def test_only_the_computed_avatar_fallback_may_bind_a_nonliteral_size
    nonliteral = panel_source.scan(/^[ \t]*font\.pixelSize:[ \t]*(?![ \t]*[0-9]+[ \t]*$)(.+)$/).map { |m| m[0].strip }
    assert_equal ["Math.max(8, Math.round(avatarBox.boxSize * 0.5))"], nonliteral,
      "only the avatar initial's box-proportional fallback may bind a nonliteral size"
  end
end
