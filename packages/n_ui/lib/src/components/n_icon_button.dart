import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';
import 'n_sliding_pills.dart' show NCountBadge;

/// Round 44px glass icon button with a required label (tooltip + screen readers) and optional badge.
class NIconButton extends StatefulWidget {
  const NIconButton({super.key, required this.icon, required this.label, required this.onPressed, this.badgeCount = 0, this.filled = false});

  final IconData icon;

  /// Spoken and shown as tooltip. Icon-only controls always need one.
  final String label;
  final VoidCallback? onPressed;
  final int badgeCount;

  /// Ink-filled variant (used for the avatar / primary icon actions).
  final bool filled;

  @override
  State<NIconButton> createState() => _NIconButtonState();
}

class _NIconButtonState extends State<NIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final enabled = widget.onPressed != null;
    final showRing = _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Tooltip(
      message: widget.label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.badgeCount > 0 ? '${widget.label}, ${widget.badgeCount} new' : widget.label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            }),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: widget.filled ? t.pillActive : t.pillTrack,
                  shape: BoxShape.circle,
                  border: showRing
                      ? Border.all(color: t.focusRing, width: 2)
                      : (t.cardBorder.a == 0 ? null : Border.all(color: t.cardBorder)),
                ),
                alignment: Alignment.center,
                child: Icon(widget.icon, size: 20, color: widget.filled ? t.pillActiveText : t.ink),
              ),
              if (widget.badgeCount > 0)
                PositionedDirectional(top: -2, end: -2, child: NCountBadge(count: widget.badgeCount)),
            ]),
          ),
        ),
      ),
    );
  }
}
