import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';
import '../approvals/approvals_page.dart' show requestTypeLabels;
import '../auth/password_pages.dart' show issueTemporaryPassword;

class AdminSection extends StatelessWidget {
  const AdminSection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/admin',
      tabId: tab,
      title: 'Admin',
      boldWord: 'settings',
      subtitle: 'Every change here is recorded in the audit log.',
      tabs: [
        SectionTab('organization', 'Company', Icons.apartment_rounded, (_) => const OrganizationTab(), visible: (me) => me.can('organization', 'configure', 'organization')),
        SectionTab('modules', 'Modules', Icons.toggle_on_rounded, (_) => const ModulesTab(), visible: (me) => me.can('features', 'view')),
        SectionTab('attendance', 'Attendance rules', Icons.my_location_rounded, (_) => const AttendanceRulesTab(), visible: (me) => me.can('organization', 'configure', 'organization')),
        SectionTab('locations', 'Locations', Icons.place_rounded, (_) => const LocationsTab(), visible: (me) => me.can('locations', 'view')),
        SectionTab('leave', 'Leave setup', Icons.beach_access_rounded, (_) => const LeaveSetupTab(), visible: (me) => me.can('leave', 'configure') || me.can('leave', 'manage', 'organization')),
        SectionTab('users', 'Users', Icons.manage_accounts_rounded, (_) => const UsersTab(), visible: (me) => me.can('users', 'view', 'organization')),
        SectionTab('roles', 'Roles', Icons.admin_panel_settings_rounded, (_) => const RolesTab(), visible: (me) => me.can('roles', 'view')),
        SectionTab('approvals', 'Approval rules', Icons.alt_route_rounded, (_) => const ApprovalRulesTab(), visible: (me) => me.can('approvals', 'configure')),
        SectionTab('expenses', 'Expense policy', Icons.receipt_rounded, (_) => const ExpenseCategoriesTab(), visible: (me) => me.can('expenses', 'configure')),
        SectionTab('notifications', 'Notifications', Icons.mark_email_unread_rounded, (_) => const NotificationAdminTab(), visible: (me) => me.can('notifications', 'configure')),
        SectionTab('integrations', 'Integrations', Icons.hub_rounded, (_) => const IntegrationsTab(), visible: (me) => me.feature('integrations') && me.can('integrations', 'view')),
      ],
    );
  }
}

// ======================================================================= organization

class OrganizationTab extends StatelessWidget {
  const OrganizationTab({super.key});

  @override
  Widget build(BuildContext context) {
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/organization')),
      builder: (context, o, reload) {
        Future<void> edit() async {
          final r = await showFormSheet<Json>(
            context,
            title: 'Company profile',
            initial: {...o, 'workingDaysText': [for (final d in (o['workingDays'] as List? ?? const [])) const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][(d as num).toInt()]].join(',')},
            fields: const [
              FieldSpec('name', 'Display name', required: true),
              FieldSpec('legalName', 'Legal name'),
              FieldSpec('registration.gstin', 'GSTIN'),
              FieldSpec('registration.pan', 'PAN'),
              FieldSpec('registration.cin', 'CIN'),
              FieldSpec('primaryContact.name', 'Primary contact'),
              FieldSpec('primaryContact.email', 'Contact email', kind: FieldKind.email),
              FieldSpec('primaryContact.phone', 'Contact phone', kind: FieldKind.phone),
              FieldSpec('supportEmail', 'Support email', kind: FieldKind.email),
              FieldSpec('timezone', 'Time zone', hint: 'Asia/Kolkata', required: true),
              FieldSpec('currency', 'Currency', hint: 'INR'),
              FieldSpec('dateFormat', 'Date format', kind: FieldKind.select, options: [NOption('dd MMM yyyy', '12 Oct 2026'), NOption('dd/MM/yyyy', '12/10/2026'), NOption('MM/dd/yyyy', '10/12/2026'), NOption('yyyy-MM-dd', '2026-10-12')]),
              FieldSpec('timeFormat', 'Time format', kind: FieldKind.select, options: [NOption('12h', '12-hour'), NOption('24h', '24-hour')]),
              FieldSpec('workingDaysText', 'Working days', hint: 'Mon,Tue,Wed,Thu,Fri,Sat'),
              FieldSpec('defaultLocale', 'Default language', kind: FieldKind.select, options: [NOption('en', 'English'), NOption('hi', 'हिन्दी'), NOption('gu', 'ગુજરાતી')]),
              FieldSpec('logoFileId', 'Logo', kind: FieldKind.file, filePurpose: 'logo', fileAccept: 'image/*'),
            ],
            omitEmpty: false,
            successMessage: 'Company profile saved.',
            submit: (v, key) async {
              final body = <String, dynamic>{...v}..remove('workingDaysText');
              const days = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
              final txt = v['workingDaysText'] as String?;
              if (txt != null) body['workingDays'] = [for (final p in txt.split(',')) if (p.trim().length >= 3 && days.contains(p.trim().toLowerCase().substring(0, 3))) days.indexOf(p.trim().toLowerCase().substring(0, 3))];
              body.removeWhere((k, val) => val == null);
              for (final k in ['registration', 'primaryContact']) {
                if (body[k] is Map) (body[k] as Map).removeWhere((_, val) => val == null);
              }
              return jsonMap(await context.api.patch('/organization', body: body, idempotencyKey: key));
            },
          );
          if (r != null) {
            reload();
            if (context.mounted) await context.services.session.reloadMe();
          }
        }

        final reg = jsonMap(o['registration']);
        final pc = jsonMap(o['primaryContact']);
        return CardGrid(minTileWidth: 380, children: [
          InfoCard(
            title: '${o['name']}',
            subtitle: '${o['legalName'] ?? ''}',
            trailing: NButton(label: 'Edit', compact: true, variant: NButtonVariant.secondary, onPressed: edit),
            child: Column(children: [
              NInfoRow(label: 'Time zone', value: '${o['timezone']}'),
              NInfoRow(label: 'Currency', value: '${o['currency']}'),
              NInfoRow(label: 'Working days', value: [for (final d in (o['workingDays'] as List? ?? const [])) const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][(d as num).toInt()]].join(', ')),
              NInfoRow(label: 'Date / time', value: '${o['dateFormat']} · ${o['timeFormat']}'),
              NInfoRow(label: 'GSTIN', value: '${reg['gstin'] ?? ''}'),
              NInfoRow(label: 'PAN', value: '${reg['pan'] ?? ''}'),
              NInfoRow(label: 'Contact', value: [pc['name'], pc['email'], pc['phone']].whereType<String>().join(' · ')),
              NInfoRow(label: 'Support email', value: '${o['supportEmail'] ?? ''}'),
            ]),
          ),
          _SettingsCard(
            title: 'Leave rules',
            section: 'leave',
            current: jsonMap(jsonMap(o['settings'])['leave']),
            fields: const [
              FieldSpec('approvalByHr', 'HR approves after the manager', kind: FieldKind.toggle),
              FieldSpec('allowNegative', 'Allow negative balances', kind: FieldKind.toggle),
              FieldSpec('countWeekends', 'Count weekly offs inside leave', kind: FieldKind.toggle),
              FieldSpec('countHolidays', 'Count holidays inside leave', kind: FieldKind.toggle),
            ],
            onSaved: reload,
          ),
          _SettingsCard(
            title: 'Payroll calendar',
            section: 'payroll',
            current: jsonMap(jsonMap(o['settings'])['payroll']),
            fields: const [
              FieldSpec('payDay', 'Pay day of month', kind: FieldKind.number, min: 1, max: 28),
              FieldSpec('cutoffDay', 'Attendance cut-off day', kind: FieldKind.number, min: 1, max: 28),
              FieldSpec('lopBasis', 'Loss-of-pay basis', kind: FieldKind.select, options: [NOption('calendar_days', 'Calendar days'), NOption('working_days', 'Working days'), NOption('fixed_30', 'Fixed 30 days')]),
              FieldSpec('roundNetPay', 'Round net pay to the rupee', kind: FieldKind.toggle),
            ],
            onSaved: reload,
          ),
          _SettingsCard(
            title: 'Approvals',
            section: 'approvals',
            current: jsonMap(jsonMap(o['settings'])['approvals']),
            fields: const [
              FieldSpec('preventSelfApproval', 'Nobody approves their own request', kind: FieldKind.toggle),
              FieldSpec('escalationHours', 'Escalate after (hours)', kind: FieldKind.number, min: 1, max: 720),
            ],
            onSaved: reload,
          ),
          if (context.me.isSuperAdmin)
            _SettingsCard(
              title: 'Security (Super Admin)',
              section: 'security',
              current: jsonMap(jsonMap(o['settings'])['security']),
              fields: const [
                FieldSpec('sessionDays', 'Stay signed in for (days)', kind: FieldKind.number, min: 1, max: 90),
                FieldSpec('reauthMinutes', 'Re-authentication valid for (minutes)', kind: FieldKind.number, min: 1, max: 60),
                FieldSpec('maxFailedLogins', 'Lock after failed sign-ins', kind: FieldKind.number, min: 3, max: 20),
                FieldSpec('lockMinutes', 'Lock duration (minutes)', kind: FieldKind.number, min: 1, max: 1440),
                FieldSpec('passwordLogin', 'Allow password sign-in', kind: FieldKind.toggle),
              ],
              onSaved: reload,
            ),
        ]);
      },
    );
  }
}

