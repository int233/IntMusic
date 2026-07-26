part of '../intmusic_client.dart';

class _SourcePill extends StatelessWidget {
  const _SourcePill({required this.label, required this.manual});

  final String label;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: manual
            ? tokens.accent.withValues(alpha: 0.14)
            : tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: manual ? tokens.accent.withValues(alpha: 0.34) : tokens.stroke,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: manual ? tokens.accent : tokens.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
