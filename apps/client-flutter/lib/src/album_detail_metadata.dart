part of '../intmusic_client.dart';

bool _albumMetadataHasContent(
  Map<String, dynamic> profile,
  List<Map<String, dynamic>> credits,
) {
  if (credits.isNotEmpty) return true;
  return profile.entries.any((entry) {
    if (entry.key == 'title' || entry.key == 'album_artist_display') {
      return false;
    }
    final value = entry.value;
    return value is List
        ? value.isNotEmpty
        : value?.toString().trim().isNotEmpty == true;
  });
}

class _AlbumMetadataOverview extends StatelessWidget {
  const _AlbumMetadataOverview({
    required this.profile,
    required this.credits,
    required this.onOpenArtist,
  });

  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> credits;
  final Future<void> Function(int) onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final facts = <(String, dynamic)>[
      ('Release type', profile['release_type']),
      ('Edition title', profile['edition_title']),
      ('Release status', profile['release_status']),
      ('Release date', profile['date']),
      ('Original release date', profile['original_date']),
      ('Year', profile['year']),
      ('Total discs', profile['total_discs']),
      ('Release country', profile['country']),
      ('Language', profile['language']),
      ('Media format', profile['media_format']),
      ('Packaging', profile['packaging']),
      ('Barcode / UPC', profile['barcode']),
    ].where((entry) => entry.$2?.toString().trim().isNotEmpty == true).toList();
    final lists =
        <(String, dynamic)>[
              ('Catalog numbers', profile['catalog_numbers']),
              ('Record labels', profile['labels']),
              ('Publishers', profile['publishers']),
              ('Genres', profile['genres']),
              ('Styles', profile['styles']),
              ('Moods', profile['moods']),
            ]
            .where((entry) => entry.$2 is List && (entry.$2 as List).isNotEmpty)
            .toList();
    final notes = <(String, dynamic)>[
      ('Copyright', profile['copyright']),
      ('Phonographic copyright', profile['phonographic_copyright']),
      ('Editorial notes', profile['notes']),
    ].where((entry) => entry.$2?.toString().trim().isNotEmpty == true).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (facts.isNotEmpty || lists.isNotEmpty || notes.isNotEmpty)
            _AlbumDetailMetadataCard(
              icon: Icons.info_outline_rounded,
              title: _tr(context, 'Release information'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (facts.isNotEmpty)
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: facts
                          .map(
                            (entry) => _AlbumMetadataFact(
                              label: _tr(context, entry.$1),
                              value: entry.$2.toString(),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  for (final entry in lists) ...[
                    const SizedBox(height: 14),
                    Text(
                      _tr(context, entry.$1),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: (entry.$2 as List)
                          .map((value) => Chip(label: Text(value.toString())))
                          .toList(growable: false),
                    ),
                  ],
                  for (final entry in notes) ...[
                    const SizedBox(height: 14),
                    Text(
                      _tr(context, entry.$1),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    SelectionArea(child: Text(entry.$2.toString())),
                  ],
                ],
              ),
            ),
          if (credits.isNotEmpty) ...[
            if (facts.isNotEmpty || lists.isNotEmpty || notes.isNotEmpty)
              const SizedBox(height: 14),
            _AlbumDetailMetadataCard(
              icon: Icons.groups_2_outlined,
              title: _tr(context, 'Credits'),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: credits
                    .map((credit) {
                      final artistId = _intValue(credit['artist_id']);
                      final role = credit['role']?.toString() ?? '';
                      final roleLabel =
                          _albumCreditRoles
                              .where((entry) => entry.$1 == role)
                              .map((entry) => entry.$2)
                              .firstOrNull ??
                          'Credit';
                      return ActionChip(
                        avatar: Icon(
                          artistId == null ? Icons.badge_outlined : Icons.link,
                          size: 17,
                        ),
                        label: Text(
                          '${_tr(context, roleLabel)} · ${credit['display_name'] ?? ''}',
                        ),
                        onPressed: artistId == null
                            ? null
                            : () => unawaited(onOpenArtist(artistId)),
                      );
                    })
                    .toList(growable: false),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Divider(color: IntMusicTheme.of(context).stroke),
        ],
      ),
    );
  }
}

class _AlbumDetailMetadataCard extends StatelessWidget {
  const _AlbumDetailMetadataCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: tokens.accent),
                const SizedBox(width: 9),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _AlbumMetadataFact extends StatelessWidget {
  const _AlbumMetadataFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 138, maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
