import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:song_mobile/features/settings/models/tts_settings.dart';
import 'package:song_mobile/features/settings/providers/tts_settings_provider.dart';
import 'package:song_mobile/features/settings/providers/settings_provider.dart';
import 'package:song_mobile/features/reader/providers/current_book_provider.dart';
import 'package:song_mobile/core/network/tts_service.dart';
import 'package:song_mobile/shared/utils/tts_language_mapper.dart';

class TTSNotifier extends Notifier<TTSService> {
  TTSService? _currentService;
  Completer<void>? _updateCompleter;

  @override
  TTSService build() {
    ref.listen(ttsSettingsProvider, (_, next) => _updateService());

    // 朗读语言跟随当前书的语言。
    //
    // Edge TTS 把语言拼进 `/tts/<lang>/<text>`，服务端据此选语音；语言错了
    // 不是「声音不对」而是彻底没声音 —— edge-tts 对不支持的语种返回
    // NoAudioReceived，服务端会留下 0 字节缓存文件，之后永远返回 200 + 空体。
    // 旧实现把语言写死在设置里（默认 'en'），日文书的朗读因此必然失败。
    ref.listen(currentBookProvider, (previous, next) {
      if (previous?.languageName != next.languageName) {
        _applyBookLanguage(next.languageName);
      }
    });

    ref.onDispose(() => _currentService?.dispose());
    final service = _createService();
    _currentService = service;
    return service;
  }

  /// Edge TTS 要用的语言标签：优先用调用方显式给的书语言（整页朗读会把本页
  /// 的语言直接传下来），其次跟随 [currentBookProvider]，书还没打开时退回
  /// 设置页里的「兜底语言码」，最后才用 [defaultTtsLanguageTag]。
  ///
  /// 显式参数不是多余的：整页朗读原先只在「语言发生变化」时同步一次，服务
  /// 一旦在书打开之前建好、而语言又没解析成功，它就会一直用兜底的 `en` ——
  /// 日文句子被送去英文语音，edge-tts 答 NoAudioReceived，服务端回 422，
  /// 整页朗读于是无声地一句句连播过去。
  String resolveEdgeLanguageCode({String? bookLanguageName}) {
    final explicit = bookLanguageName?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return ttsLanguageCodeFor(explicit);
    }

    final bookLanguage = ref.read(currentBookProvider).languageName;
    if (bookLanguage != null && bookLanguage.trim().isNotEmpty) {
      return ttsLanguageCodeFor(bookLanguage);
    }

