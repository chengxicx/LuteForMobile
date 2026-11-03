import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/providers/settings_provider.dart';
import '../../core/network/api_service.dart';
import '../../core/network/content_service.dart';
import '../../core/network/dictionary_service.dart';
import '../../core/cache/providers/page_cache_provider.dart';
import '../../core/cache/providers/term_cache_provider.dart';

// API service provider using serverUrl from settings.
//
// Watches only the fields ApiService actually depends on.  Watching the whole
// [settingsProvider] rebuilt every service below it on *any* setting change --
// including a language-filter clear during login/logout -- and a rebuilt
// outbox service used to lose the intents added during this session.
final apiServiceProvider = Provider<ApiService>((ref) {
  final serverUrl = ref.watch(settingsProvider.select((s) => s.serverUrl));
  final basicAuthUser =
      ref.watch(settingsProvider.select((s) => s.basicAuthUser));
  final basicAuthPassword =
      ref.watch(settingsProvider.select((s) => s.basicAuthPassword));
  return ApiService(
    baseUrl: serverUrl,
    basicAuthUser: basicAuthUser,
    basicAuthPassword: basicAuthPassword,
  );
});

// Content service provider
final contentServiceProvider = Provider<ContentService>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  final pageCacheService = ref.watch(pageCacheServiceProvider);
  final termCacheService = ref.watch(termCacheServiceProvider);
  final batchSize = ref.watch(
    settingsProvider.select((s) => s.statsRefreshBatchSize),
  );
  final service = ContentService(
    apiService: apiService,
    pageCacheService: pageCacheService,
    termCacheService: termCacheService,
  );
  service.setBookStatsBatchSize(batchSize);
  return service;
});

// Dictionary service provider
final dictionaryServiceProvider = Provider<DictionaryService>((ref) {
  final contentService = ref.watch(contentServiceProvider);
  return DictionaryService(
    fetchLanguageSettingsHtml: (langId) =>
        contentService.getLanguageSettingsHtml(langId),
  );
});
