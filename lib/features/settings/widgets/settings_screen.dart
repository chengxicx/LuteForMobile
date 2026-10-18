import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/providers/cache_manager_provider.dart';
import '../../../core/logger/widget_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/widgets/app_bar_leading.dart';
import '../../../shared/widgets/key_diagnostics_dialog.dart';
import '../providers/tts_settings_provider.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/dict/dict_repository.dart';
import '../../../shared/models/language.dart';
import '../../../shared/models/server_dictionary.dart';
import '../../../shared/providers/language_data_provider.dart';
import '../../../shared/providers/network_providers.dart';
import '../providers/settings_provider.dart';
import '../../books/providers/books_provider.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../models/settings.dart';
import '../models/tts_settings.dart';
import '../../../shared/theme/theme_definitions.dart';
import '../../../app.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'theme_selector_screen.dart';
import 'tts_settings_section.dart';
import 'ai_settings_section.dart';
import 'backup_restore_card.dart';
import 'storage_cache_section.dart';
import 'termux_screen.dart';
import 'text_formatting_controls.dart';

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
  bool _obscureLutePassword = true;
  String _protocolValue = 'https';
  int _buildCount = 0;
  bool _isTesting = false;
  String? _connectionStatus;
  bool _connectionTestPassed = false;
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
      // Test passes ⇒ save. Replaces the old separate Save Settings button.
      if (_connectionTestPassed && mounted) {
        await _persistConnection();
      }
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
    final formUrl = _buildFullUrl();
    if (SessionManager.serverUrl.isEmpty ||
        SessionManager.serverUrl != formUrl) {
      SessionManager.updateServerUrl(formUrl);
    }

    final result = await SessionManager.login(username, password);

    setState(() {
      _isLoggingIn = false;
      _loginStatus = result.success
          ? 'Logged in as $username.'
          : 'Login failed: ${result.message}';
    });

    if (result.success && mounted) {
      // 连接配置随登录一并落盘（host、Basic Auth），用户不必再单独点
      // Save Settings；Save 按钮保留给「改了 host 想先测连通性」的场景。
      await ref
          .read(settingsProvider.notifier)
          .updateBasicAuth(
            _authUserController.text.trim(),
            _authPasswordController.text,
          );
      await ref.read(settingsProvider.notifier).updateLocalUrl(formUrl);
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

  /// Persists the connection form (URL + Basic Auth). Called automatically
  /// when a connection test succeeds — there is no separate Save button:
  /// "Test Connection" IS the save, so a host change can't be saved without
  /// also proving it reachable.
  Future<void> _persistConnection() async {
    final newUrl = _buildFullUrl();
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
          const SnackBar(content: Text('Connection saved')),
        );
      }

      RestartWidget.restartApp(context);
    } else {
      await ref.read(settingsProvider.notifier).updateLocalUrl(newUrl);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connection saved')),
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
    // of() 可空（gen_l10n 规范输出）；delegate 已挂在 MaterialApp 上，
    // 这里必然非空。
    final l10n = AppLocalizations.of(context)!;
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
                      const SizedBox(height: 8),
                      ExpansionTile(
                        title: const Text('HTTP Basic Auth (optional)'),
                        subtitle: const Text(
                          'Collapsed by default — only for servers behind Basic Auth',
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
                                Text(
                                  'Required only if your lute server is protected by HTTP Basic Authentication.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context
                                        .appColorScheme.text.primary
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ExpansionTile(
                        title: const Text('Song Account Login'),
                        subtitle: const Text(
                          'Multi-user mode (lute v3.12+), session kept ~30 days',
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextFormField(
                                  controller: _luteUserController,
                                  decoration: const InputDecoration(
                                    labelText: 'Song Username',
                                    hintText: 'Your lute account username',
                                    border: OutlineInputBorder(),
                                  ),
                                  autocorrect: false,
                                  enableSuggestions: false,
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _lutePasswordController,
                                  decoration: InputDecoration(
                                    labelText: 'Song Password',
                                    hintText: 'Your lute account password',
                                    border: const OutlineInputBorder(),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscureLutePassword
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                      ),
                                      tooltip: _obscureLutePassword
                                          ? 'Show password'
                                          : 'Hide password',
                                      onPressed: () => setState(
                                        () => _obscureLutePassword =
                                            !_obscureLutePassword,
                                      ),
                                    ),
                                  ),
                                  obscureText: _obscureLutePassword,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _isLoggingIn
                                            ? null
                                            : _luteLogin,
                                        child: _isLoggingIn
                                            ? const SizedBox(
                                                height: 20,
                                                width: 20,
                                                child:
                                                    CircularProgressIndicator(
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
                                            session.status ==
                                                SessionStatus.loggedIn
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
                                      color: session.status ==
                                              SessionStatus.loggedIn
                                          ? context.success
                                          : context
                                                .appColorScheme.text.primary
                                                .withValues(alpha: 0.8),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // One-line session state stays visible even with the
                      // login panel collapsed.
                      Row(
                        children: [
                          Icon(
                            session.status == SessionStatus.loggedIn
                                ? Icons.check_circle
                                : Icons.info_outline,
                            size: 16,
                            color: session.status == SessionStatus.loggedIn
                                ? context.success
                                : context.appColorScheme.text.primary
                                      .withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            session.status == SessionStatus.loggedIn
                                ? 'Logged in'
                                : 'Not logged in',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColorScheme.text.primary
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
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
                              : const Text('Test Connection & Save'),
                        ),
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
              _buildSectionHeader(context, 'Reading'),
              // 屏幕方向锁：跟随系统时手机小幅倾斜就触发整页重排（有播放条
              // 时尤其扰人），默认锁竖屏；漫画横屏或想跟随系统的再切换。
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Screen Orientation',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Portrait keeps the screen upright while reading; '
                        'System follows the phone auto-rotate.',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.appColorScheme.text.secondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<OrientationLock>(
                        segments: const [
                          ButtonSegment(
                            value: OrientationLock.system,
                            icon: Icon(Icons.screen_rotation),
                            label: Text('System'),
                          ),
                          ButtonSegment(
                            value: OrientationLock.portrait,
                            icon: Icon(Icons.screen_lock_portrait),
                            label: Text('Portrait'),
                          ),
                          ButtonSegment(
                            value: OrientationLock.landscape,
                            icon: Icon(Icons.screen_lock_landscape),
                            label: Text('Landscape'),
                          ),
                        ],
                        selected: {settings.orientationLock},
                        onSelectionChanged: (selection) {
                          ref
                              .read(settingsProvider.notifier)
                              .updateOrientationLock(selection.first);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // E-ink gets its own top-level card: buried inside the Reading
              // expansion it was effectively undiscoverable on the device.
              Card(
                elevation: 2,
                child: ExpansionTile(
                  title: const Text(
                    'E-ink Mode',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'For BOOX / e-ink devices: animations off, tap zones, hardware page-turn keys',
                  ),
                  initiallyExpanded: false,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Optimize for e-ink displays: no animations, '
                                  'no shadows or glow, and tap the left or '
                                  'right third of the page to turn it',
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: settings.eInkMode,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateEInkMode(value);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => showDialog(
                              context: context,
                              builder: (_) => const KeyDiagnosticsDialog(),
                            ),
                            icon: const Icon(Icons.keyboard),
                            label: const Text(
                              'Test hardware keys (page-turn buttons)',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final notifier = ref.read(
                                settingsProvider.notifier,
                              );
                              await notifier.updateEInkMode(true);
                              await notifier.updatePageTurnAnimations(false);
                              await notifier.updateAutoPronounceOnTap(false);
                              await ref
                                  .read(termFormSettingsProvider.notifier)
                                  .updateShowTooltipImages(false);
                              // 机内 TTS（系统 SpeechSynthesis）在国行 Leaf 5C 上
                              // 大概率缺日语/韩语语音：预设里一次性切到服务端
                              // Edge TTS。新装设备默认是 none（没选过引擎），
                              // 也一并切过去；用户已明确选了其他引擎则不动。
                              final ttsProvider = ref
                                  .read(ttsSettingsProvider)
                                  .provider;
                              if (ttsProvider == TTSProvider.onDevice ||
                                  ttsProvider == TTSProvider.none) {
                                await ref
                                    .read(ttsSettingsProvider.notifier)
                                    .updateProvider(TTSProvider.edgeTTS);
                              }
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('E-ink preset applied'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.auto_awesome),
                            label: const Text('Apply e-ink preset'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
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
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Show furigana',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Readings above words that contain kanji. '
                                      'Only languages that supply readings '
                                      '(Japanese, Mandarin, Cantonese) are '
                                      'affected. This switch is the app\'s own '
                                      'and is independent of the language '
                                      'setting on the web reader.',
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
                                  value: settings.furiganaEnabled,
                                  onChanged: (value) {
                                    ref
                                        .read(settingsProvider.notifier)
                                        .updateFuriganaEnabled(value);
                                  },
                                ),
                              ),
                            ],
                          ),
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
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Dictionary button jumps to Eudic',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Off: copy the word (tap the Eudic floating ball to look it up). On: open Eudic full screen',
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
                                  value: ref
                                      .watch(termFormSettingsProvider)
                                      .dictButtonJumpMode,
                                  onChanged: (value) {
                                    ref
                                        .read(termFormSettingsProvider.notifier)
                                        .updateDictButtonJumpMode(value);
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
              const _DictDownloadCard(),
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
              // 存储与缓存：原先缓存只能靠"登录/登出"顺带清掉，用户既看不到
              // 占用，也没有办法强制刷新被 14 天 TTL 扣住的页面内容。
              _buildSectionHeader(context, 'Storage'),
              const StorageCacheSection(),
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
              // 界面语言：仅本机保存、即时生效，与 Web 端的 ui_language
              // 相互独立（用户 2026-10-14 要求）。选项 label 用各语言母语名。
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.settingsUiLanguage,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.settingsUiLanguageDesc,
                        style: TextStyle(
                          color: context.appColorScheme.text.primary
                              .withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: settings.uiLanguage,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        items: [
                          for (final lang in kUiLanguages)
                            DropdownMenuItem(
                              value: lang.code,
                              child: Text(lang.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .updateUiLanguage(value);
                          }
                        },
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

/// 本地词典（阶段 3）：本机词典池 + 按语言选用。
///  1. 服务器词典池：GET /dict/status 拉列表，逐本下载到本机词典池
///     （dict/pool/，**与语言无关**，下载地址由文件名派生，见
///     ServerDictionary.urlFor）；
///  2. 本地导入：设备上的 .mdx 文件，用内置解析器本地转换后进池。
/// 池内词典可删除；每门语言在池里"选用"一本（选用记录按语言各存一份），
/// 同一本可被多门语言共用。旧版按语言分库的 `active_<langId>.db` 会在打开
/// 本卡时被收养进池（见 DictRepository.adoptLegacyPerLangDicts）。
class _DictDownloadCard extends ConsumerStatefulWidget {
  const _DictDownloadCard();

  @override
  ConsumerState<_DictDownloadCard> createState() => _DictDownloadCardState();
}

class _DictDownloadCardState extends ConsumerState<_DictDownloadCard> {
  bool _busy = false;
  bool _importing = false;
  bool _deleting = false;
  int _percent = -1;
  int _processed = 0;
  String _error = '';

  /// 一次性提示（下载/导入成功后的下一步引导），下一次操作时清掉。
  String _hint = '';

  /// 服务器词典池（GET /dict/status）。null = 还没拿到（加载中或失败），
  /// 空列表 = 服务器池是空的。
  List<ServerDictionary>? _serverDicts;
  bool _loadingDicts = true;

  /// 拉列表失败的原因（服务器没配、没登录、服务端没这个端点）。
  String? _dictsError;

  /// 本机词典池（dict/pool/），空列表 = 一本都没下载/导入。
  List<PoolDict> _pool = const [];

  /// langId → 选用的池内文件名。
  Map<int, String> _selections = const {};

  /// 有可用词典的语言 id（选用池词典 ∪ 残留 per-lang 旧库）。
  List<int> _installedIds = const [];

  /// 是否存在旧版单词典时代的共享库（查询回落用）。
  bool _legacyShared = false;

  /// 用户显式选中的语言（为它选词典）；null 时回落到默认选择
  /// （见 [_effectiveLangId]）。
  int? _selectedLangId;

  @override
  void initState() {
    super.initState();
    _loadServerDicts();
    _refreshPool();
  }

  /// 拉服务器词典池列表。需要登录态；失败时保留本地导入入口，只是没有
  /// 可选的在线词典。
  Future<void> _loadServerDicts() async {
    setState(() {
      _loadingDicts = true;
      _dictsError = null;
    });
    final serverUrl = ref.read(settingsProvider).serverUrl;
    if (serverUrl.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _loadingDicts = false;
        _dictsError = 'Server address not configured';
      });
      return;
    }
    final json = await ref.read(apiServiceProvider).getDictStatus();
    if (!mounted) return;
    final dicts =
        json == null ? null : ServerDictionary.parseStatusResponse(json);
    setState(() {
      _loadingDicts = false;
      _serverDicts = dicts;
      _dictsError = dicts == null
          ? 'Failed to load: check the server address and login status'
          : null;
    });
  }

  /// 刷新本机词典池状态：先收养旧版 per-lang 库，再读池/选用/安装情况。
  Future<void> _refreshPool() async {
    final repo = ref.read(dictRepositoryProvider);
    await repo.adoptLegacyPerLangDicts();
    final pool = await repo.listPool();
    final selections = await repo.selectionMap();
    final ids = await repo.installedLangIds();
    final legacy = await repo.hasLegacyDict();
    if (!mounted) return;
    setState(() {
      _pool = pool;
      _selections = selections;
      _installedIds = ids;
      _legacyShared = legacy;
      // 默认选中第一个有词典的语言；语言列表加载后若仍未选，
      // build 里会回落到列表第一个（见 [_effectiveLangId]）。
      if (_selectedLangId == null && ids.isNotEmpty) {
        _selectedLangId = ids.first;
      }
    });
  }

  /// 当前生效的语言选择：显式选择优先，否则第一个已装词典的语言，
  /// 否则语言列表第一个；语言列表也拿不到（离线加载失败）时返回 null。
  int? _effectiveLangId(List<Language> languages) {
    final explicit = _selectedLangId;
    if (explicit != null) return explicit;
    if (languages.isEmpty) return null;
    for (final lang in languages) {
      if (_installedIds.contains(lang.id)) return lang.id;
    }
    return languages.first.id;
  }

  String _languageName(List<Language> languages, int? id) {
    if (id == null) return 'No language';
    for (final lang in languages) {
      if (lang.id == id) return lang.name;
    }
    return 'Language #$id';
  }

  /// 下载列表里的一本到本机词典池（不绑定语言）。
  Future<void> _downloadFile(ServerDictionary dict) async {
    final url = ServerDictionary.urlFor(
      ref.read(settingsProvider).serverUrl,
      dict.filename,
    );
    setState(() {
      _busy = true;
      _percent = 0;
      _error = '';
      _hint = '';
    });
    final ok = await ref
        .read(dictRepositoryProvider)
        .downloadToPool(
          url,
          filename: dict.filename,
          onProgress: (received, total) {
            if (total > 0 && mounted) {
              setState(() => _percent = received * 100 ~/ total);
            }
          },
        );
    if (!mounted) return;
    final languages =
        ref.read(languageListProvider).value ?? const <Language>[];
    final langName = _languageName(languages, _effectiveLangId(languages));
    setState(() {
      _busy = false;
      _percent = -1;
      if (ok) {
        _hint =
            'Downloaded to the local dictionary pool — tap it in "On this '
            'device" above to use it for $langName';
      } else {
        _error =
            'Download failed: ${dict.displayName} (link unavailable or not an '
            'app dictionary format)';
      }
    });
    await _refreshPool();
  }

  /// 把 [filename] 选用为当前语言的词典。
  Future<void> _selectDict(String filename) async {
    final languages =
        ref.read(languageListProvider).value ?? const <Language>[];
    final langId = _effectiveLangId(languages);
    if (langId == null) {
      setState(() => _error = 'Language list unavailable — reload and retry');
      return;
    }
    setState(() {
      _error = '';
      _hint = '';
    });
    try {
      await ref.read(dictRepositoryProvider).selectDict(langId, filename);
    } catch (e) {
      if (mounted) setState(() => _error = 'Selection failed: $e');
      return;
    }
    await _refreshPool();
  }

  /// 导入 .mdx 进本机词典池（不绑定语言）。
  Future<void> _importMdx() async {
    setState(() {
      _importing = true;
      _processed = 0;
      _error = '';
      _hint = '';
    });
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.any,
        withData: false,
      );
      final path = picked?.files.single.path;
      if (path == null || !path.toLowerCase().endsWith('.mdx')) {
        if (mounted) {
          setState(() {
            _importing = false;
            _error = 'Please select a .mdx file';
          });
        }
        return;
      }
      final result = await ref
          .read(dictRepositoryProvider)
          .importMdxToPool(
            path,
            onProgress: (processed) {
              if (mounted) setState(() => _processed = processed);
            },
          );
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = switch (result.status) {
          ImportStatus.ok => '',
          // 解析器的报错本身就写清了原因（哪种编码、是不是 regcode 加密），
          // 直接透出来，比笼统一句"格式不支持"有用。
          ImportStatus.unsupported =>
            'This dictionary is not supported: ${result.message}',
          ImportStatus.corrupt => 'Cannot read the file: ${result.message}',
          ImportStatus.empty => result.message,
          ImportStatus.ioError => 'Import failed: ${result.message}',
        };
        if (result.ok) {
          _hint =
              'Imported into the local dictionary pool — tap it in "On this '
              'device" above to enable it for a language';
        }
      });
      await _refreshPool();
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = 'Import failed';
        });
      }
    }
  }

  /// 删除池内词典（二次确认）。删除后清掉所有语言里指向它的选用。
  Future<void> _deleteDict(String filename) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete dictionary'),
        content: Text(
          'Delete "$filename"? The file will be removed from this device; '
          'you can download or import it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _deleting = true;
      _error = '';
      _hint = '';
    });
    await ref.read(dictRepositoryProvider).deletePoolDict(filename);
    if (!mounted) return;
    setState(() => _deleting = false);
    await _refreshPool();
  }

  /// 已安装情况的摘要（各语言选用的词典 + 旧版共享库提示）。
  String _installedSummary(List<Language> languages) {
    final parts = <String>[];
    for (final id in _installedIds) {
      final name = _languageName(languages, id);
      final picked = _selections[id];
      parts.add(picked != null ? '$name → $picked' : '$name (legacy)');
    }
    if (_legacyShared) parts.add('Legacy shared dictionary (fallback)');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final languages =
        ref.watch(languageListProvider).value ?? const <Language>[];
    final selectedId = _effectiveLangId(languages);
    final langName = _languageName(languages, selectedId);
    final current = selectedId != null ? _selections[selectedId] : null;
    final currentInPool = current != null &&
        _pool.any((d) => d.filename == current);
    // DropdownButtonFormField 的 value 必须在 items 里，否则断言炸：
    // 语言列表加载失败（离线）时 items 为空，此时只显示 hint。
    final dropdownValue =
        languages.any((l) => l.id == selectedId) ? selectedId : null;
    final busy = _busy || _importing || _deleting;
    final String subtitle;
    if (_busy) {
      subtitle = 'Downloading ${_percent < 0 ? '' : '$_percent%'}…';
    } else if (_importing) {
      subtitle = 'Parsing… $_processed entries processed';
    } else if (_deleting) {
      subtitle = 'Deleting…';
    } else if (_error.isNotEmpty) {
      // 必须排在 installed 前面：已经装好一本词典时再导一本失败的，若先走
      // installed 分支，副标题会照旧显示"已就绪"，用户以为这次也成功了。
      subtitle = _error;
    } else if (currentInPool) {
      subtitle =
          '$langName uses "$current" · offline term definitions available';
    } else if (selectedId != null && _installedIds.contains(selectedId)) {
      subtitle = '$langName uses a legacy dictionary (not in the pool)';
    } else if (_legacyShared) {
      subtitle =
          '$langName has no dictionary selected — lookups fall back to the '
          'legacy shared dictionary';
    } else {
      subtitle = '$langName has no dictionary selected';
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Local dictionary',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
            if (_hint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _hint,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
            if (_installedIds.isNotEmpty || _legacyShared) ...[
              const SizedBox(height: 6),
              Text(
                _installedSummary(languages),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
            if (_busy && _percent >= 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _percent / 100),
            ],
            if (_importing) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: dropdownValue,
              isDense: true,
              items: [
                for (final lang in languages)
                  DropdownMenuItem(
                    value: lang.id,
                    child: Text(lang.name, style: const TextStyle(fontSize: 13)),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                        _selectedLangId = v;
                        _error = '';
                        _hint = '';
                      }),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Choose a dictionary for language',
              ),
              hint: const Text('Loading languages…'),
            ),
            const SizedBox(height: 12),
            // -------------------------------------------------- 本机词典池
            Text(
              'On this device (tap to enable for the language above, or '
              'delete)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            if (_pool.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'No dictionaries yet — download from the server pool '
                  'below, or import a .mdx file',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
              )
            else
              for (final dict in _pool)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentInPool && dict.filename == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  title: Text(
                    dict.filename,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${dict.sizeMb.toStringAsFixed(1)} MB',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: busy ? null : () => _deleteDict(dict.filename),
                  ),
                  onTap: busy ? null : () => _selectDict(dict.filename),
                ),
            const SizedBox(height: 12),
            // -------------------------------------------------- 服务器词典池
            Row(
              children: [
                Text(
                  'Server dictionaries',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                if (_loadingDicts)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    onPressed: busy ? null : _loadServerDicts,
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Refresh list',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            if (_dictsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _dictsError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              )
            else if (_serverDicts != null && _serverDicts!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The server dictionary pool is empty — import one from the '
                  'web settings page first, or import a .mdx file below',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
              )
            else if (_serverDicts != null) ...[
              for (final dict in _serverDicts!)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _pool.any((d) => d.filename == dict.filename)
                        ? Icons.download_done
                        : Icons.cloud_download_outlined,
                    size: 20,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          dict.displayName,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_pool.any((d) => d.filename == dict.filename)) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            'Downloaded',
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: dict.summary.isEmpty
                      ? null
                      : Text(
                          dict.summary,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                  trailing: IconButton(
                    icon: Icon(
                      _pool.any((d) => d.filename == dict.filename)
                          ? Icons.refresh
                          : Icons.download,
                      size: 18,
                    ),
                    tooltip: _pool.any((d) => d.filename == dict.filename)
                        ? 'Download again (overwrites the local copy)'
                        : 'Download',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _busy ? null : () => _downloadFile(dict),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy || _importing || _deleting ? null : _importMdx,
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Import .mdx file'),
            ),
          ],
        ),
      ),
    );
  }
}
