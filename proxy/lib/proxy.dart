import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Everything the proxy needs, read from environment in bin/server.dart.
class ProxyConfig {
  ProxyConfig({
    required this.anthropicApiKey,
    required this.tokens,
    this.upstream = 'https://api.anthropic.com',
    this.allowedModels = const {'claude-sonnet-5', 'claude-haiku-4-5-20251001'},
    this.rateLimitPerMinute = 20,
    this.allowedOrigins = const {},
    this.maxBodyBytes = 12 * 1024 * 1024, // screenshots arrive as base64
    this.maxTokensCap = 4096,
  });

  /// The real key. Lives only in this process's environment.
  final String anthropicApiKey;

  /// Bearer tokens clients may present. One per user/device lets you
  /// revoke and rate-limit individually.
  final Set<String> tokens;
  final String upstream;
  final Set<String> allowedModels;
  final int rateLimitPerMinute;

  /// Exact Origin values allowed for browser callers (Flutter Web, the
  /// extension's chrome-extension://<id>). Native apps send no Origin.
  final Set<String> allowedOrigins;
  final int maxBodyBytes;
  final int maxTokensCap;
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

Future<void> _handle(HttpRequest req, ProxyConfig cfg, _RateLimiter limiter, http.Client client) async {
  _cors(req, cfg);

  if (req.method == 'OPTIONS') {
    req.response.statusCode = 204;
    await req.response.close();
    return;
  }
  if (req.uri.path == '/healthz') return _json(req, 200, {'ok': true});
  if (req.uri.path != '/v1/messages') return _json(req, 404, {'error': 'not_found'});
  if (req.method != 'POST') return _json(req, 405, {'error': 'method_not_allowed'});

  // --- auth ---
  final auth = req.headers.value('authorization') ?? '';
  final token = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
  var valid = false;
  for (final t in cfg.tokens) {
    // No early exit: don't leak which token matched via timing.
    valid = _constantTimeEquals(t, token) || valid;
  }
  if (!valid) return _json(req, 401, {'error': 'unauthorized'});

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

  // --- validate + rebuild the request ---
  Map<String, dynamic> body;
  try {
    body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    return _json(req, 400, {'error': 'invalid_json'});
  }
  final model = body['model'];
  final messages = body['messages'];
  if (model is! String || !cfg.allowedModels.contains(model)) {
    return _json(req, 400, {'error': 'model_not_allowed'});
  }
  if (messages is! List || messages.isEmpty) {
    return _json(req, 400, {'error': 'messages_required'});
  }
  final requested = body['max_tokens'];
  final maxTokens = requested is int && requested > 0
      ? (requested < cfg.maxTokensCap ? requested : cfg.maxTokensCap)
      : cfg.maxTokensCap;

  // Allowlist rebuild: tools, system, streaming etc. are deliberately dropped
  // so a leaked client token can only do "translate this" style calls.
  final upstreamBody = jsonEncode({'model': model, 'max_tokens': maxTokens, 'messages': messages});

  http.Response upstream;
  try {
    upstream = await client.post(
      Uri.parse('${cfg.upstream}/v1/messages'),
      headers: {
        'content-type': 'application/json',
        'x-api-key': cfg.anthropicApiKey,
        'anthropic-version': '2023-06-01',
      },
      body: upstreamBody,
    ).timeout(const Duration(seconds: 90));
  } catch (_) {
    return _json(req, 502, {'error': 'upstream_unreachable'});
  }

  final res = req.response..statusCode = upstream.statusCode;
  res.headers.contentType = ContentType.json;
  res.add(upstream.bodyBytes);
  await res.close();
}
