import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../terms_list_cache_service.dart';

final termsListCacheServiceProvider = Provider<TermsListCacheService>((ref) {
  return TermsListCacheService();
});
