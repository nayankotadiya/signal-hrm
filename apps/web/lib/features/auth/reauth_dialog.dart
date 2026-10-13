import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:n_ui/n_ui.dart';

import '../../data/api.dart';
import '../../widgets/async_view.dart';

/// Re-authentication for sensitive actions (payroll finalization, restore, recovery codes,
/// role changes, temporary passwords). People with a password confirm with it; everyone else
/// gets a 6-digit code by email. Returns true on success.
Future<bool> showReauthDialog(BuildContext context, ApiClient api, {bool usePassword = false}) async {
  if (!usePassword) {
    try {
      await api.post('/auth/reauth/request');
    } catch (e) {
      if (context.mounted) showError(context, e);
      return false;
    }
  }
  if (!context.mounted) return false;
  final r = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) => _ReauthDialog(api: api, usePassword: usePassword));
  return r ?? false;
}

class _ReauthDialog extends StatefulWidget {
  const _ReauthDialog({required this.api, required this.usePassword});
  final ApiClient api;
  final bool usePassword;

  @override
  State<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<_ReauthDialog> {
  final _input = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_input.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.usePassword) {
        await widget.api.post('/auth/reauth/password', body: {'password': _input.text});
      } else {
        await widget.api.post('/auth/reauth/verify', body: {'code': _input.text.trim()});
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AlertDialog(
      backgroundColor: t.isDark ? const Color(0xFF1E1E22) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusCard)),
      title: Text('Confirm it’s you', style: t.text.title(size: 18)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            widget.usePassword ? 'This is a sensitive action. Enter your password to continue.' : 'This is a sensitive action. We emailed you a 6-digit code.',
            style: t.text.body(),
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[NBanner(message: _error!, tone: NBannerTone.danger), const SizedBox(height: 10)],
          if (widget.usePassword)
            NTextField(
              label: 'Password',
              controller: _input,
              autofocus: true,
              obscure: true,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _verify(),
            )
          else
            NTextField(
              label: 'Code',
              controller: _input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              autofillHints: const [AutofillHints.oneTimeCode],
              onSubmitted: (_) => _verify(),
            ),
        ]),
      ),
      actions: [
        NButton(label: 'Cancel', variant: NButtonVariant.secondary, compact: true, onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
        NButton(label: 'Confirm', variant: NButtonVariant.accent, compact: true, busy: _busy, onPressed: _verify),
      ],
    );
  }
}