/// A card showing one settings section with an edit form that PUTs `/organization/settings/:section`.
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.section, required this.current, required this.fields, required this.onSaved});
  final String title;
  final String section;
  final Json current;
  final List<FieldSpec> fields;
  final VoidCallback onSaved;

  String _show(FieldSpec f) {
    final v = readPath(current, f.key);
    if (v == null) return 'Default';
    if (v is bool) return v ? 'On' : 'Off';
    if (f.kind == FieldKind.select) return f.options.firstWhere((o) => o.value == '$v', orElse: () => NOption('$v', '$v')).label;
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    return InfoCard(
      title: title,
      trailing: NButton(
        label: 'Edit',
        compact: true,
        variant: NButtonVariant.secondary,
        onPressed: () async {
          final r = await showFormSheet<Json>(
            context,
            title: title,
            initial: current,
            fields: fields,
            successMessage: 'Saved.',
            submit: (v, key) async {
              void clean(Map<dynamic, dynamic> m) {
                m.removeWhere((_, val) => val == null);
                for (final e in m.values) {
                  if (e is Map) clean(e);
                }
              }

              for (final f in fields) {
                if (f.kind == FieldKind.toggle && readPath(v, f.key) == null) writePath(v, f.key, false);
                final val = readPath(v, f.key);
                if (f.kind == FieldKind.number && val is num) writePath(v, f.key, val.round());
              }
              clean(v);
              return jsonMap(await context.api.put('/organization/settings/$section', body: v, idempotencyKey: key));
            },
          );
          if (r != null) {
            onSaved();
            if (context.mounted) await context.services.session.reloadMe();
          }
        },
      ),
      child: Column(children: [for (final f in fields) NInfoRow(label: f.label, value: _show(f))]),
    );
  }
}

// ======================================================================= modules

class ModulesTab extends StatelessWidget {
  const ModulesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final canToggle = context.me.can('features', 'configure', 'organization');
    return AsyncView<List<Json>>(
      load: () async => jsonList(await context.api.get('/organization/features')),
      builder: (context, items, reload) => InfoCard(
        title: 'Modules',
        subtitle: 'A switched-off module disappears from navigation and its API refuses requests. Data is kept.',
        child: Column(children: [
          for (final f in items)
            NSwitch(
              label: '${f['name']}',
              value: f['enabled'] == true,
              onChanged: canToggle
                  ? (v) async {
                      final c = v ? const NConfirmResult(true) : await showNConfirm(context, title: 'Turn off ${f['name']}?', message: 'People lose access to this module right away. Nothing is deleted.', confirmLabel: 'Turn off', destructive: true);
                      if (!c.confirmed || !context.mounted) return;
                      try {
                        await context.api.put('/organization/features/${f['key']}', body: {'enabled': v});
                        reload();
                        if (context.mounted) await context.services.session.reloadMe();
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    }
                  : null,
            ),
        ]),
      ),
    );
  }
}

// ======================================================================= attendance rules (Phase 4)

class AttendanceRulesTab extends StatelessWidget {
  const AttendanceRulesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/organization')),
      builder: (context, o, reload) {
        final a = jsonMap(jsonMap(o['settings'])['attendance']);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NBanner(
            message: 'Distance is calculated on the server (Haversine) against each employee\'s assigned location. Times always come from the server clock. Suspicious patterns are flagged for review, never punished automatically.',
            tone: NBannerTone.info,
          ),
          const SizedBox(height: 14),
          CardGrid(minTileWidth: 380, children: [
            _SettingsCard(
              title: 'Check-in and check-out',
              section: 'attendance',
              current: a,
              fields: const [
                FieldSpec('checkIn.requireLocation', 'Check-in needs location', kind: FieldKind.toggle),
                FieldSpec('checkIn.requireSelfie', 'Check-in needs a photo', kind: FieldKind.toggle),
                FieldSpec('checkOut.requireLocation', 'Check-out needs location', kind: FieldKind.toggle),
                FieldSpec('checkOut.requireSelfie', 'Check-out needs a photo', kind: FieldKind.toggle),
                FieldSpec('allowRemote', 'Allow recording as remote outside the geofence (flagged)', kind: FieldKind.toggle),
              ],
              onSaved: reload,
            ),
            _SettingsCard(
              title: 'GPS quality',
              section: 'attendance',
              current: a,
              fields: const [
                FieldSpec('maxAccuracyMeters', 'Maximum GPS accuracy (metres)', kind: FieldKind.number, min: 5, max: 2000, helper: 'Readings less precise than this are refused; the person is asked to retry.'),
                FieldSpec('gpsRetryLimit', 'Failed tries before the exception flow opens', kind: FieldKind.number, min: 0, max: 10),
                FieldSpec('impossibleTravelKmh', 'Flag jumps faster than (km/h)', kind: FieldKind.number, min: 30, max: 1200),
              ],
              onSaved: reload,
            ),
            _SettingsCard(
              title: 'Day rules and retention',
              section: 'attendance',
              current: a,
              fields: const [
                FieldSpec('halfDayMinutes', 'Half day below (minutes worked)', kind: FieldKind.number, min: 30, max: 720),
                FieldSpec('fullDayMinutes', 'Full day from (minutes worked)', kind: FieldKind.number, min: 60, max: 1440),
                FieldSpec('autoCheckoutHours', 'Treat as missed check-out after (hours)', kind: FieldKind.number, min: 4, max: 24),
                FieldSpec('selfieRetentionDays', 'Keep attendance photos for (days)', kind: FieldKind.number, min: 1, max: 3650),
              ],
              onSaved: reload,
            ),
          ]),
        ]);
      },
    );
  }
}

