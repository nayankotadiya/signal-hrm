import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'n_contrast.dart';
import 'n_palette.dart';
import 'n_preferences.dart';

/// Motion durations. All collapse to zero under reduced motion (see [NTokens.reducedMotion]).
@immutable
class NDurations {
  const NDurations({
    this.pillPosition = const Duration(milliseconds: 550),
    this.pillLabel = const Duration(milliseconds: 350),
    this.viewExit = const Duration(milliseconds: 220),
    this.viewEnter = const Duration(milliseconds: 520),
    this.entrance = const Duration(milliseconds: 550),
    this.entranceStagger = const Duration(milliseconds: 80),
    this.listStagger = const Duration(milliseconds: 60),
    this.counter = const Duration(milliseconds: 1100),
    this.ring = const Duration(milliseconds: 1400),
    this.meterFill = const Duration(milliseconds: 1400),
    this.bars = const Duration(milliseconds: 900),
    this.barStagger = const Duration(milliseconds: 70),
    this.donut = const Duration(milliseconds: 1200),
    this.sparkline = const Duration(milliseconds: 1600),
    this.hover = const Duration(milliseconds: 180),
    this.rowExit = const Duration(milliseconds: 320),
    this.toast = const Duration(milliseconds: 360),
    this.heldCommitWindow = const Duration(seconds: 5),
  });

  final Duration pillPosition;

  /// Width uses the same controller as position, over the first 82% (about 450ms).
  double get pillWidthInterval => 0.82;
  final Duration pillLabel;
  final Duration viewExit;
  final Duration viewEnter;
  final Duration entrance;
  final Duration entranceStagger;
  final Duration listStagger;
  final Duration counter;
  final Duration ring;
  final Duration meterFill;
  final Duration bars;
  final Duration barStagger;
  final Duration donut;
  final Duration sparkline;
  final Duration hover;
  final Duration rowExit;
  final Duration toast;

  /// Not motion: the Undo window for held commits. Never shortened by reduced motion.
  final Duration heldCommitWindow;

  static const zero = NDurations(
    pillPosition: Duration.zero,
    pillLabel: Duration.zero,
    viewExit: Duration.zero,
    viewEnter: Duration.zero,
    entrance: Duration.zero,
    entranceStagger: Duration.zero,
    listStagger: Duration.zero,
    counter: Duration.zero,
    ring: Duration.zero,
    meterFill: Duration.zero,
    bars: Duration.zero,
    barStagger: Duration.zero,
    donut: Duration.zero,
    sparkline: Duration.zero,
    hover: Duration.zero,
    rowExit: Duration.zero,
    toast: Duration.zero,
  );
}

/// Motion curves.
abstract final class NCurves {
  /// Soft spring with slight overshoot (sliding pill position).
  static const spring = Cubic(.34, 1.35, .5, 1);

  /// Emphasized deceleration (pill width, view enter, page-load entrance).
  static const emphasized = Cubic(.2, .8, .2, 1);
  static const exit = Curves.easeIn;
  static const counter = Curves.easeOutCubic;
}

/// Type helpers. All numbers use tabular figures.
@immutable
class NType {
  const NType({
    required this.ink,
    required this.muted,
    this.headingScale = 1.0,
    this.bodyScale = 1.0,
    this.captionScale = 1.0,
    this.buttonScale = 1.0,
  });

  /// Bundled in this package. Using the full asset family name (instead of `package:`) keeps
  /// the system fallbacks below unprefixed so they still resolve.
  static const family = 'packages/n_ui/Outfit';
  static const fallback = <String>['system-ui', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'];
  static const tabular = [FontFeature.tabularFigures()];

  final Color ink;
  final Color muted;
  final double headingScale;
  final double bodyScale;
  final double captionScale;
  final double buttonScale;

  TextStyle _base(double size, FontWeight w, Color color) => TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: w,
        color: color,
        height: 1.3,
      );

  /// Big light numbers: weight 300, letter-spacing -0.03em, tabular.
  TextStyle bigNumber(double size, {Color? color}) => _base(size * headingScale, FontWeight.w300, color ?? ink).copyWith(
        letterSpacing: -0.03 * size * headingScale,
        fontFeatures: tabular,
        height: 1.0,
      );

