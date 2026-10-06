import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Provider ids used for routing and the per-provider model allowlists.
const providerClaude = 'claude';
const providerGemini = 'gemini';
const providerOpenai = 'openai';

const defaultAllowedModels = <String, Set<String>>{
  providerClaude: {'claude-sonnet-5', 'claude-haiku-4-5-20251001'},
  providerGemini: {'gemini-2.5-flash', 'gemini-2.5-flash-lite', 'gemini-2.5-pro'},
  providerOpenai: {'gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini', 'gpt-4.1'},
};

/// Everything the proxy needs, read from environment in bin/server.dart.
/// A provider is enabled only if its API key is set.
class ProxyConfig {
  ProxyConfig({
    this.anthropicApiKey,
    this.geminiApiKey,
    this.openaiApiKey,
    required this.tokens,
    this.anthropicUpstream = 'https://api.anthropic.com',
    this.geminiUpstream = 'https://generativelanguage.googleapis.com',
    this.openaiUpstream = 'https://api.openai.com',
    this.allowedModels = defaultAllowedModels,
    this.rateLimitPerMinute = 20,
    this.allowedOrigins = const {},
    this.maxBodyBytes = 12 * 1024 * 1024, // screenshots arrive as base64
    this.maxTokensCap = 4096,
    this.geminiMaxOutputCap = 8192, // Gemini "thinking" tokens count against this
  });

  /// The real keys. They live only in this process's environment.
  final String? anthropicApiKey;
  final String? geminiApiKey;
  final String? openaiApiKey;

  /// Bearer tokens clients may present. One per user/device lets you
  /// revoke and rate-limit individually.
  final Set<String> tokens;
  final String anthropicUpstream;
  final String geminiUpstream;
  final String openaiUpstream;

  /// provider id -> allowed model names.
  final Map<String, Set<String>> allowedModels;
  final int rateLimitPerMinute;

  /// Exact Origin values allowed for browser callers (Flutter Web, the
  /// extension's chrome-extension://<id>). Native apps send no Origin.
  final Set<String> allowedOrigins;
  final int maxBodyBytes;
  final int maxTokensCap;
  final int geminiMaxOutputCap;

  String? keyFor(String provider) => switch (provider) {
        providerClaude => anthropicApiKey,
        providerGemini => geminiApiKey,
        providerOpenai => openaiApiKey,
        _ => null,
      };

  List<String> get enabledProviders => [
        for (final p in [providerClaude, providerGemini, providerOpenai])
          if ((keyFor(p) ?? '').isNotEmpty) p,
      ];
}

class _RateLimiter {
  _RateLimiter(this.perMinute);
  final int perMinute;
  final _hits = <String, List<DateTime>>{};

  /// Returns null if allowed, else seconds until the next slot frees up.
  int? check(String key, DateTime now) {
    final cutoff = now.subtract(const Duration(minutes: 1));
    final list = _hits.putIfAbsent(key, () => []);
    list.removeWhere((t) => t.isBefore(cutoff));
    if (list.length >= perMinute) {
      return list.first.add(const Duration(minutes: 1)).difference(now).inSeconds + 1;
    }
    list.add(now);
    return null;
  }
}

bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

Future<HttpServer> startProxy(ProxyConfig cfg, {int port = 8080, Object? address}) async {
  final server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
  final limiter = _RateLimiter(cfg.rateLimitPerMinute);
  final client = http.Client();

  server.listen((req) async {
    try {
      await _handle(req, cfg, limiter, client);
    } catch (_) {
      // Never echo internals (or anything key-adjacent) to callers.
      await _json(req, 500, {'error': 'internal_error'});
    }
  });
  return server;
}

void _cors(HttpRequest req, ProxyConfig cfg) {
  final origin = req.headers.value('origin');
  if (origin != null && cfg.allowedOrigins.contains(origin)) {
    final h = req.response.headers;
    h.set('Access-Control-Allow-Origin', origin);
    h.set('Vary', 'Origin');
    h.set('Access-Control-Allow-Headers', 'authorization, content-type');
    h.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  }
}

Future<void> _json(HttpRequest req, int status, Object body, {Map<String, String>? headers}) async {
  final res = req.response..statusCode = status;
  res.headers.contentType = ContentType.json;
  headers?.forEach(res.headers.set);
  res.write(jsonEncode(body));
  await res.close();
}

final _geminiPath = RegExp(r'^/gemini/v1beta/models/([A-Za-z0-9._-]+):generateContent$');

/// Resolves a request path to (provider, model-from-path).
(String, String?)? _route(String path) {
  if (path == '/v1/messages') return (providerClaude, null);
  if (path == '/openai/v1/chat/completions') return (providerOpenai, null);
  final m = _geminiPath.firstMatch(path);
  if (m != null) return (providerGemini, m.group(1));
  return null;
}

int _cap(Object? requested, int cap) =>
    requested is int && requested > 0 ? (requested < cap ? requested : cap) : cap;

