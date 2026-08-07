part of '../intmusic_client.dart';

extension _AlbumEditorSections on _AlbumEditorDialogState {
  Widget _albumInformationSection() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        _AlbumEditorIntro(
          icon: Icons.auto_awesome_outlined,
          title: _tr(context, 'Album metadata'),
          body: _tr(
            context,
            'Album fields describe the release. Track-specific exceptions remain editable on each track.',
          ),
        ),
        const SizedBox(height: 18),
        _albumFieldGroup('Identity and edition', const [
          'title',
          'sort_title',
          'subtitle',
          'release_type',
          'edition_title',
          'release_status',
        ]),
        _albumFieldGroup('Release details', const [
          'date',
          'original_date',
          'year',
          'total_discs',
          'country',
          'language',
          'media_format',
          'packaging',
        ]),
        _albumFieldGroup('Publishing and identifiers', const [
          'barcode',
          'catalog_numbers',
          'labels',
          'publishers',
        ]),
        _albumFieldGroup('Classification', const ['genres', 'styles', 'moods']),
        _albumFieldGroup('Rights and notes', const [
          'copyright',
          'phonographic_copyright',
          'notes',
        ]),
      ],
    );
  }

  Widget _albumFieldGroup(String title, List<String> keys) {
    final fields = _albumProfileFields
        .where((field) => keys.contains(field.$1))
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: _AlbumEditorCard(
        title: _tr(context, title),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth < 680
                ? constraints.maxWidth
                : (constraints.maxWidth - 14) / 2;
            return Wrap(
              spacing: 14,
              runSpacing: 14,
              children: fields
                  .map((field) {
                    final multiline = field.$3 == 'multiline';
                    return SizedBox(
                      width: multiline ? constraints.maxWidth : width,
                      child: TextField(
                        controller: _controllers[field.$1],
                        keyboardType: field.$3 == 'integer'
                            ? TextInputType.number
                            : TextInputType.text,
                        minLines: multiline ? 3 : 1,
                        maxLines: multiline ? 6 : 1,
                        decoration: InputDecoration(
                          labelText: _tr(context, field.$2),
                          helperText: field.$3 == 'list'
                              ? _tr(
                                  context,
                                  'Separate multiple values with semicolons',
                                )
                              : null,
                          helperMaxLines: 2,
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            );
          },
        ),
      ),
    );
  }

  Widget _albumCreditsSection() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          children: [
            Expanded(
              child: _AlbumEditorIntro(
                icon: Icons.groups_2_outlined,
                title: _tr(context, 'People and organizations'),
                body: _tr(
                  context,
                  'Add any number of performers, creators, engineers, labels, publishers, and distributors. Each entry may link to an artist.',
                ),
              ),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: () => _change(() {
                _credits.add(<String, dynamic>{
                  'role': 'producer',
                  'display_name': '',
                  'artist_id': null,
                });
              }),
              icon: const Icon(Icons.add),
              label: Text(_tr(context, 'Add credit')),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_credits.isEmpty)
          _AlbumEditorEmptyState(
            icon: Icons.person_add_alt_1_outlined,
            title: _tr(context, 'No manual credits'),
            body: _tr(
              context,
              'Add the people and organizations credited on this release.',
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _credits.length,
            onReorderItem: (oldIndex, newIndex) {
              _change(() {
                final credit = _credits.removeAt(oldIndex);
                _credits.insert(newIndex, credit);
              });
            },
            itemBuilder: (context, index) => Padding(
              key: ValueKey(_credits[index]),
              padding: const EdgeInsets.only(bottom: 12),
              child: _creditCard(index),
            ),
          ),
      ],
    );
  }

  Widget _creditCard(int index) {
    final credit = _credits[index];
    final linkedId = _intValue(credit['artist_id']);
    final linkedName = _artistName(linkedId);
    return _AlbumEditorCard(
      title: '${index + 1}. ${_creditRoleLabel(credit['role']?.toString())}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _tr(context, 'Link artist'),
            onPressed: () => _pickArtistForCredit(index),
            icon: Icon(
              linkedId == null ? Icons.link_outlined : Icons.link_rounded,
            ),
          ),
          IconButton(
            tooltip: _tr(context, 'Remove'),
            onPressed: () => _change(() => _credits.removeAt(index)),
            icon: const Icon(Icons.delete_outline),
          ),
          const Icon(Icons.drag_handle),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final role = DropdownButtonFormField<String>(
            initialValue: credit['role']?.toString() ?? 'performer',
            isExpanded: true,
            decoration: InputDecoration(labelText: _tr(context, 'Role')),
            items: _albumCreditRoles
                .map(
                  (role) => DropdownMenuItem(
                    value: role.$1,
                    child: Text(_tr(context, role.$2)),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) => _change(() => credit['role'] = value),
          );
          final name = TextFormField(
            initialValue: credit['display_name']?.toString() ?? '',
            decoration: InputDecoration(
              labelText: _tr(context, 'Credited name'),
              suffixIcon: linkedName == null
                  ? null
                  : Tooltip(
                      message: '${_tr(context, 'Linked artist')}: $linkedName',
                      child: const Icon(Icons.verified_outlined),
                    ),
            ),
            onChanged: (value) => credit['display_name'] = value,
          );
          if (compact) {
            return Column(children: [role, const SizedBox(height: 12), name]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 280, child: role),
              const SizedBox(width: 14),
              Expanded(child: name),
            ],
          );
        },
      ),
    );
  }

  String _creditRoleLabel(String? role) {
    return _tr(
      context,
      _albumCreditRoles
              .where((entry) => entry.$1 == role)
              .map((entry) => entry.$2)
              .firstOrNull ??
          'Credit',
    );
  }

  String? _artistName(int? artistId) {
    if (artistId == null) return null;
    for (final artist in _artistOptions) {
      if (_intValue(artist['id']) == artistId) {
        return artist['name']?.toString();
      }
    }
    return null;
  }

  Future<void> _pickArtistForCredit(int index) async {
    var query = '';
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = _artistOptions
              .where(
                (artist) =>
                    query.isEmpty ||
                    (artist['name']?.toString().toLowerCase() ?? '').contains(
                      query.toLowerCase(),
                    ),
              )
              .take(100)
              .toList(growable: false);
          return AlertDialog(
            title: Text(_tr(context, 'Link artist')),
            content: SizedBox(
              width: 520,
              height: 520,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: _tr(context, 'Search artists'),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => query = value.trim()),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    leading: const Icon(Icons.link_off),
                    title: Text(_tr(context, 'Keep as unlinked credit')),
                    onTap: () => Navigator.pop(context, -1),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, optionIndex) {
                        final artist = matches[optionIndex];
                        return ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person_outline),
                          ),
                          title: Text(artist['name']?.toString() ?? ''),
                          onTap: () =>
                              Navigator.pop(context, _intValue(artist['id'])),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    _change(() {
      if (selected < 0) {
        _credits[index]['artist_id'] = null;
        _credits[index]['artist_name'] = null;
        return;
      }
      _credits[index]['artist_id'] = selected;
      _credits[index]['artist_name'] = _artistName(selected);
      if ((_credits[index]['display_name']?.toString().trim() ?? '').isEmpty) {
        _credits[index]['display_name'] = _artistName(selected) ?? '';
      }
    });
  }

  Widget _albumBatchSection() {
    const fields = <(String, String)>[
      ('track_artists', 'Track artists'),
      ('composers', 'Composers'),
      ('lyricists', 'Lyricists'),
      ('genres', 'Genres'),
      ('date', 'Release date'),
      ('year', 'Year'),
      ('disc_total', 'Total discs'),
      ('track_total', 'Total tracks'),
    ];
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        _AlbumEditorIntro(
          icon: Icons.rule_folder_outlined,
          title: _tr(context, 'Apply album values to selected tracks'),
          body: _tr(
            context,
            'Only checked fields are written to checked tracks. Unselected tracks keep their own dates, artists, credits, and tags.',
          ),
        ),
        const SizedBox(height: 18),
        _AlbumEditorCard(
          title: _tr(context, 'Fields to apply'),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: fields
                .map(
                  (field) => FilterChip(
                    selected: _propagationFields.contains(field.$1),
                    label: Text(_tr(context, field.$2)),
                    onSelected: (selected) => _change(() {
                      if (selected) {
                        _propagationFields.add(field.$1);
                      } else {
                        _propagationFields.remove(field.$1);
                      }
                    }),
                  ),
                )
                .toList(growable: false),
          ),
        ),
        const SizedBox(height: 14),
        _AlbumEditorCard(
          title:
              '${_tr(context, 'Tracks')} · ${_selectedTrackIds.length}/${_tracks.length}',
          trailing: Wrap(
            spacing: 6,
            children: [
              TextButton(
                onPressed: () => _change(() {
                  _selectedTrackIds.addAll(
                    _tracks.map((track) => _intValue(track['id'])).nonNulls,
                  );
                }),
                child: Text(_tr(context, 'Select all')),
              ),
              TextButton(
                onPressed: () => _change(_selectedTrackIds.clear),
                child: Text(_tr(context, 'Deselect all')),
              ),
            ],
          ),
          child: Column(
            children: _tracks
                .map((track) {
                  final trackId = _intValue(track['id']);
                  return CheckboxListTile(
                    value:
                        trackId != null && _selectedTrackIds.contains(trackId),
                    onChanged: trackId == null
                        ? null
                        : (selected) => _change(() {
                            if (selected == true) {
                              _selectedTrackIds.add(trackId);
                            } else {
                              _selectedTrackIds.remove(trackId);
                            }
                          }),
                    secondary: _ArtworkTile(
                      title: track['title']?.toString() ?? '',
                      subtitle: track['artist_display']?.toString() ?? '',
                      size: 48,
                      icon: Icons.music_note_outlined,
                      imageUrl: _trackArtworkUrl(
                        widget.api.baseUrl,
                        track['id'],
                      ),
                    ),
                    title: Text(
                      track['title']?.toString() ?? _tr(context, 'Untitled'),
                    ),
                    subtitle: Text(
                      _joinParts([
                        track['artist_display'],
                        track['disc_number'] == null
                            ? null
                            : '${_tr(context, 'Disc')} ${track['disc_number']}',
                        track['track_number'] == null
                            ? null
                            : '#${track['track_number']}',
                        track['year'],
                      ]),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                })
                .toList(growable: false),
          ),
        ),
      ],
    );
  }

  Widget _albumMigrationSection() {
    final selected = _migrationCandidates
        .where((album) => _intValue(album['id']) == _migrationTargetId)
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        _AlbumEditorIntro(
          icon: Icons.merge_type_rounded,
          title: _tr(context, 'Move this album into another album'),
          body: _tr(
            context,
            'Use this for duplicate or incorrectly separated albums. All tracks and physical copies remain intact; the source album is folded into the target.',
          ),
        ),
        const SizedBox(height: 18),
        _AlbumEditorCard(
          title: _tr(context, 'Find target album'),
          child: Column(
            children: [
              TextField(
                controller: _migrationSearchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _searchMigrationAlbums(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: _tr(context, 'Search by album or artist'),
                  suffixIcon: _searchingAlbums
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          onPressed: _searchMigrationAlbums,
                          icon: const Icon(Icons.arrow_forward),
                        ),
                ),
              ),
              if (_migrationCandidates.isNotEmpty) ...[
                const SizedBox(height: 12),
                ..._migrationCandidates.map((album) {
                  final albumId = _intValue(album['id'])!;
                  final selected = albumId == _migrationTargetId;
                  return ListTile(
                    selected: selected,
                    onTap: () => _change(() => _migrationTargetId = albumId),
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: selected ? IntMusicTheme.of(context).accent : null,
                    ),
                    title: Text(album['title']?.toString() ?? ''),
                    subtitle: Text(
                      _joinParts([
                        album['album_artist_display'],
                        album['year'],
                        '${album['track_count'] ?? 0} ${_tr(context, 'tracks')}',
                      ]),
                    ),
                    trailing: _ArtworkTile(
                      title: album['title']?.toString() ?? '',
                      subtitle: album['album_artist_display']?.toString() ?? '',
                      size: 52,
                      icon: Icons.album_outlined,
                      imageUrl: _albumArtworkUrl(
                        widget.api.baseUrl,
                        album['id'],
                      ),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 14),
          _AlbumEditorCard(
            title: _tr(context, 'Migration preview'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_album['title']} → ${selected['title']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  _tr(
                    context,
                    'The target album keeps its title, cover, edition metadata, and credits. This album contributes its tracks and copies.',
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _migrating ? null : _migrateAlbum,
                  icon: _migrating
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.drive_file_move_outline),
                  label: Text(_tr(context, 'Move into target album')),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _searchMigrationAlbums() async {
    final query = _migrationSearchController.text.trim();
    if (query.isEmpty) return;
    _change(() {
      _searchingAlbums = true;
      _error = null;
    });
    try {
      final result = _asMap(
        await widget.api.getJson(
          '/search?q=${Uri.encodeQueryComponent(query)}&limit=40',
        ),
      );
      final candidates = ((result['albums'] as List?) ?? const [])
          .whereType<Map>()
          .map((value) => value.cast<String, dynamic>())
          .where((album) => _intValue(album['id']) != widget.albumId)
          .toList(growable: false);
      if (!mounted) return;
      _change(() {
        _migrationCandidates = candidates;
        _migrationTargetId = candidates
            .map((album) => _intValue(album['id']))
            .whereType<int>()
            .firstOrNull;
        _searchingAlbums = false;
      });
    } catch (error) {
      if (!mounted) return;
      _change(() {
        _searchingAlbums = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _migrateAlbum() async {
    final targetId = _migrationTargetId;
    if (targetId == null) return;
    _change(() {
      _migrating = true;
      _error = null;
    });
    try {
      final result = _asMap(
        await widget.api.postJson('/albums/${widget.albumId}/migrate', {
          'target_album_id': targetId,
        }),
      );
      if (!mounted) return;
      Navigator.pop(context, <String, dynamic>{
        'action': 'migrated',
        'target_album_id': _intValue(result['target_album_id']) ?? targetId,
      });
    } catch (error) {
      if (!mounted) return;
      _change(() {
        _migrating = false;
        _error = error.toString();
      });
    }
  }
}

class _AlbumEditorCard extends StatelessWidget {
  const _AlbumEditorCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

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
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
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

class _AlbumEditorIntro extends StatelessWidget {
  const _AlbumEditorIntro({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: tokens.accent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: tokens.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AlbumEditorEmptyState extends StatelessWidget {
  const _AlbumEditorEmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return _AlbumEditorCard(
      title: title,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 34),
        child: Center(
          child: Column(
            children: [
              Icon(icon, size: 40),
              const SizedBox(height: 12),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
