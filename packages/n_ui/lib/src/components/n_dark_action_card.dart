import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../logic/n_held_commit.dart';
import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';
import 'n_button.dart';
import 'n_sliding_pills.dart' show NCountBadge;
import 'n_toast.dart';

/// A row in the dark action card.
@immutable
class NActionItem {
  const NActionItem({required this.id, required this.title, this.subtitle, this.done = false, this.meta});

  final String id;
  final String title;
  final String? subtitle;

  /// Check mode only.
  final bool done;

  /// Small trailing text such as "2d" or "Due 5 pm".
  final String? meta;
}

enum NDecision { approve, decline }

/// Copy used by the approve flow. Pass localized strings.
@immutable
class NActionCardCopy {
  const NActionCardCopy({
    this.approve = 'Approve',
    this.decline = 'Decline',
    this.approved = 'Approved',
    this.declined = 'Declined',
    this.undo = 'Undo',
    this.doneOf = '{done}/{total} done',
  });

  final String approve;
  final String decline;
  final String approved;
  final String declined;
  final String undo;

  /// Footer template for check mode, `{done}` and `{total}` are replaced.
  final String doneOf;
}

enum _Mode { check, approve }

/// The one dark action card per screen. It holds that screen's most actionable list.
///
/// * [NDarkActionCard.check]: dots toggle (scale 1.15, lime fill), strike-through, footer
///   "3/5 done · 60%". Toggling is optimistic (reversible, low risk).
/// * [NDarkActionCard.approve]: Approve / Decline per row with a **held commit**: the row slides
///   right and collapses, the badge updates, a toast offers Undo for 5s, then the decision is sent
///   with an idempotency key (or sooner, when the user leaves the screen). Rejected requests bring
///   the row back with the error. Decisions that need a comment or are irreversible are routed to
///   [onConfirmRequired] instead (dialog, reauth, visible pending state).
///
/// Never place two on one screen.
class NDarkActionCard extends StatefulWidget {
  const NDarkActionCard.check({
    super.key,
    required this.title,
    required this.items,
    /// Null makes the list read-only (items that complete from a real check, not a tap).
    this.onToggle,
    this.emptyText = 'Nothing left here. New items appear as they are assigned to you.',
    this.copy = const NActionCardCopy(),
    this.maxVisible,
  })  : _mode = _Mode.check,
        commit = null,
        needsConfirmation = null,
        onConfirmRequired = null,
        describeError = null;

  const NDarkActionCard.approve({
    super.key,
    required this.title,
    required this.items,
    required Future<void> Function(NActionItem item, NDecision decision, String idempotencyKey) this.commit,
    this.needsConfirmation,
    this.onConfirmRequired,
    this.describeError,
    this.emptyText = 'No approvals waiting. New requests appear here as they arrive.',
    this.copy = const NActionCardCopy(),
    this.maxVisible,
  })  : _mode = _Mode.approve,
        onToggle = null;

  final _Mode _mode;
  final String title;
  final List<NActionItem> items;
  final String emptyText;
  final NActionCardCopy copy;
  final int? maxVisible;

  final void Function(NActionItem item, bool done)? onToggle;
  final Future<void> Function(NActionItem item, NDecision decision, String idempotencyKey)? commit;

  /// Return true when this decision must not use held commit (needs a comment, 2FA, irreversible).
  final bool Function(NActionItem item, NDecision decision)? needsConfirmation;
  final void Function(NActionItem item, NDecision decision)? onConfirmRequired;

  /// Turns a commit error into a sentence: what went wrong and how to fix it.
  final String Function(Object error)? describeError;

  @override
  State<NDarkActionCard> createState() => _NDarkActionCardState();
}

class _NDarkActionCardState extends State<NDarkActionCard> with WidgetsBindingObserver {
  late final NHeldCommitQueue _queue;
  final Map<String, NDecision> _hidden = {};
  final Set<String> _exiting = {};
  final Map<String, String> _errors = {};
  final Map<String, bool> _optimisticDone = {};

