part of '../intmusic_client.dart';

/// All transient page and dialog errors share dismissal and history behavior.
class _ErrorBanner extends StatefulWidget {
  const _ErrorBanner({required this.message, this.onDismiss});

  final String message;
  final VoidCallback? onDismiss;

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  Timer? _timer;
  bool _dismissed = false;

  void _restart() {
    _timer?.cancel();
    _dismissed = false;
    ClientLog.event('ui.notice', level: 'error', message: widget.message);
    _timer = Timer(const Duration(seconds: 8), _dismiss);
  }

  void _dismiss() {
    if (!mounted || _dismissed) return;
    _timer?.cancel();
    setState(() => _dismissed = true);
    widget.onDismiss?.call();
  }

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(_ErrorBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colors.onErrorContainer, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            IconButton(
              key: const Key('dismiss-error'),
              tooltip: _tr(context, 'Close'),
              color: colors.onErrorContainer,
              onPressed: _dismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
