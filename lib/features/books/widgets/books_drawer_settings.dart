import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/books_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/providers/network_providers.dart';
import '../../../shared/providers/language_data_provider.dart';
import '../../../shared/theme/theme_extensions.dart';

final _userSettingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final contentService = ref.read(contentServiceProvider);
  return await contentService.getUserSettings();
});

class _MinMaxValueFormatter extends TextInputFormatter {
  final int minValue;
  final int maxValue;

  _MinMaxValueFormatter(this.minValue, this.maxValue);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue;
    }

    final int? value = int.tryParse(newValue.text);
    if (value == null || value < minValue || value > maxValue) {
      return oldValue;
    }

    return newValue;
  }
}

class BooksDrawerSettings extends ConsumerStatefulWidget {
  const BooksDrawerSettings({super.key});

  @override
  ConsumerState<BooksDrawerSettings> createState() =>
      _BooksDrawerSettingsState();
}

class _BooksDrawerSettingsState extends ConsumerState<BooksDrawerSettings> {
  /// 最近一次成功读到的未冻结语言名。
  ///
  /// 抽屉打开时会静默重取语言列表（见 [initState]），重取期间 provider
  /// 回到 loading，`asData` 为 null；沿用上一份列表，下拉才不会在那一
  /// 瞬间塌成只剩 "All Languages"。
  List<String> _lastActiveNames = const <String>[];

  @override
  void initState() {
    super.initState();
    // 抽屉关闭时其内容不在树里（DrawerController 收起后只留一个空
    // box），所以 initState 就等于「用户打开了侧边栏」。语言列表是
    // 冻结状态的唯一来源，而 languageListProvider 是根 FutureProvider：
    // App 常驻时它不会自己过期，于是 web 上刚冻结的语言会一直留在
    // 下拉里。开抽屉时重取一次，代价是一个 /language/index 的 GET。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLanguages());
  }

