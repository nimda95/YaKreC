import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/device.dart';
import '../storage/device_store.dart';
import '../theme/theme_controller.dart';
import 'add_device_dialog.dart';
import 'connect_page.dart';
import 'donate_dialog.dart';
import 'settings_page.dart';

/// Home / saved-devices screen. Loosely modeled on aVNC's UI:
///   * Hamburger drawer for navigation (Settings, Donate, Source, theme).
///   * Card-based list of saved devices with quick edit/delete via a
///     trailing popup menu, tap-to-connect on the card body.
///   * FAB to add a new device.
///   * Empty state CTA when the list is empty.
///   * Both light + dark themes via [ThemeController].
class HomePage extends StatelessWidget {
  static const _sourceUrl = 'https://github.com/nimda95/yakrec';

  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YaKreC'),
        // Drawer hamburger added automatically by Scaffold.drawer.
      ),
      drawer: const _HomeDrawer(),
      body: Consumer<DeviceStore>(
        builder: (context, store, _) {
          final devices = store.devices;
          if (devices.isEmpty) return const _EmptyState();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: devices.length,
            itemBuilder: (_, i) => _DeviceCard(device: devices[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New device'),
        onPressed: () async {
          final d = await showDialog<Device>(
            context: context,
            builder: (_) => const AddDeviceDialog(),
          );
          if (d != null && context.mounted) {
            await context.read<DeviceStore>().add(d);
          }
        },
      ),
    );
  }
}

class _HomeDrawer extends StatelessWidget {
  const _HomeDrawer();

  Future<void> _openSource(BuildContext context) async {
    final uri = Uri.parse(HomePage._sourceUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not open ${HomePage._sourceUrl}'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: scheme.primaryContainer),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      'YaKreC',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Yet Another KVM REmote Client',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onPrimaryContainer.withOpacity(0.85),
                          ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Settings'),
                    subtitle: const Text('Menu / toolbar layout'),
                    onTap: () {
                      Navigator.of(context).pop(); // close drawer
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsPage(),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.volunteer_activism),
                    title: const Text('Donate'),
                    subtitle: const Text('Support development'),
                    onTap: () {
                      Navigator.of(context).pop();
                      DonateDialog.show(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: const Text('Source code'),
                    subtitle: const Text('github.com/nimda95/yakrec'),
                    onTap: () {
                      Navigator.of(context).pop();
                      _openSource(context);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: const _ThemeSegmented(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three-segment System / Light / Dark control wired to [ThemeController].
class _ThemeSegmented extends StatelessWidget {
  const _ThemeSegmented();

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeController>(
      builder: (_, ctrl, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Theme',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode),
                label: Text('Dark'),
              ),
            ],
            selected: {ctrl.mode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => ctrl.setMode(s.first),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other,
                size: 72, color: scheme.primary.withOpacity(0.55)),
            const SizedBox(height: 16),
            Text(
              'No devices yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the button below to add a PiKVM or '
              'Sipeed NanoKVM you control.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final Device device;
  const _DeviceCard({required this.device});

  IconData get _icon => switch (device.type) {
        DeviceType.pikvm => Icons.developer_board,
        DeviceType.nanokvm => Icons.memory,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cardSurface = scheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: cardSurface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ConnectPage(device: device)),
            );
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_icon, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${device.type.label} · '
                        '${device.useHttps ? 'https' : 'http'}://${device.host}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (action) async {
                    final store = context.read<DeviceStore>();
                    if (action == 'edit') {
                      final d = await showDialog<Device>(
                        context: context,
                        builder: (_) => AddDeviceDialog(existing: device),
                      );
                      if (d != null) await store.update(d);
                    } else if (action == 'delete') {
                      final ok = await _confirmDelete(context);
                      if (ok == true) await store.remove(device.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Edit'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Delete "${device.name}"?'),
        content: const Text(
          'The device entry and its saved password will be removed. '
          'You can add it back at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
