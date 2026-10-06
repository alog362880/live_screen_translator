import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ai_config.dart';
import '../services/ai_settings.dart';
import '../state/translation_controller.dart';

const _supportedLanguages = [
  'English',
  'Spanish',
  'Vietnamese',
  'Japanese',
  'French',
  'German',
  'Chinese (Simplified)',
];

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TranslationController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Target language'),
            subtitle: Text(controller.targetLanguage),
            trailing: DropdownButton<String>(
              value: controller.targetLanguage,
              items: _supportedLanguages
                  .map((lang) => DropdownMenuItem(value: lang, child: Text(lang)))
                  .toList(),
              onChanged: (value) {
                if (value != null) controller.setTargetLanguage(value);
              },
            ),
          ),
          const Divider(),
          const _AiProviderSection(),
        ],
      ),
    );
  }
}

/// Lets the user pick the AI provider (Claude / Gemini / ChatGPT) and
/// whether to go through the shared proxy or their own personal API key.
/// Split out as its own StatefulWidget so the text fields keep their own
/// controllers/focus across AiSettings' ChangeNotifier rebuilds.
class _AiProviderSection extends StatefulWidget {
  const _AiProviderSection();

  @override
  State<_AiProviderSection> createState() => _AiProviderSectionState();
}

class _AiProviderSectionState extends State<_AiProviderSection> {
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AiSettings>();
    _keyController = TextEditingController(text: settings.keyFor(settings.provider));
    _modelController = TextEditingController(text: settings.modelOverrideFor(settings.provider));
    // Persisted values load asynchronously after first build; sync once ready.
    settings.addListener(_syncFromSettingsOnce);
  }

  bool _synced = false;
  void _syncFromSettingsOnce() {
    if (_synced) return;
    _synced = true;
    final s = context.read<AiSettings>();
    _keyController.text = s.keyFor(s.provider);
    _modelController.text = s.modelOverrideFor(s.provider);
  }

  @override
  void dispose() {
    context.read<AiSettings>().removeListener(_syncFromSettingsOnce);
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _changeProvider(AiSettings settings, AiProvider next) {
    settings.setProvider(next);
    // Each provider keeps its own key/model; swap what the fields show.
    _keyController.text = settings.keyFor(next);
    _modelController.text = settings.modelOverrideFor(next);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AiSettings>();
    final provider = settings.provider;
    final isDirect = settings.mode == AiMode.direct;
    const hint = TextStyle(color: Colors.grey, fontSize: 12);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text('AI provider'),
          trailing: DropdownButton<AiProvider>(
            value: provider,
            items: [
              for (final p in AiProvider.values) DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (value) {
              if (value != null) _changeProvider(settings, value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _modelController,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Model (optional)',
              hintText: provider.defaultModel,
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => settings.setModelOverride(provider, v),
          ),
        ),
        SwitchListTile(
          title: const Text('Use my own API key'),
          subtitle: Text(
            isDirect
                ? 'Calls ${provider.label} directly from this device — no proxy, no rate limit.'
                : 'Default: requests go through the shared proxy (see /proxy).',
          ),
          value: isDirect,
          onChanged: (value) => settings.setMode(value ? AiMode.direct : AiMode.proxy),
        ),
        if (isDirect) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _keyController,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '${provider.label} API key',
                hintText: provider.keyHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => settings.setKey(provider, v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Your key is sent straight from this device to ${provider.label} in every '
              'request and stored locally in this app only. It bypasses the '
              'proxy rate limiting and revocability, and on Web it is visible to anyone '
              'inspecting network traffic from this browser. Get a key at '
              '${provider.keyConsole} — consider giving it a spend limit.',
              style: hint,
            ),
          ),
        ] else
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Proxy URL/token come from lib/secrets.dart or --dart-define at build '
              'time; the real provider keys live only on the proxy server, and the '
              'proxy must have a key for the provider you pick.',
              style: hint,
            ),
          ),
      ],
    );
  }
}
