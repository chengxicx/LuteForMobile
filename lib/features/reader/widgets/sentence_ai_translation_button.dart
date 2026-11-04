import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';

/// Entry for the server-side AI sentence analysis.
///
/// The provider/key live on the server, so there is no on-device AI setting
/// to gate this on: the button stays visible and an unconfigured server
/// explains itself inside the panel (with a link to the web Settings page).
class SentenceAITranslationButton extends ConsumerWidget {
  final VoidCallback? onTranslationRequested;

  const SentenceAITranslationButton({
    super.key,
    this.onTranslationRequested,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iconColor = context.appColorScheme.material3.primary;

    return IconButton(
      icon: const Icon(Icons.psychology),
      color: iconColor,
      onPressed: onTranslationRequested,
      tooltip: 'Translate with AI',
    );
  }
}