// ======================================================================= locations

class LocationsTab extends StatefulWidget {
  const LocationsTab({super.key});

  @override
  State<LocationsTab> createState() => _LocationsTabState();
}

class _LocationsTabState extends State<LocationsTab> {
  int _rev = 0;

  Future<void> _edit([Json? l]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: l == null ? 'New location' : 'Edit ${l['name']}',
      initial: l ?? const {'radiusMeters': 150, 'active': true},
      header: Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          icon: const Icon(Icons.my_location_rounded, size: 18),
          label: const Text('Copy my current position to the clipboard'),
          onPressed: () async {
            try {
              final g = await bridge.currentPosition();
              if (!mounted) return;
              NToast.of(context).show('You are at ${g.latitude.toStringAsFixed(6)}, ${g.longitude.toStringAsFixed(6)} (±${g.accuracyMeters.round()} m). Enter these as latitude and longitude.');
            } catch (_) {
              if (mounted) NToast.of(context).show("Couldn't read your location. Allow location access and try again.");
            }
          },
        ),
      ),
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('address', 'Address', kind: FieldKind.multiline),
        FieldSpec('latitude', 'Latitude', kind: FieldKind.number, required: true, min: -90, max: 90, hint: '23.022505'),
        FieldSpec('longitude', 'Longitude', kind: FieldKind.number, required: true, min: -180, max: 180, hint: '72.571362'),
        FieldSpec('radiusMeters', 'Allowed radius (metres)', kind: FieldKind.number, required: true, min: 10, max: 5000),
        FieldSpec('timezone', 'Time zone (if different)', hint: 'Asia/Kolkata'),
        FieldSpec('active', 'Active', kind: FieldKind.toggle),
      ],
      successMessage: 'Location saved.',
      submit: (v, key) async {
        final body = {...v, 'radiusMeters': (v['radiusMeters'] as num?)?.round(), 'active': v['active'] == true};
        return jsonMap(l == null ? await api.post('/locations', body: body, idempotencyKey: key) : await api.patch('/locations/${l['id']}', body: body, idempotencyKey: key));
      },
    );
    if (!mounted) return;
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final canManage = context.me.can('locations', 'manage');
    return InfoCard(
      title: 'Work locations',
      subtitle: 'Each employee is checked against their assigned location and its radius.',
      trailing: canManage ? NButton(label: 'New location', icon: Icons.add_location_alt_rounded, compact: true, onPressed: () => _edit()) : null,
      child: AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/locations')),
        builder: (context, items, _) => items.isEmpty
            ? const NEmptyState(title: 'No locations yet', message: 'Add your office so check-in can be verified.', compact: true, icon: Icons.place_rounded)
            : NDataTable(
                columns: const [NColumn('Name', flex: 3), NColumn('Coordinates', flex: 3, hideOnTablet: true), NColumn('Radius', numeric: true), NColumn('People', numeric: true), NColumn('Status')],
                onTapRow: canManage ? (i) => _edit(items[i]) : null,
                rows: [
                  for (final l in items)
                    [
                      Text('${l['name']}${l['address'] != null ? '\n${l['address']}' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text('${(l['latitude'] as num).toStringAsFixed(5)}, ${(l['longitude'] as num).toStringAsFixed(5)}'),
                      Text('${l['radiusMeters']} m'),
                      Text('${l['employeeCount'] ?? '—'}'),
                      StatusChip(l['active'] == false ? 'inactive' : 'active'),
                    ],
                ],
              ),
      ),
    );
  }
}

// ======================================================================= leave setup

class LeaveSetupTab extends StatefulWidget {
  const LeaveSetupTab({super.key});

  @override
  State<LeaveSetupTab> createState() => _LeaveSetupTabState();
}

class _LeaveSetupTabState extends State<LeaveSetupTab> {
  int _rev = 0;

