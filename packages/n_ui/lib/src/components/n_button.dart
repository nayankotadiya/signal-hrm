import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';

enum NButtonVariant {
  /// Ink pill (inverts in dark theme).
  primary,

  /// Accent pill for the one main call to action in a form.
  accent,

  /// Translucent pill on light surfaces.
  secondary,

  /// Light pill on the dark action card (Approve).
  onDark,

  /// Outlined pill on the dark action card (Decline).
  ghostOnDark,
}

/// Pill button. Labels are verbs ("Approve", "Check in"). Min 44px hit target on touch layouts.
class NButton extends StatefulWidget {
  const NButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = NButtonVariant.primary,
    this.icon,
    this.compact = false,
    this.busy = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final NButtonVariant variant;
  final IconData? icon;

  /// 36px visual height (the hit area still grows to 44 via padding on touch).
  final bool compact;

  /// Shows a pending state and blocks taps (server-confirmed actions).
  final bool busy;
  final String? semanticLabel;

  @override
  State<NButton> createState() => _NButtonState();
}

class _NButtonState extends State<NButton> {
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final enabled = widget.onPressed != null && !widget.busy;
    final (Color bg, Color fg, Color? border) = switch (widget.variant) {
      NButtonVariant.primary => (t.primaryButton, t.onPrimaryButton, null),
      NButtonVariant.accent => (t.accent, t.onAccent, null),
      NButtonVariant.secondary => (t.pillTrack, t.ink, t.cardBorder.a == 0 ? null : t.cardBorder),
      NButtonVariant.onDark => (t.actionCardText, t.actionCard, null),
      NButtonVariant.ghostOnDark => (const Color(0x00000000), t.actionCardText, t.actionCardMuted.withValues(alpha: 0.6)),
    };
    final height = widget.compact ? 34.0 : 44.0;
    final showRing = _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      excludeSemantics: true,
      onTap: enabled ? widget.onPressed : null,
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
          onTap: enabled ? widget.onPressed : null,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: widget.compact ? 5 : 0),
            child: AnimatedScale(
              scale: _pressed ? 0.97 : 1,
              duration: t.durations.hover,
              child: AnimatedOpacity(
                opacity: enabled ? 1 : 0.45,
                duration: t.durations.hover,
                child: Container(
                  height: height,
                  padding: EdgeInsets.symmetric(horizontal: widget.compact ? 14 : 20),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    border: showRing
                        ? Border.all(color: t.focusRing, width: 2)
                        : (border == null ? null : Border.all(color: border)),
                  ),
                  alignment: Alignment.center,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (widget.busy)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: _BusyDot(color: fg),
                        ),
                      )
                    else if (widget.icon != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 7),
                        child: Icon(widget.icon, size: 17, color: fg),
                      ),
                    Flexible(child: Text(widget.label, style: t.text.button(color: fg, size: widget.compact ? 12.5 : 13.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal pending indicator inside buttons (not a page spinner: lists use skeletons).
class _BusyDot extends StatefulWidget {
  const _BusyDot({required this.color});
  final Color color;

  @override
  State<_BusyDot> createState() => _BusyDotState();
}

class _BusyDotState extends State<_BusyDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_c),
      child: DecoratedBox(decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
    );
  }
}
