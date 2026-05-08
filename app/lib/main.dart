import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'storage/device_store.dart';
import 'theme/theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await DeviceStore.load();
  final theme = ThemeController();
  await theme.load();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: theme),
      ],
      child: const KvmApp(),
    ),
  );
}
