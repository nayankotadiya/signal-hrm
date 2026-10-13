import 'package:flutter/widgets.dart';

import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';
import 'n_entrance.dart';

enum _Phase { idle, exiting, entering }

/// Direction-aware view switching for tab bodies and sibling routes.
///
/// Going to a higher index: the old view exits toward the start (translate -40px, fade out, 220ms,
/// ease-in), and only then the new view enters from the end (translate +60px to 0, fade in, 520ms,
/// `Cubic(.2, .8, .2, 1)`). Lower index reverses. RTL mirrors the direction. Reduced motion swaps
/// instantly. Views it switches to get `NEntranceScope(enabled: false)`, so the page-load stagger
/// does not replay.
///
/// [NViewSwitcher.new] shows one [child] (keyed by [index]) and disposes the old one after exit.
/// [NViewSwitcher.indexed] keeps every child mounted (offstage when hidden) to preserve state, for
/// example the branch navigators of a shell.
class NViewSwitcher extends StatefulWidget {
  const NViewSwitcher({super.key, required this.index, required Widget this.child}) : children = null;

  const NViewSwitcher.indexed({super.key, required this.index, required List<Widget> this.children}) : child = null;

  final int index;
  final Widget? child;
  final List<Widget>? children;

  @override
  State<NViewSwitcher> createState() => _NViewSwitcherState();
}

class _NViewSwitcherState extends State<NViewSwitcher> with TickerProviderStateMixin {
  late final AnimationController _exit = AnimationController(vsync: this);
  late final AnimationController _enter = AnimationController(vsync: this, value: 1);
  late final CurvedAnimation _exitCurve = CurvedAnimation(parent: _exit, curve: NCurves.exit);
  late final CurvedAnimation _enterCurve = CurvedAnimation(parent: _enter, curve: NCurves.emphasized);

  _Phase _phase = _Phase.idle;
  late int _shownIndex; // index currently on screen (set in initState, not lazily)
  Widget? _outgoing; // single-child mode: the view being dismissed
  int _direction = 1; // +1 forward (higher index), -1 back
  bool _hasSwitched = false;
  final Set<int> _visited = {};

  @override
  void initState() {
    super.initState();
    _shownIndex = widget.index;
    _visited.add(widget.index);
  }

  @override
  void didUpdateWidget(NViewSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.index == old.index) return;
    _hasSwitched = true;
    final from = _phase == _Phase.exiting ? _shownIndex : old.index;
    _direction = widget.index > from ? 1 : -1;

    // No setState needed here: build() always runs after didUpdateWidget.
    if (NMotion.reduced(context)) {
      _exit.stop();
      _enter.value = 1;
      _phase = _Phase.idle;
      _shownIndex = widget.index;
      _outgoing = null;
      _visited.add(widget.index);
      return;
    }

    if (_phase == _Phase.exiting) return; // still leaving; the new target is picked up on completion

    final d = NTokens.of(context).durations;
    // Start exiting from wherever the current view is (it may be mid-entry).
    _outgoing = old.child;
    _enter.stop();
    final startExit = _phase == _Phase.entering ? 1 - _enter.value : 0.0;
    _phase = _Phase.exiting;
    _exit.duration = d.viewExit;
    _exit.forward(from: startExit).whenCompleteOrCancel(_onExitDone);
  }

  void _onExitDone() {
    if (!mounted || _phase != _Phase.exiting) return;
    final d = NTokens.of(context).durations;
    setState(() {
      _outgoing = null;
      _shownIndex = widget.index;
      _visited.add(widget.index);
      _phase = _Phase.entering;
    });
    _enter.duration = d.viewEnter;
    _enter.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && _phase == _Phase.entering) setState(() => _phase = _Phase.idle);
    });
  }

  @override
  void dispose() {
    _exitCurve.dispose();
    _enterCurve.dispose();
    _exit.dispose();
    _enter.dispose();
    super.dispose();
  }

  double get _rtlSign => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  /// Always wraps in Opacity + Transform (identity when idle or inactive) so the child's element
  /// position never changes and its state survives the end of an animation.
  Widget _animated(Widget child, {bool active = true}) {
    return AnimatedBuilder(
      animation: Listenable.merge([_exitCurve, _enterCurve]),
      child: child,
      builder: (context, child) {
        var dx = 0.0;
        var opacity = 1.0;
        if (active && _phase == _Phase.exiting) {
          dx = -40 * _direction * _exitCurve.value;
          opacity = 1 - _exitCurve.value;
        } else if (active && _phase == _Phase.entering) {
          dx = 60 * _direction * (1 - _enterCurve.value);
          opacity = _enterCurve.value;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(dx * _rtlSign, 0), child: child),
        );
      },
    );
  }

  Widget _scoped(Widget child) => NEntranceScope(enabled: !_hasSwitched, child: child);

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    if (children == null) {
      final exiting = _phase == _Phase.exiting;
      final visible = exiting ? (_outgoing ?? widget.child!) : widget.child!;
      // Keyed by index: the outgoing view keeps its element while it exits; the new one is fresh.
      final key = ValueKey<int>(exiting ? _shownIndex : widget.index);
      return _animated(KeyedSubtree(key: key, child: _scoped(visible)));
    }

    // Indexed mode: every visited child stays mounted with an identical wrapper structure;
    // only the shown one is onstage, ticking and animated.
    final shown = _phase == _Phase.exiting ? _shownIndex : widget.index;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        for (var i = 0; i < children.length; i++)
          if (i == shown || _visited.contains(i))
            KeyedSubtree(
              key: ValueKey<String>('slot-$i'),
              child: Offstage(
                offstage: i != shown,
                child: TickerMode(
                  enabled: i == shown,
                  child: _animated(_scoped(children[i]), active: i == shown),
                ),
              ),
            ),
      ],
    );
  }
}
