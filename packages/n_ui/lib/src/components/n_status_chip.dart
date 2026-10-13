import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';

/// System health vocabulary. Exactly four states; "healthy" only from a real check.
enum NHealth { healthy, degraded, unavailable, unknown }

/// Tone for business statuses (Approved, Pending, Rejected...). Labels come from backend enums.
enum NTone { positive, warning, negative, neutral, info }

/// Pill-shaped status chip. Meaning never relies on color alone: every chip pairs color, icon and text.
class NStatusChip extends StatelessWidget {
  /// Health chip for system components.
  const NStatusChip.health(NHealth this.health, {super.key, this.labelOverride})
      : label = null,
        tone = null,
        icon = null;

  /// Business status chip. [label] should be the localized backend status.
  const NStatusChip.status({super.key, required String this.label, required NTone this.tone, this.icon})
      : health = null,
        labelOverride = null;

  final NHealth? health;
  final String? labelOverride;
  final String? label;
  final NTone? tone;
  final IconData? icon;

  static const _healthLabels = {
    NHealth.healthy: 'Healthy',
    NHealth.degraded: 'Degraded',
    NHealth.unavailable: 'Unavailable',
    NHealth.unknown: 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final (Color color, IconData glyph, String text) = switch (health) {
      NHealth.healthy => (t.green, Icons.check_circle_rounded, labelOverride ?? _healthLabels[NHealth.healthy]!),
      NHealth.degraded => (t.amber, Icons.warning_amber_rounded, labelOverride ?? _healthLabels[NHealth.degraded]!),
      NHealth.unavailable => (t.red, Icons.error_rounded, labelOverride ?? _healthLabels[NHealth.unavailable]!),
      NHealth.unknown => (t.muted, Icons.help_outline_rounded, labelOverride ?? _healthLabels[NHealth.unknown]!),
      null => switch (tone!) {
          NTone.positive => (t.green, icon ?? Icons.check_circle_rounded, label!),
          NTone.warning => (t.amber, icon ?? Icons.schedule_rounded, label!),
          NTone.negative => (t.red, icon ?? Icons.cancel_rounded, label!),
          NTone.info => (t.accent, icon ?? Icons.info_rounded, label!),
          NTone.neutral => (t.muted, icon ?? Icons.circle_outlined, label!),
        },
    };
    // Text uses ink for contrast; color carries through the tint and icon.
    return Semantics(
      label: health != null ? 'Status: $text' : text,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: t.isDark ? 0.22 : 0.16),
          borderRadius: BorderRadius.circular(NTokens.radiusPill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(glyph, size: 14, color: t.isDark ? color : Color.lerp(color, t.ink, 0.35)),
          const SizedBox(width: 5),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.text.caption(color: t.ink, weight: FontWeight.w500))),
        ]),
      ),
    );
  }
}
