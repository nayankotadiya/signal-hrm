import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../l10n/gen/app_localizations.dart';

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NBreakpointBuilder(
        builder: (context, bp) => NPageBackground(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: NGlassCard(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Semantics(header: true, child: Text(l.notFoundTitle, style: t.text.heading(size: 28))),
                    const SizedBox(height: 8),
                    Text(l.notFoundBody, style: t.text.body(color: t.muted)),
                    const SizedBox(height: 20),
                    NButton(label: l.notFoundAction, icon: Icons.home_rounded, onPressed: () => context.go('/')),
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
