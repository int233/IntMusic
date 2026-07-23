import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Compatibility aliases for the existing feature widgets. New widgets should
// read semantic colors from IntMusicTheme instead of adding more raw colors.
const appBg = Color(0xff090a0f);
const appSurface = Color(0xff11131a);
const appSurfaceHigh = Color(0xff191c25);
const appBorder = Color(0x26ffffff);
const appHover = Color(0xff222632);
const appPrimary = Color(0xffff5c78);
const appSecondary = Color(0xffffc15c);
const appPlaying = Color(0xff56d6a0);

@immutable
class IntMusicTheme extends ThemeExtension<IntMusicTheme> {
  const IntMusicTheme({
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceGlass,
    required this.stroke,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.accentWarm,
    required this.playing,
    required this.danger,
    required this.glassBlur,
    required this.radiusSmall,
    required this.radiusMedium,
    required this.radiusLarge,
    required this.radiusXLarge,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceGlass;
  final Color stroke;
  final Color textPrimary;
  final Color textSecondary;
  final Color accent;
  final Color accentWarm;
  final Color playing;
  final Color danger;
  final double glassBlur;
  final double radiusSmall;
  final double radiusMedium;
  final double radiusLarge;
  final double radiusXLarge;

  static IntMusicTheme of(BuildContext context) =>
      Theme.of(context).extension<IntMusicTheme>() ?? dark;

  static const dark = IntMusicTheme(
    canvas: appBg,
    surface: appSurface,
    surfaceRaised: appSurfaceHigh,
    surfaceGlass: Color(0xb8151821),
    stroke: appBorder,
    textPrimary: Color(0xfff5f6fa),
    textSecondary: Color(0xffaeb4c2),
    accent: appPrimary,
    accentWarm: appSecondary,
    playing: appPlaying,
    danger: Color(0xffff657a),
    glassBlur: 30,
    radiusSmall: 10,
    radiusMedium: 14,
    radiusLarge: 20,
    radiusXLarge: 28,
  );

  static const light = IntMusicTheme(
    canvas: Color(0xfff4f5f8),
    surface: Color(0xfffbfbfd),
    surfaceRaised: Colors.white,
    surfaceGlass: Color(0xc8ffffff),
    stroke: Color(0x1f11131a),
    textPrimary: Color(0xff171820),
    textSecondary: Color(0xff666c79),
    accent: Color(0xffd82f58),
    accentWarm: Color(0xffb87912),
    playing: Color(0xff14875d),
    danger: Color(0xffc92848),
    glassBlur: 28,
    radiusSmall: 10,
    radiusMedium: 14,
    radiusLarge: 20,
    radiusXLarge: 28,
  );

  @override
  IntMusicTheme copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceGlass,
    Color? stroke,
    Color? textPrimary,
    Color? textSecondary,
    Color? accent,
    Color? accentWarm,
    Color? playing,
    Color? danger,
    double? glassBlur,
    double? radiusSmall,
    double? radiusMedium,
    double? radiusLarge,
    double? radiusXLarge,
  }) {
    return IntMusicTheme(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceGlass: surfaceGlass ?? this.surfaceGlass,
      stroke: stroke ?? this.stroke,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      accent: accent ?? this.accent,
      accentWarm: accentWarm ?? this.accentWarm,
      playing: playing ?? this.playing,
      danger: danger ?? this.danger,
      glassBlur: glassBlur ?? this.glassBlur,
      radiusSmall: radiusSmall ?? this.radiusSmall,
      radiusMedium: radiusMedium ?? this.radiusMedium,
      radiusLarge: radiusLarge ?? this.radiusLarge,
      radiusXLarge: radiusXLarge ?? this.radiusXLarge,
    );
  }