  Future<void> _type([Json? t]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: t == null ? 'New leave type' : 'Edit ${t['name']}',
      initial: t ?? const {'paid': true, 'allowHalfDay': true, 'active': true},
      fields: const [
        FieldSpec('code', 'Code', required: true, hint: 'CL'),
        FieldSpec('name', 'Name', required: true),
        FieldSpec('color', 'Colour', hint: '#6C5CE7'),
        FieldSpec('paid', 'Paid leave', kind: FieldKind.toggle),
        FieldSpec('allowHalfDay', 'Allow half days', kind: FieldKind.toggle),
        FieldSpec('requiresAttachmentAfterDays', 'Require a document after (days)', kind: FieldKind.number, min: 1, max: 60),
        FieldSpec('active', 'Active', kind: FieldKind.toggle),
      ],
      successMessage: 'Leave type saved.',
      submit: (v, key) async {
        final body = {...v, for (final k in ['paid', 'allowHalfDay', 'active']) k: v[k] == true};
        if (body['requiresAttachmentAfterDays'] is num) body['requiresAttachmentAfterDays'] = (body['requiresAttachmentAfterDays'] as num).round();
        return jsonMap(t == null ? await api.post('/leave/types', body: body, idempotencyKey: key) : await api.put('/leave/types/${t['id']}', body: body, idempotencyKey: key));
      },
    );
    if (!mounted) return;
    if (r != null) setState(() => _rev++);
  }

  Future<void> _policy([Json? p]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: p == null ? 'New leave policy' : 'Edit ${p['name']}',
      initial: p ?? const {'accrual': 'upfront', 'carryForwardMax': 0, 'minNoticeDays': 0, 'active': true},
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('leaveTypeId', 'Leave type', kind: FieldKind.asyncSelect, loadOptions: Lookups.leaveTypes, required: true),
        FieldSpec('annualQuota', 'Days per year', kind: FieldKind.number, required: true, min: 0, max: 365),
        FieldSpec('accrual', 'Accrual', kind: FieldKind.select, options: [NOption('upfront', 'All at the start of the year'), NOption('monthly', 'Monthly')]),
        FieldSpec('carryForwardMax', 'Carry forward up to (days)', kind: FieldKind.number, min: 0, max: 365),
        FieldSpec('maxConsecutiveDays', 'Maximum days in one request', kind: FieldKind.number, min: 1, max: 365),
        FieldSpec('minNoticeDays', 'Notice needed (days)', kind: FieldKind.number, min: 0, max: 90),
        FieldSpec('allowNegative', 'Allow going below zero', kind: FieldKind.toggle),
        FieldSpec('requireHrApproval', 'HR approval needed', kind: FieldKind.toggle),
        FieldSpec('appliesTo.afterProbationOnly', 'Only after probation', kind: FieldKind.toggle),
        FieldSpec('active', 'Active', kind: FieldKind.toggle),
      ],
      successMessage: 'Policy saved.',
      submit: (v, key) async {
        final body = <String, dynamic>{...v};
        for (final k in ['maxConsecutiveDays', 'minNoticeDays']) {
          if (body[k] is num) body[k] = (body[k] as num).round();
        }
        for (final k in ['allowNegative', 'requireHrApproval', 'active']) {
          body[k] = v[k] == true;
        }
        body['appliesTo'] = {'afterProbationOnly': readPath(v, 'appliesTo.afterProbationOnly') == true};
        return jsonMap(p == null ? await api.post('/leave/policies', body: body, idempotencyKey: key) : await api.put('/leave/policies/${p['id']}', body: body, idempotencyKey: key));
      },
    );
    if (!mounted) return;
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    return CardGrid(minTileWidth: 380, children: [
      InfoCard(
        title: 'Leave types',
        trailing: NButton(label: 'New', icon: Icons.add_rounded, compact: true, onPressed: () => _type()),
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/leave/types')),
          builder: (context, items, _) => Column(children: [
            for (final t in items)
              NListRow(
                dense: true,
                title: '${t['code']} · ${t['name']}',
                subtitle: [t['paid'] == true ? 'Paid' : 'Unpaid', if (t['allowHalfDay'] == true) 'half days', if (t['requiresAttachmentAfterDays'] != null) 'document after ${t['requiresAttachmentAfterDays']} days'].join(' · '),
                trailing: StatusChip(t['active'] == false ? 'inactive' : 'active'),
                onTap: () => _type(t),
              ),
          ]),
        ),
      ),
      InfoCard(
        title: 'Policies',
        trailing: NButton(label: 'New', icon: Icons.add_rounded, compact: true, onPressed: () => _policy()),
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/leave/policies')),
          builder: (context, items, _) => items.isEmpty
              ? const NEmptyState(title: 'No policies', compact: true)
              : Column(children: [
                  for (final p in items)
                    NListRow(
                      dense: true,
                      title: '${p['name']}',
                      subtitle: '${p['annualQuota']} days/yr · ${Fmt.label(p['accrual'])} · carry ${p['carryForwardMax']}${p['minNoticeDays'] != null && (p['minNoticeDays'] as num) > 0 ? ' · ${p['minNoticeDays']} days notice' : ''}',
                      trailing: StatusChip(p['active'] == false ? 'inactive' : 'active'),
                      onTap: () => _policy(p),
                    ),
                ]),
        ),
      ),
    ]);
  }
}

// ======================================================================= users

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  String _q = '';
  String _status = '';
  int _rev = 0;

  Future<void> _invite() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Add User / Create Account',
      subtitle: 'Create Login ID & password directly, or send an email invitation.',
      initial: const {'role': 'employee', 'createPassword': true},
      fields: [
        const FieldSpec('fullName', 'Full name', required: true),
        const FieldSpec('email', 'Email (Login ID)', kind: FieldKind.email, required: true),
        const FieldSpec('role', 'Role', kind: FieldKind.asyncSelect, loadOptions: Lookups.roles, required: true),
        const FieldSpec('employeeId', 'Link to employee record', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
        const FieldSpec(
          'createPassword',
          'Create Password directly',
          kind: FieldKind.toggle,
          description: 'User can sign in immediately with email & password without waiting for an email invitation.',
        ),
        FieldSpec(
          'password',
          'Password',
          kind: FieldKind.password,
          visibleWhen: (v) => v['createPassword'] == true,
          helper: 'Minimum 6 characters. User logs in with email and this password.',
        ),
      ],
      submitLabel: 'Create Account',
      successMessage: 'Account created.',
      submit: (v, key) async {
        final body = Map<String, dynamic>.from(v);
        final createPwd = body.remove('createPassword') == true;
        final pwd = body['password']?.toString().trim();
        if (!createPwd || pwd == null || pwd.isEmpty) {
          body.remove('password');
          body['sendInvitation'] = true;
        } else {
          body['password'] = pwd;
          body['sendInvitation'] = false;
        }
        return jsonMap(await context.api.post('/users', body: body, idempotencyKey: key));
      },
    );
    if (r == null || !mounted) return;
    setState(() => _rev++);
    if (r['hasPassword'] == true) {
      NToast.of(context).show('Account ready! ${r['email']} can now log in.');
    } else if (r['invitationSent'] == true) {
      NToast.of(context).show('Invitation emailed to ${r['email']}.');
    } else {
      // No email on this server: activate the account with a temporary password instead.
      await issueTemporaryPassword(context, userId: '${r['id']}', name: '${r['fullName']}');
      if (mounted) setState(() => _rev++);
    }
  }

  Future<void> _manage(Json u) async {
    final me = context.me;
    if (u['role'] == 'super_admin' && !me.isSuperAdmin && u['id'] != me.userId) return;
    await showNSheet<void>(
      context,
      title: '${u['fullName']}',
      subtitle: '${u['email'] ?? ''}',
      builder: (ctx) => ApiScope(
        api: context.api,
        child: NSheetBody(children: [
          Wrap(spacing: 8, children: [StatusChip('${u['status']}'), StatusChip('info', label: Fmt.label(u['role']))]),
          NInfoRow(label: 'Last sign-in', value: u['lastLoginAt'] == null ? 'Never' : Fmt.relative(u['lastLoginAt'])),
          if (me.can('users', 'manage', 'organization') && u['role'] != 'super_admin')
            AsyncView<List<NOption<String>>>(
              load: () => Lookups.roles(context.api),
              compact: true,
              builder: (c2, roles, _) => NSelect<String>(
                label: 'Role',
                value: '${u['role']}',
                options: [for (final r in roles) if (r.value != 'super_admin') r],
                onChanged: (v) async {
                  if (v == null || v == u['role']) return;
                  try {
                    await context.api.put('/users/${u['id']}/role', body: {'role': v});
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    setState(() => _rev++);
                  } catch (e) {
                    if (ctx.mounted) showError(ctx, e);
                  }
                },
              ),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (u['status'] == 'invited')
              NButton(
                label: 'Resend invitation',
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  try {
                    await context.api.post('/users/${u['id']}/invitation');
                    if (ctx.mounted) NToast.of(ctx).show('Invitation sent again.');
                  } catch (e) {
                    if (ctx.mounted) showError(ctx, e);
                  }
                },
              ),
            if (me.can('users', 'manage', 'organization') && u['id'] != me.userId && ['active', 'invited'].contains(u['status']))
              NButton(
                label: u['status'] == 'invited' ? 'Activate with a temporary password' : 'Reset password',
                icon: Icons.password_rounded,
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  await issueTemporaryPassword(ctx, userId: '${u['id']}', name: '${u['fullName']}');
                  if (mounted) setState(() => _rev++);
                },
              ),
            if (me.can('users', 'manage', 'organization') && u['id'] != me.userId)
              for (final s in u['status'] == 'active' ? ['suspended', 'inactive'] : ['active'])
                NButton(
                  label: s == 'active' ? 'Reactivate' : (s == 'suspended' ? 'Suspend' : 'Deactivate'),
                  compact: true,
                  variant: NButtonVariant.secondary,
                  onPressed: () async {
                    final api = context.api;
                    final c = await showNConfirm(ctx, title: '${Fmt.label(s)} ${u['fullName']}?', message: s == 'active' ? 'They can sign in again.' : 'They are signed out everywhere and cannot sign in.', confirmLabel: 'Confirm', destructive: s != 'active', reasonLabel: 'Reason', reasonRequired: s != 'active');
                    if (!c.confirmed) return;
                    try {
                      await api.post('/users/${u['id']}/status', body: {'status': s, if (c.reason != null) 'reason': c.reason});
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (mounted) setState(() => _rev++);
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    }
                  },
                ),
          ]),
          if (me.can('roles', 'manage')) _UserGrants(userId: '${u['id']}'),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        SizedBox(width: 260, child: NSearchField(hint: 'Search name or email', onChanged: (v) => setState(() => _q = v))),
        NFilterChips<String>(value: _status, onChanged: (v) => setState(() => _status = v), options: const [NOption('', 'All'), NOption('active', 'Active'), NOption('invited', 'Invited'), NOption('suspended', 'Suspended')]),
        if (me.can('users', 'create', 'organization')) NButton(label: 'Add User', icon: Icons.person_add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _invite),
      ]),
      PagedList(
        path: '/users',
        query: {'q': _q.trim(), 'status': _status},
        reloadKey: '$_q|$_status|$_rev',
        emptyTitle: 'No users',
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) {
          final visibleItems = [
            for (final u in items)
              if (u['role'] != 'super_admin' || me.isSuperAdmin) u
          ];
          return NDataTable(
            columns: const [NColumn('Name', flex: 3), NColumn('Email', flex: 3, hideOnTablet: true), NColumn('Role'), NColumn('Last sign-in', hideOnTablet: true), NColumn('Status')],
            onTapRow: (i) => _manage(visibleItems[i]),
            rows: [
              for (final u in visibleItems)
                [
                  Text('${u['fullName']}'),
                  Text('${u['email'] ?? u['phone'] ?? ''}'),
                  Text(Fmt.label(u['role'])),
                  Text(u['lastLoginAt'] == null ? 'Never' : Fmt.relative(u['lastLoginAt'])),
                  StatusChip('${u['status']}'),
                ],
            ],
          );
        },
      ),
    ]);
  }
}

