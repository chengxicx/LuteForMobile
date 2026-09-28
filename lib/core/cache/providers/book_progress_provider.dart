import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../book_progress_service.dart';

final bookProgressServiceProvider = Provider<BookProgressService>((ref) {
  return BookProgressService();
});
