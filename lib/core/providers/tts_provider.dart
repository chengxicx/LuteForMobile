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

  /// Edge TTS 要用的语言标签：优先跟随当前书的语言，书还没打开时退回
  /// 设置页里的「兜底语言码」，最后才用 [defaultTtsLanguageTag]。
  String _resolveEdgeLanguageCode() {
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

  /// 把当前书的语言同步给已建好的服务。
  ///
  /// 只对 Edge TTS 生效：其余 provider 的语言由各自的 `setSettings` 决定，
  /// 在别处插一手会改变它们既有行为（例如 on-device 的 setLanguage 会真的
  /// 去切系统语音）。
  Future<void> _applyBookLanguage(String? languageName) async {
    final service = _currentService;
    if (service is! EdgeTTSService) return;
    try {
      await service.setLanguage(ttsLanguageCodeFor(languageName));
    } catch (e) {
      debugPrint('Failed to apply book language to Edge TTS: $e');
    }
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
            languageCode: _resolveEdgeLanguageCode(),
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
