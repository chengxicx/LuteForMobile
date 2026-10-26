/// Local ("pool") dictionaries and the URLs they are looked up through.
///
/// A local dictionary lives on the Lute server as a `.db` file in the
/// pool folder.  Its row in the language's dictionary list carries the
/// **file name** as the row's "uri" -- not a URL:
///
///   <input name="dictionaries-0-dicturi" value="moji-xxxx.db" hidden disabled>
///
/// The web reading page never loads that string: `Language.dicts_for_tabs`
/// turns a `localdict` row into `/read/localdict/<langid>/<file>/[LUTE]`
/// (lute/models/language.py) and the route renders the entry's HTML
/// (lute/read/routes.py).  Handing the bare file name to a WebView instead
/// makes it resolve `moji-xxxx.db` as a *host name*, i.e. a guaranteed
/// `net::ERR_NAME_NOT_RESOLVED`.
library;

/// True when [uri] is a pool file name rather than a lookup URL.
///
/// The language settings form renders a local row's text input with the
/// file name in it, so this is what the mobile parser sees.  Anything with
/// a scheme (`https://...`), or not ending in `.db`, is a normal dictionary.
bool looksLikeLocalDictFile(String uri) {
  final trimmed = uri.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains('://')) return false;
  return trimmed.toLowerCase().endsWith('.db');
}

/// A readable fallback label for a pool file: `moji-3f2a9c.db` -> `moji-3f2a9c`.
String localDictFallbackName(String fileName) {
  final base = fileName.trim().split('/').last;
  if (base.toLowerCase().endsWith('.db')) {
    return base.substring(0, base.length - 3);
  }
  return base;
}

/// The server route that answers a lookup from one pool file.
///
/// Mirrors the web tab URL built in `Language._local_dict_tab_entry`
/// (`/read/localdict/<langid>/<filename>/[LUTE]`), with the term in place.
String buildLocalDictUrl({
  required String serverUrl,
  required int languageId,
  required String fileName,
  required String term,
}) {
  final base = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;
  final file = Uri.encodeComponent(fileName.trim());
  final text = Uri.encodeComponent(term);
  return '$base/read/localdict/$languageId/$file/$text';
}
