import 'package:flutter/material.dart';
import 'colors.dart';

class NexaTheme {
  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: NexaColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: NexaColors.primary,
      primary: NexaColors.primary,
      secondary: NexaColors.secondary,
    ),
  );
}