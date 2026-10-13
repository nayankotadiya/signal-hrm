import 'package:flutter/widgets.dart';

import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

/// Pill toggle with its label. The whole row is the hit target (min 44px tall).
class NSwitch extends StatelessWidget {
  const NSwitch({super.key, required this.label, required this.value, required this.onChanged, this.description});

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final d = NMotion.durations(context);
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      label: label,
      hint: description,
      enabled: enabled,
      onTap: enabled ? () => onChanged!(!value) : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            onChanged?.call(!value);
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged!(!value) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label, style: t.text.body(weight: FontWeight.w500)),
                  if (description != null) Text(description!, style: t.text.caption()),
                ]),
              ),
              const SizedBox(width: 12),
              AnimatedContainer(
                duration: d.pillLabel,
                curve: NCurves.emphasized,
                width: 46,
                height: 28,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: value ? t.pillActive : t.ink.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                ),
                child: AnimatedAlign(
                  duration: d.pillPosition,
                  curve: NCurves.spring,
                  alignment: value ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: value ? t.lime : const Color(0xFFFFFFFF),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