  @override
  IntMusicTheme lerp(covariant IntMusicTheme? other, double t) {
    if (other == null) {
      return this;
    }
    return IntMusicTheme(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceGlass: Color.lerp(surfaceGlass, other.surfaceGlass, t)!,
      stroke: Color.lerp(stroke, other.stroke, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentWarm: Color.lerp(accentWarm, other.accentWarm, t)!,
      playing: Color.lerp(playing, other.playing, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      glassBlur: lerpDouble(glassBlur, other.glassBlur, t)!,
      radiusSmall: lerpDouble(radiusSmall, other.radiusSmall, t)!,
      radiusMedium: lerpDouble(radiusMedium, other.radiusMedium, t)!,
      radiusLarge: lerpDouble(radiusLarge, other.radiusLarge, t)!,
      radiusXLarge: lerpDouble(radiusXLarge, other.radiusXLarge, t)!,
    );
  }
}

ThemeData buildIntMusicTheme({
  Brightness brightness = Brightness.dark,
  TargetPlatform? platform,
}) {
  final tokens = brightness == Brightness.dark
      ? IntMusicTheme.dark
      : IntMusicTheme.light;
  final targetPlatform = platform ?? defaultTargetPlatform;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: tokens.accent,
        brightness: brightness,
      ).copyWith(
        surface: tokens.surface,
        primary: tokens.accent,
        secondary: tokens.accentWarm,
        error: tokens.danger,
        outline: tokens.stroke,
      );

  final baseText = Typography.material2021(platform: targetPlatform).white
      .apply(
        fontFamily: _primaryFont(targetPlatform),
        fontFamilyFallback: const [
          'SF Pro Display',
          'SF Pro Text',
          'Segoe UI Variable',
          'Segoe UI',
          'PingFang SC',
          'Microsoft YaHei UI',
          'Noto Sans CJK SC',
          'Roboto',
        ],
        bodyColor: tokens.textPrimary,
        displayColor: tokens.textPrimary,
      );

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: tokens.canvas,
    useMaterial3: true,
    splashFactory: InkSparkle.splashFactory,
    dividerColor: tokens.stroke,
    extensions: <ThemeExtension<dynamic>>[tokens],
    textTheme: baseText.copyWith(
      displaySmall: baseText.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
      ),
      headlineMedium: baseText.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.7,
      ),
      headlineSmall: baseText.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.45,
      ),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: baseText.bodyMedium?.copyWith(height: 1.35),
      bodySmall: baseText.bodySmall?.copyWith(
        color: tokens.textSecondary,
        height: 1.3,
      ),
    ),
    iconTheme: IconThemeData(color: tokens.textSecondary),
    cardTheme: CardThemeData(
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMedium),
        side: BorderSide(color: tokens.stroke),
      ),
      elevation: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.surfaceRaised,
      selectedColor: tokens.accent.withValues(alpha: 0.18),
      side: BorderSide(color: tokens.stroke),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(40, 42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSmall),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(40, 42),
        side: BorderSide(color: tokens.stroke),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSmall),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size.square(40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSmall),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.surfaceRaised.withValues(alpha: 0.8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMedium),
        borderSide: BorderSide(color: tokens.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMedium),
        borderSide: BorderSide(color: tokens.stroke),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMedium),
        borderSide: BorderSide(color: tokens.accent, width: 1.4),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: tokens.accent,
      inactiveTrackColor: tokens.stroke,
      thumbColor: tokens.textPrimary,
      overlayColor: tokens.accent.withValues(alpha: 0.14),
      trackHeight: 3,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minVerticalPadding: 8,
      iconColor: tokens.textSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surfaceGlass,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusLarge),
        side: BorderSide(color: tokens.stroke),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surfaceGlass,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.radiusXLarge),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.stroke),
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 18)],
      ),
      textStyle: TextStyle(color: tokens.textPrimary, fontSize: 12),
    ),
  );
}

String? _primaryFont(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.macOS || TargetPlatform.iOS => '.AppleSystemUIFont',
    TargetPlatform.windows => 'Segoe UI Variable',
    _ => null,
  };
}

class IntMusicBackdrop extends StatelessWidget {
  const IntMusicBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final usesNativeWindowMaterial =
        Theme.of(context).platform == TargetPlatform.macOS;
    return ColoredBox(
      color: usesNativeWindowMaterial ? Colors.transparent : tokens.canvas,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!usesNativeWindowMaterial) ...[
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.78, -0.92),
                    radius: 1.22,
                    colors: [
                      tokens.accent.withValues(alpha: 0.16),
                      tokens.accentWarm.withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.42, 1],
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.92, 0.8),
                    radius: 1.05,
                    colors: [
                      const Color(0xff635bff).withValues(alpha: 0.1),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
          child,
        ],
      ),
    );
  }
}

class IntMusicGlass extends StatelessWidget {
  const IntMusicGlass({
    required this.child,
    this.padding,
    this.borderRadius,
    this.blur,
    this.tint,
    this.border,
    this.shadows,
    this.clipBehavior = Clip.antiAlias,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final double? blur;
  final Color? tint;
  final Border? border;
  final List<BoxShadow>? shadows;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final radius = borderRadius ?? BorderRadius.circular(tokens.radiusLarge);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow:
            shadows ??
            const [BoxShadow(color: Color(0x30000000), blurRadius: 28)],
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blur ?? tokens.glassBlur,
            sigmaY: blur ?? tokens.glassBlur,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint ?? tokens.surfaceGlass,
              border: border ?? Border.all(color: tokens.stroke),
              borderRadius: radius,
            ),
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }
}
