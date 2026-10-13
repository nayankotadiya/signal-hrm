import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../app/destinations.dart';
import '../app/links.dart';
import '../app/services.dart';
import '../data/api.dart';
import '../l10n/gen/app_localizations.dart';
import '../widgets/async_view.dart';

/// Ctrl/Cmd+K: jump to any section, or search people, tasks, leads, meetings, documents and
/// approvals. Results come from `GET /v1/search`, which only returns what the caller may see.
Future<void> showCommandPalette(BuildContext context, List<AppDestination> destinations, ValueChanged<int> goBranch) {
  final api = context.api;
  final router = GoRouter.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    builder: (ctx) => ApiScope(
      api: api,
      child: _Palette(
        destinations: destinations,
        onDestination: (i) {
          Navigator.of(ctx).pop();
          goBranch(i);
        },
        onLink: (link) {
          Navigator.of(ctx).pop();
          router.go(resolveLink(link));
        },
      ),
    ),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.destinations, required this.onDestination, required this.onLink});
  final List<AppDestination> destinations;
  final ValueChanged<int> onDestination;
  final ValueChanged<String> onLink;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  String _q = '';
  Timer? _debounce;
  List<Json> _groups = const [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  static const _groupLabels = {
    'employees': 'People',
    'departments': 'Departments',
    'teams': 'Teams',
    'tasks': 'Tasks',
    'leads': 'Leads',
    'meetings': 'Meetings',
    'documents': 'Documents',
    'policies': 'Policies',
    'approvals': 'Approvals',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String v) {
    setState(() => _q = v);
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() {
        _groups = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final j = await ApiScope.of(context).get('/search', query: {'q': q, 'limit': 5});
      if (!mounted || seq != _seq) return;
      setState(() {
        _groups = [for (final g in (j['groups'] as List? ?? const [])) (g as Map).cast<String, dynamic>()];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final q = _q.trim().toLowerCase();
    final nav = [
      for (var i = 0; i < widget.destinations.length; i++)
        if (q.isEmpty || widget.destinations[i].label(l).toLowerCase().contains(q)) i,
    ];
    return Align(
      alignment: const Alignment(0, -0.6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            color: t.isDark ? const Color(0xFF1E1E22) : Colors.white,
            borderRadius: BorderRadius.circular(t.radiusCard),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.all(14), child: NSearchField(hint: l.topSearchSoonNone, onChanged: _changed, autofocus: true)),
              Divider(height: 1, color: t.divider),
              Flexible(
                child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(8), children: [
                  if (nav.isNotEmpty) ...[
                    _heading(t, 'Go to'),
                    for (final i in nav)
                      NListRow(
                        dense: true,
                        leading: Icon(widget.destinations[i].icon, size: 18, color: t.muted),
                        title: widget.destinations[i].label(l),
                        onTap: () => widget.onDestination(i),
                      ),
                  ],
                  if (_loading) const Padding(padding: EdgeInsets.all(12), child: NSkeletonList(rows: 2)),
                  if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: t.text.body(color: t.dangerText))),
                  for (final g in _groups) ...[
                    _heading(t, _groupLabels[g['type']] ?? '${g['type']}'),
                    for (final h in (g['items'] as List? ?? const []))
                      NListRow(
                        dense: true,
                        title: '${(h as Map)['title']}',
                        subtitle: h['subtitle'] as String?,
                        onTap: () => widget.onLink('${h['link']}'),
                      ),
                  ],
                  if (!_loading && _error == null && _q.trim().length >= 2 && _groups.isEmpty)
                    Padding(padding: const EdgeInsets.all(16), child: Text('No results for "${_q.trim()}"', style: t.text.body(color: t.muted))),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _heading(NTokens t, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Semantics(header: true, child: Text(s, style: t.text.caption(weight: FontWeight.w600))),
      );
}
