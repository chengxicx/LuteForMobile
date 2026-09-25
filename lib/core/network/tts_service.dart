import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:lute_for_mobile/core/network/session_manager.dart';
import 'package:lute_for_mobile/features/settings/models/tts_settings.dart';

class TTSVoice {
  final String name;
  final String locale;
  final String? quality;
  final bool isNetworkConnectionRequired;

  TTSVoice({
    required this.name,
    required this.locale,
    this.quality,
    this.isNetworkConnectionRequired = false,
  });

  String get displayName {
    String displayName = name;

    displayName = displayName.replaceFirst(
      RegExp(r'^([a-z]{2}-[a-z]{2})-'),
      '',
    );
    displayName = displayName.replaceFirst(
      RegExp(r'^com\.google\.android\.tts\.'),
      '',
    );
    displayName = displayName.replaceFirst(
      RegExp(r'^com\.apple\.ttsbundle\.'),
      '',
    );
    displayName = displayName.replaceFirst(RegExp(r'^com\.samsung\.smt\.'), '');
    displayName = displayName.replaceAll('#', ' ');
    displayName = displayName.replaceAll('_', ' ');

    if (displayName.isEmpty) {
      displayName = name;
    }

    final parts = displayName.split(' ');
    final formattedName = parts
        .map(
          (part) => part.isEmpty
              ? ''
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');

    final localeDisplay = locale.isNotEmpty ? ' [$locale]' : '';
    final qualitySuffix = quality != null && quality != 'normal'
        ? ' ($quality)'
        : '';
    final networkSuffix = isNetworkConnectionRequired ? ' (Online)' : '';

    return '$formattedName$localeDisplay$qualitySuffix$networkSuffix';
  }

  factory TTSVoice.fromMap(Map<dynamic, dynamic> map) {
    return TTSVoice(
      name: map['name']?.toString() ?? '',
      locale: map['locale']?.toString() ?? '',
      quality: map['quality']?.toString(),
      isNetworkConnectionRequired: map['isNetworkConnectionRequired'] == true,
    );
  }
}

abstract class TTSService {
  Future<void> speak(String text);

  /// Play audio that has already been fetched, skipping the synthesis round
  /// trip [speak] pays.
  ///
  /// The read-aloud player prefetches the *next* sentence while the current
  /// one is being read, then hands the bytes straight to the platform player.
  /// Without this the reader stalls between every pair of sentences for one
  /// full HTTP request plus server-side synthesis -- the reason reading aloud
  /// on mobile "stops after every sentence" while the web player does not
  /// (the web player synthesises locally in the browser).
  ///
  /// Only services that report [supportsBytesOutput] get bytes; the rest
  /// throw, and the caller falls back to [speak].
  Future<void> speakBytes(Uint8List bytes);
  Future<void> stop();
  Future<void> setLanguage(String languageCode);
  Future<void> setSettings(TTSSettingsConfig config);

  /// Applies the speaking rate to subsequent utterances.
  ///
  /// The read-aloud player calls this before every sentence, so a rate picked
  /// in the player bar wins over whatever the settings say.  A service that
  /// has no rate concept (server-side voices whose speed is fixed, or TTS
  /// switched off) implements this as a no-op rather than failing.
  Future<void> setPlaybackRate(double rate);

