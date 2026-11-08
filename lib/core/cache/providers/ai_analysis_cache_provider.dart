import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ai_analysis_cache_service.dart';

/// Sentence translation results (`/ai/translate`), one Hive box.
final sentenceAiCacheServiceProvider = Provider<AiAnalysisCacheService>((ref) {
  return AiAnalysisCacheService(boxName: 'sentence_ai_cache');
});

/// AI grammar analysis results (`/ai/grammar/analyze`), a separate box so
/// clearing one panel's cache never touches the other's.
final aiGrammarCacheServiceProvider = Provider<AiAnalysisCacheService>((ref) {
  return AiAnalysisCacheService(boxName: 'grammar_ai_cache');
});
