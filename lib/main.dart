import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/text_block.dart';
import 'secrets.dart';
import 'services/ai_settings.dart';
import 'services/service_factory.dart';
import 'state/translation_controller.dart';
import 'ui/home_page.dart';
import 'ui/translation_overlay_stack.dart';

/// Default (proxy) mode's URL/token, from the git-ignored lib/secrets.dart
/// (copy lib/secrets.example.dart) unless overridden at build time with
/// --dart-define=PROXY_URL=... --dart-define=PROXY_TOKEN=.... Users can
/// instead switch to their own personal API key at runtime in Settings —
/// see AiSettings and settings_page.dart.
AiSettings _buildAiSettings() => AiSettings(
      defaultProxyUrl: const String.fromEnvironment('PROXY_URL', defaultValue: Secrets.proxyUrl),
      defaultProxyToken: const String.fromEnvironment('PROXY_TOKEN', defaultValue: Secrets.proxyToken),
    );

void main(List<String> args) {
  // desktop_multi_window relaunches the SAME executable for every
  // secondary window, passing ['multi_window', '<windowId>', '<jsonArgs>']
  // as the entrypoint args. Route to the overlay-only app in that case
  // instead of the full app with tray/hotkeys/home page.
  if (args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.parse(args[1]);
    final rawArgs = args.length > 2 && args[2].isNotEmpty
        ? jsonDecode(args[2]) as Map<String, dynamic>
        : <String, dynamic>{};
    runApp(_OverlayWindowApp(windowId: windowId, payload: rawArgs));
    return;
  }

  runApp(const ScreenTranslateApp());
}

class ScreenTranslateApp extends StatefulWidget {
  const ScreenTranslateApp({super.key});

  @override
  State<ScreenTranslateApp> createState() => _ScreenTranslateAppState();
}

class _ScreenTranslateAppState extends State<ScreenTranslateApp> {
  late final AiSettings _aiSettings;
  late final TranslationController _controller;

  @override
  void initState() {
    super.initState();
    _aiSettings = _buildAiSettings();
    final service = createScreenTranslationService(
      aiSettings: _aiSettings,
      targetLanguage: 'English',
    );
    _controller = TranslationController(service: service);
    _controller.initialize();

    // Picks up a previously-saved mode/personal-key choice; AiSettings
    // extends ChangeNotifier so the Settings page (and anything else
    // watching it) rebuilds once this resolves even though initState
    // can't await it.
    _aiSettings.loadPersisted().then((_) {
      if (!_aiSettings.config.isConfigured) {
        debugPrint(
          'WARNING: no AI provider configured — fill in lib/secrets.dart '
          '(see secrets.example.dart), pass --dart-define, or set a '
          'personal API key in Settings.',
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _aiSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _controller),
        ChangeNotifierProvider.value(value: _aiSettings),
      ],
      child: MaterialApp(
        title: 'Screen Translate',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      ),
    );
  }
}

/// Minimal app run inside the secondary transparent/always-on-top Windows
/// overlay window (see service_windows.dart's showOverlay). Deliberately
/// has no Scaffold/AppBar chrome — just the translated-text chips over a
/// fully transparent background so it reads as "floating over the desktop".
class _OverlayWindowApp extends StatelessWidget {
  const _OverlayWindowApp({required this.windowId, required this.payload});

  final int windowId;
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final blocksJson = (payload['blocks'] as List? ?? []).cast<Map<String, dynamic>>();
    final blocks = blocksJson.map(TextBlock.fromJson).toList();
    final scaleX = (payload['scaleX'] as num?)?.toDouble() ?? 1.0;
    final scaleY = (payload['scaleY'] as num?)?.toDouble() ?? 1.0;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: TranslationOverlayStack(blocks: blocks, scaleX: scaleX, scaleY: scaleY),
      ),
    );
  }
}