  Future<List<TTSVoice>> getAvailableVoices();
  void dispose();
  Stream<PlayerState> get playerStateStream;
  Future<Uint8List> getAudioBytes(String text);
  bool get supportsBytesOutput;
}

class OnDeviceTTSService implements TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  AudioPlayer? _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  OnDeviceTTSService() {
    _flutterTts.awaitSpeakCompletion(true);
    _flutterTts.setStartHandler(() {
      _playerStateController.add(PlayerState.playing);
    });
    _flutterTts.setCompletionHandler(() {
      _playerStateController.add(PlayerState.completed);
    });
    _flutterTts.setErrorHandler((msg) {
      _playerStateController.add(PlayerState.stopped);
    });
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _flutterTts.speak(text);
    } catch (e) {
      throw TTSException('Failed to speak with on-device TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    throw TTSException('On-device TTS does not support byte playback');
  }

  @override
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
      _playerStateController.add(PlayerState.stopped);
      if (_audioPlayer != null) {
        await _audioPlayer!.stop();
        await _audioPlayer!.release();
      }
    } catch (e) {
      throw TTSException('Failed to stop on-device TTS: $e');
    }
  }

  @override
  Future<void> setLanguage(String languageCode) async {
    try {
      await _flutterTts.setLanguage(languageCode);
    } catch (e) {
      throw TTSException('Failed to set language: $e');
    }
  }

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {
    try {
      String? voiceName = config.voice;
      String? voiceLocale = config.voiceLocale;

      debugPrint(
        'Applying on-device TTS settings: voice=$voiceName, locale=$voiceLocale, rate=${config.rate}, pitch=${config.pitch}, volume=${config.volume}',
      );

      if (voiceLocale != null && voiceLocale.isNotEmpty) {
        await _flutterTts.setLanguage(voiceLocale);
      }

      if (voiceName != null && voiceName.isNotEmpty) {
        if (voiceLocale != null && voiceLocale.isNotEmpty) {
          await _flutterTts.setVoice({
            'name': voiceName,
            'locale': voiceLocale,
          });
        } else {
          await _flutterTts.setVoice({'name': voiceName});
        }
      }
      if (config.rate != null) {
        await _flutterTts.setSpeechRate(config.rate!);
      }
      if (config.pitch != null) {
        await _flutterTts.setPitch(config.pitch!);
      }
      if (config.volume != null) {
        await _flutterTts.setVolume(config.volume!);
      }
    } catch (e) {
      throw TTSException('Failed to set on-device TTS settings: $e');
    }
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    // flutter_tts takes the rate into account on the *next* utterance, which
    // is why the player restarts the current sentence when the rate changes.
    try {
      await _flutterTts.setSpeechRate(rate);
    } catch (e) {
      throw TTSException('Failed to set on-device speech rate: $e');
    }
  }

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    try {
      final voices = await _flutterTts.getVoices;
      final result = <TTSVoice>[];
      for (final v in voices) {
        try {
          final voice = TTSVoice.fromMap(v);
          if (voice.name.isNotEmpty) {
            result.add(voice);
          }
        } catch (e) {
          debugPrint('Error parsing voice: $e');
        }
      }
      result.sort((a, b) {
        final localeCompare = a.locale.compareTo(b.locale);
        if (localeCompare != 0) return localeCompare;
        return a.name.compareTo(b.name);
      });
      return result;
    } catch (e) {
      throw TTSException('Failed to get available voices: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer?.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    throw TTSException('On-device TTS does not support byte output');
  }

  @override
  bool get supportsBytesOutput => false;
}

class KokoroTTSService implements TTSService {
  final String endpointUrl;
  final List<KokoroVoiceWeight> voices;
  final String audioFormat;
  final double speed;

  final Dio _dio = Dio();
  late final AudioPlayer _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  KokoroTTSService({
    required this.endpointUrl,
    required this.voices,
    this.audioFormat = 'mp3',
    this.speed = 1.0,
  }) {
    _audioPlayer = AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop)
      ..onPlayerStateChanged.listen((state) {
        _playerStateController.add(state);
      });
  }

  String _generateVoiceString() {
    if (voices.isEmpty) return '';
    if (voices.length == 1) {
      return voices.first.voice;
    }
    return voices.map((v) => '${v.voice}(${v.weight})').join('+');
  }

  @override
  Future<void> speak(String text) async {
    try {
      final voiceString = _generateVoiceString();
      if (voiceString.isEmpty) {
        throw TTSException('No voices selected for Kokoro TTS');
      }

      final response = await _dio.post(
        '$endpointUrl/audio/speech',
        data: {
          'model': 'kokoro',
          'input': text,
          'voice': voiceString,
          'response_format': audioFormat,
          'speed': speed,
        },
        options: Options(responseType: ResponseType.bytes),
      );

      final audioBytes = response.data as List<int>;
      await _audioPlayer.play(BytesSource(Uint8List.fromList(audioBytes)));
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException(
          'Failed to connect to Kokoro server at $endpointUrl',
        );
      }
      throw TTSException('Kokoro TTS request failed: ${e.message}');
    } catch (e) {
      throw TTSException('Failed to speak with Kokoro TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    try {
      // Already-fetched audio: straight to the platform player, no request.
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      throw TTSException('Failed to play Kokoro TTS audio: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      // No release() here. release() tears down the platform MediaPlayer, so
      // every sentence change paid to build a new one; that setup cost landed
      // squarely in the gap between two sentences. dispose() frees it.
      await _audioPlayer.stop();
    } catch (e) {
      throw TTSException('Failed to stop Kokoro TTS: $e');
    }
  }

  @override
  Future<void> setLanguage(String languageCode) async {}

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    try {
      final response = await _dio.get('$endpointUrl/audio/voices');
      final data = response.data;
      if (data is Map && data.containsKey('voices')) {
        return (data['voices'] as List)
            .map((v) => TTSVoice(name: v.toString(), locale: ''))
            .toList();
      }
      return [];
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException(
          'Failed to connect to Kokoro server at $endpointUrl',
        );
      }
      throw TTSException('Failed to fetch available voices: ${e.message}');
    } catch (e) {
      throw TTSException('Failed to get available voices: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    final voiceString = _generateVoiceString();
    if (voiceString.isEmpty) {
      throw TTSException('No voices selected for Kokoro TTS');
    }

    final response = await _dio.post(
      '$endpointUrl/audio/speech',
      data: {
        'model': 'kokoro',
        'input': text,
        'voice': voiceString,
        'response_format': audioFormat,
        'speed': speed,
      },
      options: Options(responseType: ResponseType.bytes),
    );

    final audioBytes = response.data as List<int>;
    return Uint8List.fromList(audioBytes);
  }

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<void> setPlaybackRate(double rate) async {
    // `speed` shapes the request, but the synthesized mp3 is played back by an
    // AudioPlayer -- so the rate can be applied to the audio itself without
    // paying for a second synthesis.
    await _audioPlayer.setPlaybackRate(rate);
  }
}

