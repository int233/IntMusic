part of '../main.dart';

const _artistImageTypes = <String, String>{
  'portrait': 'Portrait',
  'headshot': 'Headshot',
  'landscape': 'Landscape',
  'background': 'Background',
  'live': 'Live',
  'studio': 'Studio',
  'group': 'Group',
  'logo': 'Logo',
  'other': 'Other',
};

const _artistVisualSlots = <String, (String, IconData)>{
  'avatar': ('Avatar', Icons.account_circle_outlined),
  'artist_card': ('Artist card', Icons.grid_view_rounded),
  'search_list': ('Search list', Icons.manage_search_rounded),
  'detail_hero': ('Detail hero', Icons.panorama_outlined),
  'home_feature': ('Home feature', Icons.auto_awesome_outlined),
  'playback_background': ('Playback background', Icons.graphic_eq_rounded),
};

class _ArtistEditorDialog extends StatefulWidget {
  const _ArtistEditorDialog({
    required this.api,
    required this.artistId,
    required this.detail,
  });

  final CoreApiClient api;
  final int artistId;
  final Map<String, dynamic> detail;

  @override
  State<_ArtistEditorDialog> createState() => _ArtistEditorDialogState();
}

class _ArtistEditorDialogState extends State<_ArtistEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _sortNameController;
  late final TextEditingController _musicBrainzController;
  late final TextEditingController _typeController;
  late final TextEditingController _countryController;
  late final TextEditingController _beginController;
  late final TextEditingController _endController;
  late final TextEditingController _disambiguationController;
  late final TextEditingController _aliasesController;
  late final TextEditingController _genresController;
  late final TextEditingController _biographyController;
  late final TextEditingController _linksController;

  int _section = 0;
  bool _saving = false;
  bool _uploading = false;
  bool _previewing = false;
  String? _error;
  Map<String, dynamic>? _musicBrainzPreview;
  late List<Map<String, dynamic>> _assets;
  late Map<String, Map<String, dynamic>> _visuals;
  int? _selectedAssetId;
  int _selectedRegionIndex = 0;
  String _selectedSlot = 'avatar';

  Map<String, dynamic> get _artist => _asMap(widget.detail['artist']);
  Map<String, dynamic> get _profile => widget.detail['profile'] == null
      ? <String, dynamic>{}
      : _asMap(widget.detail['profile']);

  @override
  void initState() {
    super.initState();
    String text(Object? value) => value?.toString() ?? '';
    _nameController = TextEditingController(
      text: text(_profile['display_name']).isEmpty
          ? text(_artist['name'])
          : text(_profile['display_name']),
    );
    _sortNameController = TextEditingController(
      text: text(_profile['sort_name']).isEmpty
          ? text(_artist['sort_name'])
          : text(_profile['sort_name']),
    );
    _musicBrainzController = TextEditingController(
      text: text(_profile['musicbrainz_id']),
    );
    _typeController = TextEditingController(
      text: text(_profile['artist_type']),
    );
    _countryController = TextEditingController(text: text(_profile['country']));
    _beginController = TextEditingController(
      text: text(_profile['begin_date']),
    );
    _endController = TextEditingController(text: text(_profile['end_date']));
    _disambiguationController = TextEditingController(
      text: text(_profile['disambiguation']),
    );
    _aliasesController = TextEditingController(
      text:
          ((widget.detail['profile'] as Map?)?['aliases'] as List? ?? const [])
              .join(', '),
    );
    _genresController = TextEditingController(
      text: ((widget.detail['profile'] as Map?)?['genres'] as List? ?? const [])
          .join(', '),
    );
    _biographyController = TextEditingController(
      text: text(_profile['biography']),
    );
    _linksController = TextEditingController(
      text: ((widget.detail['profile'] as Map?)?['links'] as List? ?? const [])
          .map((link) {
            final map = (link as Map).cast<String, dynamic>();
            return '${map['label'] ?? 'Link'} | ${map['url'] ?? ''}';
          })
          .join('\n'),
    );
    _assets = ((widget.detail['assets'] as List?) ?? const [])
        .map((asset) => (asset as Map).cast<String, dynamic>())
        .toList();
    _visuals = {
      for (final visual in ((widget.detail['visuals'] as List?) ?? const []))
        (visual as Map)['slot'].toString(): visual.cast<String, dynamic>(),
    };
    if (_assets.isNotEmpty) {
      _selectedAssetId = _intValue(_assets.first['id']);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _sortNameController,
      _musicBrainzController,
      _typeController,
      _countryController,
      _beginController,
      _endController,
      _disambiguationController,
      _aliasesController,
      _genresController,
      _biographyController,
      _linksController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _avatarRegions {
    final visual = _visuals['avatar'];
    final regions = (visual?['regions'] as List?) ?? const [];
    return regions
        .map((region) => (region as Map).cast<String, dynamic>())
        .toList();
  }

  Map<String, dynamic>? get _selectedAsset {
    for (final asset in _assets) {
      if (_intValue(asset['id']) == _selectedAssetId) {
        return asset;
      }
    }
    return null;
  }

  String _assetUrl(Map<String, dynamic> asset) {
    final width = (_intValue(asset['width']) ?? 1).clamp(1, 1000000);
    final height = (_intValue(asset['height']) ?? 1).clamp(1, 1000000);
    // Use one canonical editor rendition. Multiple widget-specific sizes made
    // a remote Core render and download the same upload several times before
    // the editor could show its first frame.
    final targetWidth = min(width, 1200);
    final targetHeight = max(1, (targetWidth * height / width).round());
    final assetId = _intValue(asset['id']) ?? 0;
    final version = Uri.encodeQueryComponent(
      '${asset['created_at'] ?? ''}-$assetId',
    );
    return '${widget.api.baseUrl}/api/v1/artwork/artists/'
        '${widget.artistId}/asset-$assetId'
        '?w=$targetWidth&h=$targetHeight&v=$version';
  }

  Future<void> _previewMusicBrainz() async {
    if (_musicBrainzController.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      final result = await widget.api.postJson(
        '/artists/${widget.artistId}/musicbrainz/preview',
        {'musicbrainz_id': _musicBrainzController.text.trim()},
      );
      if (!mounted) return;
      setState(() {
        _musicBrainzPreview = _asMap(result);
        _previewing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _previewing = false;
      });
    }
  }

  void _applyMusicBrainzPreview() {
    final preview = _musicBrainzPreview;
    if (preview == null) return;
    setState(() {
      _musicBrainzController.text =
          preview['musicbrainz_id']?.toString() ?? _musicBrainzController.text;
      _nameController.text =
          preview['name']?.toString() ?? _nameController.text;
      _sortNameController.text =
          preview['sort_name']?.toString() ?? _sortNameController.text;
      _typeController.text =
          preview['artist_type']?.toString() ?? _typeController.text;
      _countryController.text =
          preview['country']?.toString() ?? _countryController.text;
      _beginController.text =
          preview['begin_date']?.toString() ?? _beginController.text;
      _endController.text =
          preview['end_date']?.toString() ?? _endController.text;
      _disambiguationController.text =
          preview['disambiguation']?.toString() ??
          _disambiguationController.text;
      _aliasesController.text = (preview['aliases'] as List? ?? const []).join(
        ', ',
      );
      _genresController.text = (preview['genres'] as List? ?? const []).join(
        ', ',
      );
      final links = (preview['links'] as List? ?? const []);
      _linksController.text = links
          .map((link) {
            final map = (link as Map).cast<String, dynamic>();
            return '${map['label'] ?? 'Link'} | ${map['url'] ?? ''}';
          })
          .join('\n');
      _musicBrainzPreview = null;
    });
  }

  Future<void> _pickImages() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: [
        'jpg',
        'jpeg',
        'jfif',
        'png',
        'webp',
        'gif',
        'bmp',
        'tif',
        'tiff',
        'ico',
        'pnm',
        'qoi',
        'tga',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: const [group]);
    if (files.isEmpty || !mounted) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      for (final file in files) {
        final result = await widget.api.uploadFile(
          '/artists/${widget.artistId}/assets',
          file,
          photoType: 'other',
        );
        for (final asset in (result as List? ?? const [])) {
          final map = (asset as Map).cast<String, dynamic>();
          final id = _intValue(map['id']);
          _assets.removeWhere((item) => _intValue(item['id']) == id);
          _assets.add(map);
          _selectedAssetId = id;
          _visuals.putIfAbsent(
            'avatar',
            () => _newVisual('avatar', assetId: id),
          );
          _visuals.putIfAbsent(
            'detail_hero',
            () => _newVisual('detail_hero', assetId: id),
          );
        }
      }
      if (!mounted) return;
      setState(() => _uploading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = error.toString();
      });
    }
  }

  Map<String, dynamic> _newVisual(String slot, {int? assetId}) => {
    'slot': slot,
    'asset_id': assetId,
    'template': 'single',
    'fit': 'cover',
    'focal_x': 0.5,
    'focal_y': 0.5,
    'blur': 0.0,
    'brightness': 1.0,
    'revision': 0,
    'regions': <Map<String, dynamic>>[],
  };

  void _addAvatarRegion() {
    final assetId = _selectedAssetId;
    if (assetId == null) return;
    final visual = Map<String, dynamic>.from(
      _visuals['avatar'] ?? _newVisual('avatar', assetId: assetId),
    );
    final regions = ((visual['regions'] as List?) ?? const [])
        .map((region) => Map<String, dynamic>.from(region as Map))
        .toList();
    if (regions.length >= 5) {
      setState(() => _error = 'An avatar can contain at most five regions.');
      return;
    }
    regions.add({
      'position': regions.length,
      'asset_id': assetId,
      'crop_x': 0.0,
      'crop_y': 0.0,
      'crop_width': 1.0,
      'crop_height': 1.0,
      'focal_x': 0.5,
      'focal_y': 0.5,
    });
    visual['regions'] = regions;
    visual['asset_id'] = assetId;
    visual['template'] = regions.length == 1 ? 'single' : 'feature';
    setState(() {
      _visuals['avatar'] = visual;
      _selectedRegionIndex = regions.length - 1;
      _error = null;
    });
  }

  void _updateRegion(Map<String, dynamic> changed) {
    final visual = Map<String, dynamic>.from(
      _visuals['avatar'] ?? _newVisual('avatar'),
    );
    final regions = ((visual['regions'] as List?) ?? const [])
        .map((region) => Map<String, dynamic>.from(region as Map))
        .toList();
    if (_selectedRegionIndex >= regions.length) return;
    changed['position'] = _selectedRegionIndex;
    regions[_selectedRegionIndex] = changed;
    visual['regions'] = regions;
    setState(() => _visuals['avatar'] = visual);
  }

  void _removeRegion(int index) {
    final visual = Map<String, dynamic>.from(
      _visuals['avatar'] ?? _newVisual('avatar'),
    );
    final regions = ((visual['regions'] as List?) ?? const [])
        .map((region) => Map<String, dynamic>.from(region as Map))
        .toList();
    if (index < 0 || index >= regions.length) return;
    regions.removeAt(index);
    for (var i = 0; i < regions.length; i++) {
      regions[i]['position'] = i;
    }
    visual['regions'] = regions;
    visual['template'] = regions.length <= 1 ? 'single' : 'feature';
    setState(() {
      _visuals['avatar'] = visual;
      _selectedRegionIndex = min(
        _selectedRegionIndex,
        max(0, regions.length - 1),
      );
    });
  }

  void _assignSelectedAsset(String slot) {
    final assetId = _selectedAssetId;
    if (assetId == null) return;
    final visual = Map<String, dynamic>.from(
      _visuals[slot] ?? _newVisual(slot),
    );
    visual['asset_id'] = assetId;
    setState(() => _visuals[slot] = visual);
  }

  Future<void> _setPhotoType(String value) async {
    final asset = _selectedAsset;
    final id = _selectedAssetId;
    if (asset == null || id == null) return;
    setState(() => asset['photo_type'] = value);
    try {
      await widget.api.postJson('/artists/${widget.artistId}/assets/$id', {
        'photo_type': value,
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _deleteSelectedAsset() async {
    final id = _selectedAssetId;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Remove image?')),
        content: Text(
          _tr(
            context,
            'The image will be removed from this artist and all of its display assignments.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_tr(context, 'Remove')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.deleteJson('/artists/${widget.artistId}/assets/$id');
      setState(() {
        _assets.removeWhere((asset) => _intValue(asset['id']) == id);
        _selectedAssetId = _assets.isEmpty
            ? null
            : _intValue(_assets.first['id']);
        for (final visual in _visuals.values) {
          if (_intValue(visual['asset_id']) == id) visual['asset_id'] = null;
          final regions = (visual['regions'] as List? ?? const [])
              .where((region) => _intValue((region as Map)['asset_id']) != id)
              .toList();
          for (var i = 0; i < regions.length; i++) {
            (regions[i] as Map)['position'] = i;
          }
          visual['regions'] = regions;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  List<String> _splitValues(String value) => value
      .split(RegExp(r'[,，\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();

  List<Map<String, String>> _parseLinks(String value) {
    return value
        .split('\n')
        .map((line) {
          final parts = line.split('|');
          if (parts.length == 1) {
            return {'label': 'Link', 'url': parts.first.trim()};
          }
          return {
            'label': parts.first.trim().isEmpty ? 'Link' : parts.first.trim(),
            'url': parts.sublist(1).join('|').trim(),
          };
        })
        .where((link) => link['url']!.isNotEmpty)
        .toList();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.postJson('/artists/${widget.artistId}', {
        'display_name': _nameController.text.trim(),
        'sort_name': _sortNameController.text.trim(),
        'musicbrainz_id': _musicBrainzController.text.trim(),
        'artist_type': _typeController.text.trim(),
        'country': _countryController.text.trim(),
        'begin_date': _beginController.text.trim(),
        'end_date': _endController.text.trim(),
        'disambiguation': _disambiguationController.text.trim(),
        'biography': _biographyController.text.trim(),
        'aliases': _splitValues(_aliasesController.text),
        'genres': _splitValues(_genresController.text),
        'links': _parseLinks(_linksController.text),
      });
      for (final entry in _visuals.entries) {
        final visual = entry.value;
        final regions = ((visual['regions'] as List?) ?? const [])
            .take(5)
            .map((region) => Map<String, dynamic>.from(region as Map))
            .toList();
        for (var i = 0; i < regions.length; i++) {
          regions[i]['position'] = i;
        }
        if (_intValue(visual['asset_id']) == null && regions.isEmpty) continue;
        await widget.api
            .postJson('/artists/${widget.artistId}/visuals/${entry.key}', {
              'asset_id': _intValue(visual['asset_id']),
              'template': visual['template']?.toString() ?? 'single',
              'fit': visual['fit']?.toString() ?? 'cover',
              'focal_x': _doubleValue(visual['focal_x'], 0.5),
              'focal_y': _doubleValue(visual['focal_y'], 0.5),
              'blur': _doubleValue(visual['blur'], 0),
              'brightness': _doubleValue(visual['brightness'], 1),
              'regions': regions,
            });
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  double _doubleValue(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.all(size.width < 760 ? 8 : 24),
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size.width < 760 ? 18 : 22),
        side: BorderSide(color: tokens.stroke),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1240,
          maxHeight: min(900, size.height - (size.width < 760 ? 16 : 48)),
        ),
        child: Column(
          children: [
            _editorToolbar(),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!, maxLines: 3),
                leading: const Icon(Icons.error_outline),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: Text(_tr(context, 'Dismiss')),
                  ),
                ],
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: KeyedSubtree(
                  key: ValueKey(_section),
                  child: switch (_section) {
                    0 => _informationSection(),
                    1 => _artworkSection(),
                    _ => _displaySection(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised.withValues(alpha: 0.9),
        border: Border(
          bottom: BorderSide(color: IntMusicTheme.of(context).stroke),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sections = SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.badge_outlined),
                label: Text(_tr(context, 'Information')),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.photo_library_outlined),
                label: Text(_tr(context, 'Artwork')),
              ),
              ButtonSegment(
                value: 2,
                icon: Icon(Icons.auto_awesome_outlined),
                label: Text(_tr(context, 'Display')),
              ),
            ],
            selected: {_section},
            onSelectionChanged: (value) =>
                setState(() => _section = value.first),
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context, false),
                child: Text(_tr(context, 'Cancel')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(_tr(context, 'Save')),
              ),
            ],
          );
          if (constraints.maxWidth < 820) {
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _tr(context, 'Edit artist'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    actions,
                  ],
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: sections,
                ),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(
                width: 180,
                child: Text(
                  _tr(context, 'Edit artist'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(child: Center(child: sections)),
              SizedBox(
                width: 200,
                child: Align(alignment: Alignment.centerRight, child: actions),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _informationSection() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = ListView(
          padding: const EdgeInsets.all(22),
          children: [
            _editorSectionCard(
              title: 'Identity',
              subtitle: 'The local display name is always under your control.',
              child: Column(
                children: [
                  _responsiveFields([
                    _field(_nameController, 'Display name'),
                    _field(_sortNameController, 'Sort name'),
                  ]),
                  const SizedBox(height: 14),
                  _responsiveFields([
                    _field(_typeController, 'Artist type'),
                    _field(_countryController, 'Country or area'),
                    _field(_beginController, 'Active from'),
                    _field(_endController, 'Active until'),
                  ]),
                  const SizedBox(height: 14),
                  _field(_disambiguationController, 'Disambiguation'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _editorSectionCard(
              title: 'MusicBrainz',
              subtitle:
                  'Imports artist information only. Artwork is never downloaded.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          _musicBrainzController,
                          'MusicBrainz ID or artist URL',
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.tonalIcon(
                        onPressed: _previewing ? null : _previewMusicBrainz,
                        icon: _previewing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.manage_search),
                        label: Text(_tr(context, 'Preview')),
                      ),
                    ],
                  ),
                  if (_musicBrainzPreview != null) ...[
                    const SizedBox(height: 14),
                    _musicBrainzPreviewCard(),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _editorSectionCard(
              title: 'Description and discovery',
              subtitle:
                  'Genres and aliases improve browsing and search without changing file tags.',
              child: Column(
                children: [
                  _responsiveFields([
                    _field(_aliasesController, 'Aliases'),
                    _field(_genresController, 'Genres'),
                  ]),
                  const SizedBox(height: 14),
                  _field(
                    _biographyController,
                    'Biography',
                    minLines: 5,
                    maxLines: 10,
                  ),
                  const SizedBox(height: 14),
                  _field(
                    _linksController,
                    'External links — one “Label | URL” per line',
                    minLines: 3,
                    maxLines: 7,
                  ),
                ],
              ),
            ),
          ],
        );
        if (constraints.maxWidth < 980) return content;
        return Row(
          children: [
            Expanded(child: content),
            SizedBox(
              width: 330,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 22, 22, 22),
                child: _artistPreviewCard(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _musicBrainzPreviewCard() {
    final preview = _musicBrainzPreview!;
    final localName = _nameController.text.trim().toLowerCase();
    final remoteName = preview['name']?.toString().trim().toLowerCase() ?? '';
    final mismatch =
        localName.isNotEmpty &&
        remoteName.isNotEmpty &&
        localName != remoteName;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: mismatch
            ? Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.46)
            : IntMusicTheme.of(context).surface,
        border: Border.all(
          color: mismatch
              ? Theme.of(context).colorScheme.error.withValues(alpha: 0.5)
              : IntMusicTheme.of(context).stroke,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mismatch)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _tr(
                        context,
                        'The remote artist name does not match the local artist. Review before applying.',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Text(
            preview['name']?.toString() ?? '',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            [
                  preview['artist_type'],
                  preview['country'],
                  preview['disambiguation'],
                ]
                .where((item) => item != null && item.toString().isNotEmpty)
                .join(' · '),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: _applyMusicBrainzPreview,
              child: Text(_tr(context, 'Use this information')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _artworkSection() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              SizedBox(height: 340, child: _assetLibrary()),
              const SizedBox(height: 16),
              SizedBox(height: 420, child: _cropWorkspace()),
              const SizedBox(height: 16),
              _assetInspector(),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 300, child: _assetLibrary()),
            VerticalDivider(width: 1, color: IntMusicTheme.of(context).stroke),
            Expanded(child: _cropWorkspace()),
            VerticalDivider(width: 1, color: IntMusicTheme.of(context).stroke),
            SizedBox(width: 280, child: _assetInspector()),
          ],
        );
      },
    );
  }

  Widget _assetLibrary() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _tr(context, 'Photo library'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _uploading ? null : _pickImages,
                icon: _uploading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_photo_alternate_outlined),
                label: Text(_tr(context, 'Add')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _assets.isEmpty
              ? _emptyArtworkLibrary()
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: _assets.length,
                  itemBuilder: (context, index) {
                    final asset = _assets[index];
                    final id = _intValue(asset['id']);
                    final selected = id == _selectedAssetId;
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _selectedAssetId = id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : IntMusicTheme.of(context).stroke,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _ArtistAssetImage(
                                imageUrl: _assetUrl(asset),
                                fit: BoxFit.cover,
                              ),
                              Positioned(
                                left: 7,
                                bottom: 7,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.62),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      _tr(
                                        context,
                                        _artistImageTypes[asset['photo_type']] ??
                                            'Other',
                                      ),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyArtworkLibrary() {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: InkWell(
        onTap: _pickImages,
        borderRadius: BorderRadius.circular(18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: IntMusicTheme.of(context).surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: IntMusicTheme.of(context).stroke),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_photo_alternate_outlined, size: 38),
                const SizedBox(height: 10),
                Text(_tr(context, 'Add artist photos')),
                const SizedBox(height: 4),
                Text(
                  _tr(context, 'JPEG, PNG, WebP, GIF, TIFF and more'),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cropWorkspace() {
    final regions = _avatarRegions;
    Map<String, dynamic>? selectedRegion;
    Map<String, dynamic>? selectedRegionAsset;
    if (regions.isNotEmpty && _selectedRegionIndex < regions.length) {
      selectedRegion = regions[_selectedRegionIndex];
      final assetId = _intValue(selectedRegion['asset_id']);
      for (final asset in _assets) {
        if (_intValue(asset['id']) == assetId) selectedRegionAsset = asset;
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(context, 'Avatar composition'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      _LocaleScope.languageOf(context) == _AppLanguage.zh
                          ? '${regions.length} / 5 个裁剪区域。1 个区域作为普通头像，'
                                '2–5 个区域自动拼合。'
                          : '${regions.length} of 5 crop regions. One region '
                                'makes a standard avatar; 2–5 form a collage.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (regions.isNotEmpty)
                      Text(
                        _tr(
                          context,
                          'Drag the frame to move the crop; drag its bottom-right handle to resize the crop.',
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: IntMusicTheme.of(context).textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (regions.isNotEmpty) ...[
                      Tooltip(
                        message: _tr(context, 'Circular avatar preview'),
                        child: _AvatarCompositionPreview(
                          size: 54,
                          circular: true,
                          assets: _assets,
                          regions: regions,
                          imageUrl: _assetUrl,
                        ),
                      ),
                      Tooltip(
                        message: _tr(context, 'Square avatar preview'),
                        child: _AvatarCompositionPreview(
                          size: 54,
                          assets: _assets,
                          regions: regions,
                          imageUrl: _assetUrl,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _removeRegion(_selectedRegionIndex),
                        icon: const Icon(Icons.remove_circle_outline),
                        label: Text(_tr(context, 'Remove current region')),
                      ),
                    ],
                    FilledButton.tonalIcon(
                      onPressed: _selectedAssetId == null || regions.length >= 5
                          ? null
                          : _addAvatarRegion,
                      icon: const Icon(Icons.crop_free),
                      label: Text(_tr(context, 'Add crop region')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: selectedRegion == null || selectedRegionAsset == null
              ? Center(
                  child: Text(
                    _tr(
                      context,
                      _assets.isEmpty
                          ? 'Add a photo to begin.'
                          : 'Select a photo, then add a crop region.',
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(18),
                  child: _ArtistCropCanvas(
                    imageUrl: _assetUrl(selectedRegionAsset),
                    imageWidth: (_intValue(selectedRegionAsset['width']) ?? 1)
                        .toDouble(),
                    imageHeight: (_intValue(selectedRegionAsset['height']) ?? 1)
                        .toDouble(),
                    region: selectedRegion,
                    onChanged: _updateRegion,
                  ),
                ),
        ),
        if (regions.isNotEmpty)
          Container(
            height: 92,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: IntMusicTheme.of(context).surfaceRaised,
              border: Border(
                top: BorderSide(color: IntMusicTheme.of(context).stroke),
              ),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: regions.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final region = regions[index];
                final assetId = _intValue(region['asset_id']);
                final asset = _assets.cast<Map<String, dynamic>?>().firstWhere(
                  (item) => _intValue(item?['id']) == assetId,
                  orElse: () => null,
                );
                return InkWell(
                  onTap: () => setState(() => _selectedRegionIndex = index),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 74,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: index == _selectedRegionIndex
                            ? Theme.of(context).colorScheme.primary
                            : IntMusicTheme.of(context).stroke,
                        width: index == _selectedRegionIndex ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (asset != null)
                          _ArtistAssetImage(
                            imageUrl: _assetUrl(asset),
                            fit: BoxFit.cover,
                          ),
                        Positioned(
                          left: 5,
                          top: 5,
                          child: CircleAvatar(
                            radius: 10,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 1,
                          top: 1,
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _removeRegion(index),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _assetInspector() {
    final asset = _selectedAsset;
    if (asset == null) {
      return Center(child: Text(_tr(context, 'Select an image')));
    }
    final width = _intValue(asset['width']) ?? 0;
    final height = _intValue(asset['height']) ?? 0;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          _tr(context, 'Image'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: width > 0 && height > 0 ? width / height : 1,
            child: _ArtistAssetImage(
              imageUrl: _assetUrl(asset),
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          asset['original_filename']?.toString() ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          '$width × $height · ${asset['mime_type'] ?? ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          initialValue: _artistImageTypes.containsKey(asset['photo_type'])
              ? asset['photo_type'].toString()
              : 'other',
          decoration: InputDecoration(labelText: _tr(context, 'Photo type')),
          items: _artistImageTypes.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(_tr(context, entry.value)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) unawaited(_setPhotoType(value));
          },
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _deleteSelectedAsset,
          icon: const Icon(Icons.delete_outline),
          label: Text(_tr(context, 'Remove image')),
        ),
      ],
    );
  }

  Widget _displaySection() {
    final currentVisual = Map<String, dynamic>.from(
      _visuals[_selectedSlot] ?? _newVisual(_selectedSlot),
    );
    final selected = _selectedAsset;
    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              _tr(context, 'Display locations'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final entry in _artistVisualSlots.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: ListTile(
                  selected: _selectedSlot == entry.key,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: Icon(entry.value.$2),
                  title: Text(_tr(context, entry.value.$1)),
                  onTap: () => setState(() => _selectedSlot = entry.key),
                ),
              ),
            const Divider(height: 28),
            DropdownButtonFormField<int>(
              key: ValueKey('$_selectedSlot-${currentVisual['asset_id']}'),
              initialValue: _intValue(currentVisual['asset_id']),
              decoration: InputDecoration(
                labelText: _tr(context, 'Assigned image'),
              ),
              items: _assets
                  .map(
                    (asset) => DropdownMenuItem(
                      value: _intValue(asset['id']),
                      child: Text(
                        asset['original_filename']?.toString() ?? 'Image',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                final visual = Map<String, dynamic>.from(currentVisual);
                visual['asset_id'] = value;
                setState(() => _visuals[_selectedSlot] = visual);
              },
            ),
            const SizedBox(height: 16),
            Text(
              _tr(context, 'Horizontal focus'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Slider(
              value: _doubleValue(currentVisual['focal_x'], 0.5).clamp(0, 1),
              onChanged: (value) {
                final visual = Map<String, dynamic>.from(currentVisual);
                visual['focal_x'] = value;
                setState(() => _visuals[_selectedSlot] = visual);
              },
            ),
            Text(
              _tr(context, 'Vertical focus'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Slider(
              value: _doubleValue(currentVisual['focal_y'], 0.5).clamp(0, 1),
              onChanged: (value) {
                final visual = Map<String, dynamic>.from(currentVisual);
                visual['focal_y'] = value;
                setState(() => _visuals[_selectedSlot] = visual);
              },
            ),
            if (_selectedSlot == 'playback_background') ...[
              Text(
                _tr(context, 'Soft blur'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Slider(
                value: _doubleValue(currentVisual['blur'], 0).clamp(0, 24),
                max: 24,
                onChanged: (value) {
                  final visual = Map<String, dynamic>.from(currentVisual);
                  visual['blur'] = value;
                  setState(() => _visuals[_selectedSlot] = visual);
                },
              ),
            ],
            if (selected != null)
              FilledButton.tonalIcon(
                onPressed: () => _assignSelectedAsset(_selectedSlot),
                icon: const Icon(Icons.check_circle_outline),
                label: Text(_tr(context, 'Use selected library image')),
              ),
          ],
        );
        final preview = _displayPreview(currentVisual);
        if (constraints.maxWidth < 820) {
          return Column(
            children: [
              Expanded(child: controls),
              SizedBox(height: 260, child: preview),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 340, child: controls),
            VerticalDivider(width: 1, color: IntMusicTheme.of(context).stroke),
            Expanded(child: preview),
          ],
        );
      },
    );
  }

  Widget _displayPreview(Map<String, dynamic> visual) {
    final assetId = _intValue(visual['asset_id']);
    Map<String, dynamic>? asset;
    for (final item in _assets) {
      if (_intValue(item['id']) == assetId) asset = item;
    }
    final wide = {
      'detail_hero',
      'home_feature',
      'playback_background',
    }.contains(_selectedSlot);
    return Container(
      padding: const EdgeInsets.all(28),
      color: IntMusicTheme.of(context).surface,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 760 : 360),
          child: AspectRatio(
            aspectRatio: wide ? 16 / 6 : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(wide ? 22 : 28),
                border: Border.all(color: IntMusicTheme.of(context).stroke),
                gradient: LinearGradient(
                  colors: [
                    _seededColor(_nameController.text, 0),
                    _seededColor(_nameController.text, 1),
                  ],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(wide ? 22 : 28),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (asset != null)
                      _ArtistAssetImage(
                        imageUrl: _assetUrl(asset),
                        fit: BoxFit.cover,
                        alignment: Alignment(
                          _doubleValue(visual['focal_x'], 0.5) * 2 - 1,
                          _doubleValue(visual['focal_y'], 0.5) * 2 - 1,
                        ),
                      ),
                    if (wide)
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xdd08090d),
                              Color(0x6608090d),
                              Colors.transparent,
                            ],
                            stops: [0, 0.48, 1],
                          ),
                        ),
                      ),
                    if (wide)
                      Positioned(
                        left: 28,
                        bottom: 24,
                        child: Text(
                          _nameController.text,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _artistPreviewCard() {
    final regions = _avatarRegions;
    final assetId = _intValue(_visuals['avatar']?['asset_id']);
    final previewRegions = regions.isNotEmpty
        ? regions
        : assetId == null
        ? <Map<String, dynamic>>[]
        : [
            {
              'position': 0,
              'asset_id': assetId,
              'crop_x': 0.0,
              'crop_y': 0.0,
              'crop_width': 1.0,
              'crop_height': 1.0,
            },
          ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surface,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            previewRegions.isEmpty
                ? ClipOval(
                    child: _ArtworkTile(
                      title: _nameController.text,
                      subtitle: 'artist',
                      size: 150,
                      icon: Icons.person_outline,
                    ),
                  )
                : _AvatarCompositionPreview(
                    size: 150,
                    circular: true,
                    assets: _assets,
                    regions: previewRegions,
                    imageUrl: _assetUrl,
                  ),
            const SizedBox(height: 22),
            Text(
              _nameController.text,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              [
                _typeController.text,
                _countryController.text,
              ].where((item) => item.trim().isNotEmpty).join(' · '),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorSectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surface,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tr(context, title),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 3),
            Text(
              _tr(context, subtitle),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }

  Widget _responsiveFields(List<Widget> children) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const SizedBox(height: 12),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              Expanded(child: children[i]),
              if (i != children.length - 1) const SizedBox(width: 12),
            ],
          ],
        );
      },
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int minLines = 1,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: _tr(context, label)),
      onChanged: (_) => setState(() {}),
    );
  }
}

class _ArtistAssetImage extends StatefulWidget {
  const _ArtistAssetImage({
    required this.imageUrl,
    required this.fit,
    this.alignment = Alignment.center,
  });

  final String imageUrl;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  State<_ArtistAssetImage> createState() => _ArtistAssetImageState();
}

class _ArtistAssetImageState extends State<_ArtistAssetImage> {
  int _attempt = 0;

  String get _effectiveUrl {
    if (_attempt == 0) return widget.imageUrl;
    final uri = Uri.parse(widget.imageUrl);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            'retry': _attempt.toString(),
          },
        )
        .toString();
  }

  @override
  void didUpdateWidget(covariant _ArtistAssetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _attempt = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _effectiveUrl,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final expected = progress.expectedTotalBytes;
        final value = expected == null || expected <= 0
            ? null
            : progress.cumulativeBytesLoaded / expected;
        return ColoredBox(
          color: IntMusicTheme.of(context).surfaceRaised,
          child: Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator.adaptive(
                strokeWidth: 2,
                value: value,
              ),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Material(
          color: IntMusicTheme.of(context).surfaceRaised,
          child: InkWell(
            onTap: () => setState(() => _attempt += 1),
            child: Tooltip(
              message: _tr(
                context,
                'Image could not be loaded. Click to retry.',
              ),
              child: Center(
                child: Icon(
                  Icons.refresh_rounded,
                  color: IntMusicTheme.of(context).textSecondary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AvatarCompositionPreview extends StatelessWidget {
  const _AvatarCompositionPreview({
    required this.size,
    required this.assets,
    required this.regions,
    required this.imageUrl,
    this.circular = false,
  });

  final double size;
  final List<Map<String, dynamic>> assets;
  final List<Map<String, dynamic>> regions;
  final String Function(Map<String, dynamic>) imageUrl;
  final bool circular;

  List<Rect> _layout(int count) {
    return switch (count) {
      1 => const [Rect.fromLTWH(0, 0, 1, 1)],
      2 => const [Rect.fromLTWH(0, 0, 0.5, 1), Rect.fromLTWH(0.5, 0, 0.5, 1)],
      3 => const [
        Rect.fromLTWH(0, 0, 0.66, 1),
        Rect.fromLTWH(0.66, 0, 0.34, 0.5),
        Rect.fromLTWH(0.66, 0.5, 0.34, 0.5),
      ],
      4 => const [
        Rect.fromLTWH(0, 0, 0.5, 0.5),
        Rect.fromLTWH(0.5, 0, 0.5, 0.5),
        Rect.fromLTWH(0, 0.5, 0.5, 0.5),
        Rect.fromLTWH(0.5, 0.5, 0.5, 0.5),
      ],
      _ => const [
        Rect.fromLTWH(0, 0, 0.6, 1),
        Rect.fromLTWH(0.6, 0, 0.2, 0.5),
        Rect.fromLTWH(0.8, 0, 0.2, 0.5),
        Rect.fromLTWH(0.6, 0.5, 0.2, 0.5),
        Rect.fromLTWH(0.8, 0.5, 0.2, 0.5),
      ],
    };
  }

  double _number(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  @override
  Widget build(BuildContext context) {
    final visibleRegions = regions.take(5).toList();
    final layout = _layout(visibleRegions.length);
    final preview = SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          for (var index = 0; index < visibleRegions.length; index++)
            Builder(
              builder: (context) {
                final region = visibleRegions[index];
                final assetId = _intValue(region['asset_id']);
                Map<String, dynamic>? asset;
                for (final candidate in assets) {
                  if (_intValue(candidate['id']) == assetId) {
                    asset = candidate;
                  }
                }
                final target = layout[index];
                final cropCenterX =
                    _number(region['crop_x'], 0) +
                    _number(region['crop_width'], 1) / 2;
                final cropCenterY =
                    _number(region['crop_y'], 0) +
                    _number(region['crop_height'], 1) / 2;
                return Positioned(
                  left: target.left * size,
                  top: target.top * size,
                  width: target.width * size,
                  height: target.height * size,
                  child: asset == null
                      ? ColoredBox(
                          color: IntMusicTheme.of(context).surfaceRaised,
                        )
                      : _ArtistAssetImage(
                          imageUrl: imageUrl(asset),
                          fit: BoxFit.cover,
                          alignment: Alignment(
                            cropCenterX.clamp(0, 1) * 2 - 1,
                            cropCenterY.clamp(0, 1) * 2 - 1,
                          ),
                        ),
                );
              },
            ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(size * 0.2),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: size * 0.12,
            offset: Offset(0, size * 0.04),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(circular ? size / 2 : size * 0.2),
        child: preview,
      ),
    );
  }
}

class _ArtistCropCanvas extends StatefulWidget {
  const _ArtistCropCanvas({
    required this.imageUrl,
    required this.imageWidth,
    required this.imageHeight,
    required this.region,
    required this.onChanged,
  });

  final String imageUrl;
  final double imageWidth;
  final double imageHeight;
  final Map<String, dynamic> region;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  State<_ArtistCropCanvas> createState() => _ArtistCropCanvasState();
}

class _ArtistCropCanvasState extends State<_ArtistCropCanvas> {
  late Map<String, dynamic> _region;

  double _value(String key, double fallback) {
    final value = _region[key];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  @override
  void initState() {
    super.initState();
    _region = Map<String, dynamic>.from(widget.region);
  }

  @override
  void didUpdateWidget(covariant _ArtistCropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.region['asset_id'] != widget.region['asset_id'] ||
        oldWidget.region['position'] != widget.region['position']) {
      _region = Map<String, dynamic>.from(widget.region);
    }
  }

  void _emit() {
    widget.onChanged(Map<String, dynamic>.from(_region));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = min(
          constraints.maxWidth / widget.imageWidth,
          constraints.maxHeight / widget.imageHeight,
        );
        final imageWidth = widget.imageWidth * scale;
        final imageHeight = widget.imageHeight * scale;
        final imageLeft = (constraints.maxWidth - imageWidth) / 2;
        final imageTop = (constraints.maxHeight - imageHeight) / 2;
        final x = _value('crop_x', 0);
        final y = _value('crop_y', 0);
        final width = _value('crop_width', 1);
        final height = _value('crop_height', 1);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                Positioned(
                  left: imageLeft,
                  top: imageTop,
                  width: imageWidth,
                  height: imageHeight,
                  child: _ArtistAssetImage(
                    imageUrl: widget.imageUrl,
                    fit: BoxFit.fill,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.46),
                    ),
                  ),
                ),
                Positioned(
                  left: imageLeft + x * imageWidth,
                  top: imageTop + y * imageHeight,
                  width: width * imageWidth,
                  height: height * imageHeight,
                  child: GestureDetector(
                    onPanUpdate: (details) {
                      setState(() {
                        _region['crop_x'] = (x + details.delta.dx / imageWidth)
                            .clamp(0.0, 1.0 - width);
                        _region['crop_y'] = (y + details.delta.dy / imageHeight)
                            .clamp(0.0, 1.0 - height);
                      });
                      _emit();
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ClipRect(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  left: -x * imageWidth,
                                  top: -y * imageHeight,
                                  width: imageWidth,
                                  height: imageHeight,
                                  child: _ArtistAssetImage(
                                    imageUrl: widget.imageUrl,
                                    fit: BoxFit.fill,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black54,
                                    blurRadius: 3,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -5,
                          bottom: -5,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeDownRight,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (details) {
                                setState(() {
                                  _region['crop_width'] =
                                      (width + details.delta.dx / imageWidth)
                                          .clamp(0.08, 1.0 - x);
                                  _region['crop_height'] =
                                      (height + details.delta.dy / imageHeight)
                                          .clamp(0.08, 1.0 - y);
                                });
                                _emit();
                              },
                              child: Tooltip(
                                message: _tr(context, 'Resize crop region'),
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.open_in_full,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
