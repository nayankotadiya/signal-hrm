import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

/// One entry in an [NSlidingPills] control.
@immutable
class NPillItem {
  const NPillItem({required this.label, this.icon, this.badgeCount = 0, this.semanticLabel});

  final String label;
  final IconData? icon;

  /// Red count bubble (unread, pending). Hidden at zero.
  final int badgeCount;

  /// Overrides [label] for screen readers.
  final String? semanticLabel;
}

enum NPillSize {
  small(36, 12.5, 14),
  medium(44, 13.5, 18),
  large(52, 14.5, 22);

  const NPillSize(this.height, this.fontSize, this.hPadding);
  final double height;
  final double fontSize;
  final double hPadding;
}

/// The single tab / nav / segmented / filter / stepper control in N UI. Nothing else may hand-roll one.
///
/// A track holds the labels and ONE indicator that travels: position animates 550ms on a soft spring
/// (`Cubic(.34, 1.35, .5, 1)`), width over the first 82% with `Cubic(.2, .8, .2, 1)`, label color 350ms.
/// The first layout places the indicator without animation. It re-measures after layout, resize,
/// text-scale and font-load changes, skips measuring while hidden or zero-width, scrolls the active
/// label to center when the labels overflow, follows a linked [PageView] while swiping, and supports
/// arrow / Home / End / Enter / Space, focus rings, RTL, screen readers and reduced motion.
class NSlidingPills extends StatefulWidget {
  const NSlidingPills({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onChanged,
    this.pageController,
    this.expand = false,
    this.size = NPillSize.medium,
    this.showLabels = true,
    this.semanticLabel,
  });

  final List<NPillItem> items;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// When the tabs drive a [PageView], pass its controller: the indicator then follows the finger.
  final PageController? pageController;

  /// Fill the available width with equal segments (mobile bottom nav, short segmented controls).
  final bool expand;
  final NPillSize size;

  /// Icons only (labels still announced to screen readers). Requires every item to have an icon.
  final bool showLabels;

  /// Group name for screen readers, e.g. "Main navigation".
  final String? semanticLabel;

  @override
  State<NSlidingPills> createState() => _NSlidingPillsState();
}

@immutable
class _Seg {
  const _Seg(this.left, this.width);
  final double left;
  final double width;

  static _Seg lerp(_Seg a, _Seg b, double t) => _Seg(lerpDouble(a.left, b.left, t)!, lerpDouble(a.width, b.width, t)!);

  bool closeTo(_Seg o) => (left - o.left).abs() < 0.5 && (width - o.width).abs() < 0.5;
}

