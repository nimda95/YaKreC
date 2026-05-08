import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// "Donate" surface for the home drawer. Two paths:
///   * **Online** — launches the project's donation page in the user's
///     browser. Always available.
///   * **Google Play** — placeholder. Real Play Billing needs products
///     configured in Play Console first; until then the button surfaces
///     a snackbar so users know it's coming. Hidden on non-Android.
class DonateDialog extends StatelessWidget {
  static const _donateUrl = 'https://aymane.xyz/yakrec-donate.html';

  const DonateDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const DonateDialog(),
    );
  }

  Future<void> _openOnline(BuildContext ctx) async {
    final uri = Uri.parse(_donateUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
        content: Text('Could not open $_donateUrl'),
      ));
    }
    if (ctx.mounted) Navigator.of(ctx).maybePop();
  }

  void _openPlay(BuildContext ctx) {
    Navigator.of(ctx).maybePop();
    // TODO: wire in_app_purchase here once Play Console products exist.
    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
      content: Text(
        'Google Play donations are coming once products are configured. '
        'Use the online donation in the meantime — thank you!',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.volunteer_activism),
      title: const Text('Support YaKreC'),
      content: const Text(
        "Thanks for using YaKreC! If you'd like to help cover hosting + "
        "development costs, you can donate via the project's website, or "
        "(soon) directly through Google Play.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Not now'),
        ),
        if (Platform.isAndroid)
          TextButton.icon(
            icon: const Icon(Icons.shop),
            label: const Text('Google Play'),
            onPressed: () => _openPlay(context),
          ),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Donation page'),
          onPressed: () => _openOnline(context),
        ),
      ],
    );
  }
}