class OpenAITTSService implements TTSService {
  final String apiKey;
  final String? model;
  final String? voice;

  final Dio _dio = Dio();
  late final AudioPlayer _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  OpenAITTSService({required this.apiKey, this.model, this.voice}) {
    _audioPlayer = AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop)
      ..onPlayerStateChanged.listen((state) {
        _playerStateController.add(state);
      });
  }

  @override
  Future<void> speak(String text) async {
    try {
      final response = await _dio.post(
        'https://api.openai.com/v1/audio/speech',
        data: {
          'model': model ?? 'tts-1',
          'input': text,
          'voice': voice ?? 'alloy',
          'response_format': 'mp3',
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      final audioBytes = response.data as List<int>;
      await _audioPlayer.play(BytesSource(Uint8List.fromList(audioBytes)));
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw TTSException('Invalid OpenAI API key');
      }
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException('Failed to connect to OpenAI API');
      }
      throw TTSException('OpenAI TTS request failed: ${e.message}');
    } catch (e) {
      throw TTSException('Failed to speak with OpenAI TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    try {
      // Already-fetched audio: straight to the platform player, no request.
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      throw TTSException('Failed to play OpenAI TTS audio: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      // No release() here. release() tears down the platform MediaPlayer, so
      // every sentence change paid to build a new one; that setup cost landed
      // squarely in the gap between two sentences. dispose() frees it.
      await _audioPlayer.stop();
    } catch (e) {
      throw TTSException('Failed to stop OpenAI TTS: $e');
    }
  }

  @override
  Future<void> setLanguage(String languageCode) async {}

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    return [
      'alloy',
      'echo',
      'fable',
      'onyx',
      'nova',
      'shimmer',
    ].map((v) => TTSVoice(name: v, locale: 'en-US')).toList();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    final response = await _dio.post(
      'https://api.openai.com/v1/audio/speech',
      data: {
        'model': model ?? 'tts-1',
        'input': text,
        'voice': voice ?? 'alloy',
        'response_format': 'mp3',
      },
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ),
    );

    final audioBytes = response.data as List<int>;
    return Uint8List.fromList(audioBytes);
  }

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<void> setPlaybackRate(double rate) async {
    // The OpenAI speech API has no speed parameter, so the rate is applied to
    // the returned audio instead of being silently dropped.
    await _audioPlayer.setPlaybackRate(rate);
  }
}

class LocalOpenAITTSService implements TTSService {
  final String endpointUrl;
  final String? model;
  final String? voice;
  final String? apiKey;

