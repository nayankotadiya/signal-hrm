import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:n_ui/n_ui.dart';

import '../data/api.dart';
import '../platform/bridge.dart';
import 'async_view.dart';
import 'format.dart';

enum FieldKind { text, multiline, email, phone, number, money, date, time, select, asyncSelect, toggle, file, password }

typedef OptionLoader = Future<List<NOption<String>>> Function(ApiClient api);

/// One field of a generated form. [key] may be a dot path ("checkIn.requireSelfie").
class FieldSpec {
  const FieldSpec(
    this.key,
    this.label, {
    this.kind = FieldKind.text,
    this.required = false,
    this.options = const [],
    this.loadOptions,
    this.helper,
    this.hint,
    this.visibleWhen,
    this.filePurpose = 'attachment',
    this.fileAccept = '*/*',
    this.fileCapture,
    this.maxLength,
    this.min,
    this.max,
    this.description,
  });

  final String key;
  final String label;
  final FieldKind kind;
  final bool required;
  final List<NOption<String>> options;
  final OptionLoader? loadOptions;
  final String? helper;
  final String? hint;
  final String? description; // for toggles
  final bool Function(Json values)? visibleWhen;
  final String filePurpose;
  final String fileAccept;
  final String? fileCapture;
  final int? maxLength;
  final num? min;
  final num? max;
}

Object? readPath(Json j, String path) {
  Object? cur = j;
  for (final p in path.split('.')) {
    if (cur is Map) {
      cur = cur[p];
    } else {
      return null;
    }
  }
  return cur;
}

void writePath(Json j, String path, Object? value) {
  final parts = path.split('.');
  var cur = j;
  for (var i = 0; i < parts.length - 1; i++) {
    cur = (cur[parts[i]] ??= <String, dynamic>{}) as Json;
  }
  cur[parts.last] = value;
}

/// Opens a form in a sheet and submits it. Server field errors map onto the matching fields;
/// the idempotency key is fixed for the life of the sheet so a double tap or retry never duplicates.
Future<T?> showFormSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<FieldSpec> fields,
  Json initial = const {},
  required Future<T> Function(Json values, String idempotencyKey) submit,
  String submitLabel = 'Save',
  String? successMessage,
  Widget? header,
  bool omitEmpty = true,
}) {
  final api = ApiScope.of(context);
  final toast = NToast.of(context);
  return showNSheet<T>(
    context,
    title: title,
    subtitle: subtitle,
    builder: (ctx) => ApiScope(
      api: api,
      child: _FormSheet<T>(fields: fields, initial: initial, submit: submit, submitLabel: submitLabel, header: header, omitEmpty: omitEmpty, onDone: (r) {
        if (successMessage != null) toast.show(successMessage);
        Navigator.of(ctx).pop(r);
      }),
    ),
  );
}

class _FormSheet<T> extends StatefulWidget {
  const _FormSheet({required this.fields, required this.initial, required this.submit, required this.submitLabel, required this.onDone, required this.omitEmpty, this.header});
  final List<FieldSpec> fields;
  final Json initial;
  final Future<T> Function(Json values, String idempotencyKey) submit;
  final String submitLabel;
  final void Function(T result) onDone;
  final Widget? header;
  final bool omitEmpty;

  @override
  State<_FormSheet<T>> createState() => _FormSheetState<T>();
}

