/// 音频缓存文件的命名规则，以及「哪些文件是孤儿、可以回收」的判定。
///
/// 命名：`audiobook_<bookId>_v<version>.audio`；下载中的半截文件是
/// `<同名>.part`（见 `_downloadAudioToFile` 的断点续传）。
///
/// **为什么把版本写进文件名**（2026-10-10）：
/// 旧命名是 `audiobook_<bookId>_<audioUrl.hashCode.abs()>.audio`。服务端给音源
/// URL 挂了 `?v=<音频文件 mtime>`（`lute/book/service.py: media_audio_url`），
/// 换了音频文件 `?v=` 就变，hash 跟着变 —— 于是**旧文件永远没人回收**，缓存
/// 目录里堆着一份份 6–64MB 的历史版本。而且 Dart 的字符串 hashCode 跨版本
/// 不保证稳定，事后也没法从文件名反推"当前版本是哪一个"。
/// 把 `?v=` 显式写进名字后，版本可解析，「同书留最新、其余回收」才有依据。
///
/// 这一层刻意是纯函数（不碰文件系统），判定逻辑才能被直接测到 —— 删错文件
/// 的代价是用户白下几十 MB，比留着更糟。
library;

/// 音频缓存目录名（相对 app cache 目录）。
const String kAudioCacheDirName = 'audiobooks';

const String kAudioCacheFilePrefix = 'audiobook_';
const String kAudioCacheFileSuffix = '.audio';
const String kAudioCachePartialSuffix = '.part';

/// 新命名里版本标记的前缀，用来把新命名和旧命名区分开：
/// `audiobook_7_v1759900000.audio`（新）vs `audiobook_7_1234567.audio`（旧）。
const String kAudioCacheVersionMarker = 'v';

/// 音源 URL 对应的版本标记。
///
/// 优先取 `?v=`（服务端写的音频文件 mtime）；远端音源（未下载的 video 书）
/// 没有 `?v=`，退回 URL 哈希 —— 那时版本号只承担「不同 URL 不要互相覆盖」的
/// 作用，不参与新旧比较（比较用 mtime，见 [selectOrphanAudioCacheFiles]）。
String audioCacheVersion(String audioUrl) {
  final version = Uri.tryParse(audioUrl)?.queryParameters['v'];
  if (version != null && version.trim().isNotEmpty) return version.trim();
  return 'h${audioUrl.hashCode.abs()}';
}

/// 某个音源 URL 在缓存目录里的文件名。
String audioCacheFileName({required int bookId, required String audioUrl}) =>
    '$kAudioCacheFilePrefix${bookId}_$kAudioCacheVersionMarker'
    '${audioCacheVersion(audioUrl)}$kAudioCacheFileSuffix';

/// 缓存目录里的一个音频文件（已解析出归属）。
class AudioCacheFile {
  const AudioCacheFile({
    required this.fileName,
    required this.bookId,
    required this.version,
    required this.isPartial,
    required this.modifiedAt,
  });

  final String fileName;
  final int bookId;

  /// 文件名里的版本标记；null 表示旧命名 —— 判不出新旧，一律当孤儿。
  final String? version;

  /// 半截文件（`.part`，断点续传的起点）。
  final bool isPartial;

  final DateTime modifiedAt;

  bool get isLegacy => version == null;
}

/// 解析缓存目录里的一个文件名。
///
/// 不认识的名字（不是本模块的、bookId 不是数字）返回 null —— 调用方不该去
/// 删一个看不懂的文件。
AudioCacheFile? parseAudioCacheFile({
  required String fileName,
  required DateTime modifiedAt,
}) {
  if (!fileName.startsWith(kAudioCacheFilePrefix)) return null;

  var name = fileName;
  var isPartial = false;
  if (name.endsWith(kAudioCachePartialSuffix)) {
    isPartial = true;
    name = name.substring(0, name.length - kAudioCachePartialSuffix.length);
  }
  if (!name.endsWith(kAudioCacheFileSuffix)) return null;

  final middle = name.substring(
    kAudioCacheFilePrefix.length,
    name.length - kAudioCacheFileSuffix.length,
  );
  final split = middle.indexOf('_');
  if (split <= 0 || split == middle.length - 1) return null;

  final bookId = int.tryParse(middle.substring(0, split));
  if (bookId == null) return null;

  final rest = middle.substring(split + 1);
  final version =
      rest.startsWith(kAudioCacheVersionMarker) &&
          rest.length > kAudioCacheVersionMarker.length
      ? rest.substring(kAudioCacheVersionMarker.length)
      : null;

  return AudioCacheFile(
    fileName: fileName,
    bookId: bookId,
    version: version,
    isPartial: isPartial,
    modifiedAt: modifiedAt,
  );
}

/// 挑出该删的音频缓存文件名。
///
/// 四条规则，任一命中即回收（[keepFileNames] 里的一律留下）：
///
/// 1. **旧命名**（改造前的 `<hash>` 名字）：判不出新旧，一次性清掉，之后按
///    新命名重新下载；
/// 2. **书已不在书架**（只有给了 [knownBookIds] 才判）：书删了，几十 MB 的
///    音频没有任何理由留着。给 null 表示"书架未知"（比如冷启动还没拉到
///    书架），此时**不做这条判定** —— 拿一个空集合当"什么都没有"会把用户
///    所有离线音频删光；
/// 3. **同一本书下不是最新的那份**：`?v=` 变了留下的历史版本，正是这次要堵
///    的泄漏。用 mtime 比而不是版本号 —— `?v=` 通常是 mtime 数值，但远端
///    音源那档是 URL 哈希，两者不可比；
/// 4. **太旧的 `.part`**：断点续传的残片，放太久只会占地方。
List<String> selectOrphanAudioCacheFiles(
  List<AudioCacheFile> files, {
  required DateTime now,
  Set<int>? knownBookIds,
  Set<String> keepFileNames = const {},
  Duration partialMaxAge = const Duration(days: 3),
}) {
  // 每本书只留最新的一份完整文件。先按 (mtime, 版本) 排序，让 mtime 打平时
  // 的取舍也是确定的 —— 目录列举顺序不保证稳定，同一份输入要给出同一个答案。
  final complete = files.where((f) => !f.isPartial && !f.isLegacy).toList()
    ..sort((a, b) {
      final byTime = a.modifiedAt.compareTo(b.modifiedAt);
      if (byTime != 0) return byTime;
      return (a.version ?? '').compareTo(b.version ?? '');
    });
  final newestByBook = <int, String>{};
  for (final f in complete) {
    newestByBook[f.bookId] = f.fileName;
  }

  final orphans = <String>{};
  for (final f in files) {
    if (keepFileNames.contains(f.fileName)) continue;

    if (f.isLegacy) {
      orphans.add(f.fileName);
      continue;
    }
    if (knownBookIds != null && !knownBookIds.contains(f.bookId)) {
      orphans.add(f.fileName);
      continue;
    }
    if (!f.isPartial) {
      if (newestByBook[f.bookId] != f.fileName) orphans.add(f.fileName);
      continue;
    }
    if (now.difference(f.modifiedAt) > partialMaxAge) {
      orphans.add(f.fileName);
    }
  }

  return orphans.toList()..sort();
}
