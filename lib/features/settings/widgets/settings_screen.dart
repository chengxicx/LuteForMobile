import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/providers/cache_manager_provider.dart';
import '../../../core/logger/widget_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../core/network/session_manager.dart';
import '../providers/settings_provider.dart';
import '../../books/providers/books_provider.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/settings.dart';
import '../../../shared/theme/theme_definitions.dart';
import '../../../app.dart';
import 'theme_selector_screen.dart';
import 'tts_settings_section.dart';
import 'ai_settings_section.dart';
import 'backup_restore_card.dart';
import 'termux_screen.dart';
import 'language_settings_card.dart';
import 'text_formatting_controls.dart';
import '../../../shared/utils/number_input.dart';

/// A bounded integer field.
///
/// Commits on submit or on losing focus, not per keystroke.  Saving per
/// keystroke silently lost values: typing 500 into a 1-10 field saved the 5,
/// dropped the 50 and 500 as out of range, and left the field reading 500
/// while the setting was 5.  Out-of-range input is now clamped, the applied
/// value is written back into the field, and the reason is shown under it.
class NumberField extends StatefulWidget {
  final String label;
  final String initialValue;
  final String hint;
  final int minValue;
  final int maxValue;
  final ValueChanged<String> onChanged;

  const NumberField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.hint,
    required this.minValue,
    required this.maxValue,
    required this.onChanged,
  });

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// The value actually in effect -- what the field falls back to when the
  /// input cannot be used.
  late String _committed;
  String? _error;
  bool _disposed = false;
  bool _settingText = false;

  @override
  void initState() {
    super.initState();
    _committed = widget.initialValue;
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _setControllerText(widget.initialValue);
      _committed = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // A value typed and then left on screen (card collapsed, screen popped)
    // is committed on the way out.
    _commit();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setControllerText(String text) {
    // Setting the text programmatically still fires onChanged, which would
    // clear the error this commit is about to show.
    _settingText = true;
    _controller.text = text;
    _settingText = false;
  }

  void _commit() {
    final resolved = resolveNumberInput(
      _controller.text,
      min: widget.minValue,
      max: widget.maxValue,
      fallback: _committed,
    );
    final nextText = resolved.value;
    final error = resolved.error;

    if (_controller.text != nextText) {
      _setControllerText(nextText);
    }
    if (nextText != _committed) {
      _committed = nextText;
      widget.onChanged(nextText);
    }
    if (!_disposed && error != _error) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          focusNode: _focusNode,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            hintText: widget.hint,
            errorText: _error,
          ),
          controller: _controller,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) {
            if (_settingText) return;
            if (!_disposed && _error != null) {
              setState(() => _error = null);
            }
          },
          onSubmitted: (_) => _commit(),
        ),
      ],
    );
  }
}

