import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../platform/bridge.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

const docCategories = [
  NOption('policy', 'Policy'),
  NOption('contract', 'Contract'),
  NOption('id_proof', 'ID proof'),
  NOption('address_proof', 'Address proof'),
  NOption('letter', 'Letter'),
  NOption('certificate', 'Certificate'),
  NOption('tax', 'Tax'),
  NOption('general', 'General'),
];

class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  String _filter = 'all';
  String _q = '';
  int _rev = 0;
  bool _openedFromLink = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    String? open;
    String? filter;
    try {
      final qp = GoRouterState.of(context).uri.queryParameters;
      open = qp['open'];
      filter = qp['filter'];
    } catch (_) {}
    if (!_openedFromLink) {
      _openedFromLink = true;
      if (filter == 'to_acknowledge') _filter = 'ack';
      if (filter == 'expiring') _filter = 'expiring';
      if (open != null) WidgetsBinding.instance.addPostFrameCallback((_) => openDocument(context, open!, onChanged: () => setState(() => _rev++)));
    }
  }

  Future<void> _upload() async {
    final me = context.me;
    final r = await showFormSheet<Json>(
      context,
      title: 'Upload document',
      initial: const {'category': 'general', 'access': {'scope': 'private'}, 'retention': 'standard'},
      fields: [
        const FieldSpec('fileId', 'File', kind: FieldKind.file, required: true, filePurpose: 'document', fileAccept: 'application/pdf,image/*,.docx,.xlsx,.txt'),
        const FieldSpec('title', 'Title', required: true),
        const FieldSpec('category', 'Category', kind: FieldKind.select, options: docCategories),
        const FieldSpec('relatedEmployeeId', 'About employee', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
        const FieldSpec('access.scope', 'Who can see it', kind: FieldKind.select, options: [NOption('private', 'Only HR and the employee'), NOption('organization', 'Everyone'), NOption('departments', 'Some departments'), NOption('employees', 'Specific people')]),
        FieldSpec('accessDepartment', 'Department', kind: FieldKind.asyncSelect, loadOptions: Lookups.departments, visibleWhen: (v) => readPath(v, 'access.scope') == 'departments'),
        const FieldSpec('expiryDate', 'Expires on', kind: FieldKind.date),
        if (me.can('documents', 'manage')) const FieldSpec('isPolicy', 'This is a company policy', kind: FieldKind.toggle),
        FieldSpec('requiresAcknowledgement', 'Ask people to acknowledge it', kind: FieldKind.toggle, visibleWhen: (v) => v['isPolicy'] == true),
        const FieldSpec('retention', 'Retention', kind: FieldKind.select, options: [NOption('standard', 'Standard'), NOption('legal_hold', 'Legal hold'), NOption('delete_after_exit', 'Delete after exit'), NOption('permanent', 'Keep permanently')]),
      ],
      submitLabel: 'Upload',
      successMessage: 'Document uploaded.',
      submit: (v, key) async {
        final body = <String, dynamic>{...v}..remove('accessDepartment');
        final access = jsonMap(v['access']);
        body['access'] = {
          'scope': access['scope'] ?? 'private',
          'departmentIds': [if (v['accessDepartment'] != null) v['accessDepartment']],
          'employeeIds': [if (access['scope'] == 'employees' && v['relatedEmployeeId'] != null) v['relatedEmployeeId']],
        };
        body['isPolicy'] = v['isPolicy'] == true;
        body['requiresAcknowledgement'] = v['requiresAcknowledgement'] == true;
        return jsonMap(await context.api.post('/documents', body: body, idempotencyKey: key));
      },
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _letter() async {
    final me = context.me;
    final r = await showFormSheet<Json>(
      context,
      title: 'Generate a letter',
      subtitle: 'Created from your current records and stored as a private document.',
      fields: [
        const FieldSpec('kind', 'Letter', kind: FieldKind.select, required: true, options: [NOption('employment', 'Employment letter'), NOption('salary_certificate', 'Salary certificate')]),
        if (me.can('documents', 'create', 'team')) const FieldSpec('employeeId', 'For employee', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees, helper: 'Leave empty for yourself.'),
        const FieldSpec('purpose', 'Purpose', hint: 'Bank account, visa…'),
      ],
      submitLabel: 'Generate',
      successMessage: 'Letter generated. Downloading…',
      submit: (v, key) async => jsonMap(await context.api.post('/documents/letters', body: v, idempotencyKey: key)),
    );
    if (r == null || r['fileId'] == null || !mounted) return;
    try {
      final f = await context.api.download('/files/${r['fileId']}/content');
      bridge.downloadBytes(f.bytes, '${r['name'] ?? f.fileName}', 'application/pdf');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NSectionHeader(
          title: 'Documents',
          boldWord: '& policies',
          subtitle: 'Files are served only through permission checks; links never expose storage.',
          trailing: [
            if (me.can('documents', 'create')) NButton(label: 'Upload', icon: Icons.upload_file_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _upload),
            if (me.employeeId != null) NButton(label: 'Letter', icon: Icons.description_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _letter),
          ],
        ),
        if (me.employeeId != null) _PendingAcks(rev: _rev, onChanged: () => setState(() => _rev++)),
        Toolbar(children: [
          SizedBox(width: 260, child: NSearchField(hint: 'Search documents', onChanged: (v) => setState(() => _q = v))),
          NFilterChips<String>(
            value: _filter,
            onChanged: (v) => setState(() => _filter = v),
            options: [
              const NOption('all', 'All'),
              const NOption('policies', 'Policies'),
              if (me.employeeId != null) const NOption('mine', 'About me'),
              const NOption('expiring', 'Expiring soon'),
              if (me.employeeId != null) const NOption('ack', 'To acknowledge'),
            ],
          ),
        ]),
        if (_filter != 'ack')
          PagedList(
            path: '/documents',
            query: {'q': _q.trim(), if (_filter == 'policies') 'policies': true, if (_filter == 'mine') 'mine': true, if (_filter == 'expiring') 'expiringDays': 30},
            reloadKey: '$_filter|$_q|$_rev',
            emptyTitle: 'No documents',
            emptyIcon: Icons.folder_open_rounded,
            itemBuilder: (_, __, ___) => const SizedBox.shrink(),
            wrap: (context, items, reload) => NDataTable(
              columns: const [NColumn('Title', flex: 4), NColumn('Category'), NColumn('Access', hideOnTablet: true), NColumn('Version', numeric: true, hideOnTablet: true), NColumn('Expires'), NColumn('Updated', hideOnTablet: true)],
              onTapRow: (i) => openDocument(context, '${items[i]['id']}', onChanged: reload),
              rows: [
                for (final d in items)
                  [
                    Text('${d['isPolicy'] == true ? '📜 ' : ''}${d['title']}', maxLines: 2),
                    Text(Fmt.label(d['category'])),
                    Text(Fmt.label(jsonMap(d['access'])['scope'])),
                    Text('v${d['currentVersion']}'),
                    Text(d['expiryDate'] == null ? '—' : Fmt.date(d['expiryDate'])),
                    Text(Fmt.relative(d['updatedAt'])),
                  ],
              ],
            ),
          ),
      ]),
    );
  }
}

