import 'package:flutter_test/flutter_test.dart';
import 'package:song_mobile/features/settings/models/tts_settings.dart';

TTSSettings _with(TTSProvider provider, {TTSSettingsConfig? config}) {
  return TTSSettings(
    provider: provider,
    providerConfigs: {provider: config ?? const TTSSettingsConfig()},
  );
}

void main() {
  // 「朗读引擎未配置」提示的判据。
  //
  // 播放条开关默认开着，引擎为 none 时用户按下播放只有沉默；提示只在
  // 引擎真的念不出声时出现，正常引擎上不能多出这条文案。
  group('TTSSettings.readAloudConfigured', () {
    test('none is not configured', () {
      expect(_with(TTSProvider.none).readAloudConfigured, isFalse);
    });

    test('on-device and edge tts need no local configuration', () {
      expect(_with(TTSProvider.onDevice).readAloudConfigured, isTrue);
      expect(_with(TTSProvider.edgeTTS).readAloudConfigured, isTrue);
    });

    test('openai needs an api key', () {
      expect(_with(TTSProvider.openAI).readAloudConfigured, isFalse);
      expect(
        _with(
          TTSProvider.openAI,
          config: const TTSSettingsConfig(apiKey: '  '),
        ).readAloudConfigured,
        isFalse,
      );
      expect(
        _with(
          TTSProvider.openAI,
          config: const TTSSettingsConfig(apiKey: 'sk-test'),
        ).readAloudConfigured,
        isTrue,
      );
    });

    test('self-hosted engines need an endpoint', () {
      for (final provider in [
        TTSProvider.localOpenAI,
        TTSProvider.kokoroTTS,
        TTSProvider.supertonicFastApi,
      ]) {
        expect(_with(provider).readAloudConfigured, isFalse, reason: '$provider');
        expect(
          _with(
            provider,
            config: const TTSSettingsConfig(endpointUrl: 'http://host:8880'),
          ).readAloudConfigured,
          isTrue,
          reason: '$provider',
        );
      }
    });

    test('a config missing for the chosen provider counts as unconfigured', () {
      expect(
        TTSSettings(
          provider: TTSProvider.openAI,
          providerConfigs: const {},
        ).readAloudConfigured,
        isFalse,
      );
    });
  });
}
