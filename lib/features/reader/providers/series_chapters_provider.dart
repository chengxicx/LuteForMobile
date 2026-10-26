import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logger/api_logger.dart';
import '../../../shared/providers/server_status_provider.dart';
import '../../books/providers/books_provider.dart';
import '../models/series_chapter.dart';

/// The chapters of one book set, in reading order.
///
/// Keyed by the series tag the reading page reports (`PageData.seriesTag`).
/// The reader watches it while a chapter is open, so the list is fetched
/// once per set per session and then shared by the end-of-chapter buttons
/// (which want the neighbours' numbers) and the Contents sheet (which wants
/// the titles).
///
/// Online it asks the server -- adding a chapter to a set must show up
/// immediately -- and falls back to the cached member list when the server
/// is unreachable, which is what makes the sheet usable on the subway.  An
/// empty result is a legitimate answer: a tag with no members, or offline
/// with nothing cached, and the sheet then says so instead of spinning.
final seriesChaptersProvider = FutureProvider.autoDispose
    .family<List<SeriesChapter>, String>((ref, tag) async {
      final repository = ref.read(booksRepositoryProvider);

      Future<List<SeriesChapter>?> fromServer() async {
        try {
          final books = await repository.getSeriesBooks(tag);
          try {
            await repository.saveSeriesBooksToCache(tag, books);
          } catch (e) {
            // A cache write failing must not cost the user the list they
            // just asked for.
            ApiLogger.logError('seriesChaptersCacheWrite', e, details: tag);
          }
          return buildSeriesChapters(books);
        } catch (e) {
          ApiLogger.logError('seriesChapters', e, details: tag);
          return null;
        }
      }

      Future<List<SeriesChapter>?> fromCache() async {
        try {
          final cached = await repository.getSeriesBooksFromCache(tag);
          if (cached != null && cached.isNotEmpty) {
            return buildSeriesChapters(cached);
          }
        } catch (e) {
          ApiLogger.logError('seriesChaptersCacheRead', e, details: tag);
        }
        return null;
      }

      if (ServerStatusManager.isReachable) {
        final fresh = await fromServer();
        if (fresh != null) return fresh;
        return await fromCache() ?? const [];
      }

      // Not known to be reachable -- which is also the state of a reader
      // that opened a chapter from its offline pack a moment after
      // launch, before the first request has proved the server is up.
      // The cache answers that case, but an empty cache is not the same
      // as "this set has no chapters": fall through to one real attempt
      // so the block gets its numbers instead of staying blank for the
      // rest of the session (the result is kept, and a truly offline
      // attempt fails fast).
      final cached = await fromCache();
      if (cached != null) return cached;
      return await fromServer() ?? const [];
    });
