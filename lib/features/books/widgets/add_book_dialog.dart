import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/models/language.dart';
import '../../../shared/providers/language_data_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/book_create.dart';
import '../providers/books_provider.dart';
import '../../../shared/providers/network_providers.dart';

class AddBookDialog extends ConsumerStatefulWidget {
  const AddBookDialog({super.key});

  @override
  ConsumerState<AddBookDialog> createState() => _AddBookDialogState();
}

class _AddBookDialogState extends ConsumerState<AddBookDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _textController = TextEditingController();
  final _sourceUriController = TextEditingController();
  final _tagsController = TextEditingController();
  final _importUrlController = TextEditingController();
  final _thresholdController = TextEditingController(text: '250');
  final _scrollController = ScrollController();

  List<Language> _languages = const [];
  int? _selectedLanguageId;
  String _splitBy = 'paragraphs';
  bool _isLoadingLanguages = true;
  bool _isSaving = false;
  bool _isImporting = false;
  bool _importStarted = false;
  int _importPercent = 0;
  String? _importMessage;

  /// Inline error banner.  The dialog used to report failures through a
  /// SnackBar, which the soft keyboard covers -- the user had to dismiss the
  /// keyboard to find out that a field (or the import) had failed.
  String? _errorMessage;

  String? _textFilePath;
  String? _textFileName;
  String? _audioFilePath;
  String? _audioFileName;

  @override
  void initState() {
    super.initState();
    _loadLanguages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    _sourceUriController.dispose();
    _tagsController.dispose();
    _importUrlController.dispose();
    _thresholdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Close the keyboard before acting on the form.
  ///
  /// Every action here reads or validates the fields, and the keyboard is the
  /// reason both the result and the errors used to be out of sight.
  void _dismissKeyboard() {
    FocusScope.of(context).unfocus();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadLanguages() async {
    var languages = const <Language>[];
    try {
      // Same terminal list the rest of the app uses: server -> /book/new form
      // -> the languages already present on this account's shelf.  A sub-user
      // cannot read /language/index, and the /book/new fallback has a 2.5 s
      // budget that a cold mobile request can miss; without the shelf stage
      // the Add Book dialog showed "No languages available" and refused to
      // save anything, which is what "importing a text book does nothing"
      // looked like.
      final result = await ref.read(languageListResultProvider.future);
      languages = result.languages;
    } catch (_) {
      // Fall through to the shelf cache below.
    }

    if (languages.isEmpty) {
      final books = ref.read(booksProvider);
      final byId = <int, Language>{};
      for (final book in [...books.activeBooks, ...books.archivedBooks]) {
        final id = book.langId;
        final name = book.language.trim();
        if (id == null || id <= 0 || name.isEmpty) continue;
        byId.putIfAbsent(id, () => Language(id: id, name: name));
      }
      languages = byId.values.toList();
    }

    var currentLanguageId = ref.read(settingsProvider).currentBookLangId;
    if (currentLanguageId == null ||
        !languages.any((lang) => lang.id == currentLanguageId)) {
      try {
        final contentService = ref.read(contentServiceProvider);
        final currentLanguageSetting = await contentService.getUserSetting(
          'current_language_id',
        );
        final parsed = int.tryParse(currentLanguageSetting ?? '');
        if (parsed != null && languages.any((lang) => lang.id == parsed)) {
          currentLanguageId = parsed;
        }
      } catch (_) {
        // Keep the shelf default; the dropdown still works.
      }
    }

    final hasCurrentLanguage =
        currentLanguageId != null &&
        languages.any((lang) => lang.id == currentLanguageId);

    if (!mounted) return;
    setState(() {
      _languages = languages;
      _selectedLanguageId = hasCurrentLanguage
          ? currentLanguageId
          : (languages.isNotEmpty ? languages.first.id : null);
      _isLoadingLanguages = false;
    });
  }

  Future<void> _importFromUrl() async {
    _dismissKeyboard();
    final url = _importUrlController.text.trim();
    if (url.isEmpty) {
      _showError('Enter a URL to import.');
      return;
    }

    setState(() {
      _isImporting = true;
      _errorMessage = null;
    });

    try {
      final preview = await ref
          .read(booksProvider.notifier)
          .previewBookImportFromUrl(url);
      if (!mounted) return;
      setState(() {
        if (_titleController.text.trim().isEmpty) {
          _titleController.text = preview.title;
        }
        _sourceUriController.text = preview.sourceUri;
        _textController.text = preview.text;
      });
      _scrollToTop();
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _pickTextFile() async {
    _dismissKeyboard();
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'epub', 'pdf', 'srt', 'vtt'],
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      if (file.path == null || file.path!.isEmpty) {
        _showError('Could not access selected file path.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _textFilePath = file.path;
        _textFileName = file.name;
        _errorMessage = null;
        if (_titleController.text.trim().isEmpty) {
          _titleController.text = _filenameWithoutExtension(file.name);
        }
      });
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _pickAudioFile() async {
    _dismissKeyboard();
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp3',
          'm4a',
          'wav',
          'ogg',
          'opus',
          'aac',
          'flac',
          'webm',
        ],
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      if (file.path == null || file.path!.isEmpty) {
        _showError('Could not access selected file path.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _audioFilePath = file.path;
        _audioFileName = file.name;
        _errorMessage = null;
      });
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    _dismissKeyboard();

    setState(() {
      _errorMessage = null;
    });

    if (!_formKey.currentState!.validate()) {
      _showError('Please complete the highlighted fields.');
      _scrollToTop();
      return;
    }

    final languageId = _selectedLanguageId;
    if (languageId == null || languageId <= 0) {
      _showError(
        _languages.isEmpty
            ? 'No languages available. This account may not have language-'
                      'management permission - ask the server admin.'
            : 'Please select a language.',
      );
      _scrollToTop();
      return;
    }

    final threshold = int.tryParse(_thresholdController.text.trim());
    if (threshold == null || threshold < 1 || threshold > 1500) {
      _showError('Words per page must be between 1 and 1500.');
      _scrollToTop();
      return;
    }

    final hasText = _textController.text.trim().isNotEmpty;
    final hasTextFile = _textFilePath != null && _textFilePath!.isNotEmpty;

    if (hasText && hasTextFile) {
      _showError('Both Text and Text file are set, please only specify one.');
      _scrollToTop();
      return;
    }

    if (!hasText && !hasTextFile) {
      _showError('Please specify either Text or Text file.');
      _scrollToTop();
      return;
    }

    final tags = _tagsController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final request = BookCreateRequest(
      languageId: languageId,
      title: _titleController.text.trim(),
      text: _textController.text.trim(),
      sourceUri: _sourceUriController.text.trim(),
      tags: tags,
      splitBy: _splitBy,
      thresholdPageTokens: threshold,
      textFilePath: _textFilePath,
      audioFilePath: _audioFilePath,
    );

    setState(() {
      _isSaving = true;
      _importStarted = false;
      _importPercent = 0;
      _importMessage = null;
    });

    try {
      // The server imports on a background task and the client polls it.
      // Those few seconds are the whole wait, so surface the progress here
      // instead of leaving the dialog on a frozen spinner.
      final newBookId = await ref
          .read(booksProvider.notifier)
          .createBook(
            request,
            onProgress: (percent, message) {
              if (!mounted) return;
              setState(() {
                _importStarted = true;
                _importPercent = percent;
                if (message != null && message.trim().isNotEmpty) {
                  _importMessage = message;
                }
              });
            },
          );
      if (!mounted) return;
      Navigator.of(context).pop(newBookId);
    } catch (e) {
      _showError(e.toString());
      _scrollToTop();
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String _filenameWithoutExtension(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0) return filename;
    return filename.substring(0, dot);
  }

  void _showError(String message) {
    if (!mounted) return;
    final text = message
        .replaceFirst('Exception: ', '')
        .replaceFirst('Failed to create book: ', '')
        .replaceFirst('Failed to import from URL: ', '');
    setState(() {
      _errorMessage = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogWidth = screenWidth * 0.94;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      title: const Text('Add Book'),
      content: SizedBox(
        width: dialogWidth,
        child: _isLoadingLanguages
            ? const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            : Form(
                key: _formKey,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_errorMessage != null) ...[
                        _ErrorBanner(message: _errorMessage!),
                        const SizedBox(height: 12),
                      ],
                      if (_isSaving) ...[
                        _ImportProgress(
                          indeterminate: !_importStarted,
                          percent: _importPercent,
                          message: _importMessage,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _importUrlController,
                        decoration: InputDecoration(
                          labelText: 'Import URL',
                          hintText: 'https://example.com/article',
                          suffixIcon: _isImporting
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.download),
                                  tooltip: 'Import',
                                  onPressed: _importFromUrl,
                                ),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue:
                            _languages.any((l) => l.id == _selectedLanguageId)
                            ? _selectedLanguageId
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Language',
                        ),
                        items: _languages
                            .map(
                              (lang) => DropdownMenuItem<int>(
                                value: lang.id,
                                child: Text(lang.name),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedLanguageId = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _titleController,
                        decoration: const InputDecoration(labelText: 'Title'),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Title is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _textController,
                        decoration: const InputDecoration(
                          labelText: 'Text',
                          alignLabelWithHint: true,
                        ),
                        minLines: 6,
                        maxLines: 12,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _textFileName == null
                                  ? 'Text file: none selected'
                                  : 'Text file: $_textFileName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _pickTextFile,
                            child: const Text('Pick Text File'),
                          ),
                          if (_textFilePath != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                setState(() {
                                  _textFilePath = null;
                                  _textFileName = null;
                                });
                              },
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _audioFileName == null
                                  ? 'Audio file: none selected'
                                  : 'Audio file: $_audioFileName',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _pickAudioFile,
                            child: const Text('Pick Audio File'),
                          ),
                          if (_audioFilePath != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                setState(() {
                                  _audioFilePath = null;
                                  _audioFileName = null;
                                });
                              },
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _sourceUriController,
                        decoration: const InputDecoration(
                          labelText: 'Text source',
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _tagsController,
                        decoration: const InputDecoration(
                          labelText: 'Tags',
                          hintText: 'tag1, tag2',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _splitBy,
                        decoration: const InputDecoration(
                          labelText: 'Split by',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'paragraphs',
                            child: Text('Paragraphs'),
                          ),
                          DropdownMenuItem(
                            value: 'sentences',
                            child: Text('Sentences'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _splitBy = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _thresholdController,
                        decoration: const InputDecoration(
                          labelText: 'Words per page',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// The dialog's persistent error line.
///
/// Inline on purpose: the old SnackBar sat under the soft keyboard, so a
/// rejected import or a missing field was invisible until the user dismissed
/// the keyboard.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 20,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress for the server-side background import (`/book/import/status`).
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({
    required this.indeterminate,
    required this.percent,
    this.message,
  });

  final bool indeterminate;
  final int percent;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final value = (percent / 100).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          indeterminate
              ? 'Creating book…'
              : 'Importing book… $percent%',
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: indeterminate ? null : value),
        if (message != null && message!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            message!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
