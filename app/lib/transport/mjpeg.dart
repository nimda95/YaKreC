import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../log/logger.dart';

class MjpegFrame {
  final Uint8List bytes;
  final int seq;
  MjpegFrame(this.bytes, this.seq);
}

/// Streams frames from a `multipart/x-mixed-replace` MJPEG endpoint.
/// Single subscription. Call [start] once, listen, [stop] to release.
class MjpegStream {
  final Uri url;
  final Map<String, String> headers;
  final bool acceptSelfSigned;
  final Logger logger;

  HttpClient? _http;
  StreamController<MjpegFrame>? _ctrl;
  bool _stopped = false;
  int _seq = 0;

  MjpegStream({
    required this.url,
    required this.headers,
    required this.acceptSelfSigned,
    required this.logger,
  });

  Stream<MjpegFrame> start() {
    _ctrl = StreamController<MjpegFrame>(onCancel: stop);
    _run();
    return _ctrl!.stream;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      _http?.close(force: true);
    } catch (_) {}
    await _ctrl?.close();
  }

  Future<void> _run() async {
    try {
      _http = HttpClient();
      if (acceptSelfSigned) {
        _http!.badCertificateCallback = (_, __, ___) => true;
      }
      _http!.connectionTimeout = const Duration(seconds: 10);
      logger.i('mjpeg', 'GET $url');
      final req = await _http!.getUrl(url);
      headers.forEach((k, v) => req.headers.add(k, v));
      final resp = await req.close();
      logger.i('mjpeg', 'HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final ct = resp.headers.contentType;
      final ctRaw = resp.headers.value('content-type');
      logger.i('mjpeg', 'content-type: ${ctRaw ?? '(none)'}');
      // ContentType.value strips parameters, so read boundary explicitly.
      // Fall back to a regex over the raw header for servers that pack the
      // boundary unusually (e.g. quoted, or no whitespace after `;`).
      final boundaryStr = ct?.parameters['boundary'] ??
          _boundary(ct?.toString() ?? '') ??
          _boundary(ctRaw ?? '');
      if (boundaryStr == null || boundaryStr.isEmpty) {
        // Dump every response header so we can see what the server actually
        // sent — saves a debugging round-trip.
        final hdrs = <String>[];
        resp.headers.forEach((k, v) => hdrs.add('$k: ${v.join(', ')}'));
        logger.e('mjpeg', 'no boundary; headers were:\n${hdrs.join('\n')}');
        throw FormatException(
            'no multipart boundary in Content-Type: ${ctRaw ?? '(none)'}');
      }
      logger.i('mjpeg', 'boundary: $boundaryStr');
      await _parse(resp, utf8.encode('--$boundaryStr'));
      logger.w('mjpeg', 'stream ended');
    } catch (err, st) {
      if (!_stopped) {
        logger.e('mjpeg', 'stream error: $err');
        _ctrl?.addError(err, st);
      }
    }
  }

  static String? _boundary(String ct) {
    final m = RegExp(r'boundary=([^;]+)').firstMatch(ct);
    return m?.group(1)?.replaceAll('"', '').trim();
  }

  Future<void> _parse(Stream<List<int>> stream, List<int> boundary) async {
    final buf = <int>[];
    await for (final chunk in stream) {
      if (_stopped) return;
      buf.addAll(chunk);
      while (true) {
        final consumed = _tryEmit(buf, boundary);
        if (consumed <= 0) break;
        buf.removeRange(0, consumed);
      }
    }
  }

  int _tryEmit(List<int> data, List<int> boundary) {
    final start = _indexOf(data, boundary, 0);
    if (start < 0) return 0;
    final hdrStart = start + boundary.length;
    final hdrEnd = _indexOf(data, _crlfcrlf, hdrStart);
    if (hdrEnd < 0) return 0;
    final hdrText = ascii.decode(
      data.sublist(hdrStart, hdrEnd),
      allowInvalid: true,
    );
    final cl = _contentLength(hdrText);
    final bodyStart = hdrEnd + 4;
    int bodyEnd;
    if (cl != null) {
      bodyEnd = bodyStart + cl;
      if (data.length < bodyEnd) return 0;
    } else {
      final next = _indexOf(data, boundary, bodyStart);
      if (next < 0) return 0;
      bodyEnd = next;
      if (bodyEnd >= bodyStart + 2 &&
          data[bodyEnd - 2] == 0x0D &&
          data[bodyEnd - 1] == 0x0A) {
        bodyEnd -= 2;
      }
    }
    final frame = Uint8List.fromList(data.sublist(bodyStart, bodyEnd));
    _ctrl?.add(MjpegFrame(frame, _seq++));
    return cl != null ? bodyEnd : bodyEnd;
  }

  static const _crlfcrlf = [0x0D, 0x0A, 0x0D, 0x0A];

  static int _indexOf(List<int> data, List<int> pat, int from) {
    final n = data.length - pat.length;
    outer:
    for (int i = from; i <= n; i++) {
      for (int j = 0; j < pat.length; j++) {
        if (data[i + j] != pat[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int? _contentLength(String headers) {
    for (final line in headers.split(RegExp(r'\r?\n'))) {
      if (line.toLowerCase().startsWith('content-length:')) {
        return int.tryParse(line.split(':')[1].trim());
      }
    }
    return null;
  }
}