  Future<void> _refreshLanguages() async {
    try {
      ref.invalidate(languageListProvider);
      await ref.read(languageListProvider.future);
    } on Exception {
      // 离线：沿用上次的列表，抽屉照常可用。
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final languagesState = ref.watch(activeLanguageNamesProvider);

    final loadedNames = languagesState.asData?.value;
    if (loadedNames != null) _lastActiveNames = loadedNames;

    // 只列未冻结的语言（对齐 web 过滤下拉）。若已保存的过滤值对应的
    // 语言后来被冻结，先回落到 All，避免 DropdownButton 的 value
    // 不在 items 里触发断言；过滤栏会在语言列表加载后自动清掉它。
    final List<String> activeNames = loadedNames ?? _lastActiveNames;
    final savedFilter = settings.languageFilter;
    final effectiveFilter = savedFilter != null &&
            activeNames.isNotEmpty &&
            !activeNames.contains(savedFilter)
        ? null
        : savedFilter;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            title: const Text(
              'Book Settings',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            initiallyExpanded: true,
            children: [
              const SizedBox(height: 8),
              Text(
                'Display Options',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Show Tags',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: settings.showTags,
                      onChanged: (value) async {
                        ref
                            .read(settingsProvider.notifier)
                            .updateShowTags(value);
                        await ref.read(booksProvider.notifier).loadBooks();
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text(
                    'Show Last Read',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: settings.showLastRead,
                      onChanged: (value) async {
                        ref
                            .read(settingsProvider.notifier)
                            .updateShowLastRead(value);
                        await ref.read(booksProvider.notifier).loadBooks();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Filter by Language',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: context.appColorScheme.border.outline,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: DropdownButton<String>(
                  value: effectiveFilter,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('All Languages'),
                    ),
                    ...activeNames.map(
                      (lang) => DropdownMenuItem<String>(
                        value: lang,
                        child: Text(lang),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    ref
                        .read(settingsProvider.notifier)
                        .updateLanguageFilter(value);
                    await ref.read(booksProvider.notifier).loadBooks();
                  },
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Stats Refresh Settings',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Consumer(
                builder: (context, ref, child) {
                  final asyncValue = ref.watch(_userSettingsProvider);
                  return asyncValue.when(
                    data: (settings) {
                      final sampleSize =
                          int.tryParse(
                            settings['stats_calc_sample_size']?.toString() ??
                                '',
                          ) ??
                          5;
                      return _SampleSizeTextField(
                        initialValue: sampleSize.toString(),
                        settingKey: 'stats_calc_sample_size',
                      );
                    },
                    loading: () => const SizedBox(
                      height: 48,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (_, __) => _SampleSizeTextField(
                      initialValue: '15',
                      settingKey: 'stats_calc_sample_size',
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Actions',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                await ref
                    .read(booksProvider.notifier)
                    .refreshExpiredBooks(forceRefreshAll: true);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Book stats refreshed'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh All Stats'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchSizeTextField extends ConsumerStatefulWidget {
  final String initialValue;

  const _BatchSizeTextField({required this.initialValue});

  @override
  ConsumerState<_BatchSizeTextField> createState() =>
      _BatchSizeTextFieldState();
}

class _BatchSizeTextFieldState extends ConsumerState<_BatchSizeTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(_BatchSizeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Books to Process at Once',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      controller: _controller,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        _MinMaxValueFormatter(1, 5),
      ],
      onChanged: (value) {
        final intValue = int.tryParse(value);
        if (intValue != null && intValue >= 1 && intValue <= 5) {
          ref
              .read(settingsProvider.notifier)
              .updateStatsRefreshBatchSize(intValue);
        }
      },
    );
  }
}

class _CooldownHoursTextField extends ConsumerStatefulWidget {
  final String initialValue;

  const _CooldownHoursTextField({required this.initialValue});

  @override
  ConsumerState<_CooldownHoursTextField> createState() =>
      _CooldownHoursTextFieldState();
}

class _CooldownHoursTextFieldState
    extends ConsumerState<_CooldownHoursTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(_CooldownHoursTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Cooldown Before Refresh (hours)',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      controller: _controller,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        _MinMaxValueFormatter(1, 336),
      ],
      onChanged: (value) {
        final intValue = int.tryParse(value);
        if (intValue != null && intValue >= 1 && intValue <= 336) {
          ref
              .read(settingsProvider.notifier)
              .updateStatsRefreshCooldownHours(intValue);
        }
      },
    );
  }
}

class _SampleSizeTextField extends ConsumerStatefulWidget {
  final String initialValue;
  final String settingKey;

  const _SampleSizeTextField({
    required this.initialValue,
    required this.settingKey,
  });

  @override
  ConsumerState<_SampleSizeTextField> createState() =>
      _SampleSizeTextFieldState();
}

class _SampleSizeTextFieldState extends ConsumerState<_SampleSizeTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(_SampleSizeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Pages to Refresh',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      controller: _controller,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        _MinMaxValueFormatter(1, 500),
      ],
      onChanged: (value) {
        final intValue = int.tryParse(value);
        if (intValue != null && intValue >= 1 && intValue <= 500) {
          ref
              .read(settingsProvider.notifier)
              .updateStatsCalcSampleSize(intValue);
          ref
              .read(contentServiceProvider)
              .setUserSetting(
                widget.settingKey,
                intValue.toString(),
                noQueue: true,
              )
              // 设置字段的写入是「尽力而为」：离线时立刻失败即可 —— 既不该排进
              // 队列（改设置自然会重发），也不该让异常逃进 zone（这条链路没有
              // 任何地方 await 它）。
              .catchError((Object _) {});
        }
      },
    );
  }
}

class _Stats500SampleSizeTextField extends ConsumerStatefulWidget {
  final String initialValue;

  const _Stats500SampleSizeTextField({required this.initialValue});

  @override
  ConsumerState<_Stats500SampleSizeTextField> createState() =>
      _Stats500SampleSizeTextFieldState();
}

class _Stats500SampleSizeTextFieldState
    extends ConsumerState<_Stats500SampleSizeTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(_Stats500SampleSizeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: '500 Sample Size',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      controller: _controller,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        _MinMaxValueFormatter(1, 500),
      ],
      onChanged: (value) {
        final intValue = int.tryParse(value);
        if (intValue != null && intValue >= 1 && intValue <= 500) {
          ref
              .read(settingsProvider.notifier)
              .updateStats500SampleSize(intValue);
        }
      },
    );
  }
}
