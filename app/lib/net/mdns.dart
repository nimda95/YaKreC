import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:permission_handler/permission_handler.dart';

/// Result of an mDNS resolve attempt.
sealed class MdnsResult {
  const MdnsResult();
}

class MdnsResolved extends MdnsResult {
  final String address;
  const MdnsResolved(this.address);
}

class MdnsNotNeeded extends MdnsResult {
  const MdnsNotNeeded();
}

class MdnsPermissionDenied extends MdnsResult {
  /// True when the OS will no longer prompt — the user must change settings.
  final bool permanentlyDenied;
  const MdnsPermissionDenied({this.permanentlyDenied = false});
}

class MdnsFailed extends MdnsResult {
  final String reason;
  const MdnsFailed(this.reason);
}

/// In-process cache for the lifetime of the app: hostname → IP. Cleared by
/// the OS along with the process; we deliberately don't persist it because
/// LAN IPs change after DHCP renews.
final Map<String, String> _cache = {};

bool _looksLocal(String host) {
  final h = host.toLowerCase();
  // Treat ".local" hostnames OR single-label names (no dots) as mDNS targets.
  return h.endsWith('.local') || !h.contains('.');
}

String _stripPort(String host) {
  // host strings can carry a `:port` suffix (e.g. "kvm.local:8080"). mDNS
  // resolves names, not endpoints — strip the port for the lookup and let
  // the caller re-attach it.
  final colon = host.lastIndexOf(':');
  if (colon < 0) return host;
  // IPv6 already excluded: hosts here are user-typed names.
  return host.substring(0, colon);
}

String? _portSuffix(String host) {
  final colon = host.lastIndexOf(':');
  if (colon < 0) return null;
  return host.substring(colon);
}

/// True iff [host] is something we'd attempt to resolve via mDNS.
bool isMdnsTarget(String host) => _looksLocal(_stripPort(host));

/// Probe whether the system needs an mDNS lookup for [host] *and* whether the
/// permission required to do so is currently granted. Used to decide whether
/// to show the explanatory pre-prompt before connecting.
Future<bool> needsMdnsPermissionPrompt(String host) async {
  if (!isMdnsTarget(host)) return false;
  if (_cache.containsKey(_stripPort(host).toLowerCase())) return false;
  if (!Platform.isAndroid) return false;
  final status = await Permission.nearbyWifiDevices.status;
  return !status.isGranted;
}

/// Request the runtime permission for mDNS scans. Caller is expected to have
/// already shown the explanatory dialog before invoking this.
Future<MdnsPermissionDenied?> requestMdnsPermission() async {
  if (!Platform.isAndroid) return null;
  final result = await Permission.nearbyWifiDevices.request();
  if (result.isGranted) return null;
  return MdnsPermissionDenied(
    permanentlyDenied: result.isPermanentlyDenied,
  );
}

/// Resolve [host] to an IP via mDNS. No-op for hosts that are already IPs or
/// non-`.local` DNS names. Caches the result for the session.
///
/// On Android, requires NEARBY_WIFI_DEVICES on API 33+; the caller is
/// expected to have already prompted for it via [requestMdnsPermission].
Future<MdnsResult> resolveLocal(String host) async {
  final hostNoPort = _stripPort(host);
  if (!_looksLocal(hostNoPort)) return const MdnsNotNeeded();

  final cached = _cache[hostNoPort.toLowerCase()];
  if (cached != null) {
    return MdnsResolved('$cached${_portSuffix(host) ?? ''}');
  }

  if (Platform.isAndroid) {
    final status = await Permission.nearbyWifiDevices.status;
    if (!status.isGranted) {
      return MdnsPermissionDenied(
        permanentlyDenied: status.isPermanentlyDenied,
      );
    }
  }

  // Bonjour-style names omit the trailing ".local" — append it for single-
  // label inputs so the multicast packet is well-formed.
  final fullName =
      hostNoPort.contains('.') ? hostNoPort : '$hostNoPort.local';

  final client = MDnsClient();
  try {
    await client.start();
    String? found;
    final stream = client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(fullName),
        )
        .timeout(const Duration(seconds: 3));
    await for (final r in stream) {
      found = r.address.address;
      break;
    }
    if (found == null) {
      // IPv4 didn't answer — try IPv6 in case the device is link-local v6.
      final stream6 = client
          .lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv6(fullName),
          )
          .timeout(const Duration(seconds: 3));
      await for (final r in stream6) {
        found = r.address.address;
        break;
      }
    }
    if (found == null) {
      return const MdnsFailed('No answer from mDNS within 3s.');
    }
    _cache[hostNoPort.toLowerCase()] = found;
    debugPrint('mdns: $hostNoPort -> $found');
    return MdnsResolved('$found${_portSuffix(host) ?? ''}');
  } on TimeoutException {
    return const MdnsFailed('mDNS lookup timed out.');
  } catch (e) {
    return MdnsFailed('$e');
  } finally {
    client.stop();
  }
}

/// Drop a cached resolution — useful on connect failure so the next attempt
/// re-runs the lookup (the device may have moved IPs).
void invalidateMdnsCache(String host) {
  _cache.remove(_stripPort(host).toLowerCase());
}