/// Extra per-user grants on top of the role (temporary or record-specific access).
class _UserGrants extends StatelessWidget {
  const _UserGrants({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/users/$userId/permissions')),
      compact: true,
      builder: (context, p, reload) {
        final extra = jsonList(p['extra'] ?? p['grants'] ?? p['items']);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 8),
          const NCardTitle('Extra permissions', subtitle: 'On top of the role. You can only grant what you hold.'),
          if (extra.isEmpty) Text('None.', style: t.text.caption()),
          for (final g in extra)
            NListRow(
              dense: true,
              title: '${g['grant']}',
              subtitle: [if (g['expiresAt'] != null) 'until ${Fmt.date(g['expiresAt'])}', if (g['reason'] != null) '${g['reason']}'].join(' · '),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                onPressed: () async {
                  try {
                    await context.api.post('/users/$userId/permissions/remove', body: {'grant': g['grant']});
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Grant a permission'),
              onPressed: () async {
                final r = await showFormSheet<Json>(
                  context,
                  title: 'Grant a permission',
                  fields: const [
                    FieldSpec('grant', 'Permission', required: true, hint: 'payroll:view:organization', helper: 'resource:action:scope'),
                    FieldSpec('expiresAt', 'Expires on', kind: FieldKind.date),
                    FieldSpec('reason', 'Reason', required: true),
                  ],
                  successMessage: 'Permission granted.',
                  submit: (v, key) async => jsonMap(await context.api.post('/users/$userId/permissions', body: v, idempotencyKey: key)),
                );
                if (r != null) reload();
              },
            ),
          ),
        ]);
      },
    );
  }
}

// ======================================================================= roles

class RolesTab extends StatefulWidget {
  const RolesTab({super.key});

  @override
  State<RolesTab> createState() => _RolesTabState();
}

class _RolesTabState extends State<RolesTab> {
  String? _role;
  Set<String>? _draft;
  bool _saving = false;

