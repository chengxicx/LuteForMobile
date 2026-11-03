import 'package:shared_preferences/shared_preferences.dart';

import '../network/session_manager.dart';

/// One-time migration of the pre-scope preference keys.
///
/// Older builds wrote account-specific choices without a scope suffix
/// (`dict_for_lang_<id>`, `book_lang_id_<bookId>`, `book_lang_name_<bookId>`).
/// The first version that introduced scoping migrated them lazily, on the
/// first *read* -- so whichever account opened the dictionary card first
/// claimed the other account's entries.  On a shared device that is a real
/// data loss (the owner's selections silently moved into the guest's scope).
///
/// This runs once, before the first frame, using the identity the device was
/// last used with.  After it, the legacy keys are gone and every account only
/// sees its own `@scope` keys -- no later account can claim them.
const String _markerKey = 'legacy_scoped_prefs_migrated_v1';

const String _dictPrefix = 'dict_for_lang_';
const String _bookLangIdPrefix = 'book_lang_id_';
const String _bookLangNamePrefix = 'book_lang_name_';

/// Claims the unscoped keys for the current (hydrated) identity.
///
/// Safe to call repeatedly; after the first run the marker short-circuits.
/// Keys that are absent or hold an empty value are simply dropped: an empty
/// value carries no choice, and leaving it behind would let a later account
/// claim it again.
///
/// [scopeOverride] is a test seam; production always uses
/// [SessionManager.cacheScope].
Future<void> migrateLegacyScopedPrefs({
  SharedPreferences? prefs,
  String? scopeOverride,
}) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  if (p.getBool(_markerKey) == true) return;

  final scope = scopeOverride ?? SessionManager.cacheScope;
  // No server configured yet: 'default' is not reachable from any real
  // account, so keep the legacy keys until the first identity exists.
  if (scope.isEmpty || scope == 'default') return;

  for (final key in p.getKeys().toList()) {
    if (key.contains('@')) continue;

    final dict = RegExp('^$_dictPrefix(\\d+)\$').firstMatch(key);
    if (dict != null) {
      await _migrateString(
        p,
        key,
        '$_dictPrefix${dict.group(1)}@$scope',
      );
      continue;
    }

    final bookId = RegExp('^$_bookLangIdPrefix(\\d+)\$').firstMatch(key);
    if (bookId != null) {
      await _migrateInt(
        p,
        key,
        '$_bookLangIdPrefix${bookId.group(1)}@$scope',
      );
      continue;
    }

    final bookName =
        RegExp('^$_bookLangNamePrefix(\\d+)\$').firstMatch(key);
    if (bookName != null) {
      await _migrateString(
        p,
        key,
        '$_bookLangNamePrefix${bookName.group(1)}@$scope',
      );
    }
  }

  await p.setBool(_markerKey, true);
}

Future<void> _migrateString(
  SharedPreferences prefs,
  String legacyKey,
  String scopedKey,
) async {
  final legacy = prefs.get(legacyKey);
  final existing = prefs.get(scopedKey);
  final scopedEmpty = existing == null || '$existing'.trim().isEmpty;
  if (scopedEmpty) {
    final value = legacy == null ? '' : '$legacy'.trim();
    if (value.isNotEmpty) await prefs.setString(scopedKey, value);
  }
  await prefs.remove(legacyKey);
}

Future<void> _migrateInt(
  SharedPreferences prefs,
  String legacyKey,
  String scopedKey,
) async {
  final legacy = prefs.get(legacyKey);
  final scopedExists = prefs.get(scopedKey) != null;
  if (!scopedExists) {
    final value =
        legacy is int ? legacy : int.tryParse(legacy == null ? '' : '$legacy');
    if (value != null && value > 0) await prefs.setInt(scopedKey, value);
  }
  await prefs.remove(legacyKey);
}