  @override
  void initState() {
    super.initState();
    _queue = NHeldCommitQueue(
      onFailed: (id, error) {
        if (!mounted) return;
        setState(() {
          _hidden.remove(id);
          _errors[id] = widget.describeError?.call(error) ??
              'This decision was not saved. Check your connection and try again.';
        });
      },
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(NDarkActionCard old) {
    super.didUpdateWidget(old);
    final ids = widget.items.map((e) => e.id).toSet();
    _hidden.removeWhere((id, _) => !ids.contains(id) && !_queue.isPending(id));
    _errors.removeWhere((id, _) => !ids.contains(id));
    // Server state caught up with optimistic toggles.
    for (final item in widget.items) {
      if (_optimisticDone[item.id] == item.done) _optimisticDone.remove(item.id);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app counts as leaving the screen: send held decisions now.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _queue.flushAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _queue.dispose(); // flushes pending decisions
    super.dispose();
  }

  bool _isDone(NActionItem i) => _optimisticDone[i.id] ?? i.done;

  void _toggle(NActionItem item) {
    final next = !_isDone(item);
    setState(() => _optimisticDone[item.id] = next);
    widget.onToggle?.call(item, next);
  }

  Future<void> _decide(NActionItem item, NDecision decision) async {
    if (widget.needsConfirmation?.call(item, decision) ?? false) {
      widget.onConfirmRequired?.call(item, decision);
      return;
    }
    final toast = NToast.of(context);
    final d = NMotion.durations(context);
    setState(() {
      _errors.remove(item.id);
      _exiting.add(item.id);
    });
    _queue.hold(item.id, (key) => widget.commit!(item, decision, key));
    final verb = decision == NDecision.approve ? widget.copy.approved : widget.copy.declined;
    toast.show(
      '$verb · ${item.title}',
      duration: _queue.window,
      action: NToastAction(
        label: widget.copy.undo,
        onPressed: () {
          if (_queue.undo(item.id) && mounted) {
            setState(() {
              _exiting.remove(item.id);
              _hidden.remove(item.id);
            });
          }
        },
      ),
    );
    await Future<void>.delayed(d.rowExit);
    if (!mounted || !_exiting.contains(item.id)) return;
    setState(() {
      _exiting.remove(item.id);
      if (_queue.isPending(item.id)) _hidden[item.id] = decision;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final visible = widget.items.where((i) => !_hidden.containsKey(i.id)).toList();
    final shown = widget.maxVisible == null ? visible : visible.take(widget.maxVisible!).toList();
    final isCheck = widget._mode == _Mode.check;
    final total = widget.items.length;
    final doneCount = isCheck ? widget.items.where(_isDone).length : 0;
    final badge = isCheck ? total - doneCount : visible.where((i) => !_exiting.contains(i.id)).length;

    return Semantics(
      container: true,
      label: widget.title,
      child: Stack(clipBehavior: Clip.none, children: [
        // Grey sheet peeking about 9px above the card's top edge.
        Positioned(
          top: 0,
          left: 18,
          right: 18,
          height: 24,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.actionCardSheet,
              borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusSheet)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Container(
            padding: EdgeInsets.all(t.space(18)),
            decoration: BoxDecoration(
              color: t.actionCard,
              borderRadius: BorderRadius.circular(t.radiusCard),
              boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 30, spreadRadius: -12, offset: Offset(0, 16))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(widget.title, style: t.text.title(color: t.actionCardText)),
                  ),
                ),
                Semantics(
                  label: '$badge waiting',
                  excludeSemantics: true,
                  child: NCountBadge(count: badge),
                ),
              ]),
              SizedBox(height: t.space(12)),
              if (shown.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: t.space(14)),
                  child: Text(widget.emptyText, style: t.text.body(color: t.actionCardMuted)),
                )
              else
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) Container(height: 1, color: const Color(0x14FFFFFF)),
                  _RowExit(
                    key: ValueKey(shown[i].id),
                    exiting: _exiting.contains(shown[i].id),
                    child: isCheck
                        ? _CheckRow(
                            item: shown[i],
                            done: _isDone(shown[i]),
                            onToggle: widget.onToggle == null ? null : () => _toggle(shown[i]),
                          )
                        : _ApproveRow(
                            item: shown[i],
                            copy: widget.copy,
                            error: _errors[shown[i].id],
                            onDecide: (d) => _decide(shown[i], d),
                          ),
                  ),
                ],
              if (isCheck && total > 0) ...[
                SizedBox(height: t.space(12)),
                Text(
                  '${widget.copy.doneOf.replaceAll('{done}', '$doneCount').replaceAll('{total}', '$total')}'
                  ' · ${(doneCount * 100 / total).round()}%',
                  style: t.text.caption(color: t.actionCardMuted),
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Slide right and collapse. Constant wrapper structure so the row's state is never reset.
class _RowExit extends StatelessWidget {
  const _RowExit({super.key, required this.exiting, required this.child});
  final bool exiting;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = NMotion.durations(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: exiting ? 1.0 : 0.0),
      duration: d.rowExit,
      curve: NCurves.emphasized,
      child: child,
      builder: (context, v, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: (1 - v).clamp(0.0, 1.0),
          child: Opacity(
            opacity: (1 - v * 1.3).clamp(0.0, 1.0),
            child: Transform.translate(offset: Offset(80 * v, 0), child: child),
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.item, required this.done, required this.onToggle});
  final NActionItem item;
  final bool done;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      checked: done,
      label: item.title,
      onTap: onToggle,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: MouseRegion(
          cursor: onToggle == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                _CheckDot(done: done),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    AnimatedDefaultTextStyle(
                      duration: NMotion.durations(context).pillLabel,
                      style: t.text.body(color: done ? t.actionCardMuted : t.actionCardText).copyWith(
                            decoration: done ? TextDecoration.lineThrough : TextDecoration.none,
                            decorationColor: t.actionCardMuted,
                          ),
                      child: Text(item.title),
                    ),
                    if (item.subtitle != null) Text(item.subtitle!, style: t.text.caption(color: t.actionCardMuted)),
                  ]),
                ),
                if (item.meta != null) Text(item.meta!, style: t.text.caption(color: t.actionCardMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckDot extends StatefulWidget {
  const _CheckDot({required this.done});
  final bool done;

  @override
  State<_CheckDot> createState() => _CheckDotState();
}

class _CheckDotState extends State<_CheckDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  @override
  void didUpdateWidget(_CheckDot old) {
    super.didUpdateWidget(old);
    if (old.done != widget.done && !NMotion.reduced(context)) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final scale = 1 + 0.15 * math.sin(math.pi * _pulse.value);
        return Transform.scale(
          scale: scale,
          child: AnimatedContainer(
            duration: NMotion.durations(context).pillLabel,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.done ? t.lime : const Color(0x00000000),
              border: Border.all(color: widget.done ? t.lime : t.actionCardMuted, width: 1.6),
            ),
            child: widget.done
                ? const Icon(Icons.check_rounded, size: 14, color: Color(0xFF1F1F21))
                : null,
          ),
        );
      },
    );
  }
}

class _ApproveRow extends StatelessWidget {
  const _ApproveRow({required this.item, required this.copy, required this.onDecide, this.error});
  final NActionItem item;
  final NActionCardCopy copy;
  final String? error;
  final ValueChanged<NDecision> onDecide;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, style: t.text.body(color: t.actionCardText, weight: FontWeight.w500)),
              if (item.subtitle != null) ...[
                const SizedBox(height: 2),
                Text(item.subtitle!, style: t.text.caption(color: t.actionCardMuted)),
              ],
            ]),
          ),
          if (item.meta != null) Text(item.meta!, style: t.text.caption(color: t.actionCardMuted)),
        ]),
        if (error != null) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(error!, style: t.text.caption(color: const Color(0xFFFF9EA1))),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          NButton(
            label: copy.approve,
            variant: NButtonVariant.onDark,
            compact: true,
            semanticLabel: '${copy.approve} ${item.title}',
            onPressed: () => onDecide(NDecision.approve),
          ),
          NButton(
            label: copy.decline,
            variant: NButtonVariant.ghostOnDark,
            compact: true,
            semanticLabel: '${copy.decline} ${item.title}',
            onPressed: () => onDecide(NDecision.decline),
          ),
        ]),
      ]),
    );
  }
}
