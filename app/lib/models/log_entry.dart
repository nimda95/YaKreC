enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime ts;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry(this.level, this.tag, this.message) : ts = DateTime.now();

  String formatted() =>
      '${ts.toIso8601String()} [${level.name.toUpperCase().padRight(5)}] $tag: $message';
}