class _FormSheetState<T> extends State<_FormSheet<T>> {
  final Map<String, Object?> _values = {};
  final Map<String, TextEditingController> _text = {};
  final Map<String, String> _errors = {};
  final Map<String, String> _fileNames = {};
  final Map<String, bool> _uploading = {};
  String? _formError;
  bool _busy = false;
  final String _key = newIdempotencyKey();

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final v = readPath(widget.initial, f.key);
      _values[f.key] = v;
      if (_isText(f.kind)) _text[f.key] = TextEditingController(text: v == null ? '' : '$v');
    }
  }

  bool _isText(FieldKind k) => const {FieldKind.text, FieldKind.multiline, FieldKind.email, FieldKind.phone, FieldKind.number, FieldKind.money, FieldKind.password, FieldKind.time}.contains(k);

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json get _current {
    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      writePath(out, f.key, _value(f));
    }
    return out;
  }

  Object? _value(FieldSpec f) {
    if (_isText(f.kind)) {
      final s = _text[f.key]!.text.trim();
      if (s.isEmpty) return null;
      if (f.kind == FieldKind.number || f.kind == FieldKind.money) return num.tryParse(s.replaceAll(',', ''));
      return s;
    }
    final v = _values[f.key];
    if (f.kind == FieldKind.date && v is DateTime) return Fmt.day(v);
    return v;
  }

  bool _validate() {
    _errors.clear();
    final cur = _current;
    for (final f in widget.fields) {
      if (f.visibleWhen != null && !f.visibleWhen!(cur)) continue;
      final v = _value(f);
      if (f.required && (v == null || (v is String && v.isEmpty))) _errors[f.key] = 'Required';
      if ((f.kind == FieldKind.number || f.kind == FieldKind.money) && _text[f.key]!.text.trim().isNotEmpty && v == null) _errors[f.key] = 'Enter a number';
      if (v is num && f.min != null && v < f.min!) _errors[f.key] = 'Must be at least ${f.min}';
      if (v is num && f.max != null && v > f.max!) _errors[f.key] = 'Must be at most ${f.max}';
      if (f.kind == FieldKind.email && v is String && !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v)) _errors[f.key] = 'Enter a valid email address';
      if (f.kind == FieldKind.password && v is String && v.isNotEmpty && v.length < 6) _errors[f.key] = 'Must be at least 6 characters';
    }
    return _errors.isEmpty;
  }

  Future<void> _submit() async {
    setState(() => _formError = null);
    if (!_validate()) {
      setState(() {});
      return;
    }
    final cur = _current;
    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      if (f.visibleWhen != null && !f.visibleWhen!(cur)) continue;
      final v = _value(f);
      final hadInitial = readPath(widget.initial, f.key) != null;
      if (v == null && widget.omitEmpty && !hadInitial) continue;
      writePath(out, f.key, v);
    }
    setState(() => _busy = true);
    try {
      final r = await widget.submit(out, _key);
      if (!mounted) return;
      widget.onDone(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _formError = e.message;
        for (final d in e.details) {
          final match = widget.fields.where((f) => d.field == f.key || d.field.startsWith('${f.key}.') || f.key.endsWith('.${d.field}'));
          if (match.isNotEmpty) _errors[match.first.key] = d.message;
        }
        if (e.details.isNotEmpty && _errors.isNotEmpty) _formError = 'Check the highlighted fields.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _formError = describeError(e);
      });
    }
  }

  Future<void> _pickFile(FieldSpec f) async {
    final picked = await bridge.pickFile(accept: f.fileAccept, capture: f.fileCapture);
    if (picked == null || !mounted) return;
    setState(() {
      _uploading[f.key] = true;
      _errors.remove(f.key);
    });
    try {
      final rec = await ApiScope.of(context).upload(picked, purpose: f.filePurpose);
      if (!mounted) return;
      setState(() {
        _values[f.key] = rec['id'];
        _fileNames[f.key] = picked.name;
        _uploading[f.key] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading[f.key] = false;
        _errors[f.key] = describeError(e);
      });
    }
  }

  Widget _field(FieldSpec f) {
    final err = _errors[f.key];
    void changed(Object? v) => setState(() {
          _values[f.key] = v;
          _errors.remove(f.key);
        });
    switch (f.kind) {
      case FieldKind.text:
      case FieldKind.email:
      case FieldKind.phone:
      case FieldKind.password:
      case FieldKind.time:
        return NTextField(
          label: f.label,
          controller: _text[f.key],
          required: f.required,
          error: err,
          helper: f.helper,
          hint: f.hint ?? (f.kind == FieldKind.time ? 'HH:MM (24-hour)' : null),
          maxLength: f.maxLength,
          obscure: f.kind == FieldKind.password,
          keyboardType: switch (f.kind) {
            FieldKind.email => TextInputType.emailAddress,
            FieldKind.phone => TextInputType.phone,
            FieldKind.time => TextInputType.datetime,
            _ => TextInputType.text,
          },
          onChanged: (_) => setState(() => _errors.remove(f.key)),
        );
      case FieldKind.multiline:
        return NTextField(label: f.label, controller: _text[f.key], required: f.required, error: err, helper: f.helper, hint: f.hint, maxLines: 5, minLines: 3, maxLength: f.maxLength, onChanged: (_) => setState(() => _errors.remove(f.key)));
      case FieldKind.number:
      case FieldKind.money:
        return NTextField(
          label: f.label,
          controller: _text[f.key],
          required: f.required,
          error: err,
          helper: f.helper,
          hint: f.hint,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
          prefixIcon: f.kind == FieldKind.money ? Icons.currency_rupee_rounded : null,
          onChanged: (_) => setState(() => _errors.remove(f.key)),
        );
      case FieldKind.date:
        final v = _values[f.key];
        final d = v is DateTime ? v : (v == null ? null : DateTime.tryParse('$v'));
        return NDateField(label: f.label, value: d, required: f.required, error: err, helper: f.helper, onChanged: changed);
      case FieldKind.select:
        return NSelect<String>(label: f.label, options: f.options, value: _values[f.key] == null ? null : '${_values[f.key]}', required: f.required, error: err, helper: f.helper, onChanged: changed);
      case FieldKind.asyncSelect:
        return AsyncView<List<NOption<String>>>(
          load: () => f.loadOptions!(ApiScope.of(context)),
          compact: true,
          skeletonRows: 1,
          builder: (context, opts, _) => NSelect<String>(label: f.label, options: opts, value: _values[f.key] == null ? null : '${_values[f.key]}', required: f.required, error: err, helper: f.helper, onChanged: changed),
        );
      case FieldKind.toggle:
        return NSwitch(label: f.label, description: f.description ?? f.helper, value: _values[f.key] == true, onChanged: (v) => changed(v));
      case FieldKind.file:
        final has = _values[f.key] != null;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NFieldLabel(f.label, required: f.required),
          Row(children: [
            NButton(
              label: has ? 'Replace file' : 'Choose file',
              icon: Icons.attach_file_rounded,
              variant: NButtonVariant.secondary,
              compact: true,
              busy: _uploading[f.key] == true,
              onPressed: () => _pickFile(f),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(_fileNames[f.key] ?? (has ? 'File attached' : 'No file chosen'), overflow: TextOverflow.ellipsis, style: NTokens.of(context).text.caption())),
          ]),
          if (f.helper != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(f.helper!, style: NTokens.of(context).text.caption())),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(err, style: NTokens.of(context).text.caption(color: NTokens.of(context).dangerText))),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    return NSheetBody(
      actions: [
        NButton(label: 'Cancel', variant: NButtonVariant.secondary, compact: true, onPressed: _busy ? null : () => Navigator.of(context).pop()),
        NButton(label: widget.submitLabel, variant: NButtonVariant.accent, compact: true, busy: _busy, onPressed: _uploading.values.any((u) => u) ? null : _submit),
      ],
      children: [
        if (widget.header != null) widget.header!,
        if (_formError != null) NBanner(message: _formError!, tone: NBannerTone.danger),
        for (final f in widget.fields)
          if (f.visibleWhen == null || f.visibleWhen!(cur)) _field(f),
      ],
    );
  }
}
