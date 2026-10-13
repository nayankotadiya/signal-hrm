import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import 'format.dart';

const _positive = {'approved', 'active', 'present', 'done', 'completed', 'paid', 'verified', 'won', 'connected', 'finalized', 'accepted', 'healthy', 'success', 'reviewed_ok', 'acknowledged', 'resolved', 'sent', 'stored', 'ready', 'booked', 'settled', 'within_radius', 'confirmed', 'actioned', 'succeeded'};
const _warning = {'pending', 'submitted', 'late', 'half_day', 'in_progress', 'in_review', 'review', 'pending_approval', 'clarification', 'probation', 'onboarding', 'notice', 'scheduled', 'invited', 'calculated', 'open', 'retrying', 'pending_correction', 'incomplete', 'proposal', 'qualified', 'contacted', 'running', 'uploaded', 'escalated', 'expiring', 'queued', 'building', 'exception_pending', 'on_probation', 'extended', 'interested', 'meeting_scheduled'};
const _negative = {'rejected', 'absent', 'failed', 'lost', 'blocked', 'suspended', 'error', 'expired', 'cancelled', 'exited', 'reviewed_concern', 'denied', 'failure', 'outside_radius', 'accuracy_too_low', 'unavailable', 'critical', 'high', 'inactive', 'unreachable', 'no_location'};
const _info = {'new', 'todo', 'on_leave', 'holiday', 'weekly_off', 'draft', 'live', 'info', 'medium', 'low'};

NTone toneFor(String status) {
  if (_positive.contains(status)) return NTone.positive;
  if (_warning.contains(status)) return NTone.warning;
  if (_negative.contains(status)) return NTone.negative;
  if (_info.contains(status)) return NTone.info;
  return NTone.neutral;
}

/// Status chip from a backend status value. Text label + icon, never colour alone.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});
  final String? status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final s = status ?? 'unknown';
    return NStatusChip.status(label: label ?? Fmt.label(s), tone: toneFor(s));
  }
}
