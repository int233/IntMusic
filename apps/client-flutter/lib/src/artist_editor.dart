part of '../intmusic_client.dart';

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

  void _mutate(VoidCallback mutation) => setState(mutation);
}