class _PendingAcks extends StatelessWidget {
  const _PendingAcks({required this.rev, required this.onChanged});
  final int rev;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<Json>>(
      reloadKey: rev,
      compact: true,
      skeletonRows: 1,
      load: () async => jsonList(await context.api.get('/documents/acknowledgements/pending')),
      builder: (context, items, _) => items.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: NDarkActionCard.check(
                title: 'Policies to acknowledge',
                items: [for (final a in items) NActionItem(id: '${a['documentId'] ?? a['id']}', title: '${a['title'] ?? 'Policy'}', subtitle: a['version'] != null ? 'Version ${a['version']}' : null)],
                onToggle: (item, done) async {
                  if (!done) return;
                  await openDocument(context, item.id, onChanged: onChanged);
                },
                emptyText: 'All policies acknowledged.',
              ),
            ),
    );
  }
}

/// Document detail: download, acknowledgement, versions and (for managers) access log.
Future<void> openDocument(BuildContext context, String id, {VoidCallback? onChanged}) {
  final api = context.api;
  return showNSheet<void>(
    context,
    title: 'Document',
    builder: (ctx) => ApiScope(
      api: api,
      child: AsyncView<Json>(
        load: () async => jsonMap(await api.get('/documents/$id')),
        builder: (ctx, d, reload) {
          final t = NTokens.of(ctx);
          final can = jsonMap(d['can']);
          final acks = d['acknowledgements'] == null ? null : jsonMap(d['acknowledgements']);
          Future<void> download([String? fileId]) async {
            try {
              final f = await api.download('/files/${fileId ?? d['currentFileId']}/content');
              bridge.downloadBytes(f.bytes, f.fileName == 'download' ? '${d['title']}' : f.fileName, f.mimeType);
            } catch (e) {
              if (ctx.mounted) showError(ctx, e);
            }
          }

          return ListView(padding: const EdgeInsets.all(20), children: [
            Text('${d['title']}', style: t.text.title(size: 20)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusChip('${d['status']}'),
              if (d['isPolicy'] == true) const StatusChip('info', label: 'Policy'),
              Text('${Fmt.label(d['category'])} · v${d['currentVersion']} · ${Fmt.bytes(d['sizeBytes'])}', style: t.text.caption()),
            ]),
            const SizedBox(height: 12),
            NInfoRow(label: 'Access', value: Fmt.label(jsonMap(d['access'])['scope'])),
            if (d['expiryDate'] != null) NInfoRow(label: 'Expires', value: Fmt.date(d['expiryDate'])),
            NInfoRow(label: 'Retention', value: Fmt.label(d['retention'])),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              NButton(label: 'Download', icon: Icons.download_rounded, compact: true, onPressed: download),
              if (d['requiresAcknowledgement'] == true && ctx.me.employeeId != null)
                NButton(
                  label: 'I have read and understood',
                  icon: Icons.verified_rounded,
                  compact: true,
                  variant: NButtonVariant.accent,
                  onPressed: () async {
                    try {
                      await api.post('/documents/$id/acknowledge');
                      if (ctx.mounted) NToast.of(ctx).show('Acknowledged. Thank you.');
                      onChanged?.call();
                      reload();
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    }
                  },
                ),
              if (can['manage'] == true)
                NButton(
                  label: 'New version',
                  icon: Icons.upload_rounded,
                  compact: true,
                  variant: NButtonVariant.secondary,
                  onPressed: () async {
                    final r = await showFormSheet<Json>(
                      ctx,
                      title: 'Upload new version',
                      subtitle: d['requiresAcknowledgement'] == true ? 'Everyone will be asked to acknowledge the new version.' : null,
                      fields: const [FieldSpec('fileId', 'File', kind: FieldKind.file, required: true, filePurpose: 'document'), FieldSpec('note', 'What changed')],
                      submit: (v, key) async => jsonMap(await api.post('/documents/$id/versions', body: v, idempotencyKey: key)),
                      successMessage: 'New version uploaded.',
                    );
                    if (r != null) reload();
                  },
                ),
              if (can['manage'] == true)
                NButton(
                  label: d['status'] == 'archived' ? 'Restore' : 'Archive',
                  icon: Icons.archive_outlined,
                  compact: true,
                  variant: NButtonVariant.secondary,
                  onPressed: () async {
                    try {
                      await api.patch('/documents/$id', body: {'status': d['status'] == 'archived' ? 'active' : 'archived'});
                      reload();
                      onChanged?.call();
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    }
                  },
                ),
            ]),
            if (acks != null) ...[
              const SizedBox(height: 16),
              NCardTitle('Acknowledgements', subtitle: '${acks['acknowledged']} of ${acks['assigned']} acknowledged'),
              NProgressBar(fraction: (acks['assigned'] as num) == 0 ? 0 : (acks['acknowledged'] as num) / (acks['assigned'] as num)),
            ],
            const SizedBox(height: 16),
            const NCardTitle('Versions'),
            for (final v in jsonList(d['versions']))
              NListRow(dense: true, title: 'Version ${v['version']}${v['note'] != null ? ' · ${v['note']}' : ''}', subtitle: Fmt.dateTime(v['createdAt']), trailing: IconButton(tooltip: 'Download this version', icon: const Icon(Icons.download_rounded, size: 18), onPressed: () => download('${v['fileId']}'))),
            if (can['manage'] == true) ...[
              const SizedBox(height: 16),
              const NCardTitle('Access log'),
              AsyncView<List<Json>>(
                load: () async => jsonList(await api.get('/documents/$id/access-log')),
                compact: true,
                builder: (ctx, logs, _) => logs.isEmpty
                    ? Text('No access recorded yet.', style: t.text.caption())
                    : Column(children: [for (final l in logs.take(50)) NListRow(dense: true, title: '${l['userName'] ?? l['userId']} · ${Fmt.label(l['action'])}', subtitle: Fmt.dateTime(l['at'] ?? l['createdAt']))]),
              ),
            ],
          ]);
        },
      ),
    ),
  );
}
