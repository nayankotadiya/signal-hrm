import 'package:flutter/widgets.dart';

import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

/// Turns the page-load entrance on or off for a subtree. [NViewSwitcher] disables it for views it
/// switches to, so changing tabs never replays the screen's first-entry stagger.
class NEntranceScope extends InheritedWidget {
  const NEntranceScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NEntranceScope>()?.enabled ?? true;

  @override
  bool updateShouldNotify(NEntranceScope oldWidget) => enabled != oldWidget.enabled;
}

/// One orchestrated page-load step: fade in and rise 14px over 550ms with `Cubic(.2, .8, .2, 1)`,
/// delayed by `order * 80ms`. Runs once, on first build. No leftover delay afterwards, so hover
/// effects respond instantly. Reduced motion shows the final state immediately.
class NEntrance extends StatefulWidget {
  const NEntrance({super.key, required this.order, required this.child});

  /// Position in the stagger sequence (0 = first).
  final int order;
  final Widget child;

  @override
  State<NEntrance> createState() => _NEntranceState();
}

class _NEntranceState extends State<NEntrance> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _skip = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c != null || _skip) return;
    final d = NTokens.of(context).durations;
    if (!NEntranceScope.enabledOf(context) || NMotion.reduced(context) || d.entrance == Duration.zero) {
      _skip = true;
      return;
    }
    final delay = d.entranceStagger * widget.order;
    final total = delay + d.entrance;
    final c = AnimationController(vsync: this, duration: total);
    _c = c;
    _curve = CurvedAnimation(
      parent: c,
      curve: Interval(delay.inMicroseconds / total.inMicroseconds, 1, curve: NCurves.emphasized),
    );
    c.forward();
  }

  late CurvedAnimation _curve;

  @override
  void dispose() {
    if (_c != null) _curve.dispose();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_skip || c == null) return widget.child;
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        // Same structure at every value (including 1) so the child is never rebuilt from scratch.
        final v = _curve.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
        );
      },
    );
  }
}
