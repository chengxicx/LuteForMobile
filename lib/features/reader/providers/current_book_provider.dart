import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
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
    return const CurrentBookState.empty();
  }

  Future<void> setBook(Book book) async {
    if (book.langId == null) {
      state = CurrentBookState(
        bookId: book.id,
        langId: book.langId,
        languageName: book.language,
        book: book,
      );
      return;
    }

    final contentService = ref.read(contentServiceProvider);
    final language = await contentService.getLanguageById(book.langId!);

    state = CurrentBookState(
      bookId: book.id,
      langId: book.langId,
      languageName: language?.name ?? book.language,
      book: book,
    );
  }

  /// 阅读器只按 id 加载书时（典型场景：启动时恢复上次在读的书）手上没有
  /// [Book] 对象，只有 bookId 和 langId —— 这时也必须把语言补进来。
  ///
  /// 不补的后果：TTS 拿不到当前书的语言，只好退回设置页的兜底语言码
  /// （默认 `en`）。日文书因此被丢给英文语音，edge-tts 返回
  /// `NoAudioReceived`，服务端缓存一个 0 字节 mp3，之后每次请求都是
  /// 200 + 空响应体，朗读永久失败。
  Future<void> setBookLanguage(int bookId, int? langId) async {
    if (state.bookId == bookId &&
        (state.languageName?.trim().isNotEmpty ?? false)) {
      return;
    }

    // 书架列表里的 Book 自带语言名（服务端 datatables 返回 LgName），优先用它。
    try {
      final booksState = ref.read(booksProvider);
      for (final b in [...booksState.activeBooks, ...booksState.archivedBooks]) {
        if (b.id == bookId) {
          if (!b.isSeries) {
            await setBook(b);
            return;
          }
          break;
        }
      }
    } catch (_) {
      // 书架还没加载完，走下面的 langId 兜底。
    }

    String? name;
    if (langId != null && langId != 0) {
      try {
        final language =
            await ref.read(contentServiceProvider).getLanguageById(langId);
        name = language?.name;
      } catch (_) {
        name = null;
      }
    }

    state = state.copyWith(
      bookId: bookId,
      langId: langId ?? state.langId,
      languageName: name,
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
