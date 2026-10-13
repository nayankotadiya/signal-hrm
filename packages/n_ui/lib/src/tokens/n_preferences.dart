import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

enum NAppearance { light, dark, system }

/// iOS-inspired = glass (blur, transparency, big radii). Classic = flatter, stronger borders.
enum NThemeStyle { iosInspired, classic }

enum NAccent { purple, blue, green, orange, pink, teal, custom }

enum NDensity {
  compact(0.85),
  comfortable(1.0),
  spacious(1.15);

  const NDensity(this.factor);
  final double factor;
}

enum NNavStyle { topPills, sidebar, rail, bottom }

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}

double _num(Object? raw, double fallback, double min, double max) {
  if (raw is num && raw.isFinite) return raw.toDouble().clamp(min, max);
  return fallback;
}

bool _bool(Object? raw, bool fallback) => raw is bool ? raw : fallback;

/// A user's N UI preferences (`user_preferences` collection). Every field has a safe default, and
/// parsing never throws: unknown or malformed values fall back, so a bad sync can't break the UI.
/// Changing preferences never touches data or permissions.
@immutable
class NPreferences {
  const NPreferences({
    this.appearance = NAppearance.system,
    this.themeStyle = NThemeStyle.iosInspired,
    this.accent = NAccent.purple,
    this.customAccent,
    this.textScale = 1.0,
    this.headingScale = 1.0,
    this.bodyScale = 1.0,
    this.captionScale = 1.0,
    this.buttonScale = 1.0,
    this.density = NDensity.comfortable,
    this.radiusScale = 1.0,
    this.shadowIntensity = 1.0,
    this.blur = 1.0,
    this.transparency = 1.0,
    this.navStyle = NNavStyle.topPills,
    this.reducedMotion = false,
    this.reducedTransparency = false,
    this.highContrast = false,
    this.largerText = false,
  });

  final NAppearance appearance;
  final NThemeStyle themeStyle;
  final NAccent accent;

  /// Used when [accent] is [NAccent.custom]; contrast-clamped by the token resolver.
  final Color? customAccent;

  /// Overall text scale (multiplies the platform text scale). 0.85 to 2.0.
  final double textScale;
  final double headingScale;
  final double bodyScale;
  final double captionScale;
  final double buttonScale;
  final NDensity density;

  /// 0.5 (squarer) to 1.25 (rounder). Pills always stay fully round.
  final double radiusScale;

  /// 0 (flat) to 1.5.
  final double shadowIntensity;

  /// 0 to 1, multiplies glass blur.
  final double blur;

  /// 0 (solid) to 1 (full glass).
  final double transparency;
  final NNavStyle navStyle;
  final bool reducedMotion;
  final bool reducedTransparency;
  final bool highContrast;
  final bool largerText;

  /// Effective overall text scale including the "Larger text" accessibility switch.
  double get effectiveTextScale => (textScale * (largerText ? 1.25 : 1.0)).clamp(0.85, 2.0);

  NPreferences copyWith({
    NAppearance? appearance,
    NThemeStyle? themeStyle,
    NAccent? accent,
    Color? customAccent,
    double? textScale,
    double? headingScale,
    double? bodyScale,
    double? captionScale,
    double? buttonScale,
    NDensity? density,
    double? radiusScale,
    double? shadowIntensity,
    double? blur,
    double? transparency,
    NNavStyle? navStyle,
    bool? reducedMotion,
    bool? reducedTransparency,
    bool? highContrast,
    bool? largerText,
  }) {
    return NPreferences(
      appearance: appearance ?? this.appearance,
      themeStyle: themeStyle ?? this.themeStyle,
      accent: accent ?? this.accent,
      customAccent: customAccent ?? this.customAccent,
      textScale: textScale ?? this.textScale,
      headingScale: headingScale ?? this.headingScale,
      bodyScale: bodyScale ?? this.bodyScale,
      captionScale: captionScale ?? this.captionScale,
      buttonScale: buttonScale ?? this.buttonScale,
      density: density ?? this.density,
      radiusScale: radiusScale ?? this.radiusScale,
      shadowIntensity: shadowIntensity ?? this.shadowIntensity,
      blur: blur ?? this.blur,
      transparency: transparency ?? this.transparency,
      navStyle: navStyle ?? this.navStyle,
      reducedMotion: reducedMotion ?? this.reducedMotion,
      reducedTransparency: reducedTransparency ?? this.reducedTransparency,
      highContrast: highContrast ?? this.highContrast,
      largerText: largerText ?? this.largerText,
    );
  }

  Map<String, Object?> toJson() => {
        'appearance': appearance.name,
        'themeStyle': themeStyle.name,
        'accent': accent.name,
        'customAccent': customAccent == null ? null : _hex(customAccent!),
        'textScale': textScale,
        'headingScale': headingScale,
        'bodyScale': bodyScale,
        'captionScale': captionScale,
        'buttonScale': buttonScale,
        'density': density.name,
        'radiusScale': radiusScale,
        'shadowIntensity': shadowIntensity,
        'blur': blur,
        'transparency': transparency,
        'navStyle': navStyle.name,
        'reducedMotion': reducedMotion,
        'reducedTransparency': reducedTransparency,
        'highContrast': highContrast,
        'largerText': largerText,
      };

  /// Tolerant parser: anything missing or malformed falls back to [base] (the organization defaults).
  factory NPreferences.fromJson(Map<String, Object?> json, {NPreferences base = const NPreferences()}) {
    return NPreferences(
      appearance: _enumByName(NAppearance.values, json['appearance'], base.appearance),
      themeStyle: _enumByName(NThemeStyle.values, json['themeStyle'], base.themeStyle),
      accent: _enumByName(NAccent.values, json['accent'], base.accent),
      customAccent: _parseHex(json['customAccent']) ?? base.customAccent,
      textScale: _num(json['textScale'], base.textScale, 0.85, 2.0),
      headingScale: _num(json['headingScale'], base.headingScale, 0.8, 1.4),
      bodyScale: _num(json['bodyScale'], base.bodyScale, 0.8, 1.4),
      captionScale: _num(json['captionScale'], base.captionScale, 0.8, 1.4),
      buttonScale: _num(json['buttonScale'], base.buttonScale, 0.8, 1.4),
      density: _enumByName(NDensity.values, json['density'], base.density),
      radiusScale: _num(json['radiusScale'], base.radiusScale, 0.5, 1.25),
      shadowIntensity: _num(json['shadowIntensity'], base.shadowIntensity, 0.0, 1.5),
      blur: _num(json['blur'], base.blur, 0.0, 1.0),
      transparency: _num(json['transparency'], base.transparency, 0.0, 1.0),
      navStyle: _enumByName(NNavStyle.values, json['navStyle'], base.navStyle),
      reducedMotion: _bool(json['reducedMotion'], base.reducedMotion),
      reducedTransparency: _bool(json['reducedTransparency'], base.reducedTransparency),
      highContrast: _bool(json['highContrast'], base.highContrast),
      largerText: _bool(json['largerText'], base.largerText),
    );
  }

  static String _hex(Color c) {
    String two(double v) {
      final i = (v * 255).round();
      final byte = i < 0 ? 0 : (i > 255 ? 255 : i);
      return byte.toRadixString(16).padLeft(2, '0');
    }

    return '#${two(c.r)}${two(c.g)}${two(c.b)}'.toUpperCase();
  }

  static Color? _parseHex(Object? raw) {
    if (raw is! String) return null;
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(raw.trim());
    if (m == null) return null;
    return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
  }

  @override
  bool operator ==(Object other) =>
      other is NPreferences && _mapEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  static bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }
}
