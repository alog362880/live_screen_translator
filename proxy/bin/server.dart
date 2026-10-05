import 'dart:io';

import 'package:screen_translate_proxy/proxy.dart';

Set<String> _csv(String? v) =>
    (v ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

/// Minimal KEY=VALUE parser for the git-ignored proxy/.env file.
Map<String, String> _loadDotEnv(String path) {
  final f = File(path);
  if (!f.existsSync()) return {};
  final out = <String, String>{};
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i <= 0) continue;
    var v = line.substring(i + 1).trim();
    if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
      v = v.substring(1, v.length - 1);
    }
    if (v.isNotEmpty) out[line.substring(0, i).trim()] = v;
  }
  return out;
}

Future<void> main() async {
  // Real environment variables win over .env (so prod/Docker config is unaffected).
  final env = {..._loadDotEnv('.env'), ...Platform.environment};
  final key = env['ANTHROPIC_API_KEY'] ?? '';
  final tokens = _csv(env['PROXY_TOKENS']);

  if (key.isEmpty || tokens.isEmpty) {
    stderr.writeln('ANTHROPIC_API_KEY and PROXY_TOKENS (comma-separated) are required (set them in proxy/.env or the environment).');
    exit(64);
  }
  if (tokens.any((t) => t.length < 24)) {
    stderr.writeln('Every PROXY_TOKENS entry must be at least 24 chars (try: openssl rand -hex 24).');
    exit(64);
  }

  final cfg = ProxyConfig(
    anthropicApiKey: key,
    tokens: tokens,
    upstream: env['ANTHROPIC_BASE_URL'] ?? 'https://api.anthropic.com',
    allowedModels: env['ALLOWED_MODELS'] != null
        ? _csv(env['ALLOWED_MODELS'])
        : const {'claude-sonnet-5', 'claude-haiku-4-5-20251001'},
    rateLimitPerMinute: int.tryParse(env['RATE_LIMIT_PER_MIN'] ?? '') ?? 20,
    allowedOrigins: _csv(env['ALLOWED_ORIGINS']),
  );

  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  await startProxy(cfg, port: port);
  stdout.writeln('Proxy listening on :$port (${tokens.length} token(s), '
      '${cfg.rateLimitPerMinute} req/min each)');
}