  /// Page heading: weight 300; pair with [headingBold] for the one bold word.
  TextStyle heading({double size = 34, Color? color}) =>
      _base(size * headingScale, FontWeight.w300, color ?? ink).copyWith(letterSpacing: -0.02 * size, height: 1.15);
  TextStyle headingBold({double size = 34, Color? color}) => heading(size: size, color: color).copyWith(fontWeight: FontWeight.w600);
  TextStyle title({double size = 17, Color? color}) => _base(size * headingScale, FontWeight.w500, color ?? ink);
  TextStyle body({double size = 13.5, Color? color, FontWeight weight = FontWeight.w400}) =>
      _base(size * bodyScale, weight, color ?? ink).copyWith(fontFeatures: tabular);
  TextStyle caption({double size = 11.5, Color? color, FontWeight weight = FontWeight.w400}) =>
      _base(size * captionScale, weight, color ?? muted).copyWith(fontFeatures: tabular, letterSpacing: 0.1);
  TextStyle button({double size = 13.5, Color? color}) =>
      _base(size * buttonScale, FontWeight.w500, color ?? ink).copyWith(height: 1.1);
}

/// The single source of N UI design values. Widgets read `NTokens.of(context)` and never hardcode
/// a color, radius or duration. Resolved at runtime from [NPreferences] by [NTokens.resolve].
@immutable
class NTokens extends ThemeExtension<NTokens> {
  const NTokens({
    required this.brightness,
    required this.style,
    required this.pageGradient,
    required this.frameColor,
    required this.frameWidth,
    required this.panelGradient,
    required this.card,
    required this.cardBorder,
    required this.cardShadow,
    required this.ink,
    required this.muted,
    required this.divider,
    required this.pillTrack,
    required this.pillActive,
    required this.pillActiveText,
    required this.accent,
    required this.onAccent,
    required this.primaryButton,
    required this.onPrimaryButton,
    required this.focusRing,
    required this.chartStart,
    required this.chartEnd,
    required this.lime,
    required this.yellow,
    required this.teal,
    required this.green,
    required this.red,
    required this.amber,
    required this.dangerTint,
    required this.dangerText,
    required this.actionCard,
    required this.actionCardText,
    required this.actionCardMuted,
    required this.actionCardSheet,
    required this.radiusFrame,
    required this.radiusPanel,
    required this.radiusCard,
    required this.radiusTile,
    required this.radiusSheet,
    required this.density,
    required this.blurSigma,
    required this.durations,
    required this.reducedMotion,
    required this.reducedTransparency,
    required this.highContrast,
    required this.text,
  });

  final Brightness brightness;
  final NThemeStyle style;

  // Surfaces
  final Gradient pageGradient;
  final Color frameColor;
  final double frameWidth;
  final Gradient panelGradient;
  final Color card;
  final Color cardBorder;
  final List<BoxShadow> cardShadow;

  // Text and lines
  final Color ink;
  final Color muted;
  final Color divider;

  // Pills
  final Color pillTrack;
  final Color pillActive;
  final Color pillActiveText;

  // Accent and actions
  final Color accent;
  final Color onAccent;
  final Color primaryButton;
  final Color onPrimaryButton;
  final Color focusRing;
  final Color chartStart;
  final Color chartEnd;

  // Palette accents
  final Color lime;
  final Color yellow;
  final Color teal;
  final Color green;
  final Color red;
  final Color amber;
  final Color dangerTint;
  final Color dangerText;

  // The one dark action card
  final Color actionCard;
  final Color actionCardText;
  final Color actionCardMuted;
  final Color actionCardSheet;

  // Shape
  final double radiusFrame;
  final double radiusPanel;
  final double radiusCard;
  final double radiusTile;
  final double radiusSheet;
  static const double radiusPill = 99;

  // Spacing
  final double density;
  double space(double base) => base * density;
  double get gap => space(14);
  double get cardPadding => space(16);
  double panelPadding({required bool mobile}) => mobile ? space(16) : space(24);

  // Effects and motion
  final double blurSigma;
  final NDurations durations;
  final bool reducedMotion;
  final bool reducedTransparency;
  final bool highContrast;
  final NType text;

  bool get isDark => brightness == Brightness.dark;

  /// Reads tokens from the nearest Theme. Falls back to safe light defaults if none is installed.
  static NTokens of(BuildContext context) =>
      Theme.of(context).extension<NTokens>() ?? NTokens.resolve(const NPreferences(), Brightness.light);