  final Dio _dio = Dio();
  late final AudioPlayer _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  LocalOpenAITTSService({
    required this.endpointUrl,
    this.model,
    this.voice,
    this.apiKey,
  }) {
    _audioPlayer = AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop)
      ..onPlayerStateChanged.listen((state) {
        _playerStateController.add(state);
      });
  }

  @override
  Future<void> speak(String text) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};

      if (apiKey != null && apiKey!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }

      final response = await _dio.post(
        '$endpointUrl/audio/speech',
        data: {
          'model': model ?? 'tts-1',
          'input': text,
          'voice': voice ?? 'alloy',
          'response_format': 'mp3',
        },
        options: Options(responseType: ResponseType.bytes, headers: headers),
      );

      final audioBytes = response.data as List<int>;
      await _audioPlayer.play(BytesSource(Uint8List.fromList(audioBytes)));
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException(
          'Failed to connect to local endpoint at $endpointUrl',
        );
      }
      if (e.response?.statusCode == 401) {
        throw TTSException('Invalid API key for local endpoint');
      }
      throw TTSException('Local OpenAI TTS request failed: ${e.message}');
    } catch (e) {
      throw TTSException('Failed to speak with local OpenAI TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    try {
      // Already-fetched audio: straight to the platform player, no request.
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      throw TTSException('Failed to play Local OpenAI TTS audio: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      // No release() here. release() tears down the platform MediaPlayer, so
      // every sentence change paid to build a new one; that setup cost landed
      // squarely in the gap between two sentences. dispose() frees it.
      await _audioPlayer.stop();
    } catch (e) {
      throw TTSException('Failed to stop local OpenAI TTS: $e');
    }
  }

  @override
  Future<void> setLanguage(String languageCode) async {}

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    return [
      'alloy',
      'echo',
      'fable',
      'onyx',
      'nova',
      'shimmer',
    ].map((v) => TTSVoice(name: v, locale: 'en-US')).toList();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    final headers = <String, String>{'Content-Type': 'application/json'};

    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    final response = await _dio.post(
      '$endpointUrl/audio/speech',
      data: {
        'model': model ?? 'tts-1',
        'input': text,
        'voice': voice ?? 'alloy',
        'response_format': 'mp3',
      },
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );

    final audioBytes = response.data as List<int>;
    return Uint8List.fromList(audioBytes);
  }

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<void> setPlaybackRate(double rate) async {
    // Same reason as OpenAITTSService: the local endpoint takes no speed.
    await _audioPlayer.setPlaybackRate(rate);
  }
}

class SupertonicFastApiTTSService implements TTSService {
  final String endpointUrl;
  final String voice;
  final String languageCode;
  final int totalSteps;
  final double speed;

  final Dio _dio = Dio();
  late final AudioPlayer _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  SupertonicFastApiTTSService({
    required this.endpointUrl,
    required this.voice,
    required this.languageCode,
    required this.totalSteps,
    required this.speed,
  }) {
    _audioPlayer = AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop)
      ..onPlayerStateChanged.listen((state) {
        _playerStateController.add(state);
      });
  }

  String get _synthesizeUrl => '$endpointUrl/synthesize';

  @override
  Future<void> speak(String text) async {
    try {
      final audioBytes = await getAudioBytes(text);
      await _audioPlayer.play(BytesSource(audioBytes));
    } catch (e) {
      if (e is TTSException) {
        rethrow;
      }
      throw TTSException('Failed to speak with Supertonic FastAPI TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    try {
      // Already-fetched audio: straight to the platform player, no request.
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      throw TTSException('Failed to play Supertonic FastAPI TTS audio: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      // No release() here. release() tears down the platform MediaPlayer, so
      // every sentence change paid to build a new one; that setup cost landed
      // squarely in the gap between two sentences. dispose() frees it.
      await _audioPlayer.stop();
    } catch (e) {
      throw TTSException('Failed to stop Supertonic FastAPI TTS: $e');
    }
  }

  @override
  Future<void> setLanguage(String languageCode) async {}

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    try {
      final response = await _dio.get('$endpointUrl/voices');
      final data = response.data;

      if (data is Map && data['voices'] is List) {
        return (data['voices'] as List)
            .map((v) => TTSVoice(name: v.toString(), locale: languageCode))
            .toList();
      }

      return [];
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException(
          'Failed to connect to Supertonic FastAPI at $endpointUrl',
        );
      }
      throw TTSException(
        'Failed to fetch Supertonic FastAPI voices: ${e.message}',
      );
    } catch (e) {
      throw TTSException('Failed to load Supertonic FastAPI voices: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    try {
      final response = await _dio.post(
        _synthesizeUrl,
        data: {
          'text': text,
          'voice': voice,
          'lang': languageCode,
          'total_steps': totalSteps,
          'speed': speed,
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Content-Type': 'application/json'},
        ),
      );

      final audioBytes = response.data as List<int>;
      return Uint8List.fromList(audioBytes);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException(
          'Failed to connect to Supertonic FastAPI at $endpointUrl',
        );
      }
      throw TTSException('Supertonic FastAPI TTS request failed: ${e.message}');
    } catch (e) {
      throw TTSException(
        'Failed to fetch audio from Supertonic FastAPI TTS: $e',
      );
    }
  }

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<void> setPlaybackRate(double rate) async {
    await _audioPlayer.setPlaybackRate(rate);
  }
}

