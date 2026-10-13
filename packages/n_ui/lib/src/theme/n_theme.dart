import 'package:flutter/material.dart';

import '../motion/n_motion.dart';
import '../tokens/n_preferences.dart';
import '../tokens/n_tokens.dart';

/// Builds a Material [ThemeData] that carries [NTokens] as an extension. Material widgets are only
/// used as plumbing (text selection, scroll behaviour, dialogs); visible components are N UI widgets.
abstract final class NTheme {
  static ThemeData build(NPreferences prefs, Brightness brightness) {
    final t = NTokens.resolve(prefs, brightness);
    final scheme = ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: brightness,
    ).copyWith(
      primary: t.accent,
      onPrimary: t.onAccent,
      surface: t.card.withValues(alpha: 1),
      onSurface: t.ink,
      error: t.red,
      outline: t.divider,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: NType.family,
      fontFamilyFallback: NType.fallback,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dividerColor: t.divider,
      focusColor: t.focusRing.withValues(alpha: 0.18),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionColor: t.accent.withValues(alpha: 0.28),
        selectionHandleColor: t.accent,
      ),
      extensions: [t],
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: t.ink, displayColor: t.ink),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: t.actionCard, borderRadius: BorderRadius.circular(10)),
        textStyle: t.text.caption(color: t.actionCardText),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: NPageTransitionsBuilder(),
        TargetPlatform.iOS: NPageTransitionsBuilder(),
        TargetPlatform.windows: NPageTransitionsBuilder(),
        TargetPlatform.macOS: NPageTransitionsBuilder(),
        TargetPlatform.linux: NPageTransitionsBuilder(),
        TargetPlatform.fuchsia: NPageTransitionsBuilder(),
      }),
    );
  }

  /// Resolves light/dark from the appearance preference and the platform brightness.
  static Brightness brightnessFor(NAppearance appearance, Brightness platform) => switch (appearance) {
        NAppearance.light => Brightness.light,
        NAppearance.dark => Brightness.dark,
        NAppearance.system => platform,
      };
}

/// A quiet fade-and-rise for pushed (non-sibling) routes such as detail pages and full-screen forms.
/// Sibling routes use the direction-aware switcher instead. Honors reduced motion.
class NPageTransitionsBuilder extends PageTransitionsBuilder {
  const NPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (NMotion.reduced(context)) return child;
    final curved = CurvedAnimation(parent: animation, curve: NCurves.emphasized, reverseCurve: NCurves.exit);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}