  /// Builds tokens from preferences. Pure and fast: safe to call on every preference change.
  factory NTokens.resolve(NPreferences p, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final classic = p.themeStyle == NThemeStyle.classic;
    final solid = p.reducedTransparency || p.highContrast;

    final ink = dark ? NPalette.darkInk : NPalette.lightInk;
    var muted = dark ? NPalette.darkMuted : NPalette.lightMuted;
    if (p.highContrast) muted = dark ? const Color(0xFFC9CEDB) : const Color(0xFF3D424B);

    // Card opacity: glass by default, more opaque for Classic, solid for reduced transparency.
    final baseCard = dark ? NPalette.darkCard : NPalette.lightCard;
    final glassAlpha = baseCard.a;
    final classicAlpha = dark ? 0.94 : 0.92;
    var alpha = classic ? classicAlpha : glassAlpha;
    alpha = alpha + (1 - alpha) * (1 - p.transparency); // transparency slider: 0 = solid
    if (solid) alpha = 1;
    final card = baseCard.withValues(alpha: alpha);

    final surfaceForContrast = NContrast.over(card, dark ? NPalette.darkPanel[1] : NPalette.lightPanel[1]);
    final rawAccent = switch (p.accent) {
      NAccent.purple => NPalette.accentPurple,
      NAccent.blue => NPalette.accentBlue,
      NAccent.green => NPalette.accentGreen,
      NAccent.orange => NPalette.accentOrange,
      NAccent.pink => NPalette.accentPink,
      NAccent.teal => NPalette.accentTeal,
      NAccent.custom => p.customAccent ?? NPalette.accentPurple,
    };
    final accent = NContrast.clampAccent(rawAccent, surface: surfaceForContrast);

    final r = p.radiusScale.clamp(0.5, 1.25) * (classic ? 0.6 : 1.0);
    final shadowK = p.shadowIntensity.clamp(0.0, 1.5) * (classic ? 0.5 : 1.0);
    final divider = p.highContrast ? ink.withValues(alpha: 0.35) : NPalette.divider;

    return NTokens(
      brightness: brightness,
      style: p.themeStyle,
      pageGradient: LinearGradient(
        // 135deg in CSS: top-left to bottom-right
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark ? NPalette.darkPage : NPalette.lightPage,
        stops: dark ? NPalette.darkPageStops : NPalette.lightPageStops,
      ),
      frameColor: dark ? NPalette.darkFrame : NPalette.lightFrame,
      frameWidth: 6,
      panelGradient: LinearGradient(
        // 160deg: mostly top to bottom, slightly left to right
        begin: const Alignment(-0.36, -1),
        end: const Alignment(0.36, 1),
        colors: dark ? NPalette.darkPanel : NPalette.lightPanel,
        stops: dark ? NPalette.darkPanelStops : NPalette.lightPanelStops,
      ),
      card: card,
      cardBorder: classic || p.highContrast
          ? (dark ? const Color(0x33FFFFFF) : const Color(0x330F1115))
          : Colors.transparent,
      cardShadow: shadowK == 0
          ? const []
          : [
              BoxShadow(
                offset: const Offset(0, 8),
                blurRadius: 24,
                spreadRadius: -14,
                color: (dark ? Colors.black : const Color(0xFF283C78)).withValues(alpha: (dark ? 0.6 : 0.35) * shadowK),
              ),
            ],
      ink: ink,
      muted: muted,
      divider: divider,
      pillTrack: solid
          ? (dark ? const Color(0xFF262B3B) : const Color(0xFFF2F4F7))
          : (dark ? NPalette.darkPillTrack : NPalette.lightPillTrack),
      pillActive: dark ? NPalette.darkInk : NPalette.lightInk,
      pillActiveText: dark ? NPalette.lightInk : Colors.white,
      accent: accent,
      onAccent: NContrast.onColor(accent),
      primaryButton: dark ? NPalette.darkInk : NPalette.lightInk,
      onPrimaryButton: dark ? NPalette.lightInk : Colors.white,
      focusRing: accent,
      chartStart: accent,
      chartEnd: NPalette.teal,
      lime: NPalette.lime,
      yellow: NPalette.yellow,
      teal: NPalette.teal,
      green: NPalette.green,
      red: NPalette.red,
      amber: NPalette.amber,
      dangerTint: NPalette.dangerTint,
      dangerText: dark ? const Color(0xFFFF8A8E) : NPalette.dangerText,
      actionCard: NPalette.actionCard,
      actionCardText: NPalette.actionCardText,
      actionCardMuted: NPalette.actionCardMuted,
      actionCardSheet: NPalette.actionCardSheet,
      radiusFrame: 30 * r,
      radiusPanel: 24 * r,
      radiusCard: 22 * r,
      radiusTile: 13 * r,
      radiusSheet: 20 * r,
      density: p.density.factor,
      blurSigma: solid || classic ? 0 : 18 * p.blur.clamp(0.0, 1.0),
      durations: p.reducedMotion ? NDurations.zero : const NDurations(),
      reducedMotion: p.reducedMotion,
      reducedTransparency: solid,
      highContrast: p.highContrast,
      text: NType(
        ink: ink,
        muted: muted,
        headingScale: p.headingScale,
        bodyScale: p.bodyScale,
        captionScale: p.captionScale,
        buttonScale: p.buttonScale,
      ),
    );
  }

