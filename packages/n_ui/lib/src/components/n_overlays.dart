import 'package:flutter/material.dart';

import '../layout/n_breakpoint.dart';
import '../tokens/n_tokens.dart';
import 'n_button.dart';
import 'n_inputs.dart';

/// Opens a panel: a right-side drawer on tablet and wider, a bottom sheet on mobile.
/// [builder] receives the sheet's context so it can `Navigator.pop(context, result)`.
Future<T?> showNSheet<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  String? subtitle,
  double? width,
}) {
  final t = NTokens.of(context);
  final bp = NBreakpoint.of(context);
  final surface = t.isDark ? const Color(0xFF1E1E22) : const Color(0xFFFBFBFC);

  Widget frame(BuildContext ctx, {required bool drawer}) {
    final tt = NTokens.of(ctx);
    return Material(
      color: surface,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, drawer ? 18 : 4, 8, 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(title, style: tt.text.title(size: 19))),
                  if (subtitle != null) Text(subtitle, style: tt.text.caption()),
                ]),
              ),
              IconButton(tooltip: 'Close', icon: Icon(Icons.close_rounded, color: tt.muted), onPressed: () => Navigator.of(ctx).pop()),
            ]),
          ),
          Divider(height: 1, color: tt.divider),
          Expanded(child: builder(ctx)),
        ]),
      ),
    );
  }

  if (bp.isMobile) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      showDragHandle: true,
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusPanel))),
      builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.9, child: frame(ctx, drawer: false)),
    );
  }
  final w = width ?? (bp == NBreakpoint.tablet ? 480.0 : 560.0);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: t.durations.viewEnter,
    pageBuilder: (ctx, _, __) => Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radiusPanel),
          child: SizedBox(width: w, height: double.infinity, child: frame(ctx, drawer: true)),
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: NCurves.emphasized);
      final dir = Directionality.of(ctx) == TextDirection.rtl ? -1.0 : 1.0;
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: Tween(begin: Offset(0.08 * dir, 0), end: Offset.zero).animate(curved), child: child),
      );
    },
  );
}

/// Standard scrollable sheet body with a sticky action row.
class NSheetBody extends StatelessWidget {
  const NSheetBody({super.key, required this.children, this.actions = const []});
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              children[i],
            ],
          ],
        ),
      ),
      if (actions.isNotEmpty)
        Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: t.divider))),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
        ),
    ]);
  }
}

class NConfirmResult {
  const NConfirmResult(this.confirmed, [this.reason]);
  final bool confirmed;
  final String? reason;
}

/// Confirmation dialog. With [reasonLabel], a reason is required before confirming
/// (rejections, destructive or sensitive actions).
Future<NConfirmResult> showNConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
  String? reasonLabel,
  bool reasonRequired = true,
  String? typeToConfirm,
}) async {
  final reason = TextEditingController();
  final typed = TextEditingController();
  final r = await showDialog<NConfirmResult>(
    context: context,
    builder: (ctx) {
      final t = NTokens.of(ctx);
      return StatefulBuilder(builder: (ctx, setState) {
        final reasonOk = reasonLabel == null || !reasonRequired || reason.text.trim().length >= 3;
        final typedOk = typeToConfirm == null || typed.text.trim() == typeToConfirm;
        return AlertDialog(
          backgroundColor: t.isDark ? const Color(0xFF1E1E22) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusCard)),
          title: Text(title, style: t.text.title(size: 18)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(message, style: t.text.body()),
              if (reasonLabel != null) ...[
                const SizedBox(height: 14),
                NTextField(label: reasonLabel, controller: reason, maxLines: 3, required: reasonRequired, onChanged: (_) => setState(() {}), autofocus: true),
              ],
              if (typeToConfirm != null) ...[
                const SizedBox(height: 14),
                NTextField(label: 'Type "$typeToConfirm" to confirm', controller: typed, onChanged: (_) => setState(() {})),
              ],
            ]),
          ),
          actions: [
            NButton(label: cancelLabel, variant: NButtonVariant.secondary, compact: true, onPressed: () => Navigator.of(ctx).pop(const NConfirmResult(false))),
            NButton(
              label: confirmLabel,
              compact: true,
              variant: destructive ? NButtonVariant.primary : NButtonVariant.accent,
              icon: destructive ? Icons.warning_amber_rounded : null,
              onPressed: reasonOk && typedOk ? () => Navigator.of(ctx).pop(NConfirmResult(true, reason.text.trim().isEmpty ? null : reason.text.trim())) : null,
            ),
          ],
        );
      });
    },
  );
  // Controllers are left to GC: the dialog's exit animation may still read them.
  return r ?? const NConfirmResult(false);
}