Future<void> _handle(HttpRequest req, ProxyConfig cfg, _RateLimiter limiter, http.Client client) async {
  _cors(req, cfg);

  if (req.method == 'OPTIONS') {
    req.response.statusCode = 204;
    await req.response.close();
    return;
  }
  if (req.uri.path == '/healthz') {
    return _json(req, 200, {'ok': true, 'providers': cfg.enabledProviders});
  }
  final route = _route(req.uri.path);
  if (route == null) return _json(req, 404, {'error': 'not_found'});
  if (req.method != 'POST') return _json(req, 405, {'error': 'method_not_allowed'});
  final (provider, pathModel) = route;

  // --- auth ---
  final auth = req.headers.value('authorization') ?? '';
  final token = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
  var valid = false;
  for (final t in cfg.tokens) {
    // No early exit: don't leak which token matched via timing.
    valid = _constantTimeEquals(t, token) || valid;
  }
  if (!valid) return _json(req, 401, {'error': 'unauthorized'});

  final apiKey = cfg.keyFor(provider);
  if (apiKey == null || apiKey.isEmpty) {
    return _json(req, 404, {'error': 'provider_not_configured'});
  }

  // --- rate limit (per token) ---
  final wait = limiter.check(token, DateTime.now());
  if (wait != null) {
    return _json(req, 429, {'error': 'rate_limited'}, headers: {'Retry-After': '$wait'});
  }

  // --- bounded body read ---
  final declared = req.contentLength;
  if (declared > cfg.maxBodyBytes) return _json(req, 413, {'error': 'body_too_large'});
  final bytes = <int>[];
  await for (final chunk in req) {
    bytes.addAll(chunk);
    if (bytes.length > cfg.maxBodyBytes) return _json(req, 413, {'error': 'body_too_large'});
  }
  Map<String, dynamic> body;
  try {
    body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    return _json(req, 400, {'error': 'invalid_json'});
  }

  // --- validate + rebuild an allowlisted upstream request ---
  // Anything not copied here (system prompts, tools, streaming, safety
  // overrides...) is dropped, so a leaked token can only do "translate this".
  final allowed = cfg.allowedModels[provider] ?? const <String>{};
  late Uri url;
  late Map<String, String> headers;
  late Object upstreamBody;

  switch (provider) {
    case providerClaude:
      final model = body['model'];
      final messages = body['messages'];
      if (model is! String || !allowed.contains(model)) {
        return _json(req, 400, {'error': 'model_not_allowed'});
      }
      if (messages is! List || messages.isEmpty) {
        return _json(req, 400, {'error': 'messages_required'});
      }
      url = Uri.parse('${cfg.anthropicUpstream}/v1/messages');
      headers = {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'};
      upstreamBody = {
        'model': model,
        'max_tokens': _cap(body['max_tokens'], cfg.maxTokensCap),
        'messages': messages,
      };
    case providerOpenai:
      final model = body['model'];
      final messages = body['messages'];
      if (model is! String || !allowed.contains(model)) {
        return _json(req, 400, {'error': 'model_not_allowed'});
      }
      if (messages is! List || messages.isEmpty) {
        return _json(req, 400, {'error': 'messages_required'});
      }
      url = Uri.parse('${cfg.openaiUpstream}/v1/chat/completions');
      headers = {'authorization': 'Bearer $apiKey'};
      upstreamBody = {
        'model': model,
        'max_completion_tokens':
            _cap(body['max_completion_tokens'] ?? body['max_tokens'], cfg.maxTokensCap),
        'messages': messages,
      };
    default: // gemini
      final model = pathModel;
      final contents = body['contents'];
      if (model == null || !allowed.contains(model)) {
        return _json(req, 400, {'error': 'model_not_allowed'});
      }
      if (contents is! List || contents.isEmpty) {
        return _json(req, 400, {'error': 'contents_required'});
      }
      final gen = body['generationConfig'];
      final genMap = gen is Map ? gen : const {};
      final mime = genMap['responseMimeType'];
      final temp = genMap['temperature'];
      url = Uri.parse('${cfg.geminiUpstream}/v1beta/models/$model:generateContent');
      headers = {'x-goog-api-key': apiKey};
      upstreamBody = {
        'contents': contents,
        'generationConfig': {
          'maxOutputTokens': _cap(genMap['maxOutputTokens'], cfg.geminiMaxOutputCap),
          if (mime == 'application/json' || mime == 'text/plain') 'responseMimeType': mime,
          if (temp is num && temp >= 0 && temp <= 2) 'temperature': temp,
        },
      };
  }

  http.Response upstream;
  try {
    upstream = await client
        .post(
          url,
          headers: {'content-type': 'application/json', ...headers},
          body: jsonEncode(upstreamBody),
        )
        .timeout(const Duration(seconds: 90));
  } catch (_) {
    return _json(req, 502, {'error': 'upstream_unreachable'});
  }

  final res = req.response..statusCode = upstream.statusCode;
  res.headers.contentType = ContentType.json;
  res.add(upstream.bodyBytes);
  await res.close();
}
