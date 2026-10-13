import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/n_tokens.dart';

InputDecoration _decoration(NTokens t, {String? hint, String? error, IconData? prefixIcon, Widget? suffix, String? helper}) {
  final radius = BorderRadius.circular(t.radiusTile);
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    hintStyle: t.text.body(color: t.muted),
    errorText: error,
    errorMaxLines: 3,
    helperText: helper,
    helperMaxLines: 3,
    helperStyle: t.text.caption(),
    errorStyle: t.text.caption(color: t.dangerText),
    isDense: true,
    filled: true,
    fillColor: t.card,
    prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 18, color: t.muted),
    suffixIcon: suffix,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: border(t.divider),
    enabledBorder: border(t.divider),
    focusedBorder: border(t.focusRing, 2),
    errorBorder: border(t.dangerText),
    focusedErrorBorder: border(t.dangerText, 2),
    disabledBorder: border(t.divider.withValues(alpha: t.divider.a * 0.5)),
  );
}

/// Visible label above every field (never placeholder-only labels).
class NFieldLabel extends StatelessWidget {
  const NFieldLabel(this.text, {super.key, this.required = false});
  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: text),
          if (required) TextSpan(text: ' *', style: TextStyle(color: t.dangerText)),
        ]),
        style: t.text.caption(color: t.ink, weight: FontWeight.w500),
      ),
    );
  }
}

class NTextField extends StatelessWidget {
  const NTextField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.hint,
    this.helper,
    this.error,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.inputFormatters,
    this.obscure = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.enabled = true,
    this.autofocus = false,
    this.required = false,
    this.prefixIcon,
    this.suffix,
    this.autofillHints,
    this.textInputAction,
    this.focusNode,
  });

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? hint;
  final String? helper;
  final String? error;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool obscure;
  final int maxLines;
  final int? minLines;
  final int? maxLength;
  final bool enabled;
  final bool autofocus;
  final bool required;
  final IconData? prefixIcon;
  final Widget? suffix;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      NFieldLabel(label, required: required),
      TextFormField(
        controller: controller,
        initialValue: controller == null ? initialValue : null,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        keyboardType: keyboardType ?? (maxLines > 1 ? TextInputType.multiline : null),
        inputFormatters: inputFormatters,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        minLines: minLines,
        maxLength: maxLength,
        enabled: enabled,
        autofocus: autofocus,
        autofillHints: autofillHints,
        textInputAction: textInputAction,
        focusNode: focusNode,
        style: t.text.body(),
        cursorColor: t.ink,
        decoration: _decoration(t, hint: hint, error: error, prefixIcon: prefixIcon, suffix: suffix, helper: helper),
      ),
    ]);
  }
}

class NOption<T> {
  const NOption(this.value, this.label, {this.subtitle});
  final T value;
  final String label;
  final String? subtitle;
}

class NSelect<T> extends StatelessWidget {
  const NSelect({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.hint,
    this.error,
    this.helper,
    this.required = false,
    this.enabled = true,
  });

  final String label;
  final List<NOption<T>> options;
  final T? value;
  final ValueChanged<T?>? onChanged;
  final String? hint;
  final String? error;
  final String? helper;
  final bool required;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final valid = options.any((o) => o.value == value) ? value : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      NFieldLabel(label, required: required),
      DropdownButtonFormField<T>(
        initialValue: valid,
        isExpanded: true,
        items: [
          for (final o in options)
            DropdownMenuItem<T>(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis, style: t.text.body())),
        ],
        onChanged: enabled ? onChanged : null,
        dropdownColor: t.isDark ? const Color(0xFF26262B) : Colors.white,
        borderRadius: BorderRadius.circular(t.radiusTile),
        icon: Icon(Icons.expand_more_rounded, color: t.muted),
        decoration: _decoration(t, hint: hint, error: error, helper: helper),
      ),
    ]);
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

