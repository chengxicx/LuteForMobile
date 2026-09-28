import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/term.dart';
import '../../../core/outbox/providers/outbox_provider.dart';
import '../../../shared/providers/network_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../reader/models/term_form.dart';
import '../../reader/widgets/term_form.dart' show TermFormWidget;

/// 词条编辑器保存表单的**唯一出口**：进 outbox，不直接 POST。
///
/// `/read/edit_term/<id>` 提交的是整条词，而这条链路随时可能断（用户就是在地铁
/// 上读）。直接发的话，失败等于「Failed to update term」加一条已经丢掉的编辑。
/// outbox 收的是**意图**（"这个词该是这些字段"），重放时再拼请求，所以断网也
/// 不会丢。
///
/// 和阅读页双击改状态共用 `term:<id>` 这个合并键：先改表单再双击，`coalesce`
/// 会把这里的 formData 快照保住（见 `pending_intent.dart` 的 `coalesce`）。
///
/// 提成函数是为了能测：它是纯的（只碰 outbox），不需要搭 widget 树就能断言
/// 「表单编辑变成了 TermEditIntent 且带着完整快照」。见
/// `test/term_edit_outbox_wiring_test.dart`。
@visibleForTesting
Future<void> queueTermFormEdit(OutboxNotifier outbox, TermForm form) async {
  final termId = form.termId;
  if (termId == null) {
    // 还没有服务端 id 的词不能合并、也不能就地显示，只能按「新建」排队。
    await outbox.enqueueTermCreate(
      form.languageId,
      form.term,
      form.toFormData(),
    );
    return;
  }

  await outbox.enqueueTermStatus(
    termId,
    form.status,
    langId: form.languageId,
    formData: form.toFormData(),
  );
}

class TermEditDialogWrapper extends ConsumerStatefulWidget {
  final Term term;
  final VoidCallback onDelete;
  final void Function(Term)? onSave;

  const TermEditDialogWrapper({
    super.key,
    required this.term,
    required this.onDelete,
    this.onSave,
  });

  @override
  ConsumerState<TermEditDialogWrapper> createState() =>
      _TermEditDialogWrapperState();
}

class _TermEditDialogWrapperState extends ConsumerState<TermEditDialogWrapper> {
  TermForm? _termForm;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadTermForm();
  }

  Term _createTermFromForm(TermForm form) {
    return Term(
      id: form.termId!,
      text: form.term,
      translation: form.translation,
      status: form.status,
      langId: form.languageId,
      language: widget.term.language,
      tags: form.tags,
      createdDate: widget.term.createdDate,
    );
  }

  Future<void> _loadTermForm() async {
    try {
      final contentService = ref.read(contentServiceProvider);
      _termForm = await contentService.getTermFormByIdWithParentDetails(
        widget.term.id,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load term: $e')));
        Navigator.pop(context);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _termForm == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return AnimatedPadding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).appBarTheme.backgroundColor,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Edit Term',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (_isSaving)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Delete Term'),
                        content: const Text(
                          'Are you sure you want to delete this term?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onDelete();
                            },
                            child: Text(
                              'Delete',
                              style: TextStyle(
                                color: context.appColorScheme.error.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: TermFormWidget(
                termForm: _termForm!,
                onSave: (updatedForm) async {
                  try {
                    await queueTermFormEdit(
                      ref.read(outboxProvider.notifier),
                      updatedForm,
                    );
                    if (mounted) {
                      final updatedTerm = _createTermFromForm(updatedForm);
                      widget.onSave?.call(updatedTerm);
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to queue term update: $e'),
                        ),
                      );
                    }
                  }
                },
                onUpdate: (updatedForm) async {
                  setState(() {
                    _termForm = updatedForm;
                  });
                  try {
                    setState(() {
                      _isSaving = true;
                    });
                    // 同 onSave：先入队再反映到界面。入队是本地 Hive 写，断网
                    // 也成立，所以这里不再有「离线就报错」的分支。
                    await queueTermFormEdit(
                      ref.read(outboxProvider.notifier),
                      updatedForm,
                    );
                    if (mounted) {
                      final updatedTerm = _createTermFromForm(updatedForm);
                      widget.onSave?.call(updatedTerm);
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to queue term update: $e'),
                        ),
                      );
                    }
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isSaving = false;
                      });
                    }
                  }
                },
                onCancel: () => Navigator.pop(context),
                contentService: ref.read(contentServiceProvider),
                dictionaryService: ref.read(dictionaryServiceProvider),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
