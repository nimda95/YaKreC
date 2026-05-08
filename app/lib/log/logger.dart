import 'dart:async';

import '../models/log_entry.dart';

class Logger {
  final List<LogEntry> _entries = [];
  final _ctrl = StreamController<LogEntry>.broadcast();
  static const _maxEntries = 5000;

  List<LogEntry> get entries => List.unmodifiable(_entries);
  Stream<LogEntry> get stream => _ctrl.stream;

  void log(LogLevel level, String tag, String message) {
    final e = LogEntry(level, tag, message);
    _entries.add(e);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, 200);
    }
    _ctrl.add(e);
  }

  void d(String tag, String m) => log(LogLevel.debug, tag, m);
  void i(String tag, String m) => log(LogLevel.info, tag, m);
  void w(String tag, String m) => log(LogLevel.warn, tag, m);
  void e(String tag, String m) => log(LogLevel.error, tag, m);

  String exportText() => _entries.map((e) => e.formatted()).join('\n');

  Future<void> dispose() => _ctrl.close();
}
