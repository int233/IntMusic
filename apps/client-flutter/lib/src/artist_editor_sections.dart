part of '../intmusic_client.dart';

extension _ArtistEditorSections on _ArtistEditorDialogState {
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
                _mutate(() => _section = value.first),
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
                        onTap: () => _mutate(() => _selectedAssetId = id),
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
                  onTap: () => _mutate(() => _selectedRegionIndex = index),
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
                  onTap: () => _mutate(() => _selectedSlot = entry.key),
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
                _mutate(() => _visuals[_selectedSlot] = visual);
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
                _mutate(() => _visuals[_selectedSlot] = visual);
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
                _mutate(() => _visuals[_selectedSlot] = visual);
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
                  _mutate(() => _visuals[_selectedSlot] = visual);
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
      onChanged: (_) => _mutate(() {}),
    );
  }
}
