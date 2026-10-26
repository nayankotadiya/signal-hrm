import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../app/services.dart';
import 'async_view.dart';
import 'format.dart';

class ChatMessage {
  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.actionLabel,
    this.actionCallback,
  });

  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String? actionLabel;
  final VoidCallback? actionCallback;
}

/// Floating AI Assistant FAB that opens the Signal HR Voice & Text Chatbot.
class AiAssistantFab extends StatelessWidget {
  const AiAssistantFab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);

    return FloatingActionButton.small(
      heroTag: 'signal_ai_assistant_fab',
      tooltip: 'Signal HR AI Assistant',
      backgroundColor: t.accent,
      foregroundColor: Colors.white,
      elevation: 4,
      onPressed: () => showAiAssistantSheet(context),
      child: const Icon(Icons.auto_awesome_rounded, size: 20),
    );
  }
}

/// Opens the Signal HR AI Voice & Text Chatbot sheet.
void showAiAssistantSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _AiAssistantSheetContent(),
  );
}

class _AiAssistantSheetContent extends StatefulWidget {
  const _AiAssistantSheetContent();

  @override
  State<_AiAssistantSheetContent> createState() => _AiAssistantSheetContentState();
}

class _AiAssistantSheetContentState extends State<_AiAssistantSheetContent> {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isListening = false;
  bool _speakReplies = false;