  static const _scopes = ['own', 'team', 'department', 'organization'];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final canEdit = me.can('roles', 'manage');
    return AsyncView<Json>(
      load: () async {
        final api = context.api;
        final catalog = jsonMap(await api.get('/roles/catalog'));
        final roles = jsonList(await api.get('/roles'));
        return {'catalog': catalog, 'roles': roles};
      },
      builder: (context, d, reload) {
        final catalog = jsonMap(d['catalog']);
        final allRoles = jsonList(d['roles']);
        final roles = [for (final r in allRoles) if (r['key'] != 'super_admin' || me.isSuperAdmin) r];
        if (roles.isEmpty) return const SizedBox.shrink();
        final resources = jsonMap(catalog['resources']);
        final actions = [for (final a in (catalog['actions'] as List? ?? const [])) '$a'];
        final role = roles.firstWhere((r) => r['key'] == (_role ?? roles.first['key']), orElse: () => roles.first);
        final current = _draft ?? {for (final g in (role['grants'] as List? ?? const [])) '$g'};
        final locked = role['key'] == 'super_admin' || !canEdit;
        String? scopeOf(String res, String act) {
          for (final s in _scopes.reversed) {
            if (current.contains('$res:$act:$s')) return s;
          }
          return null;
        }

        void setScope(String res, String act, String? s) {
          final next = {...current}..removeWhere((g) => g.startsWith('$res:$act:'));
          if (s != null) next.add('$res:$act:$s');
          setState(() => _draft = next);
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar(children: [
            NFilterChips<String>(
              value: '${role['key']}',
              onChanged: (v) => setState(() {
                _role = v;
                _draft = null;
              }),
              options: [for (final r in roles) NOption('${r['key']}', '${r['name']} (${r['userCount'] ?? 0})')],
            ),
            if (canEdit)
              NButton(
                label: 'New role',
                icon: Icons.add_rounded,
                compact: true,
                variant: NButtonVariant.accent,
                onPressed: () async {
                  final r = await showFormSheet<Json>(
                    context,
                    title: 'Create new role',
                    subtitle: 'Define a custom role with tailored permissions.',
                    fields: [
                      const FieldSpec('name', 'Role name', required: true, helper: 'Example: Shift Supervisor, Sales Lead'),
                      const FieldSpec('key', 'Role identifier (slug)', helper: 'Optional. Lowercase with underscores, e.g. shift_supervisor'),
                      const FieldSpec('description', 'Description', kind: FieldKind.multiline),
                      FieldSpec(
                        'copyFrom',
                        'Copy base permissions from',
                        kind: FieldKind.select,
                        options: [
                          for (final ro in roles) NOption('${ro['key']}', '${ro['name']}'),
                        ],
                        helper: 'Start with an existing role and tweak permissions.',
                      ),
                    ],
                    submitLabel: 'Create role',
                    successMessage: 'Role created.',
                    submit: (v, key) async => jsonMap(await context.api.post('/roles', body: v, idempotencyKey: key)),
                  );
                  if (r != null) {
                    setState(() {
                      _role = '${r['key']}';
                      _draft = null;
                    });
                    reload();
                  }
                },
              ),
            if (!locked && _draft != null) ...[
              NButton(
                label: 'Save role',
                compact: true,
                variant: NButtonVariant.accent,
                busy: _saving,
                onPressed: () async {
                  final c = await showNConfirm(context, title: 'Save ${role['name']}?', message: 'Everyone with this role gets the new permissions within a minute. The change is recorded with your reason.', confirmLabel: 'Save', reasonLabel: 'Reason');
                  if (!c.confirmed || !context.mounted) return;
                  setState(() => _saving = true);
                  try {
                    await context.api.put('/roles/${role['key']}', body: {'grants': current.toList()..sort()});
                    if (context.mounted) NToast.of(context).show('Role saved.');
                    setState(() => _draft = null);
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
              ),
              NButton(label: 'Discard', compact: true, variant: NButtonVariant.secondary, onPressed: () => setState(() => _draft = null)),
            ],
            if (!locked && _draft == null && role['system'] == true)
              NButton(
                label: 'Reset to default',
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  final c = await showNConfirm(context, title: 'Reset ${role['name']}?', message: 'Restores the default permissions for this role.', confirmLabel: 'Reset', destructive: true);
                  if (!c.confirmed || !context.mounted) return;
                  try {
                    await context.api.put('/roles/${role['key']}/reset');
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            if (canEdit && role['system'] != true && role['key'] != 'super_admin' && _draft == null)
              NButton(
                label: 'Delete role',
                icon: Icons.delete_outline_rounded,
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () async {
                  final count = (role['userCount'] as num?)?.toInt() ?? 0;
                  if (count > 0) {
                    showError(context, 'Cannot delete ${role['name']}: $count user(s) are assigned to it.');
                    return;
                  }
                  final c = await showNConfirm(
                    context,
                    title: 'Delete ${role['name']}?',
                    message: 'This custom role will be permanently removed.',
                    confirmLabel: 'Delete',
                    destructive: true,
                  );
                  if (!c.confirmed || !context.mounted) return;
                  try {
                    await context.api.delete('/roles/${role['key']}');
                    if (context.mounted) NToast.of(context).show('Role deleted.');
                    setState(() {
                      _role = null;
                      _draft = null;
                    });
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
          ]),
          if (role['key'] == 'super_admin') const Padding(padding: EdgeInsets.only(bottom: 12), child: NBanner(message: 'Super Admin always holds every permission and cannot be edited.', tone: NBannerTone.info)),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: (role['system'] == true ? t.muted : t.accent).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                role['system'] == true ? 'System Role' : 'Custom Role',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: role['system'] == true ? t.muted : t.accent),
              ),
            ),
            if (role['description'] != null && '${role['description']}'.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(child: Text('${role['description']}', style: t.text.caption(), overflow: TextOverflow.ellipsis)),
            ],
          ]),
          const SizedBox(height: 6),
          Text('Scopes: own < team < department < organization. Leaving an action empty means no access.', style: t.text.caption()),
          const SizedBox(height: 8),
          for (final res in resources.entries)
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text('${res.value}', style: t.text.body(weight: FontWeight.w500)),
              subtitle: Text(
                [for (final a in actions) if (scopeOf(res.key, a) != null) '$a: ${scopeOf(res.key, a)}'].join(' · ').ifEmpty('No access'),
                style: t.text.caption(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final a in actions)
                    SizedBox(
                      width: 190,
                      child: NSelect<String>(
                        label: Fmt.label(a),
                        value: scopeOf(res.key, a) ?? '',
                        enabled: !locked,
                        options: [const NOption('', 'None'), for (final s in _scopes) NOption(s, Fmt.label(s))],
                        onChanged: (v) => setScope(res.key, a, (v == null || v.isEmpty) ? null : v),
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
              ],
            ),
        ]);
      },
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ======================================================================= approval rules

class ApprovalRulesTab extends StatefulWidget {
  const ApprovalRulesTab({super.key});

  @override
  State<ApprovalRulesTab> createState() => _ApprovalRulesTabState();
}

class _ApprovalRulesTabState extends State<ApprovalRulesTab> {
  int _rev = 0;

  /// Stages are entered one per line: "Name | approverType | role-or-permission | mode | dueHours".
  Future<void> _edit([Json? r]) async {
    final api = context.api;
    String stagesText(Json r) => [
          for (final s in jsonList(r['stages'])) [s['name'], s['approverType'], s['role'] ?? s['permission'] ?? '', s['mode'] ?? 'single', s['dueHours'] ?? 48].join(' | '),
        ].join('\n');
    final res = await showFormSheet<Json>(
      context,
      title: r == null ? 'New approval rule' : 'Edit rule',
      initial: r == null
          ? const {'requestType': 'leave', 'stagesText': 'Manager | manager | | single | 48', 'preventSelfApproval': true, 'active': true, 'priority': 0}
          : {...r, 'stagesText': stagesText(r), 'minAmount': jsonMap(r['match'])['minAmount'], 'maxAmount': jsonMap(r['match'])['maxAmount']},
      fields: [
        FieldSpec('requestType', 'Request type', kind: FieldKind.select, required: true, options: [for (final e in requestTypeLabels.entries) NOption(e.key, e.value)]),
        const FieldSpec('name', 'Name'),
        const FieldSpec('priority', 'Priority (higher wins)', kind: FieldKind.number),
        const FieldSpec('minAmount', 'Only when amount ≥', kind: FieldKind.money),
        const FieldSpec('maxAmount', 'Only when amount ≤', kind: FieldKind.money),
        const FieldSpec(
          'stagesText',
          'Stages',
          kind: FieldKind.multiline,
          required: true,
          helper: 'One per line: Name | manager / department_head / role / permission | role key or resource:action | single / parallel_any / parallel_all | hours to respond',
        ),
        const FieldSpec('preventSelfApproval', 'Prevent self-approval', kind: FieldKind.toggle),
        const FieldSpec('requireRejectComment', 'Require a comment to reject', kind: FieldKind.toggle),
        const FieldSpec('active', 'Active', kind: FieldKind.toggle),
      ],
      successMessage: 'Rule saved.',
      submit: (v, key) async {
        final stages = <Json>[];
        for (final line in '${v['stagesText']}'.split('\n')) {
          final p = line.split('|').map((s) => s.trim()).toList();
          if (p.length < 2 || p[0].isEmpty) continue;
          final type = p[1];
          stages.add({
            'name': p[0],
            'approverType': type,
            if (type == 'role' && p.length > 2 && p[2].isNotEmpty) 'role': p[2],
            if (type == 'permission' && p.length > 2 && p[2].isNotEmpty) 'permission': p[2],
            'mode': p.length > 3 && p[3].isNotEmpty ? p[3] : 'single',
            'dueHours': p.length > 4 ? (int.tryParse(p[4]) ?? 48) : 48,
          });
        }
        final body = {
          'requestType': v['requestType'],
          if (v['name'] != null) 'name': v['name'],
          'priority': (v['priority'] as num?)?.round() ?? 0,
          'match': {if (v['minAmount'] != null) 'minAmount': v['minAmount'], if (v['maxAmount'] != null) 'maxAmount': v['maxAmount']},
          'stages': stages,
          'preventSelfApproval': v['preventSelfApproval'] == true,
          'requireRejectComment': v['requireRejectComment'] == true,
          'active': v['active'] == true,
        };
        return jsonMap(r == null ? await api.post('/approvals/rules', body: body, idempotencyKey: key) : await api.put('/approvals/rules/${r['id']}', body: body, idempotencyKey: key));
      },
    );
    if (!mounted) return;
    if (res != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    return InfoCard(
      title: 'Approval rules',
      subtitle: 'Without a matching rule, the built-in default chain applies. Payroll and salary stages never fall back to a different approver.',
      trailing: NButton(label: 'New rule', icon: Icons.add_rounded, compact: true, onPressed: () => _edit()),
      child: AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/approvals/rules')),
        builder: (context, items, reload) => items.isEmpty
            ? const NEmptyState(title: 'Using default chains', compact: true, icon: Icons.alt_route_rounded)
            : Column(children: [
                for (final r in items)
                  NListRow(
                    title: '${requestTypeLabels[r['requestType']] ?? r['requestType']} · ${r['name'] ?? 'Rule'}',
                    subtitle: jsonList(r['stages']).map((s) => '${s['name']} (${Fmt.label(s['approverType'])})').join(' → '),
                    onTap: () => _edit(r),
                    trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                      StatusChip(r['active'] == false ? 'inactive' : 'active'),
                      IconButton(
                        tooltip: 'Delete rule',
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        onPressed: () async {
                          final c = await showNConfirm(context, title: 'Delete this rule?', message: 'New requests use the default chain or another rule. Requests in progress keep their stages.', confirmLabel: 'Delete', destructive: true);
                          if (!c.confirmed || !context.mounted) return;
                          try {
                            await context.api.delete('/approvals/rules/${r['id']}');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ]),
                  ),
              ]),
      ),
    );
  }
}

// ======================================================================= expense categories

class ExpenseCategoriesTab extends StatefulWidget {
  const ExpenseCategoriesTab({super.key});

  @override
  State<ExpenseCategoriesTab> createState() => _ExpenseCategoriesTabState();
}

class _ExpenseCategoriesTabState extends State<ExpenseCategoriesTab> {
  int _rev = 0;

  Future<void> _edit([Json? c]) async {
    final api = context.api;
    final r = await showFormSheet<Json>(
      context,
      title: c == null ? 'New category' : 'Edit ${c['name']}',
      initial: c ?? const {'active': true},
      fields: const [
        FieldSpec('name', 'Name', required: true),
        FieldSpec('code', 'Code'),
        FieldSpec('perClaimLimit', 'Limit per claim', kind: FieldKind.money),
        FieldSpec('monthlyLimit', 'Monthly limit per person', kind: FieldKind.money),
        FieldSpec('receiptRequiredAbove', 'Receipt required above', kind: FieldKind.money),
        FieldSpec('active', 'Active', kind: FieldKind.toggle),
      ],
      successMessage: 'Category saved.',
      submit: (v, key) async {
        final body = {...v, 'active': v['active'] == true};
        return jsonMap(c == null ? await api.post('/expenses/categories', body: body, idempotencyKey: key) : await api.put('/expenses/categories/${c['id']}', body: body, idempotencyKey: key));
      },
    );
    if (!mounted) return;
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final cur = context.me.currency;
    return InfoCard(
      title: 'Expense categories and limits',
      trailing: NButton(label: 'New', icon: Icons.add_rounded, compact: true, onPressed: () => _edit()),
      child: AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/expenses/categories')),
        builder: (context, items, _) => NDataTable(
          columns: const [NColumn('Category', flex: 3), NColumn('Per claim', numeric: true), NColumn('Monthly', numeric: true), NColumn('Receipt above', numeric: true, hideOnTablet: true), NColumn('Status')],
          onTapRow: (i) => _edit(items[i]),
          rows: [
            for (final c in items)
              [
                Text('${c['name']}'),
                Text(c['perClaimLimit'] == null ? '—' : Fmt.money(c['perClaimLimit'], cur)),
                Text(c['monthlyLimit'] == null ? '—' : Fmt.money(c['monthlyLimit'], cur)),
                Text(c['receiptRequiredAbove'] == null ? '—' : Fmt.money(c['receiptRequiredAbove'], cur)),
                StatusChip(c['active'] == false ? 'inactive' : 'active'),
              ],
          ],
        ),
      ),
    );
  }
}

// ======================================================================= notifications admin

class NotificationAdminTab extends StatefulWidget {
  const NotificationAdminTab({super.key});

  @override
  State<NotificationAdminTab> createState() => _NotificationAdminTabState();
}

class _NotificationAdminTabState extends State<NotificationAdminTab> {
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InfoCard(
        title: 'Email templates',
        subtitle: 'Override the built-in wording. Placeholders like {{name}} are filled from the event.',
        trailing: NButton(
          label: 'New template',
          icon: Icons.add_rounded,
          compact: true,
          onPressed: () async {
            final r = await showFormSheet<Json>(
              context,
              title: 'Template',
              initial: const {'channel': 'email', 'active': true},
              fields: const [
                FieldSpec('event', 'Event', required: true, hint: 'approval_pending'),
                FieldSpec('channel', 'Channel', kind: FieldKind.select, options: [NOption('email', 'Email'), NOption('in_app', 'In app')]),
                FieldSpec('subject', 'Subject'),
                FieldSpec('body', 'Body', kind: FieldKind.multiline, required: true),
                FieldSpec('active', 'Active', kind: FieldKind.toggle),
              ],
              successMessage: 'Template saved.',
              submit: (v, key) async => jsonMap(await context.api.put('/notifications/templates', body: {...v, 'active': v['active'] == true}, idempotencyKey: key)),
            );
            if (r != null) setState(() => _rev++);
          },
        ),
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/notifications/templates')),
          builder: (context, items, reload) => items.isEmpty
              ? Text('Using built-in templates.', style: t.text.body(color: t.muted))
              : Column(children: [
                  for (final tp in items)
                    NListRow(
                      dense: true,
                      title: '${Fmt.label(tp['event'])} · ${Fmt.label(tp['channel'])}',
                      subtitle: '${tp['subject'] ?? ''}',
                      trailing: IconButton(
                        tooltip: 'Delete template',
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        onPressed: () async {
                          try {
                            await context.api.delete('/notifications/templates/${tp['id']}');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ),
                ]),
        ),
      ),
      const SizedBox(height: 14),
      InfoCard(
        title: 'Delivery history',
        child: PagedList(
          path: '/notifications/deliveries',
          emptyTitle: 'No deliveries yet',
          itemBuilder: (_, __, ___) => const SizedBox.shrink(),
          wrap: (context, items, _) => NDataTable(
            columns: const [NColumn('Event', flex: 2), NColumn('Channel'), NColumn('To', flex: 2, hideOnTablet: true), NColumn('When'), NColumn('Status'), NColumn('Error', flex: 2, hideOnTablet: true)],
            rows: [
              for (final d in items)
                [Text(Fmt.label(d['event'])), Text(Fmt.label(d['channel'])), Text('${d['to'] ?? ''}'), Text(Fmt.relative(d['createdAt'])), StatusChip('${d['status']}'), Text('${d['error'] ?? ''}', maxLines: 2)],
            ],
          ),
        ),
      ),
    ]);
  }
}

// ======================================================================= integrations

class IntegrationsTab extends StatelessWidget {
  const IntegrationsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final canConfigure = context.me.can('integrations', 'configure', 'organization');
    return AsyncView<List<Json>>(
      load: () async => jsonList(await context.api.get('/integrations')),
      builder: (context, items, reload) => CardGrid(minTileWidth: 360, children: [
        for (final i in items)
          InfoCard(
            title: switch (i['provider']) {
              'meta_leads' => 'Meta lead ads',
              'whatsapp' => 'WhatsApp',
              _ => 'SMS',
            },
            trailing: StatusChip('${i['status']}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (i['available'] != true)
                Text('Not available in this version.', style: t.text.body(color: t.muted))
              else ...[
                Text('New leads from your Facebook and Instagram lead forms arrive in CRM within minutes, de-duplicated by phone and email.', style: t.text.body(color: t.muted)),
                const SizedBox(height: 8),
                if (i['webhookConfigured'] != true) const NBanner(message: 'The server is missing META_APP_SECRET or META_VERIFY_TOKEN, so Meta cannot deliver leads yet.', tone: NBannerTone.warning),
                if (i['connection'] != null) ...[
                  NInfoRow(label: 'Page', value: '${jsonMap(jsonMap(i['connection'])['config'])['pageId'] ?? ''}'),
                  NInfoRow(label: 'Last sync', value: jsonMap(i['connection'])['lastSyncAt'] == null ? 'Never' : Fmt.relative(jsonMap(i['connection'])['lastSyncAt'])),
                  if (jsonMap(i['connection'])['lastError'] != null) NBanner(message: '${jsonMap(i['connection'])['lastError']}', tone: NBannerTone.danger),
                  NInfoRow(label: 'Last 24 hours', value: jsonMap(i['last24h']).entries.map((e) => '${Fmt.label(e.key)}: ${e.value}').join(' · ')),
                ],
                const SizedBox(height: 8),
                if (canConfigure)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    NButton(
                      label: i['connection'] == null ? 'Connect' : 'Reconnect',
                      compact: true,
                      onPressed: () async {
                        final r = await showFormSheet<Json>(
                          context,
                          title: 'Connect Meta lead ads',
                          subtitle: 'The token is checked with Meta, then stored encrypted. It is never shown again.',
                          fields: const [
                            FieldSpec('pageId', 'Facebook Page ID', required: true),
                            FieldSpec('accessToken', 'Page access token', kind: FieldKind.password, required: true),
                            FieldSpec('defaultOwnerEmployeeId', 'Assign new leads to', kind: FieldKind.asyncSelect, loadOptions: Lookups.employees),
                            FieldSpec('formIdsText', 'Only these form IDs (optional)', hint: '1234567890, 2345678901'),
                          ],
                          successMessage: 'Saved.',
                          submit: (v, key) async {
                            final body = <String, dynamic>{...v}..remove('formIdsText');
                            if (v['formIdsText'] != null) body['formIds'] = [for (final s in '${v['formIdsText']}'.split(',')) if (s.trim().isNotEmpty) s.trim()];
                            return jsonMap(await context.api.put('/integrations/meta', body: body, idempotencyKey: key));
                          },
                        );
                        if (r != null) reload();
                      },
                    ),
                    if (i['connection'] != null)
                      NButton(label: 'Sync log', compact: true, variant: NButtonVariant.secondary, onPressed: () => _logs(context, '${i['provider']}')),
                    if (i['connection'] != null && i['status'] != 'disabled')
                      NButton(
                        label: 'Disconnect',
                        compact: true,
                        variant: NButtonVariant.secondary,
                        onPressed: () async {
                          final c = await showNConfirm(context, title: 'Disconnect?', message: 'New leads stop arriving. Existing leads stay in CRM.', confirmLabel: 'Disconnect', destructive: true);
                          if (!c.confirmed || !context.mounted) return;
                          try {
                            await context.api.delete('/integrations/${i['provider']}');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                  ]),
              ],
            ]),
          ),
      ]),
    );
  }

  Future<void> _logs(BuildContext context, String provider) {
    final api = context.api;
    return showNSheet<void>(
      context,
      title: 'Sync log',
      builder: (ctx) => ApiScope(
        api: api,
        child: AsyncView<List<Json>>(
          load: () async => jsonList(await api.get('/integrations/$provider/logs')),
          builder: (ctx, items, reload) => items.isEmpty
              ? const NEmptyState(title: 'Nothing synced yet')
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final l in items)
                    NListRow(
                      dense: true,
                      title: '${l['externalId']} · ${Fmt.label(l['outcome'])}',
                      subtitle: '${Fmt.dateTime(l['at'])} · ${l['attempts'] ?? 0} attempts${l['error'] != null ? ' · ${l['error']}' : ''}',
                      trailing: l['outcome'] == 'failed'
                          ? TextButton(
                              onPressed: () async {
                                try {
                                  await api.post('/integrations/logs/${l['id']}/retry');
                                  reload();
                                } catch (e) {
                                  if (ctx.mounted) showError(ctx, e);
                                }
                              },
                              child: const Text('Retry'),
                            )
                          : null,
                    ),
                ]),
        ),
      ),
    );
  }
}