/// Edge TTS via the Lute server's /tts/<lang>/<text> endpoint.
///
/// The server synthesizes speech using edge-tts and returns an mp3 (cached on
/// the server). The Lute server may require Basic Auth, so credentials are
/// passed through so requests don't fail with a 401.
class EdgeTTSService implements TTSService {
  final String serverUrl;

  /// 当前朗读用的语言标签（如 `ja-JP`），会拼进 `/tts/<lang>/<text>`，
  /// 服务端据此选语音。
  ///
  /// 故意不是 final：它要随「当前书」的语言变化，见 [setLanguage]。
  /// 旧实现把它在构造时定死、调用方又默认传 `'en'`，结果任何日文书都被丢给
  /// 英文语音合成 —— edge-tts 返回 NoAudioReceived，服务端留下 0 字节缓存，
  /// 之后每次请求都是 200 + 空响应体，朗读永久失败。
  String _languageCode;

  final String basicAuthUser;
  final String basicAuthPassword;

  final Dio _dio = Dio();
  late final AudioPlayer _audioPlayer;
  final _playerStateController = StreamController<PlayerState>.broadcast();

  EdgeTTSService({
    required this.serverUrl,
    String languageCode = 'en',
    this.basicAuthUser = '',
    this.basicAuthPassword = '',
  }) : _languageCode = languageCode {
    _audioPlayer = AudioPlayer()
      ..setReleaseMode(ReleaseMode.stop)
      ..onPlayerStateChanged.listen((state) {
        _playerStateController.add(state);
      });

    // Multi-user session cookie (and stored Basic Auth, if configured).
    _dio.options.headers.addAll(SessionManager.authHeaders());
    if (basicAuthUser.isNotEmpty) {
      _dio.options.headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$basicAuthUser:$basicAuthPassword'))}';
    }
  }

  /// 当前生效的语言标签。设置页的「Test Speech」用它挑同语种的例句 ——
  /// 拿英文句子去喂日文语音会直接 NoAudioReceived。
  String get languageCode => _languageCode;

  /// Whether *response* is the server saying "this text cannot be voiced".
  ///
  /// The server answers **422** with `{"error": "tts synthesis failed"}` for a
  /// fragment edge-tts refuses to voice. A 4xx is deliberate: this deployment
  /// sits behind Cloudflare, and Cloudflare discards an origin **5xx** body and
  /// substitutes its own `error code: 502` page. So the JSON marker that used
  /// to identify this case is *not* readable through the public domain -- a
  /// client that only looked for the marker rethrew a generic HTTP error, which
  /// surfaced a raw Dio message to the user and left the read-aloud player
  /// stuck on the fragment instead of skipping it.
  ///
  /// The **502 + marker** form is still accepted so a new client can talk to a
  /// server that has not been updated yet (directly, or through a proxy that
  /// does not rewrite the body).
  ///
  /// Exposed for tests on purpose: this status-code mapping is the contract
  /// with the server and breaks silently if someone "simplifies" it back to a
  /// body sniff.
  @visibleForTesting
  static bool isSynthesisFailureResponse(Response<dynamic>? response) {
    final status = response?.statusCode;
    if (status == 422) return true;
    if (status != 502) return false;

    final body = response?.data;
    String? text;
    if (body is List<int>) {
      try {
        text = utf8.decode(body);
      } catch (_) {}
    } else if (body is String) {
      text = body;
    }
    return text != null && text.contains('"tts synthesis failed"');
  }