  @override
  void initState() {
    super.initState();
    // Default welcome message in English
    _messages.add(
      ChatMessage(
        text: "Hello! I am your Signal HR AI Assistant. How can I help you today? You can ask about your attendance, shift hours, leave balances, or upcoming holidays in English.",
        isUser: false,
        timestamp: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleUserMessage(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    setState(() {
      _messages.add(ChatMessage(text: clean, isUser: true, timestamp: DateTime.now()));
      _isLoading = true;
    });
    _textCtrl.clear();
    _scrollToBottom();

    final response = await _generateAiReply(clean);

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _messages.add(response);
    });
    _scrollToBottom();
  }

  Future<ChatMessage> _generateAiReply(String query) async {
    final lower = query.toLowerCase();
    final api = context.api;
    final now = DateTime.now();

    // 1. Attendance status queries
    if (lower.contains('status') || lower.contains('attendance') || lower.contains('checked in') || lower.contains('check in') || lower.contains('check out')) {
      try {
        final today = jsonMap(await api.get('/attendance/today'));
        final state = '${today['state'] ?? 'not_checked_in'}';
        final record = jsonMap(today['record']);
        final location = jsonMap(today['location']);
        final locName = location['name'] ?? 'Office';

        if (state == 'checked_in') {
          final inAt = record['checkIn']?['at'] as String?;
          final timeStr = inAt != null ? Fmt.time(inAt) : 'earlier';
          final worked = (record['workedMinutes'] as num?)?.toInt() ?? 0;
          return ChatMessage(
            text: "✅ You are currently Checked In at $locName. Your session started at $timeStr. You have logged ${Fmt.minutes(worked)} so far today.",
            isUser: false,
            timestamp: now,
            actionLabel: "Go to Attendance",
            actionCallback: () {
              Navigator.of(context).pop();
              context.go('/time/attendance');
            },
          );
        } else if (state == 'checked_out') {
          final worked = (record['workedMinutes'] as num?)?.toInt() ?? 0;
          return ChatMessage(
            text: "🏁 You have already Checked Out for today. Total time logged: ${Fmt.minutes(worked)}. Rest well!",
            isUser: false,
            timestamp: now,
            actionLabel: "View Summary",
            actionCallback: () {
              Navigator.of(context).pop();
              context.go('/time/attendance');
            },
          );
        } else {
          return ChatMessage(
            text: "⚠️ You are Not Checked In yet for today ($now). Remember that regular shift hours end at 7:00 PM. Would you like to record your check-in now?",
            isUser: false,
            timestamp: now,
            actionLabel: "Check In Now",
            actionCallback: () {
              Navigator.of(context).pop();
              context.go('/time/attendance');
            },
          );
        }
      } catch (_) {
        return ChatMessage(
          text: "You can view and record your daily attendance in the Time tracking section.",
          isUser: false,
          timestamp: now,
          actionLabel: "Open Attendance",
          actionCallback: () {
            Navigator.of(context).pop();
            context.go('/time/attendance');
          },
        );
      }
    }

    // 2. Punctuality / Score queries
    if (lower.contains('punctuality') || lower.contains('score') || lower.contains('performance') || lower.contains('rating')) {
      try {
        final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
        final cal = jsonMap(await api.get('/attendance/calendar', query: {'month': monthKey}));
        final summary = jsonMap(cal['summary']);
        final present = (summary['present'] as num?)?.toInt() ?? 0;
        final lateCount = (summary['late'] as num?)?.toInt() ?? 0;
        final halfDay = (summary['half_day'] as num?)?.toInt() ?? 0;
        final total = present + lateCount + halfDay;
        final score = total == 0 ? 100 : (((present * 1.0 + halfDay * 0.5) / total) * 100).round();

        return ChatMessage(
          text: "⭐ Your AI Punctuality Score for this month is $score%.\n• Present on-time: $present days\n• Late arrivals: $lateCount days\n• Half-days: $halfDay days\nKeep up the great consistency!",
          isUser: false,
          timestamp: now,
        );
      } catch (_) {
        return ChatMessage(
          text: "Your monthly punctuality is tracked based on your on-time punches and shift completions.",
          isUser: false,
          timestamp: now,
        );
      }
    }

    // 3. Leave balance queries
    if (lower.contains('leave') || lower.contains('vacation') || lower.contains('holiday balance') || lower.contains('day off')) {
      try {
        final balances = jsonList(await api.get('/leave/balances'));
        if (balances.isNotEmpty) {
          final lines = balances.map((b) => "• ${b['leaveTypeName'] ?? 'Leave'}: ${b['balance'] ?? 0} days remaining").join('\n');
          return ChatMessage(
            text: "🏖️ Here are your current Leave Balances:\n$lines",
            isUser: false,
            timestamp: now,
            actionLabel: "Apply for Leave",
            actionCallback: () {
              Navigator.of(context).pop();
              context.go('/time/leave');
            },
          );
        }
      } catch (_) {}
      return ChatMessage(
        text: "You can review all your leave balances and request time off under Time > Leave.",
        isUser: false,
        timestamp: now,
        actionLabel: "View Leaves",
        actionCallback: () {
          Navigator.of(context).pop();
          context.go('/time/leave');
        },
      );
    }

    // 4. Shift & work hours queries
    if (lower.contains('shift') || lower.contains('hour') || lower.contains('timing') || lower.contains('schedule') || lower.contains('7:00') || lower.contains('evening')) {
      return ChatMessage(
        text: "⏰ Standard Office Shift:\n• Shift Hours: 09:00 AM to 07:00 PM (Monday to Saturday)\n• Lunch & Rest Break: 1 hour\n• Check-Out Reminder: Automated 7:00 PM evening reminder via In-App, Slack & WhatsApp.",
        isUser: false,
        timestamp: now,
        actionLabel: "View Shifts",
        actionCallback: () {
          Navigator.of(context).pop();
          context.go('/time/shifts');
        },
      );
    }

    // 5. Holiday queries
    if (lower.contains('holiday') || lower.contains('festival') || lower.contains('off day')) {
      try {
        final holidays = jsonList(await api.get('/attendance/holidays'));
        if (holidays.isNotEmpty) {
          final next = holidays.first;
          return ChatMessage(
            text: "🎉 Upcoming Company Holiday:\n• ${next['name'] ?? 'Holiday'}: ${Fmt.date(next['date'] ?? '')}\nEnjoy your time with family!",
            isUser: false,
            timestamp: now,
          );
        }
      } catch (_) {}
      return ChatMessage(
        text: "You can explore the full company holiday calendar in Time > Holidays.",
        isUser: false,
        timestamp: now,
        actionLabel: "View Calendar",
        actionCallback: () {
          Navigator.of(context).pop();
          context.go('/time/calendar');
        },
      );
    }

    // 6. Default AI fallback response
    return ChatMessage(
      text: "I can help you with anything related to Signal HRM at Bulletproof Brands:\n"
          "• 'What is my attendance status today?'\n"
          "• 'What is my punctuality score?'\n"
          "• 'How many leave days do I have left?'\n"
          "• 'What are my shift hours and 7 PM checkout rules?'\n"
          "• 'When is the next company holiday?'",
      isUser: false,
      timestamp: now,
    );
  }

  void _simulateVoiceInput() {
    setState(() => _isListening = !_isListening);
    if (_isListening) {
      NToast.of(context).show("Listening in English... (say: 'What is my attendance status?')");
      Timer(const Duration(seconds: 2), () {
        if (!mounted || !_isListening) return;
        setState(() => _isListening = false);
        _handleUserMessage("What is my attendance status today?");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.75,
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            decoration: BoxDecoration(
              color: t.muted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  ),
                  child: Icon(Icons.auto_awesome_rounded, size: 18, color: t.accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Signal HR AI Assistant',
                        style: t.text.title().copyWith(fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                      Text(
                        'Voice & Chat HR Intelligence (English)',
                        style: t.text.caption(color: t.muted).copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _speakReplies ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                    color: _speakReplies ? t.accent : t.muted,
                    size: 20,
                  ),
                  tooltip: _speakReplies ? 'Mute voice replies' : 'Speak replies aloud',
                  onPressed: () => setState(() => _speakReplies = !_speakReplies),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Quick Suggestion Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _PromptChip(
                  label: "🕒 Today's Status",
                  onTap: () => _handleUserMessage("What is my attendance status today?"),
                  tokens: t,
                ),
                _PromptChip(
                  label: "⭐ Punctuality Score",
                  onTap: () => _handleUserMessage("What is my punctuality score?"),
                  tokens: t,
                ),
                _PromptChip(
                  label: "🏖️ Leave Balance",
                  onTap: () => _handleUserMessage("How many leaves do I have left?"),
                  tokens: t,
                ),
                _PromptChip(
                  label: "⏰ Shift & 7 PM Rule",
                  onTap: () => _handleUserMessage("What are my shift hours and check-out rules?"),
                  tokens: t,
                ),
                _PromptChip(
                  label: "🎉 Next Holiday",
                  onTap: () => _handleUserMessage("When is the next holiday?"),
                  tokens: t,
                ),
              ],
            ),
          ),

          // Message List
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, idx) {
                final msg = _messages[idx];
                return _ChatBubble(message: msg, tokens: t);
              },
            ),
          ),

          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                  ),
                  const SizedBox(width: 8),
                  Text('Signal AI is thinking...', style: t.text.caption(color: t.muted)),
                ],
              ),
            ),

          // Input Bar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.card,
              border: Border(top: BorderSide(color: t.cardBorder.withValues(alpha: 0.5))),
            ),
            child: Row(
              children: [
                // Voice Mic Button
                IconButton(
                  icon: Icon(
                    _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: _isListening ? t.red : t.accent,
                  ),
                  tooltip: 'Voice command (English)',
                  onPressed: _simulateVoiceInput,
                ),
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _handleUserMessage,
                    style: t.text.body(),
                    decoration: InputDecoration(
                      hintText: 'Ask in English (e.g. "What is my status?")...',
                      hintStyle: t.text.caption(color: t.muted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        borderSide: BorderSide(color: t.cardBorder),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.send_rounded, color: t.accent),
                  onPressed: () => _handleUserMessage(_textCtrl.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptChip extends StatelessWidget {
  const _PromptChip({required this.label, required this.onTap, required this.tokens});
  final String label;
  final VoidCallback onTap;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: tokens.text.caption(weight: FontWeight.w600).copyWith(fontSize: 11)),
        backgroundColor: tokens.isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        onPressed: onTap,
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message, required this.tokens});
  final ChatMessage message;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isUser ? tokens.accent : (tokens.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9));
    final fg = isUser ? Colors.white : tokens.ink;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16).copyWith(
                bottomRight: isUser ? const Radius.circular(2) : const Radius.circular(16),
                bottomLeft: !isUser ? const Radius.circular(2) : const Radius.circular(16),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.text,
                  style: tokens.text.body().copyWith(color: fg, height: 1.4, fontSize: 13),
                ),
                if (message.actionLabel != null && message.actionCallback != null) ...[
                  const SizedBox(height: 8),
                  NButton(
                    label: message.actionLabel!,
                    compact: true,
                    variant: NButtonVariant.secondary,
                    onPressed: message.actionCallback!,
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              Fmt.time(message.timestamp.toIso8601String()),
              style: tokens.text.caption(color: tokens.muted).copyWith(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
