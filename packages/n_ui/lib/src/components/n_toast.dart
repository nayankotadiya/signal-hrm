import 'dart:async';

import 'package:flutter/widgets.dart';

import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

@immutable
class NToastAction {
  const NToastAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

@immutable
class NToastData {
  const NToastData(this.id, this.message, this.action);
  final int id;
  final String message;
  final NToastAction? action;
}

/// Shows toasts: dark pill, bottom-center, slides up, announced politely to screen readers,
/// optional action (Undo) in lime. One toast at a time; a new one replaces the current.
class NToastController extends ChangeNotifier {
  NToastData? _current;
  Timer? _timer;
  int _seq = 0;

  NToastData? get current => _current;

  void show(String message, {NToastAction? action, Duration duration = const Duration(seconds: 4)}) {
    _timer?.cancel();
    _current = NToastData(++_seq, message, action);
    _timer = Timer(duration, hide);
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Place once above the app content (inside MaterialApp.builder). Read with [NToast.of].
class NToastHost extends StatefulWidget {
  const NToastHost({super.key, required this.child, this.bottomInset = 24});
  final Widget child;

  /// Extra distance from the bottom (e.g. above the floating mobile nav).
  final double bottomInset;

  @override
  State<NToastHost> createState() => _NToastHostState();
}

class _NToastHostState extends State<NToastHost> {
  final NToastController _controller = NToastController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NToast(
      controller: _controller,
      child: Stack(children: [
        Positioned.fill(child: widget.child),
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + widget.bottomInset,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _ToastView(data: _controller.current, onDismiss: _controller.hide),
          ),
        ),
      ]),
    );
  }
}

class NToast extends InheritedWidget {
  const NToast({super.key, required this.controller, required super.child});
  final NToastController controller;

  static NToastController of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<NToast>();
    assert(w != null, 'No NToastHost above this context');
    return w!.controller;
  }

  @override
  bool updateShouldNotify(NToast oldWidget) => controller != oldWidget.controller;
}

class _ToastView extends StatefulWidget {
  const _ToastView({required this.data, required this.onDismiss});
  final NToastData? data;
  final VoidCallback onDismiss;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> {
  NToastData? _shown;

  @override
  void didUpdateWidget(_ToastView old) {
    super.didUpdateWidget(old);
    if (widget.data != null) _shown = widget.data; // keep the last content while sliding out
  }

  @override
  void initState() {
    super.initState();
    _shown = widget.data;
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final d = NMotion.durations(context);
    final visible = widget.data != null;
    final data = _shown;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 1.4),
        duration: d.toast,
        curve: NCurves.emphasized,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: d.toast,
          child: Center(
            child: data == null
                ? const SizedBox.shrink()
                : Semantics(
                    liveRegion: true,
                    container: true,
                    child: Container(
                      key: ValueKey(data.id),
                      constraints: const BoxConstraints(maxWidth: 520, minHeight: 48),
                      padding: const EdgeInsetsDirectional.only(start: 20, end: 8, top: 6, bottom: 6),
                      decoration: BoxDecoration(
                        color: t.actionCard,
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10))],
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(data.message, style: t.text.body(color: t.actionCardText)),
                          ),
                        ),
                        if (data.action != null) ...[
                          const SizedBox(width: 8),
                          Semantics(
                            button: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                data.action!.onPressed();
                                widget.onDismiss();
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Container(
                                  constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  alignment: Alignment.center,
                                  child: Text(
                                    data.action!.label,
                                    style: t.text.button(color: t.lime).copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ] else
                          const SizedBox(width: 12),
                      ]),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