    final configured = ref
        .read(ttsSettingsProvider)
        .providerConfigs[TTSProvider.edgeTTS]
        ?.languageCode
        ?.trim();
    return (configured == null || configured.isEmpty)
        ? defaultTtsLanguageTag
        : configured;
  }

  /// 把语言推给当前的主服务 —— 只对 Edge TTS 生效（其余 provider 的语言由
  /// 各自的 `setSettings` 决定，在别处插一手会改变它们既有行为）。
  ///
  /// 每句开口前调用（见 tts_player_provider 的 `_applyLanguage`）：语言不该
  /// 只在服务创建那一刻定一次，也不该只在「语言发生变化」时才更新。返回实际
  /// 推下去的标签供调用方做诊断显示；主服务不是 Edge 时返回 null。
  Future<String?> syncEdgeLanguage({String? bookLanguageName}) async {
    final service = _currentService;
    if (service is! EdgeTTSService) return null;
    final tag = resolveEdgeLanguageCode(bookLanguageName: bookLanguageName);
    try {
      await service.setLanguage(tag);
    } catch (e) {
      debugPrint('Failed to apply book language to Edge TTS: $e');
    }
    return tag;
  }

  /// 把当前书的语言同步给已建好的服务。
  ///
  /// 只对 Edge TTS 生效：其余 provider 的语言由各自的 `setSettings` 决定，
  /// 在别处插一手会改变它们既有行为（例如 on-device 的 setLanguage 会真的
  /// 去切系统语音）。
  Future<void> _applyBookLanguage(String? languageName) async {
    await syncEdgeLanguage(bookLanguageName: languageName);
  }

  Future<void> _updateService() {
    if (_updateCompleter != null && !_updateCompleter!.isCompleted) {
      _updateCompleter!.complete();
    }
    _updateCompleter = Completer();

    final newService = _createService();
    final oldService = _currentService;
    _currentService = newService;
    state = newService;

    oldService?.dispose();

    Future.delayed(Duration.zero, () {
      _updateCompleter?.complete();
    });

    return _updateCompleter!.future;
  }

  Future<void> ensureServiceReady() async {
    if (_updateCompleter != null && !_updateCompleter!.isCompleted) {
      await _updateCompleter!.future;
    }
  }

  TTSService _createService() {
    try {
      final settings = ref.read(ttsSettingsProvider);
      final provider = settings.provider;
      final config = settings.providerConfigs[provider];

      switch (provider) {
        case TTSProvider.onDevice:
          final service = OnDeviceTTSService();
          if (config != null) {
            service.setSettings(config);
          }
          return service;
        case TTSProvider.kokoroTTS:
          return KokoroTTSService(
            endpointUrl: config?.endpointUrl ?? 'http://localhost:8880/v1',
            voices: config?.kokoroVoices ?? [],
            audioFormat: 'mp3',
            speed: config?.speed ?? 1.0,
          );
        case TTSProvider.openAI:
          return OpenAITTSService(
            apiKey: config?.apiKey ?? '',
            model: config?.model,
            voice: config?.voice,
          );
        case TTSProvider.localOpenAI:
          return LocalOpenAITTSService(
            endpointUrl: config?.endpointUrl ?? '',
            model: config?.model,
            voice: config?.voice,
            apiKey: config?.apiKey,
          );
        case TTSProvider.supertonicFastApi:
          return SupertonicFastApiTTSService(
            endpointUrl: config?.endpointUrl ?? 'http://192.168.1.159:8800',
            voice: config?.voice ?? 'M1',
            languageCode: config?.languageCode ?? 'en',
            totalSteps: config?.totalSteps ?? 5,
            speed: config?.speed ?? 1.05,
          );
        case TTSProvider.edgeTTS:
          final appSettings = ref.read(settingsProvider);
          return EdgeTTSService(
            serverUrl: appSettings.serverUrl,
            // 跟随当前书的语言，而不是设置页里那个固定值。
            languageCode: resolveEdgeLanguageCode(),
            basicAuthUser: appSettings.basicAuthUser,
            basicAuthPassword: appSettings.basicAuthPassword,
          );
        case TTSProvider.none:
          return NoTTSService();
      }
    } catch (e, stackTrace) {
      debugPrint('Error creating TTS service: $e');
      debugPrint('Stack trace: $stackTrace');
      return NoTTSService();
    }
  }
}

final ttsServiceProvider = NotifierProvider<TTSNotifier, TTSService>(() {
  return TTSNotifier();
});

/// 离线本地兜底引擎的 on-device 配置（点词发音与整页朗读播放器共用）。
///
/// 语速来自设置页 on-device 的 Rate（默认 0.5 = Android 正常速度）：裸引擎
/// 的语速是设备引擎的出厂默认，用户体感太快、设置滑块也对它不生效；显式
/// 应用配置后，滑块就是离线兜底的语速旋钮。旧版本持久化数据可能缺
/// on-device 配置项，缺了就用默认值补一份。
TTSSettingsConfig onDeviceConfigForFallback(TTSSettings settings) {
  return settings.providerConfigs[TTSProvider.onDevice] ??
      const TTSSettingsConfig(rate: 0.5, pitch: 1.0, volume: 1.0);
}

/// 兜底引擎开口前的装配：应用配置（语速/音调/音量）与当前书的语言。
/// 两步都尽力而为：失败不阻塞发音，引擎退到出厂默认的声音与语速。
Future<void> prepareOnDeviceFallback(
  OnDeviceTTSService service, {
  required TTSSettingsConfig config,
  String? bookLanguageName,
}) async {
  try {
    await service.setSettings(config);
  } catch (e) {
    debugPrint('TTS fallback: failed to apply on-device settings: $e');
  }
  final language = bookLanguageName?.trim();
  if (language == null || language.isEmpty) return;
  try {
    await service.setLanguage(ttsLanguageCodeFor(language));
  } catch (e) {
    debugPrint('TTS fallback: failed to set language "$language": $e');
  }
}
