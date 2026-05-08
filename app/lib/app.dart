import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme/theme_controller.dart';
import 'ui/home_page.dart';

class KvmApp extends StatelessWidget {
  const KvmApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = Colors.deepPurple;
    return Consumer<ThemeController>(
      builder: (_, theme, __) => MaterialApp(
        title: 'YaKreC',
        debugShowCheckedModeBanner: false,
        themeMode: theme.mode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
