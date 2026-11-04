/// One complete Server-Sent Event, as the wire format defines it.
class SseEvent {
  final String event;
  final String data;

  const SseEvent({required this.event, required this.data});
}

/// Incremental parser for `text/event-stream` bodies.
///
/// Dio's byte stream arrives in arbitrary chunks, so the parser works one
/// already-split line at a time: [addLine] returns the event when the blank
/// separator line closes it, and null otherwise.  [flush] closes a final
/// event that the server sent without its trailing blank line.
///
/// Only `event:` and `data:` are kept.  `id:` and `retry:` are part of the
/// SSE protocol but the AI grammar endpoint does not use them, and `:` lines
/// are comments (often heartbeats) that must not become events.
class SseParser {
  String _event = '';
  final StringBuffer _data = StringBuffer();
  bool _hasData = false;

  SseEvent? addLine(String line) {
    if (line.isEmpty) return flush();

    if (line.startsWith(':')) return null;

    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    // The spec allows one optional space after the colon; strip exactly one
    // so meaningful leading spaces in a data value survive.
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        _event = value;
        break;
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
        break;
      default:
        // id / retry / unknown fields: not used by this endpoint.
        break;
    }
    return null;
  }

  SseEvent? flush() {
    if (!_hasData && _event.isEmpty) return null;
    final event = SseEvent(
      event: _event.isEmpty ? 'message' : _event,
      data: _data.toString(),
    );
    _event = '';
    _data.clear();
    _hasData = false;
    return event;
  }
}
