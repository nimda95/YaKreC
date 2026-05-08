import 'package:flutter/material.dart';

import '../storage/menu_layout_store.dart';

/// Stable id + display info for every customisable menu action. The id
/// matches the `_MenuAction.name` used at the connect-page side, so the
/// settings here line up with the actual action surface.
class _ActionDef {
  final String id;
  final IconData icon;
  final String label;
  const _ActionDef(this.id, this.icon, this.label);

  static const all = <_ActionDef>[
    _ActionDef('disconnect', Icons.power_settings_new, 'Disconnect'),
    _ActionDef('toggleZoomLock', Icons.lock_open, 'Lock zoom'),
    _ActionDef('rotate', Icons.screen_rotation, 'Rotate device'),
    _ActionDef('toggleFullscreen', Icons.fullscreen, 'Fullscreen'),
    _ActionDef('toggleAbsolutePointer', Icons.mouse_outlined, 'Absolute pointer'),
    _ActionDef('enterPip', Icons.picture_in_picture_alt, 'Picture in Picture'),
    _ActionDef('toggleJiggler', Icons.directions_run, 'Mouse jiggler'),
    _ActionDef('power', Icons.power_settings_new, 'Power…'),
    _ActionDef('qualityControls', Icons.tune, 'Stream quality…'),
    _ActionDef('streaming', Icons.cast_connected, 'Streaming…'),
    _ActionDef('toggleMicMute', Icons.mic, 'Mute / unmute mic'),
    _ActionDef('toggleDebug', Icons.bug_report_outlined, 'Debug info'),
    _ActionDef('showLog', Icons.notes, 'View logs'),
    _ActionDef('specialKeys', Icons.bolt, 'Special keys'),
    _ActionDef('osKeyboard', Icons.keyboard, 'On-screen keyboard'),
    _ActionDef('keysOverlay', Icons.keyboard_command_key, 'Keys overlay'),
    _ActionDef('toggleOskFloating', Icons.toggle_off, 'Floating keyboard mode'),
    _ActionDef('nativeKeyboard', Icons.keyboard_alt_outlined, 'Native keyboard'),
  ];
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  MenuLayout? _layout;

  @override
  void initState() {
    super.initState();
    MenuLayoutStore.load().then((l) {
      if (mounted) {
        setState(() => _layout = l);
        l.addListener(_onLayoutChanged);
      }
    });
  }

  @override
  void dispose() {
    _layout?.removeListener(_onLayoutChanged);
    super.dispose();
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          if (layout != null)
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: 'Reset to defaults',
              onPressed: () => layout.reset(),
            ),
        ],
      ),
      body: layout == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('Menu actions'),
                const _ColumnLegend(),
                for (final a in _ActionDef.all) _ActionRow(action: a, layout: layout),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ColumnLegend extends StatelessWidget {
  const _ColumnLegend();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: const [
          Expanded(child: SizedBox()),
          SizedBox(width: 56, child: Center(child: Text('Popup',
              style: TextStyle(fontSize: 12, color: Colors.grey)))),
          SizedBox(width: 56, child: Center(child: Text('Toolbar',
              style: TextStyle(fontSize: 12, color: Colors.grey)))),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final _ActionDef action;
  final MenuLayout layout;
  const _ActionRow({required this.action, required this.layout});

  @override
  Widget build(BuildContext context) {
    final placement = layout.placementFor(action.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(action.icon),
          const SizedBox(width: 16),
          Expanded(child: Text(action.label)),
          SizedBox(
            width: 56,
            child: Switch(
              value: placement.popup,
              onChanged: (v) => layout.setPlacement(
                action.id,
                placement.copyWith(popup: v),
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Switch(
              value: placement.toolbar,
              onChanged: (v) => layout.setPlacement(
                action.id,
                placement.copyWith(toolbar: v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
