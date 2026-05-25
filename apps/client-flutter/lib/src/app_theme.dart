import 'package:flutter/material.dart';

const appBg = Color(0xff0d0f12);
const appSurface = Color(0xff15171c);
const appSurfaceHigh = Color(0xff1c1f26);
const appBorder = Color(0xff2a2e37);
const appHover = Color(0xff242832);
const appPrimary = Color(0xffe45d72);
const appSecondary = Color(0xffd8b15f);
const appPlaying = Color(0xff66d19e);

ThemeData buildIntMusicTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: appPrimary,
    brightness: Brightness.dark,
  ).copyWith(surface: appSurface, primary: appPrimary, secondary: appSecondary);

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: appBg,
    useMaterial3: true,
    dividerColor: appBorder,
    textTheme: Typography.material2021(platform: TargetPlatform.windows).white
        .apply(
          fontFamily: 'Microsoft YaHei UI',
          fontFamilyFallback: const [
            'Microsoft YaHei',
            'SimHei',
            'PingFang SC',
            'Noto Sans CJK SC',
            'Segoe UI',
          ],
          bodyColor: const Color(0xffe9edf2),
          displayColor: const Color(0xffe9edf2),
        ),
    iconTheme: const IconThemeData(color: Color(0xffd3d7dd)),
    cardTheme: CardThemeData(
      color: appSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 0,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: appSurfaceHigh,
      selectedColor: appPrimary.withValues(alpha: 0.18),
      side: const BorderSide(color: appBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: appPrimary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: appSurfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: appBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: appBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: appPrimary),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      dense: true,
      minVerticalPadding: 8,
      iconColor: Color(0xffcfd4db),
    ),
  );
}
