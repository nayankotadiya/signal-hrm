import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';
import 'package:n_ui/src/tokens/n_palette.dart';

void main() {
  group('NTokens.resolve', () {
    test('light and dark swap ink and invert the active pill', () {
      final light = NTokens.resolve(const NPreferences(), Brightness.light);
      final dark = NTokens.resolve(const NPreferences(), Brightness.dark);
      expect(light.ink, const Color(0xFF0F1115));
      expect(dark.ink, const Color(0xFFEDEFF5));
      expect(light.pillActive, light.ink);
      expect(dark.pillActive, dark.ink);
      expect(dark.pillActiveText, const Color(0xFF0F1115));
    });

    test('the dark action card is identical in both themes', () {
      final light = NTokens.resolve(const NPreferences(), Brightness.light);
      final dark = NTokens.resolve(const NPreferences(), Brightness.dark);
      expect(light.actionCard, const Color(0xFF1F1F21));
      expect(dark.actionCard, light.actionCard);
    });

    test('reduced transparency gives solid cards and no blur', () {
      final t = NTokens.resolve(const NPreferences(reducedTransparency: true), Brightness.light);
      expect(t.card.a, 1.0);
      expect(t.blurSigma, 0);
      expect(t.reducedTransparency, isTrue);
    });

    test('classic is flatter: smaller radii, no blur, visible borders', () {
      final ios = NTokens.resolve(const NPreferences(), Brightness.light);
      final classic = NTokens.resolve(const NPreferences(themeStyle: NThemeStyle.classic), Brightness.light);
      expect(classic.radiusCard, lessThan(ios.radiusCard));
      expect(classic.blurSigma, 0);
      expect(ios.blurSigma, greaterThan(0));
      expect(classic.cardBorder.a, greaterThan(0));
    });

    test('reduced motion zeroes every motion duration but keeps the Undo window', () {
      final t = NTokens.resolve(const NPreferences(reducedMotion: true), Brightness.light);
      expect(t.durations.pillPosition, Duration.zero);
      expect(t.durations.viewEnter, Duration.zero);
      expect(t.durations.counter, Duration.zero);
      expect(t.durations.heldCommitWindow, const Duration(seconds: 5));
    });

    test('density scales spacing', () {
      final compact = NTokens.resolve(const NPreferences(density: NDensity.compact), Brightness.light);
      final spacious = NTokens.resolve(const NPreferences(density: NDensity.spacious), Brightness.light);
      expect(compact.gap, lessThan(spacious.gap));
    });

    test('lerp returns endpoints at 0 and 1', () {
      final a = NTokens.resolve(const NPreferences(), Brightness.light);
      final b = NTokens.resolve(const NPreferences(), Brightness.dark);
      expect(a.lerp(b, 0).ink, a.ink);
      expect(a.lerp(b, 1).ink, b.ink);
    });
  });

  group('contrast', () {
    test('black on white is 21:1', () {
      expect(NContrast.ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    });

    test('muted text passes AA on every light panel stop and card', () {
      final t = NTokens.resolve(const NPreferences(), Brightness.light);
      for (final panel in NPalette.lightPanel) {
        expect(NContrast.ratio(t.muted, panel), greaterThanOrEqualTo(4.5), reason: 'on panel $panel');
        final card = NContrast.over(t.card, panel);
        expect(NContrast.ratio(t.muted, card), greaterThanOrEqualTo(4.5), reason: 'on card over $panel');
      }
    });

    test('muted text passes AA on dark cards', () {
      final t = NTokens.resolve(const NPreferences(), Brightness.dark);
      for (final panel in NPalette.darkPanel) {
        expect(NContrast.ratio(t.muted, NContrast.over(t.card, panel)), greaterThanOrEqualTo(4.5));
      }
    });

    test('every accent preset keeps AA text contrast in both themes', () {
      for (final accent in NAccent.values.where((a) => a != NAccent.custom)) {
        for (final b in Brightness.values) {
          final t = NTokens.resolve(NPreferences(accent: accent), b);
          expect(NContrast.ratio(t.onAccent, t.accent), greaterThanOrEqualTo(4.5), reason: '$accent $b');
        }
      }
    });

    test('a failing custom accent is clamped until it passes', () {
      const yellow = Color(0xFFFFF200); // fails with both white and ink on a light card
      final t = NTokens.resolve(const NPreferences(accent: NAccent.custom, customAccent: yellow), Brightness.light);
      expect(NContrast.ratio(t.onAccent, t.accent), greaterThanOrEqualTo(4.5));
      expect(t.accent, isNot(yellow));
    });
  });

  group('NPreferences', () {
    test('round-trips through JSON', () {
      const p = NPreferences(
        appearance: NAppearance.dark,
        themeStyle: NThemeStyle.classic,
        accent: NAccent.custom,
        customAccent: Color(0xFF123456),
        density: NDensity.compact,
        reducedMotion: true,
        textScale: 1.4,
      );
      expect(NPreferences.fromJson(p.toJson()), p);
    });

    test('malformed values fall back to safe defaults instead of throwing', () {
      final p = NPreferences.fromJson({
        'appearance': 'neon',
        'textScale': 'huge',
        'radiusScale': 99,
        'customAccent': 'not-a-color',
        'reducedMotion': 'yes',
      });
      expect(p.appearance, NAppearance.system);
      expect(p.textScale, 1.0);
      expect(p.radiusScale, 1.25); // clamped
      expect(p.customAccent, isNull);
      expect(p.reducedMotion, isFalse);
    });

    test('organization defaults apply until the user overrides them', () {
      const org = NPreferences(accent: NAccent.teal, themeStyle: NThemeStyle.classic);
      final p = NPreferences.fromJson({'accent': 'pink'}, base: org);
      expect(p.accent, NAccent.pink);
      expect(p.themeStyle, NThemeStyle.classic);
    });
  });

  group('NBreakpoint', () {
    test('boundaries match the responsive table', () {
      expect(NBreakpoint.fromWidth(360), NBreakpoint.mobile);
      expect(NBreakpoint.fromWidth(759), NBreakpoint.mobile);
      expect(NBreakpoint.fromWidth(760), NBreakpoint.tablet);
      expect(NBreakpoint.fromWidth(999), NBreakpoint.tablet);
      expect(NBreakpoint.fromWidth(1000), NBreakpoint.laptop);
      expect(NBreakpoint.fromWidth(1439), NBreakpoint.laptop);
      expect(NBreakpoint.fromWidth(1440), NBreakpoint.desktop);
      expect(NBreakpoint.fromWidth(1920).bentoColumns, 4);
    });
  });
}