  @override
  NTokens copyWith({NDurations? durations, bool? reducedMotion}) {
    return NTokens(
      brightness: brightness,
      style: style,
      pageGradient: pageGradient,
      frameColor: frameColor,
      frameWidth: frameWidth,
      panelGradient: panelGradient,
      card: card,
      cardBorder: cardBorder,
      cardShadow: cardShadow,
      ink: ink,
      muted: muted,
      divider: divider,
      pillTrack: pillTrack,
      pillActive: pillActive,
      pillActiveText: pillActiveText,
      accent: accent,
      onAccent: onAccent,
      primaryButton: primaryButton,
      onPrimaryButton: onPrimaryButton,
      focusRing: focusRing,
      chartStart: chartStart,
      chartEnd: chartEnd,
      lime: lime,
      yellow: yellow,
      teal: teal,
      green: green,
      red: red,
      amber: amber,
      dangerTint: dangerTint,
      dangerText: dangerText,
      actionCard: actionCard,
      actionCardText: actionCardText,
      actionCardMuted: actionCardMuted,
      actionCardSheet: actionCardSheet,
      radiusFrame: radiusFrame,
      radiusPanel: radiusPanel,
      radiusCard: radiusCard,
      radiusTile: radiusTile,
      radiusSheet: radiusSheet,
      density: density,
      blurSigma: blurSigma,
      durations: durations ?? this.durations,
      reducedMotion: reducedMotion ?? this.reducedMotion,
      reducedTransparency: reducedTransparency,
      highContrast: highContrast,
      text: text,
    );
  }

  /// Theme animation between token sets: colors and sizes interpolate, the rest switches at 50%.
  @override
  NTokens lerp(covariant ThemeExtension<NTokens>? other, double t) {
    if (other is! NTokens) return this;
    final o = other;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    double d(double a, double b) => lerpDouble(a, b, t)!;
    final pick = t < 0.5 ? this : o;
    return NTokens(
      brightness: pick.brightness,
      style: pick.style,
      pageGradient: Gradient.lerp(pageGradient, o.pageGradient, t)!,
      frameColor: c(frameColor, o.frameColor),
      frameWidth: d(frameWidth, o.frameWidth),
      panelGradient: Gradient.lerp(panelGradient, o.panelGradient, t)!,
      card: c(card, o.card),
      cardBorder: c(cardBorder, o.cardBorder),
      cardShadow: BoxShadow.lerpList(cardShadow, o.cardShadow, t) ?? const [],
      ink: c(ink, o.ink),
      muted: c(muted, o.muted),
      divider: c(divider, o.divider),
      pillTrack: c(pillTrack, o.pillTrack),
      pillActive: c(pillActive, o.pillActive),
      pillActiveText: c(pillActiveText, o.pillActiveText),
      accent: c(accent, o.accent),
      onAccent: pick.onAccent,
      primaryButton: c(primaryButton, o.primaryButton),
      onPrimaryButton: c(onPrimaryButton, o.onPrimaryButton),
      focusRing: c(focusRing, o.focusRing),
      chartStart: c(chartStart, o.chartStart),
      chartEnd: c(chartEnd, o.chartEnd),
      lime: lime,
      yellow: yellow,
      teal: teal,
      green: green,
      red: red,
      amber: amber,
      dangerTint: dangerTint,
      dangerText: c(dangerText, o.dangerText),
      actionCard: actionCard,
      actionCardText: actionCardText,
      actionCardMuted: actionCardMuted,
      actionCardSheet: actionCardSheet,
      radiusFrame: d(radiusFrame, o.radiusFrame),
      radiusPanel: d(radiusPanel, o.radiusPanel),
      radiusCard: d(radiusCard, o.radiusCard),
      radiusTile: d(radiusTile, o.radiusTile),
      radiusSheet: d(radiusSheet, o.radiusSheet),
      density: d(density, o.density),
      blurSigma: d(blurSigma, o.blurSigma),
      durations: pick.durations,
      reducedMotion: pick.reducedMotion,
      reducedTransparency: pick.reducedTransparency,
      highContrast: pick.highContrast,
      text: pick.text,
    );
  }
}
