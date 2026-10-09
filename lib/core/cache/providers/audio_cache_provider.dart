import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio_cache_service.dart';

final audioCacheServiceProvider = Provider<AudioCacheService>((ref) {
  return AudioCacheService();
});