class SettingsScreen extends ConsumerStatefulWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const SettingsScreen({super.key, this.scaffoldKey});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _localUrlController = TextEditingController();
  final _authUserController = TextEditingController();
  final _authPasswordController = TextEditingController();
  final _luteUserController = TextEditingController();
  final _lutePasswordController = TextEditingController();
  String _protocolValue = 'https';
  int _buildCount = 0;
  bool _isTesting = false;
  String? _connectionStatus;
  bool _connectionTestPassed = false;
  bool _bookStatsExpanded = false;
  bool _readerExpanded = false;
  bool _isLoggingIn = false;
  String? _loginStatus;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('local_url') ?? '';
      final authUser = prefs.getString('basic_auth_user') ?? '';
      final authPassword = prefs.getString('basic_auth_password') ?? '';
      final luteUser = prefs.getString('lute_login_username') ?? '';
      if (mounted) {
        final parsed = _parseUrl(savedUrl);
        _protocolValue = parsed.$1;
        _localUrlController.text = parsed.$2;
        _authUserController.text = authUser;
        _authPasswordController.text = authPassword;
        _luteUserController.text = luteUser;
      }
    });
  }

  @override
  void dispose() {
    _localUrlController.dispose();
    _authUserController.dispose();
    _authPasswordController.dispose();
    _luteUserController.dispose();
    _lutePasswordController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isTesting = true;
      _connectionStatus = null;
      _connectionTestPassed = false;
    });

    final url = _buildFullUrl();
    final authUser = _authUserController.text.trim();
    final authPassword = _authPasswordController.text;
    try {
      final result = await SessionManager.checkServerInfo(
        url,
        basicAuthUser: authUser,
        basicAuthPassword: authPassword,
      );

      setState(() {
        _isTesting = false;
        if (result.ok) {
          _connectionStatus = result.version.isEmpty
              ? 'Connection successful!'
              : 'Connection successful — lute server version '
                    '${result.version}';
          _connectionTestPassed = true;
        } else if (result.requiresLogin) {
          _connectionStatus =
              'Server is reachable, but multi-user login is required. '
              'Enter your lute username/password below and press Log In.';
          // The server answered, so the URL is valid and can be saved.
          _connectionTestPassed = true;
        } else if (result.requiresBasicAuth) {
          _connectionStatus =
              'Server is reachable, but HTTP Basic Auth failed (401). '
              'Check the Basic Auth fields above.';
          _connectionTestPassed = true;
        } else {
          _connectionStatus = 'Connection failed: ${result.message}';
          _connectionTestPassed = false;
        }
      });
    } catch (e) {
      setState(() {
        _connectionStatus = 'Connection failed: ${e.toString()}';
        _isTesting = false;
        _connectionTestPassed = false;
      });
    }
  }

  Future<void> _luteLogin() async {
    final username = _luteUserController.text.trim();
    final password = _lutePasswordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _loginStatus = 'Enter your lute username and password.';
      });
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoggingIn = true;
      _loginStatus = null;
    });

    // Login targets the active server URL; fall back to the form URL only
    // when no server is configured yet. Otherwise a cookie could end up
    // associated with a URL the user never saved.
    if (SessionManager.serverUrl.isEmpty) {
      SessionManager.updateServerUrl(_buildFullUrl());
    }

    final result = await SessionManager.login(username, password);

    setState(() {
      _isLoggingIn = false;
      _loginStatus = result.success
          ? 'Logged in as $username.'
          : 'Login failed: ${result.message}';
    });

    if (result.success && mounted) {
      // Other users may have different books/terms: drop stale caches.
      await ref.read(cacheManagerProvider).clearServerDependentCaches();
      await ref.read(settingsProvider.notifier).clearCurrentBook();
      ref.read(booksProvider.notifier).loadBooks();
    }
  }

  Future<void> _luteLogout() async {
    await SessionManager.logout();
    setState(() {
      _loginStatus = 'Logged out.';
    });
    if (mounted) {
      await ref.read(cacheManagerProvider).clearServerDependentCaches();
      await ref.read(settingsProvider.notifier).clearCurrentBook();
      ref.read(booksProvider.notifier).loadBooks();
    }
  }

  void _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    final newUrl = _buildFullUrl();

    await _testConnection();

    if (!_connectionTestPassed) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final oldUrl = prefs.getString('local_url') ?? '';

    await ref
        .read(settingsProvider.notifier)
        .updateBasicAuth(
          _authUserController.text.trim(),
          _authPasswordController.text,
        );

    if (oldUrl != newUrl) {
      await ref.read(settingsProvider.notifier).clearCurrentBook();
      await ref.read(settingsProvider.notifier).updateLocalUrl(newUrl);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully')),
        );
      }

      RestartWidget.restartApp(context);
    } else {
      await ref.read(settingsProvider.notifier).updateLocalUrl(newUrl);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully')),
        );
      }

      if (oldUrl.isEmpty && newUrl.isNotEmpty) {
        ref.read(booksProvider.notifier).loadBooks();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    WidgetLogger.logRebuild('SettingsScreen', _buildCount);

    final settings = ref.watch(settingsProvider);
    final session = ref.watch(sessionProvider);
    final themeSettings = ref.watch(themeSettingsProvider);
    final textSettings = ref.watch(textFormattingSettingsProvider);

    // Settings 是 IndexedStack 切页（不是 Navigator push），切走后本 widget
    // 仍留在栈中：只有真正显示时才拦截系统返回键，否则会在其它 tab 上误拦截。
    final isCurrentRoute = ref.watch(currentScreenRouteProvider) == 'settings';

    return PopScope(
      canPop: !isCurrentRoute,
      onPopInvoked: (didPop) {
        if (didPop) return;
        ref
            .read(navigationProvider)
            .navigateToScreen(ref.read(lastMainRouteProvider));
      },
      child: Scaffold(
        appBar: AppBar(
          leading: const BackToMainButton(),
          title: const Text('Settings'),
          elevation: 2,
          actions: [
            AppBarLeading(scaffoldKey: widget.scaffoldKey),
            const SizedBox(width: 8),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              _buildSectionHeader(context, 'Server'),
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Server Configuration',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 110,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(_protocolValue),
                              initialValue: _protocolValue,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'http',
                                  child: Text('http://'),
                                ),
                                DropdownMenuItem(
                                  value: 'https',
                                  child: Text('https://'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _protocolValue = value);
                                  _connectionTestPassed = false;
                                  _connectionStatus = null;
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _localUrlController,
                              decoration: InputDecoration(
                                labelText: 'Server Host',
                                hintText:
                                    'e.g. lute.example.com or 192.168.1.100:5001',
                                border: const OutlineInputBorder(),
                                errorText: settings.isUrlValid
                                    ? null
                                    : 'Invalid URL format',
                                suffixIcon: _connectionStatus != null
                                    ? Icon(
                                        _connectionTestPassed
                                            ? Icons.check_circle
                                            : Icons.error,
                                        color: _connectionTestPassed
                                            ? context.success
                                            : context.error,
                                      )
                                    : settings.isUrlValid
                                    ? Icon(
                                        Icons.check_circle,
                                        color: context.connected,
                                      )
                                    : Icon(Icons.error, color: context.error),
                              ),
                              keyboardType: TextInputType.url,
                              onChanged: (_) {
                                _connectionTestPassed = false;
                                _connectionStatus = null;
                              },
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Please enter a server host';
                                }
                                final host = value.trim();
                                if (host.contains('://') ||
                                    host.contains(' ')) {
                                  return 'Enter only the host (no http://)';
                                }
                                try {
                                  final authority = '$_protocolValue://$host';
                                  final uri = Uri.parse(authority);
                                  if (uri.host.isEmpty) {
                                    return 'Please enter a valid host';
                                  }
                                } catch (_) {
                                  return 'Please enter a valid host';
                                }
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      if (settings.termuxIntegrationEnabled &&
                          settings.serverUrl == Settings.termuxUrl) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Authentication is not needed for the local Termux server and will be ignored.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _authUserController,
                        decoration: const InputDecoration(
                          labelText: 'Username (Basic Auth)',
                          hintText: 'e.g. song',
                          border: OutlineInputBorder(),
                        ),
                        autocorrect: false,
                        onChanged: (_) {
                          _connectionTestPassed = false;
                          _connectionStatus = null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _authPasswordController,
                        decoration: const InputDecoration(
                          labelText: 'Password (Basic Auth)',
                          hintText: 'Leave blank if no authentication',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (_) {
                          _connectionTestPassed = false;
                          _connectionStatus = null;
                        },
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Required only if your lute server is protected by HTTP Basic Authentication.',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.appColorScheme.text.primary
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Lute Account Login (multi-user mode)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Required when your lute server has multi-user login enabled (lute v3.12+). The session is kept for ~30 days.',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.appColorScheme.text.primary.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _luteUserController,
                        decoration: const InputDecoration(
                          labelText: 'Lute Username',
                          hintText: 'Your lute account username',
                          border: OutlineInputBorder(),
                        ),
                        autocorrect: false,
                        enableSuggestions: false,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _lutePasswordController,
                        decoration: const InputDecoration(
                          labelText: 'Lute Password',
                          hintText: 'Your lute account password',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isLoggingIn ? null : _luteLogin,
                              child: _isLoggingIn
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Log In'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: OutlinedButton(
                              onPressed:
                                  session.status == SessionStatus.loggedIn
                                  ? _luteLogout
                                  : null,
                              child: const Text('Log Out'),
                            ),
                          ),
                        ],
                      ),
                      if (_loginStatus != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _loginStatus!,
                          style: TextStyle(
                            fontSize: 12,
                            color: session.status == SessionStatus.loggedIn
                                ? context.success
                                : context.appColorScheme.text.primary
                                      .withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isTesting ? null : _testConnection,
                              child: _isTesting
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Test Connection'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _saveSettings,
                              child: const Text('Save Settings'),
                            ),
                          ),
                        ],
                      ),
                      if (_connectionStatus != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _connectionTestPassed
                                ? context.success.withValues(alpha: 0.1)
                                : context.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _connectionTestPassed
                                  ? context.success
                                  : context.error,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _connectionTestPassed
                                    ? Icons.check_circle
                                    : Icons.error,
                                color: _connectionTestPassed
                                    ? context.success
                                    : context.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _connectionStatus!,
                                  style: TextStyle(
                                    color: _connectionTestPassed
                                        ? context.success
                                        : context.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Termux Integration',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Enable Termux server features',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Transform.scale(
                              scale: 0.8,
                              child: Switch(
                                value: settings.termuxIntegrationEnabled,
                                onChanged: (value) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .updateTermuxIntegrationEnabled(value);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (settings.termuxIntegrationEnabled) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Server Selection',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'Use Termux server (localhost)',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Transform.scale(
                              scale: 0.8,
                              child: Switch(
                                value: settings.serverUrl == Settings.termuxUrl,
                                onChanged: (value) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .setServerSelection(value);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const BackupRestoreCard(),
              if (settings.termuxIntegrationEnabled) ...[
                const SizedBox(height: 16),
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Termux Integration',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            TextButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const TermuxScreen(),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.phone_android),
                              label: const Text('Open'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Run Lute3 server locally on your device using Termux',
                          style: TextStyle(
                            color: context.appColorScheme.text.primary
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current Settings',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      _buildSettingRow('Server URL', settings.serverUrl),
                      if (settings.serverUrl == Settings.termuxUrl)
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Using Termux (localhost)',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildSectionHeader(context, 'Reading'),
              // The reader's drawer panel used to be the only place these lived,
              // and there they were unreachable (non-scrollable panel, pushed
              // off-screen).  Same controls, one more way in.
              Card(
                elevation: 2,
                child: ExpansionTile(
                  title: const Text(
                    'Text Formatting',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  // Expanded by default: collapsed, the preview -- the only
                  // thing that shows what these controls actually do -- sat one
                  // tap out of sight.
                  initiallyExpanded: true,
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(16.0),
                      child: TextFormattingControls(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const LanguageSettingsCard(),
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                child: ExpansionTile(
                  title: const Text(
                    'Reading',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  initiallyExpanded: _readerExpanded,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _readerExpanded = expanded;
                    });
                  },
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Sentence Combining in Sentence Reader '),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Combine sentences with'),
                              const SizedBox(width: 8),
                              Text(
                                '${settings.combineShortSentences ?? 3} terms or less',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Slider(
                            value: (settings.combineShortSentences ?? 3)
                                .toDouble(),
                            min: 1,
                            max: 10,
                            divisions: 9,
                            label: (settings.combineShortSentences ?? 3)
                                .toString(),
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateCombineShortSentences(value.toInt());
                            },
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Sentences with this many terms or fewer will be combined to handle fragmentation from PDF/EPUB sources.',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColorScheme.text.primary
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text('Double Tap Timeout'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Timeout duration'),
                              const SizedBox(width: 8),
                              Text(
                                '${settings.doubleTapTimeout}ms',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Slider(
                            value: settings.doubleTapTimeout.toDouble(),
                            min: 200,
                            max: 400,
                            divisions: 8,
                            label: '${settings.doubleTapTimeout}ms',
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateDoubleTapTimeout(value.toInt());
                            },
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'The lower the value the faster the tooltip opens and the harder it is to open the Term Form',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColorScheme.text.primary
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text('Page Navigation'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Enable swipe navigation'),
                              const Spacer(),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: textSettings.swipeNavigationEnabled,
                                  onChanged: (value) {
                                    ref
                                        .read(
                                          textFormattingSettingsProvider
                                              .notifier,
                                        )
                                        .updateSwipeNavigationEnabled(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Text('Mark pages as read when swiping'),
                              const Spacer(),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: textSettings.swipeMarksRead,
                                  onChanged: (value) {
                                    ref
                                        .read(
                                          textFormattingSettingsProvider
                                              .notifier,
                                        )
                                        .updateSwipeMarksRead(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Text('Page Turn Animations'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Enable page turn animations'),
                              const Spacer(),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.pageTurnAnimations,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updatePageTurnAnimations(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Text('Page Preloading'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Enable page preloading',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Preload next page for faster navigation',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.enablePagePreload,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateEnablePagePreload(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Auto-load term stats cards',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Automatically load term stats cards instead of showing a manual Load button',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.autoLoadTermStatsCards,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateAutoLoadTermStatsCards(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          const Text('Tooltip Caching'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Enable tooltip caching',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Cache tooltips for faster loading (48 hour expiry)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.enableTooltipCaching,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateEnableTooltipCaching(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          if (settings.enableTooltipCaching) ...[
                            const SizedBox(height: 16),
                            NumberField(
                              label: 'Max Concurrent Tooltip Fetches',
                              initialValue: settings.maxConcurrentTooltipFetches
                                  .toString(),
                              hint: '1-10',
                              minValue: 1,
                              maxValue: 10,
                              onChanged: (value) {
                                final intValue = int.tryParse(value);
                                if (intValue != null) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .updateMaxConcurrentTooltipFetches(
                                        intValue,
                                      );
                                }
                              },
                            ),
                          ],
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              const Text('Show stats bar in reader'),
                              const Spacer(),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.showStatsBar,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateShowStatsBar(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Show known terms count',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Display known terms count in stats bar (requires API calls)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.showKnownTermsCount,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateShowKnownTermsCount(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Auto pronounce on tap',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Read a word aloud the moment its card appears',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.autoPronounceOnTap,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateAutoPronounceOnTap(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Triple-tap to mark as known',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Quickly mark words as known by tapping three times',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.enableTripleTapToMarkKnown,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateEnableTripleTapToMarkKnown(
                                          value,
                                        );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                child: ExpansionTile(
                  title: const Text(
                    'Terms',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  initiallyExpanded: false,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            title: const Text('Show Term Stats Card'),
                            value: settings.showTermStatsCard,
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateShowTermStatsCard(value);
                            },
                            contentPadding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const TTSSettingsSection(),
              const SizedBox(height: 16),
              const AISettingsSection(),
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                child: ExpansionTile(
                  title: const Text(
                    'Book Stats Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  initiallyExpanded: _bookStatsExpanded,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _bookStatsExpanded = expanded;
                    });
                  },
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          NumberField(
                            label: 'Calc Sample Size',
                            initialValue: settings.statsCalcSampleSize
                                .toString(),
                            hint: '1-500',
                            minValue: 1,
                            maxValue: 500,
                            onChanged: (value) {
                              final intValue = int.tryParse(value);
                              if (intValue != null) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .updateStatsCalcSampleSize(intValue);
                              }
                            },
                          ),
                          const SizedBox(height: 16),
                          SwitchListTile(
                            title: const Text('Auto Refresh Full Stats'),
                            value: settings.autoRefreshFullStats,
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateAutoRefreshFullStats(value);
                            },
                            contentPadding: EdgeInsets.zero,
                          ),
                          SwitchListTile(
                            title: const Text(
                              'Experimental Book Details Full Stats Endpoint',
                            ),
                            subtitle: const Text(
                              'Dev server only. Experimental proof of concept for the new backend stats refresh endpoint. Leave this off on normal servers.',
                            ),
                            value: settings
                                .experimentalBookDetailsFullStatsEndpoint,
                            onChanged: (value) {
                              ref
                                  .read(settingsProvider.notifier)
                                  .updateExperimentalBookDetailsFullStatsEndpoint(
                                    value,
                                  );
                            },
                            contentPadding: EdgeInsets.zero,
                          ),
                          if (settings.autoRefreshFullStats) ...[
                            const SizedBox(height: 8),
                            NumberField(
                              label: 'Books to Process at Once',
                              initialValue: settings.statsRefreshBatchSize
                                  .toString(),
                              hint: '1-5',
                              minValue: 1,
                              maxValue: 5,
                              onChanged: (value) {
                                final intValue = int.tryParse(value);
                                if (intValue != null) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .updateStatsRefreshBatchSize(intValue);
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            NumberField(
                              label: 'Cooldown Before Refresh (hours)',
                              initialValue: settings.statsRefreshCooldownHours
                                  .toString(),
                              hint: '1-336 (14 days)',
                              minValue: 1,
                              maxValue: 336,
                              onChanged: (value) {
                                final intValue = int.tryParse(value);
                                if (intValue != null) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .updateStatsRefreshCooldownHours(
                                        intValue,
                                      );
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            NumberField(
                              label: 'Full Refresh Sample Size',
                              initialValue: settings.stats500SampleSize
                                  .toString(),
                              hint: '1-500',
                              minValue: 1,
                              maxValue: 500,
                              onChanged: (value) {
                                final intValue = int.tryParse(value);
                                if (intValue != null) {
                                  ref
                                      .read(settingsProvider.notifier)
                                      .updateStats500SampleSize(intValue);
                                }
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildSectionHeader(context, 'Appearance'),
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Theme',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const ThemeSelectorScreen(),
                                ),
                              );
                            },
                            icon: const Icon(Icons.tune),
                            label: Text(_getThemeLabel(themeSettings)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _getThemeDescription(themeSettings),
                        style: TextStyle(
                          color: context.appColorScheme.text.primary.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reset Settings',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This will reset all settings to their default values.',
                        style: TextStyle(
                          color: context.appColorScheme.text.primary.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Reset Settings'),
                                content: const Text(
                                  'Are you sure you want to reset all settings to defaults?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      ref
                                          .read(settingsProvider.notifier)
                                          .resetSettings();
                                      final resetUrl = ref
                                          .read(settingsProvider)
                                          .serverUrl;
                                      final parsedReset = _parseUrl(resetUrl);
                                      _protocolValue = parsedReset.$1;
                                      _localUrlController.text = parsedReset.$2;
                                      _authUserController.clear();
                                      _authPasswordController.clear();
                                      _connectionStatus = null;
                                      _connectionTestPassed = false;
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Settings reset to defaults',
                                          ),
                                        ),
                                      );
                                    },
                                    child: const Text('Reset'),
                                  ),
                                ],
                              ),
                            );
                          },
                          icon: const Icon(Icons.restore),
                          label: const Text('Reset to Defaults'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildFullUrl() {
    final host = _localUrlController.text.trim();
    if (host.isEmpty) return '';
    return '$_protocolValue://$host';
  }

  (String, String) _parseUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) return ('https', '');
    final uri = Uri.tryParse(value);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final idx = value.indexOf('://');
      final host = idx >= 0 ? value.substring(idx + 3) : value;
      return (uri.scheme, host);
    }
    return ('https', value);
  }

  /// 分组标题。
  /// 原先设置页是一长串平铺的 Card、没有任何分组，十几个区块连成一片很难定位；
  /// 加上语义标题后可以按分区扫读。
  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 10.0, left: 4.0),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: context.m3Primary,
        ),
      ),
    );
  }

  Widget _buildSettingRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: context.appColorScheme.text.primary.withValues(
                  alpha: 0.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getThemeLabel(ThemeSettings themeSettings) {
    if (themeSettings.selectedUserTheme != null) {
      return themeSettings.selectedUserTheme!.name;
    }
    final themeType = themeSettings.themeType;
    switch (themeType) {
      case ThemeType.light:
        return 'Light';
      case ThemeType.dark:
        return 'Dark';
      case ThemeType.blackAndWhite:
        return 'Black and White device';
    }
  }

  String _getThemeDescription(ThemeSettings themeSettings) {
    if (themeSettings.selectedUserTheme != null) {
      return 'Custom theme';
    }
    final themeType = themeSettings.themeType;
    switch (themeType) {
      case ThemeType.light:
        return 'Bright, clean interface';
      case ThemeType.dark:
        return 'Dark interface for low light';
      case ThemeType.blackAndWhite:
        return 'Optimized for black and white screens';
    }
  }
}
