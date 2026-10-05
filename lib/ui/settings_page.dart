import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

/// Lets the user switch between the shared proxy (default) and their own
/// personal Anthropic API key. Split out as its own StatefulWidget so the
/// key TextField keeps its own controller/focus across AiSettings'
/// ChangeNotifier rebuilds elsewhere on the page.
class _AiProviderSection extends StatefulWidget {
  const _AiProviderSection();

  @override
  State<_AiProviderSection> createState() => _AiProviderSectionState();
}

class _AiProviderSectionState extends State<_AiProviderSection> {
  late final TextEditingController _keyController;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AiSettings>();
    _keyController = TextEditingController(text: settings.personalApiKey);
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AiSettings>();
    final isDirect = settings.mode == AiMode.direct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Use my own Anthropic API key'),
          subtitle: Text(
            isDirect
                ? 'Calls Anthropic directly from this device — no proxy, no rate limit.'
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
              decoration: const InputDecoration(
                labelText: 'Anthropic API key',
                hintText: 'sk-ant-...',
                border: OutlineInputBorder(),
              ),
              onChanged: settings.setPersonalApiKey,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Your key is sent straight from this device to api.anthropic.com in every '
              'request and stored locally in this app only. It bypasses the proxy\'s '
              'rate limiting and revocability, and on Web it is visible to anyone '
              'inspecting network traffic from this browser. Get a key at '
              'console.anthropic.com — consider giving it a spend limit.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ] else
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Proxy URL/token come from lib/secrets.dart or --dart-define at build '
              'time; the real Anthropic key lives only on the proxy server.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