  Future<Uint8List> _fetchAudio(String text) async {
    final encodedText = Uri.encodeComponent(text);
    final url = '$serverUrl/tts/$_languageCode/$encodedText';
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // Fresh per request: the session cookie can be renewed at any time.
          headers: SessionManager.authHeaders(),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw TTSException('Empty audio returned from Edge TTS server');
      }
      return Uint8List.fromList(bytes);
    } on DioException catch (e) {
      // "Cannot voice this fragment" is a skip, not a failure: callers must
      // surface neither an error banner nor a stuck player. Anything else
      // (a real outage, a 401, ...) still bubbles up as an error.
      if (isSynthesisFailureResponse(e.response)) {
        throw TTSUnpronounceableFragmentException(
          'edge-tts cannot synthesize this fragment',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> speak(String text) async {
    try {
      final audioBytes = await _fetchAudio(text);
      await _audioPlayer.play(BytesSource(audioBytes));
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw TTSException(
          'Server authentication failed. Check your server credentials.',
        );
      }
      if (e.type == DioExceptionType.connectionError) {
        throw TTSException('Failed to connect to Lute server at $serverUrl');
      }
      throw TTSException('Edge TTS request failed: ${e.message}');
    } catch (e) {
      if (e is TTSException) {
        // TTSUnpronounceableFragmentException (422 "tts synthesis failed")
        // is rethrown here so the caller -- e.g. ttsPlayerProvider -- can treat
        // it as "sentence done, advance" instead of a hard error. We do NOT
        // inject a synthetic PlayerState.completed into the broadcast stream,
        // because that event can be dropped if the caller re-subscribes between
        // the emit and delivery (race), which left playback stuck on fragments
        // that the server cannot voice.
        rethrow;
      }
      throw TTSException('Failed to speak with Edge TTS: $e');
    }
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    try {
      // Already-fetched audio: straight to the platform player, no request.
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      throw TTSException('Failed to play Edge TTS audio: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      // No release() here. release() tears down the platform MediaPlayer, so
      // every sentence change paid to build a new one; that setup cost landed
      // squarely in the gap between two sentences. dispose() frees it.
      await _audioPlayer.stop();
    } catch (e) {
      throw TTSException('Failed to stop Edge TTS: $e');
    }
  }

  /// 切换朗读语言。由 [TTSNotifier] 在「当前书」变化时调用，
  /// 保证 `/tts/<lang>/<text>` 里的语言与正在读的书一致。
  @override
  Future<void> setLanguage(String languageCode) async {
    final next = languageCode.trim();
    if (next.isEmpty || next == _languageCode) return;
    _languageCode = next;
  }

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {}

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    // The server picks the voice automatically based on the language code.
    return [TTSVoice(name: 'Server voice', locale: _languageCode)];
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _playerStateController.close();
  }

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Future<Uint8List> getAudioBytes(String text) async => _fetchAudio(text);

  @override
  bool get supportsBytesOutput => true;

  @override
  Future<void> setPlaybackRate(double rate) async {
    // The server's `/tts/<lang>/<text>` route has no rate parameter -- the
    // voice, and so the tempo the server synthesizes at, is fixed.  The rate
    // is therefore applied to the returned mp3 by the AudioPlayer, which is
    // exactly what the web player's `/tts/` fallback does with
    // `audio.playbackRate`.
    await _audioPlayer.setPlaybackRate(rate);
  }
}

class NoTTSService implements TTSService {
  @override
  Future<void> speak(String text) async {
    debugPrint('TTS is disabled');
  }

  @override
  Future<void> speakBytes(Uint8List bytes) async {
    debugPrint('TTS is disabled');
  }

  @override
  Future<void> stop() async {
    debugPrint('TTS is disabled');
  }

  @override
  Future<void> setLanguage(String languageCode) async {
    debugPrint('TTS is disabled');
  }

  @override
  Future<void> setSettings(TTSSettingsConfig config) async {
    debugPrint('TTS is disabled');
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    // TTS is off; the player bar's rate control has nothing to act on.
  }

  @override
  Future<List<TTSVoice>> getAvailableVoices() async {
    return [];
  }

  @override
  void dispose() {}

  @override
  Stream<PlayerState> get playerStateStream =>
      Stream.value(PlayerState.completed);

  @override
  Future<Uint8List> getAudioBytes(String text) async {
    throw TTSException('TTS is disabled');
  }

  @override
  bool get supportsBytesOutput => false;
}

class TTSException implements Exception {
  final String message;
  TTSException(this.message);

  @override
  String toString() => message;
}

/// The server answered 422 with `{"error": "tts synthesis failed"}`: the
/// sentence cannot be synthesized (typically because it was split down to a
/// single punctuation mark that edge-tts will not voice). Callers should
/// treat this as "skip this fragment and move on", not as a hard error to
/// surface to the user.
///
/// See [EdgeTTSService.isSynthesisFailureResponse] for why this is a 422 and
/// not the 502 it used to be.
class TTSUnpronounceableFragmentException extends TTSException {
  TTSUnpronounceableFragmentException(super.message);
}
