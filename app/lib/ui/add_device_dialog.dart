import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../storage/credential_store.dart';

/// Adds or edits a device. Kept intentionally lean: just the bits required
/// to identify and authenticate. Connection mode + audio settings + any
/// other per-session knobs live in the connect-page menu instead.
class AddDeviceDialog extends StatefulWidget {
  final Device? existing;
  const AddDeviceDialog({super.key, this.existing});

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _user;
  late final TextEditingController _pass;

  late DeviceType _type;
  late bool _https;
  late bool _selfSigned;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _user = TextEditingController(text: e?.username ?? 'admin');
    _pass = TextEditingController();
    _type = e?.type ?? DeviceType.pikvm;
    _https = e?.useHttps ?? (_type == DeviceType.pikvm);
    _selfSigned = e?.acceptSelfSigned ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _onTypeChanged(DeviceType t) {
    setState(() {
      _type = t;
      // Sane defaults per device type. User can still override.
      if (widget.existing == null) {
        _https = (t == DeviceType.pikvm);
      }
    });
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _host.text.trim().isEmpty) return;
    final id = widget.existing?.id ?? const Uuid().v4();
    final existing = widget.existing;
    final d = Device(
      id: id,
      name: _name.text.trim(),
      type: _type,
      host: _host.text.trim(),
      useHttps: _https,
      acceptSelfSigned: _selfSigned,
      // Preserve the existing per-session knobs across edits — those are
      // managed from the connect-page menu, not this dialog.
      mode: existing?.mode ?? ConnectionMode.mjpeg,
      customHeaders: existing?.customHeaders ?? {},
      webrtcAudioRx: existing?.webrtcAudioRx ?? false,
      webrtcMicTx: existing?.webrtcMicTx ?? false,
      micDeviceId: existing?.micDeviceId,
      audioSinkId: existing?.audioSinkId,
      keymap: existing?.keymap,
      mouseSensitivity: existing?.mouseSensitivity ?? 1.0,
      scrollSensitivity: existing?.scrollSensitivity ?? 1.0,
      username: _user.text.trim().isEmpty ? null : _user.text.trim(),
    );
    if (_pass.text.isNotEmpty) {
      await CredentialStore.setPassword(id, _pass.text);
    }
    if (mounted) Navigator.of(context).pop(d);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add device' : 'Edit device'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<DeviceType>(
                value: _type,
                decoration: const InputDecoration(labelText: 'Device type'),
                items: DeviceType.values
                    .map((t) =>
                        DropdownMenuItem(value: t, child: Text(t.label)))
                    .toList(),
                onChanged: (v) => v == null ? null : _onTypeChanged(v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: 'pikvm.local, 10.0.0.5, or 10.0.0.5:8080',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use HTTPS'),
                value: _https,
                onChanged: (v) => setState(() => _https = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Accept self-signed certificates'),
                value: _selfSigned,
                onChanged:
                    _https ? (v) => setState(() => _selfSigned = v) : null,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                decoration: InputDecoration(
                  labelText: widget.existing == null
                      ? 'Password'
                      : 'Password (leave blank to keep)',
                ),
                obscureText: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
