class DataTablesResponse<T> {
  final int draw;
  final int recordsTotal;
  final int recordsFiltered;
  final List<T> data;

  DataTablesResponse({
    required this.draw,
    required this.recordsTotal,
    required this.recordsFiltered,
    required this.data,
  });

  factory DataTablesResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJsonT,
  ) {
    // 容错取整：服务端字段缺失或为 null 时，不应让整页列表崩溃。
    int asInt(dynamic v, [int fallback = 0]) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    final rawData = json['data'];
    return DataTablesResponse(
      draw: asInt(json['draw'], 1),
      recordsTotal: asInt(json['recordsTotal']),
      recordsFiltered: asInt(json['recordsFiltered']),
      data: rawData is List
          ? rawData
                .whereType<Map<String, dynamic>>()
                .map(fromJsonT)
                .toList()
          : <T>[],
    );
  }
}
