import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../layout/n_breakpoint.dart';
import '../tokens/n_tokens.dart';
import 'n_button.dart';
import 'n_toast.dart';

/// Empty state: says what is empty and offers the next step. Never filled with fake rows.
class NEmptyState extends StatelessWidget {
  const NEmptyState({super.key, required this.title, this.message, this.icon = Icons.inbox_rounded, this.actionLabel, this.onAction, this.compact = false});
  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      container: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 16 : 40, horizontal: 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: compact ? 40 : 56,
            height: compact ? 40 : 56,
            decoration: BoxDecoration(color: t.pillTrack, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(icon, color: t.muted, size: compact ? 20 : 26),
          ),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: t.text.title(size: compact ? 14 : 16)),
          if (message != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(message!, textAlign: TextAlign.center, style: t.text.body(color: t.muted)),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            NButton(label: actionLabel!, onPressed: onAction, compact: true, icon: Icons.add_rounded),
          ],
        ]),
      ),
    );
  }
}

/// Error state: plain message, retry, and the correlation id for support (copyable).
class NErrorState extends StatelessWidget {
  const NErrorState({super.key, required this.message, this.title = "Couldn't load this", this.correlationId, this.onRetry, this.compact = false});
  final String title;
  final String message;
  final String? correlationId;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 14 : 36, horizontal: 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_rounded, color: t.dangerText, size: compact ? 22 : 30),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: t.text.title(size: compact ? 14 : 16)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(message, textAlign: TextAlign.center, style: t.text.body(color: t.muted)),
          ),
          if (correlationId != null) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Clipboard.setData(ClipboardData(text: correlationId!));
                NToast.of(context).show('Reference copied');
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text('Reference: $correlationId', style: t.text.caption()),
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            NButton(label: 'Try again', icon: Icons.refresh_rounded, variant: NButtonVariant.secondary, compact: true, onPressed: onRetry),
          ],
        ]),
      ),
    );
  }
}

/// Section header: title, optional subtitle and trailing actions. Wraps on narrow screens.
class NSectionHeader extends StatelessWidget {
  const NSectionHeader({super.key, required this.title, this.subtitle, this.trailing = const [], this.boldWord});
  final String title;
  final String? boldWord;
  final String? subtitle;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final heading = Semantics(
      header: true,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: title, style: t.text.heading(size: 26)),
          if (boldWord != null) TextSpan(text: ' $boldWord', style: t.text.headingBold(size: 26)),
        ]),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            heading,
            if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: t.text.body(color: t.muted))),
          ]),
          if (trailing.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: trailing),
        ],
      ),
    );
  }
}

/// Card heading used inside cards.
class NCardTitle extends StatelessWidget {
  const NCardTitle(this.title, {super.key, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final isMobile = NBreakpoint.of(context).isMobile;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(header: true, child: Text(title, style: t.text.title(size: 15))),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: t.text.caption()),
                ],
              ]),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: box.maxWidth.isFinite ? box.maxWidth * (isMobile ? 0.55 : 0.45) : double.infinity,
                ),
                child: trailing!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Label / value pair for detail views.
class NInfoRow extends StatelessWidget {
  const NInfoRow({super.key, required this.label, required this.value, this.valueWidget});
  final String label;
  final String value;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 360;
          final l = Text(label, style: t.text.caption());
          final v = valueWidget ?? SelectableText(value.isEmpty ? '—' : value, style: t.text.body());
          if (narrow) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [l, const SizedBox(height: 2), v]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 160, child: l),
            Expanded(child: v),
          ]);
        }),
      ),
    );
  }
}

/// Inline banner for warnings / info inside a page or form.
class NBanner extends StatelessWidget {
  const NBanner({super.key, required this.message, this.tone = NBannerTone.info, this.title, this.action});
  final String message;
  final String? title;
  final NBannerTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final (Color c, IconData icon) = switch (tone) {
      NBannerTone.info => (t.accent, Icons.info_outline_rounded),
      NBannerTone.warning => (t.amber, Icons.warning_amber_rounded),
      NBannerTone.danger => (t.red, Icons.error_outline_rounded),
      NBannerTone.success => (t.green, Icons.check_circle_outline_rounded),
    };
    return Semantics(
      container: true,
      liveRegion: tone == NBannerTone.danger,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(t.radiusTile),
          border: Border.all(color: c.withValues(alpha: 0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: c, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) Text(title!, style: t.text.body(weight: FontWeight.w600)),
              Text(message, style: t.text.body()),
            ]),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ]),
      ),
    );
  }
}

enum NBannerTone { info, warning, danger, success }
