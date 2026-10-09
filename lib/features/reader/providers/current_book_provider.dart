import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../books/models/book.dart';
import '../../books/providers/books_provider.dart';
import '../../../shared/providers/network_providers.dart';

@immutable
class CurrentBookState {
  final int? bookId;
  final int? langId;
  final String? languageName;
  final Book? book;

  const CurrentBookState({
    this.bookId,
    this.langId,
    this.languageName,
    this.book,
  });

  const CurrentBookState.empty()
    : bookId = null,
      langId = null,
      languageName = null,
      book = null;

  CurrentBookState copyWith({
    int? bookId,
    int? langId,
    String? languageName,
    Book? book,
  }) {
    return CurrentBookState(
      bookId: bookId ?? this.bookId,
      langId: langId ?? this.langId,
      languageName: languageName ?? this.languageName,
      book: book ?? this.book,
    );
  }
}

class CurrentBookNotifier extends Notifier<CurrentBookState> {
  @override
  CurrentBookState build() {
    // 书架到货后补一次语言解析。
    //
    // 「启动时恢复上次在读的书」会在书架列表到达之前就 loadBook，那一刻
    // [setBookLanguage] 的两条取名路子都可能落空：书架还是空的，而
    // `/language/index` 那趟网络也可能失败。语言就此一直空着 —— Edge TTS
    // 只好退回兜底的 `en`，日文句子被送去英文语音（edge-tts 答
    // NoAudioReceived，服务端回 422，整页朗读无声连播）。书架一到就自愈，
    // 不必等用户翻页或重新打开这本书。
    ref.listen(booksProvider, (_, _) {
      final bookId = state.bookId;
      if (bookId == null) return;
      if (state.languageName?.trim().isNotEmpty ?? false) return;
      final shelfBook = _findShelfBook(bookId);
      if (shelfBook == null) return;
      unawaited(setBookLanguage(bookId, shelfBook.langId ?? state.langId));
    });

    return const CurrentBookState.empty();
  }

  /// 书架里这本书，或 null（书架没加载完、或这行是聚合行）。
  ///
  /// 聚合行（Book Set）没有真实 BkID，永远不能当作书打开 —— 与 app.dart 里
  /// 打开书籍时的判断保持一致。
  Book? _findShelfBook(int bookId) {
    try {
      final booksState = ref.read(booksProvider);
      for (final b in [...booksState.activeBooks, ...booksState.archivedBooks]) {
        if (b.id == bookId && !b.isSeries) return b;
      }
    } catch (_) {
      // 书架还没就绪；它变化时会再试一次（见 build 里的 ref.listen）。
    }
    return null;
  }

  /// 这本书的语言名，按可靠性从高到低取第一个拿得到的。
  ///
  /// 语言名是 TTS 的硬依赖：拿不到就只能退回兜底语言码，而语言错的后果不是
  /// 「声音不好听」，是**彻底没有声音**（见 tts_provider 的注释）。所以这里
  /// 刻意多留几条路，而不是只指望 `getLanguageById` 那条要走
  /// `/language/index` HTML 解析的路：
  ///   ① 调用方手里的名字（书架 Book 的 LgName，服务端 datatables 的 JSON）；
  ///   ② 书架上同一本书自带的 LgName；
  ///   ③ 语言 id → 名字；
  ///   ④ 本次已经解析出来的名字（同一本书时）。
  Future<String?> _resolveLanguageName(
    int bookId,
    int? langId, {
    String? providedName,
  }) async {
    final provided = providedName?.trim();
    if (provided != null && provided.isNotEmpty) return provided;

    final shelfBook = _findShelfBook(bookId);
    final shelfName = shelfBook?.language.trim();
    if (shelfName != null && shelfName.isNotEmpty) return shelfName;

    final effectiveLangId = langId ?? shelfBook?.langId;
    if (effectiveLangId != null && effectiveLangId != 0) {
      try {
        final name = (await ref
                .read(contentServiceProvider)
                .getLanguageById(effectiveLangId))
            ?.name;
        if (name != null && name.trim().isNotEmpty) return name;
      } catch (e) {
        // 全静默会让「TTS 忽然没声音」变成无头案，至少留一条痕迹。
        debugPrint(
          'Could not resolve language name for id $effectiveLangId: $e',
        );
      }
    }

    if (state.bookId == bookId) {
      final existing = state.languageName?.trim();
      if (existing != null && existing.isNotEmpty) return existing;
    }

    return null;
  }

  Future<void> setBook(Book book) async {
    final name = await _resolveLanguageName(
      book.id,
      book.langId,
      providedName: book.language,
    );
    state = CurrentBookState(
      bookId: book.id,
      langId: book.langId,
      languageName: name,
      book: book,
    );
  }

  /// 阅读器只按 id 加载书时（典型场景：启动时恢复上次在读的书）手上没有
  /// [Book] 对象，只有 bookId 和 langId —— 这时也必须把语言补进来。
  ///
  /// 不补的后果：TTS 拿不到当前书的语言，只好退回设置页的兜底语言码
  /// （默认 `en`）；日文书因此被丢给英文语音，edge-tts 返回
  /// `NoAudioReceived`，服务端回 422，整页朗读无声连播。
  ///
  /// 换书时语言名必须跟着换：拿上一本书的语言去念这一本，同样是一串 422。
  Future<void> setBookLanguage(int bookId, int? langId) async {
    if (state.bookId == bookId &&
        (state.languageName?.trim().isNotEmpty ?? false)) {
      return;
    }

    final name = await _resolveLanguageName(bookId, langId);

    // 解析期间别处已经把语言填好了（例如书架到货触发的那次），不要覆盖。
    if (state.bookId == bookId &&
        (state.languageName?.trim().isNotEmpty ?? false)) {
      return;
    }

    final sameBook = state.bookId == bookId;
    state = CurrentBookState(
      bookId: bookId,
      langId: langId ?? (sameBook ? state.langId : null),
      languageName: name ?? (sameBook ? state.languageName : null),
      book: sameBook ? state.book : null,
    );
  }

  void clear() {
    state = const CurrentBookState.empty();
  }
}

final currentBookProvider =
    NotifierProvider<CurrentBookNotifier, CurrentBookState>(() {
      return CurrentBookNotifier();
    });