/// ISO day string (YYYY-MM-DD) for a local date.
String nDay(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// Date field backed by the platform date picker. Shows the date in a readable form.
class NDateField extends StatelessWidget {
  const NDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
    this.error,
    this.helper,
    this.required = false,
    this.enabled = true,
    this.format,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final String? error;
  final String? helper;
  final bool required;
  final bool enabled;
  final String Function(DateTime)? format;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final text = value == null ? '' : (format?.call(value!) ?? '${_two(value!.day)} ${_months[value!.month - 1]} ${value!.year}');
    Future<void> pick() async {
      final now = DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: firstDate ?? DateTime(now.year - 80),
        lastDate: lastDate ?? DateTime(now.year + 5),
      );
      if (picked != null) onChanged(picked);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      NFieldLabel(label, required: required),
      Semantics(
        button: true,
        label: '$label${text.isEmpty ? '' : ', $text'}',
        child: InkWell(
          borderRadius: BorderRadius.circular(t.radiusTile),
          onTap: enabled ? pick : null,
          child: InputDecorator(
            isEmpty: text.isEmpty,
            decoration: _decoration(
              t,
              hint: 'Select a date',
              error: error,
              helper: helper,
              suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                if (value != null && !required && enabled)
                  IconButton(tooltip: 'Clear', icon: Icon(Icons.close_rounded, size: 16, color: t.muted), onPressed: () => onChanged(null)),
                Padding(padding: const EdgeInsets.only(right: 10), child: Icon(Icons.calendar_today_rounded, size: 16, color: t.muted)),
              ]),
            ),
            child: Text(text, style: t.text.body()),
          ),
        ),
      ),
    ]);
  }
}

/// Search box with a clear button. Debouncing is the caller's job.
class NSearchField extends StatefulWidget {
  const NSearchField({super.key, required this.hint, required this.onChanged, this.initial = '', this.autofocus = false, this.onSubmitted});
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final String initial;
  final bool autofocus;

  @override
  State<NSearchField> createState() => _NSearchFieldState();
}

class _NSearchFieldState extends State<NSearchField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      textField: true,
      label: widget.hint,
      child: TextField(
        controller: _c,
        autofocus: widget.autofocus,
        onChanged: (v) {
          setState(() {});
          widget.onChanged(v);
        },
        onSubmitted: widget.onSubmitted,
        style: t.text.body(),
        cursorColor: t.ink,
        textInputAction: TextInputAction.search,
        decoration: _decoration(
          t,
          hint: widget.hint,
          prefixIcon: Icons.search_rounded,
          suffix: _c.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: Icon(Icons.close_rounded, size: 16, color: t.muted),
                  onPressed: () {
                    _c.clear();
                    setState(() {});
                    widget.onChanged('');
                  },
                ),
        ).copyWith(border: OutlineInputBorder(borderRadius: BorderRadius.circular(NTokens.radiusPill), borderSide: BorderSide(color: t.divider))),
      ),
    );
  }
}

/// Single-select filter chips (horizontal scroll on narrow screens).
class NFilterChips<T> extends StatelessWidget {
  const NFilterChips({super.key, required this.options, required this.value, required this.onChanged, this.semanticLabel});
  final List<NOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      label: semanticLabel,
      container: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(o.label, style: t.text.caption(color: o.value == value ? t.pillActiveText : t.ink, weight: FontWeight.w500)),
                selected: o.value == value,
                onSelected: (_) => onChanged(o.value),
                showCheckmark: false,
                selectedColor: t.pillActive,
                backgroundColor: t.pillTrack,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Segmented yes/no style checkbox row with label and description.
class NCheckRow extends StatelessWidget {
  const NCheckRow({super.key, required this.label, required this.value, required this.onChanged, this.description});
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radiusTile),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false), activeColor: t.primaryButton, checkColor: t.onPrimaryButton),
            const SizedBox(width: 6),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: t.text.body(weight: FontWeight.w500)),
                  if (description != null) Text(description!, style: t.text.caption()),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
