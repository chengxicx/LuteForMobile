/// 服务器词典池里的一本词典——`GET /dict/status` 的一条。
///
/// 服务端的池是 `lute/static/dict/` 下的 .db 文件（见 lute-v3 的
/// `lute/dict/service.py`）：设置页的"本地词典"卡片把这个列表拉下来，
/// 用户选一本下载到对应语言的激活库（`active_<langId>.db`）。
///
/// 元数据（标题/词条数）来自导入时写的 sidecar；走 CLI 转换、没写
/// sidecar 的词典只有文件名和大小，展示时逐级退回。
class ServerDictionary {
  const ServerDictionary({
    required this.filename,
    required this.isDefault,
    this.title,
    this.sizeMb,
    this.entries,
    this.terms,
    this.source,
    this.importedAt,
    this.modified,
  });

  /// 池内的文件名（下载地址由 [urlFor] 派生）。
  final String filename;

  /// 是否是服务端的默认词典（手机旧版默认下载的那本）。
  final bool isDefault;

  /// 词典标题；CLI 转换、没写 sidecar 的词典没有。
  final String? title;

  /// 文件大小（MB）。
  final double? sizeMb;

  /// 去重后的释义条数。
  final int? entries;

  /// 词头数。
  final int? terms;

  final String? source;
  final String? importedAt;
  final String? modified;

  /// 列表里显示的名字：有标题用标题，否则退回文件名。
  String get displayName {
    final t = title?.trim();
    return (t == null || t.isEmpty) ? filename : t;
  }

  /// "81.2 MB · 15.4 万条释义 · 40.1 万词头" 这样一行摘要；缺的项跳过，
  /// 全缺时是空串（调用方据此不渲染副标题）。
  String get summary {
    final parts = <String>[
      if (sizeMb != null) '${sizeMb!.toStringAsFixed(1)} MB',
      if (entries != null) '${_compact(entries!)}条释义',
      if (terms != null) '${_compact(terms!)}词头',
    ];
    return parts.join(' · ');
  }

  /// 大数字换成"万"：153775 -> "15.4 万"。一万以下原样。
  static String _compact(int n) {
    if (n < 10000) return '$n';
    final wan = (n / 1000) / 10; // 一位小数
    return '${(wan * 10).round() / 10} 万';
  }

  factory ServerDictionary.fromJson(Map<String, dynamic> json) {
    return ServerDictionary(
      filename: json['filename'] as String? ?? '',
      isDefault: json['is_default'] as bool? ?? false,
      title: json['title'] as String?,
      sizeMb: (json['size_mb'] as num?)?.toDouble(),
      entries: (json['entries'] as num?)?.toInt(),
      terms: (json['terms'] as num?)?.toInt(),
      source: json['source'] as String?,
      importedAt: json['imported_at'] as String?,
      modified: json['modified'] as String?,
    );
  }

  /// 解析 `GET /dict/status` 的响应体。不是成功形状——旧版服务端没有
  /// 这个端点、或 result 不是 success——时返回 null。
  static List<ServerDictionary>? parseStatusResponse(Map<String, dynamic> json) {
    if (json['result'] != 'success') return null;
    final list = json['dictionaries'];
    if (list is! List) return null;
    return list
        .whereType<Map<String, dynamic>>()
        .map(ServerDictionary.fromJson)
        .toList();
  }

  /// 这本词典的下载地址。
  ///
  /// 池内文件走静态路由，**不需要登录态**——列表才需要。地址只由服务器
  /// 地址和文件名派生，所以换服务器地址后旧地址自然失效，没有别处
  /// 需要同步的"当前词典 URL"状态。
  static String urlFor(String serverUrl, String filename) {
    final trimmed = serverUrl.trim();
    final normalized =
        trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
    return '$normalized/static/dict/$filename';
  }
}
