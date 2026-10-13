import 'package:flutter/painting.dart';

/// WCAG 2.x contrast helpers used to verify tokens and clamp custom accents.
abstract final class NContrast {
  /// Contrast ratio between two opaque colors (1.0 to 21.0).
  static double ratio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Composites a translucent [fg] over an opaque [bg].
  static Color over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

  /// Picks white or [ink] for text on [background], whichever contrasts more.
  static Color onColor(Color background, {Color ink = const Color(0xFF0F1115)}) {
    const white = Color(0xFFFFFFFF);
    return ratio(white, background) >= ratio(ink, background) ? white : ink;
  }

  /// Returns an accent that keeps at least [minText] contrast with its best text color and at least
  /// [minUi] contrast against [surface] (non-text UI, WCAG 1.4.11). Adjusts lightness in small steps,
  /// keeping hue and saturation, so a user's custom color stays recognisable.
  static Color clampAccent(
    Color accent, {
    required Color surface,
    double minText = 4.5,
    double minUi = 3.0,
  }) {
    bool ok(Color c) => ratio(onColor(c), c) >= minText && ratio(c, surface) >= minUi;
    if (ok(accent)) return accent.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(accent.withValues(alpha: 1));
    final surfaceIsLight = surface.computeLuminance() > 0.4;
    // Move away from the surface: darker on light surfaces, lighter on dark ones.
    for (var i = 1; i <= 40; i++) {
      final delta = 0.02 * i;
      final l = (surfaceIsLight ? hsl.lightness - delta : hsl.lightness + delta).clamp(0.0, 1.0);
      final candidate = hsl.withLightness(l).toColor();
      if (ok(candidate)) return candidate;
    }
    return surfaceIsLight ? const Color(0xFF3B2FB8) : const Color(0xFFB9B2FF);
  }
}
