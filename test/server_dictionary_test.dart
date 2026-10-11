import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/core/network/api_service.dart';
import 'package:song_mobile/shared/models/server_dictionary.dart';

void main() {
  group('ServerDictionary.fromJson', () {
    test('完整元数据（web 导入路径写的 sidecar）', () {
      final d = ServerDictionary.fromJson({
        'filename': 'ja_zh_shogakukan_v2.db',
        'is_default': true,
        'title': '新世纪日汉双解大辞典',
        'size_mb': 81.2,
        'entries': 153775,
        'terms': 400516,
        'source': 'xsjrihanshuangjie.mdx',
        'imported_at': '2026-10-12 03:32',
        'modified': '2026-10-12 03:31',
      });
      expect(d.filename, 'ja_zh_shogakukan_v2.db');
      expect(d.isDefault, isTrue);
      expect(d.displayName, '新世纪日汉双解大辞典');
      expect(d.summary, '81.2 MB · 15.4 万条释义 · 40.1 万词头');
    });

    test('CLI 转换、没写 sidecar：只有文件名和大小', () {
      final d = ServerDictionary.fromJson({
        'filename': 'plain.db',
        'installed': true,
        'size_mb': 12.0,
      });
      expect(d.displayName, 'plain.db');
      expect(d.summary, '12.0 MB');
      expect(d.isDefault, isFalse);
      expect(d.entries, isNull);
    });

    test('title 是空白时退回文件名', () {
      final d = ServerDictionary.fromJson({'filename': 'x.db', 'title': '   '});
      expect(d.displayName, 'x.db');
    });

    test('一万以下的数字不换“万”', () {
      final d = ServerDictionary.fromJson({
        'filename': 'small.db',
        'entries': 999,
        'terms': 12,
      });
      expect(d.summary, '999条释义 · 12词头');
    });
  });

  group('parseStatusResponse', () {
    test('成功形状解析成列表', () {
      final list = ServerDictionary.parseStatusResponse({
        'result': 'success',
        'default_filename': 'ja_zh_shogakukan_v2.db',
        'dictionaries': [
          {'filename': 'ja_zh_shogakukan_v2.db', 'is_default': true},
          {'filename': 'other.db', 'is_default': false},
        ],
      });
      expect(list, isNotNull);
      expect(list!.length, 2);
      expect(list.first.isDefault, isTrue);
      expect(list.last.filename, 'other.db');
    });

    test('result 不是 success → null（旧版服务端没这个端点）', () {
      expect(
        ServerDictionary.parseStatusResponse({'result': 'failure'}),
        isNull,
      );
    });

    test('dictionaries 缺失或不是列表 → null', () {
      expect(ServerDictionary.parseStatusResponse({'result': 'success'}), isNull);
      expect(
        ServerDictionary.parseStatusResponse({
          'result': 'success',
          'dictionaries': 'nope',
        }),
        isNull,
      );
    });
  });

  group('urlFor', () {
    test('拼静态下载地址', () {
      expect(
        ServerDictionary.urlFor('https://lute.example.org', 'a.db'),
        'https://lute.example.org/static/dict/a.db',
      );
    });

    test('服务器地址带尾巴斜杠时不重复', () {
      expect(
        ServerDictionary.urlFor('https://lute.example.org/', 'a.db'),
        'https://lute.example.org/static/dict/a.db',
      );
    });
  });

  group('ApiService.getDictStatus', () {
    test('解析 /dict/status 的 JSON', () async {
      final dio = Dio()
        ..httpClientAdapter = _JsonAdapter(
          jsonEncode({
            'result': 'success',
            'default_filename': 'ja_zh_shogakukan_v2.db',
            'dictionaries': [
              {
                'filename': 'ja_zh_shogakukan_v2.db',
                'is_default': true,
                'title': '新世纪日汉双解大辞典',
                'size_mb': 81.2,
              },
            ],
          }),
        );
      final api = ApiService(baseUrl: 'http://lute.invalid', dio: dio);
      final json = await api.getDictStatus();
      expect(json, isNotNull);
      final list = ServerDictionary.parseStatusResponse(json!);
      expect(list, isNotNull);
      expect(list!.single.filename, 'ja_zh_shogakukan_v2.db');
      expect(list.single.displayName, '新世纪日汉双解大辞典');
    });

    test('请求打到 /dict/status', () async {
      final adapter = _JsonAdapter('{"result":"success","dictionaries":[]}');
      final dio = Dio()..httpClientAdapter = adapter;
      final api = ApiService(baseUrl: 'http://lute.invalid', dio: dio);
      await api.getDictStatus();
      expect(adapter.lastPath, '/dict/status');
    });

    test('网络失败返回 null（调用方降级，不抛）', () async {
      final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
      final api = ApiService(baseUrl: 'http://lute.invalid', dio: dio);
      expect(await api.getDictStatus(), isNull);
    });
  });
}

/// 返回固定 JSON 的假 socket。`ApiService` takes an injectable `Dio`,
/// so the only thing faked here is the transport.
class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);

  final String body;
  String lastPath = '';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(requestOptions: options, error: 'offline');
  }

  @override
  void close({bool force = false}) {}
}
