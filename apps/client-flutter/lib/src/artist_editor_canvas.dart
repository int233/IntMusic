part of '../intmusic_client.dart';

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