class _NSlidingPillsState extends State<NSlidingPills> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _c;
  late final CurvedAnimation _pos;
  late final CurvedAnimation _width;
  final GlobalKey _contentKey = GlobalKey();
  final ScrollController _scroll = ScrollController();
  late List<GlobalKey> _itemKeys;
  late List<FocusNode> _focusNodes;

  List<_Seg>? _segs;
  double _contentWidth = 0;
  _Seg _from = const _Seg(0, 0);
  _Seg _to = const _Seg(0, 0);
  bool _measured = false;
  bool _measureScheduled = false;

  /// Live indicator while a linked PageView is being swiped or settling.
  _Seg? _dragSeg;

  /// True while a tap-initiated page animation runs; the spring drives the indicator then.
  bool _tapDriven = false;
  Timer? _tapDrivenTimer;
  int? _focusedIndex;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 550), value: 1);
    _pos = CurvedAnimation(parent: _c, curve: NCurves.spring);
    _width = CurvedAnimation(parent: _c, curve: const Interval(0, 0.82, curve: NCurves.emphasized));
    _createItemState();
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(_scheduleMeasure);
    widget.pageController?.addListener(_onPage);
  }

  void _createItemState() {
    _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
    _focusNodes = List.generate(widget.items.length, (i) => FocusNode(debugLabel: 'NSlidingPills item $i'));
  }

  @override
  void didUpdateWidget(NSlidingPills old) {
    super.didUpdateWidget(old);
    if (old.pageController != widget.pageController) {
      old.pageController?.removeListener(_onPage);
      widget.pageController?.addListener(_onPage);
    }
    if (old.items.length != widget.items.length) {
      for (final n in _focusNodes) {
        n.dispose();
      }
      _createItemState();
      _segs = null;
      _measured = false;
      _scheduleMeasure();
      return;
    }
    if (old.selectedIndex != widget.selectedIndex) _animateTo(widget.selectedIndex);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasure(); // text scale, directionality, theme density
  }

  @override
  void didChangeMetrics() => _scheduleMeasure(); // window resize, rotation

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PaintingBinding.instance.systemFonts.removeListener(_scheduleMeasure);
    widget.pageController?.removeListener(_onPage);
    _tapDrivenTimer?.cancel();
    _pos.dispose();
    _width.dispose();
    _c.dispose();
    _scroll.dispose();
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- measuring

  _Seg get _current => _Seg(
        lerpDouble(_from.left, _to.left, _pos.value)!,
        lerpDouble(_from.width, _to.width, _width.value)!,
      );

  void _scheduleMeasure() {
    if (_measureScheduled || !mounted) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _measure();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _measure() {
    final content = _contentKey.currentContext?.findRenderObject();
    if (content is! RenderBox || !content.attached || !content.hasSize || content.size.width <= 0) {
      return; // hidden or not laid out yet; the next layout schedules another measure
    }
    final segs = <_Seg>[];
    for (final key in _itemKeys) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final offset = box.localToGlobal(Offset.zero, ancestor: content);
      segs.add(_Seg(offset.dx, box.size.width));
    }
    final prev = _segs;
    final changed = prev == null || prev.length != segs.length || [for (var i = 0; i < segs.length; i++) !segs[i].closeTo(prev[i])].any((x) => x);
    _contentWidth = content.size.width;
    if (!changed && _measured) return;

    final sel = widget.selectedIndex.clamp(0, segs.length - 1);
    final first = !_measured;
    setState(() {
      _segs = segs;
      if (first || !_c.isAnimating) {
        _from = segs[sel];
        _to = segs[sel];
        _c.value = 1; // no animation on first layout or on a pure re-measure
      } else {
        _to = segs[sel]; // retarget mid-flight
      }
      _measured = true;
    });
    if (first) _scrollToCenter(sel, animate: false);
  }

  // ---------------------------------------------------------------- motion

  void _animateTo(int index) {
    final segs = _segs;
    if (!_measured || segs == null || index < 0 || index >= segs.length) {
      _scheduleMeasure();
      return;
    }
    _from = _dragSeg ?? _current;
    _to = segs[index];
    _dragSeg = null;
    if (NMotion.reduced(context)) {
      _c.value = 1; // notifies the AnimatedBuilder; the indicator jumps
    } else {
      _c.forward(from: 0);
    }
    _scrollToCenter(index, animate: true);
  }

  void _scrollToCenter(int index, {required bool animate}) {
    final segs = _segs;
    if (segs == null || !_scroll.hasClients || index >= segs.length) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
    final seg = segs[index];
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final center = seg.left + seg.width / 2;
    final fromStart = rtl ? _contentWidth - center : center;
    final target = (fromStart - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    if (!animate || NMotion.reduced(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 550), curve: NCurves.emphasized);
    }
  }

  void _onPage() {
    // A PageView can notify during layout (e.g. on resize); never setState mid-layout.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onPage();
      });
      return;
    }
    final pc = widget.pageController;
    final segs = _segs;
    if (pc == null || !pc.hasClients || segs == null || segs.isEmpty) return;
    final page = pc.page;
    if (page == null) return;
    final settled = (page - page.round()).abs() < 0.001;
    if (_tapDriven) {
      if (settled) _clearTapDriven();
      return;
    }
    if (settled) {
      if (_dragSeg != null) {
        final idx = page.round().clamp(0, segs.length - 1);
        setState(() {
          _dragSeg = null;
          _from = segs[idx];
          _to = segs[idx];
          _c.value = 1;
        });
      }
      return;
    }
    final i = page.floor().clamp(0, segs.length - 1);
    final j = (i + 1).clamp(0, segs.length - 1);
    final seg = _Seg.lerp(segs[i], segs[j], page - page.floor());
    _c.stop();
    setState(() => _dragSeg = seg);
  }

  void _clearTapDriven() {
    _tapDriven = false;
    _tapDrivenTimer?.cancel();
    _tapDrivenTimer = null;
  }

  void _handleTap(int index) {
    if (index == widget.selectedIndex) {
      widget.onChanged(index);
      return;
    }
    if (widget.pageController != null) {
      _tapDriven = true;
      _tapDrivenTimer?.cancel();
      // Safety: if the parent never animates the PageView, resume following swipes.
      _tapDrivenTimer = Timer(const Duration(milliseconds: 1200), _clearTapDriven);
    }
    widget.onChanged(index);
  }

  // ---------------------------------------------------------------- keyboard

  KeyEventResult _onKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = widget.items.length;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final key = event.logicalKey;
    int? target;
    if (key == LogicalKeyboardKey.arrowRight) {
      target = rtl ? index - 1 : index + 1;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      target = rtl ? index + 1 : index - 1;
    } else if (key == LogicalKeyboardKey.home) {
      target = 0;
    } else if (key == LogicalKeyboardKey.end) {
      target = n - 1;
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.numpadEnter) {
      _handleTap(index);
      return KeyEventResult.handled;
    }
    if (target == null) return KeyEventResult.ignored;
    target = (target + n) % n; // wrap around
    _focusNodes[target].requestFocus();
    _handleTap(target);
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    assert(widget.items.isNotEmpty, 'NSlidingPills needs at least one item');
    final t = NTokens.of(context);
    // Register dependencies so text-scale and direction changes trigger a re-measure.
    MediaQuery.textScalerOf(context);
    Directionality.of(context);
    final n = widget.items.length;
    final durations = NMotion.durations(context);

    final row = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          if (widget.expand) Expanded(child: _buildItem(context, t, durations, i, n)) else _buildItem(context, t, durations, i, n),
      ],
    );

    final content = Stack(
      key: _contentKey,
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            if (!_measured) return const SizedBox.shrink();
            final seg = _dragSeg ?? _current;
            return Positioned(
              left: seg.left,
              width: seg.width < 0 ? 0 : seg.width,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                key: const ValueKey('n-sliding-pills-indicator'),
                decoration: BoxDecoration(
                  color: t.pillActive,
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  boxShadow: t.reducedTransparency
                      ? null
                      : [BoxShadow(color: t.pillActive.withValues(alpha: 0.22), blurRadius: 10, offset: const Offset(0, 3))],
                ),
              ),
            );
          },
        ),
        row,
      ],
    );

    _scheduleMeasure(); // cheap: compares and only rebuilds when something moved

    final Widget body = widget.expand
        ? content
        : ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus},
            ),
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.hardEdge,
              child: content,
            ),
          );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: t.pillTrack,
          borderRadius: BorderRadius.circular(NTokens.radiusPill),
          border: t.cardBorder == const Color(0x00000000) ? null : Border.all(color: t.cardBorder),
        ),
        child: body,
      ),
    );
  }

  Widget _buildItem(BuildContext context, NTokens t, NDurations d, int i, int n) {
    final item = widget.items[i];
    final selected = i == widget.selectedIndex;
    final showRing = _focusedIndex == i && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final labelColor = selected ? t.pillActiveText : t.ink;
    final iconOnly = !widget.showLabels && item.icon != null;

    return Semantics(
      container: true,
      selected: selected,
      button: true,
      inMutuallyExclusiveGroup: true,
      label: '${item.semanticLabel ?? item.label}, tab ${i + 1} of $n',
      onTap: () => _handleTap(i),
      excludeSemantics: true,
      child: Focus(
        focusNode: _focusNodes[i],
        skipTraversal: !selected, // roving tab stop: Tab lands on the selected item only
        onKeyEvent: (node, event) => _onKey(i, event),
        onFocusChange: (focused) => setState(() => _focusedIndex = focused ? i : (_focusedIndex == i ? null : _focusedIndex)),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _handleTap(i),
            child: CustomPaint(
              foregroundPainter: _FocusRingPainter(color: t.focusRing, visible: showRing),
              child: Container(
                key: _itemKeys[i],
                height: widget.size.height,
                padding: EdgeInsets.symmetric(horizontal: iconOnly ? widget.size.hPadding * 0.75 : t.space(widget.size.hPadding)),
                alignment: Alignment.center,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: labelColor),
                  duration: d.pillLabel,
                  curve: Curves.easeOut,
                  builder: (context, color, _) {
                    final c = color ?? labelColor;
                    final label = Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: widget.expand ? TextOverflow.ellipsis : TextOverflow.visible,
                      style: t.text.button(size: widget.size.fontSize, color: c).copyWith(
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                    );
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (item.icon != null) Icon(item.icon, size: widget.size.fontSize + 5, color: c),
                        if (item.icon != null && !iconOnly) SizedBox(width: t.space(7)),
                        // Flexible only when the segment width is bounded (expand mode); the
                        // scrolling track gives unbounded width, where Flexible would throw.
                        if (!iconOnly)
                          if (widget.expand) Flexible(child: label) else label,
                        if (item.badgeCount > 0) ...[
                          const SizedBox(width: 6),
                          NCountBadge(count: item.badgeCount),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter({required this.color, required this.visible});
  final Color color;
  final bool visible;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    // 2px ring, offset 2px outside the pill: inflate by offset + half the stroke.
    final rect = (Offset.zero & size).inflate(3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(NTokens.radiusPill)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) => old.color != color || old.visible != visible;
}

/// Small red count bubble used by pills, the bell and the dark action card. Hidden at zero.
class NCountBadge extends StatelessWidget {
  const NCountBadge({super.key, required this.count, this.max = 99});
  final int count;
  final int max;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final t = NTokens.of(context);
    final text = count > max ? '$max+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.red, borderRadius: BorderRadius.circular(NTokens.radiusPill)),
      child: Text(text, style: t.text.caption(size: 10.5, color: const Color(0xFFFFFFFF), weight: FontWeight.w600)),
    );
  }
}
