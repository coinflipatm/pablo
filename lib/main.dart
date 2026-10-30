import 'package:flutter/material.dart';

import 'intent_channel.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  IntentChannel.install();
  runApp(const PabloApp());
}

class PabloApp extends StatelessWidget {
  const PabloApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFF59E0B),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Pablo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0F1217),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF181D26),
          foregroundColor: Color(0xFFE2E8F0),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(color: Color(0xFF181D26)),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF181D26),
          border: OutlineInputBorder(),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(60),
            textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
