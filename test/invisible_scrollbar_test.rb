# frozen_string_literal: true
require "test_helper"

class InvisibleScrollbarTest < Minitest::Test
  def qml
    @qml ||= File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
  end

  # The default ScrollBar paints a groove and handle straight over the
  # content's right edge — graphics die under it. Scrolling itself must keep
  # working, so every scroll surface uses the shared invisible indicator
  # instead of a styled one.
  def test_every_scroll_surface_uses_the_invisible_indicator
    assert_includes qml, "component InvisibleScroll: ScrollBar", "the shared invisible indicator must exist"
    assert_equal 0, qml.scan(/ScrollBar\.vertical: ScrollBar \{
\s*policy:/).length + qml.scan(/ScrollBar\.vertical: ScrollBar \{\}/).length + qml.scan(/ScrollBar\.vertical: ScrollBar \{
\s*policy: triageReaderScroll/).length,
      "a default-styled ScrollBar still paints over content"
    assert_match(/ScrollBar\.vertical: InvisibleScroll \{ \}/, qml)
    assert_operator qml.scan(/ScrollBar\.vertical: InvisibleScroll \{ \}/).length, :>=, 6,
      "every scroll surface must hang the invisible indicator"
  end
end
