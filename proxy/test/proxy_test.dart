import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:screen_translate_proxy/proxy.dart';
import 'package:test/test.dart';

const token = 'test-token-0123456789-abcdefghij';

void main() {
  late HttpServer fakeUpstream;
  late HttpServer proxy;
  late String base;
  final seenBodies = <Map<String, dynamic>>[];
  final seenHeaders = <HttpHeaders>[];
  final seenPaths = <String>[];

  Future<void> startAll({Set<String>? onlyProviders}) async {
    seenBodies.clear();
    seenHeaders.clear();
    seenPaths.clear();
    fakeUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeUpstream.listen((req) async {
      seenPaths.add(req.uri.path);
      seenBodies.add(jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>);
      seenHeaders.add(req.headers);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true}));
      await req.response.close();
    });
    final up = 'http://127.0.0.1:${fakeUpstream.port}';
    bool on(String p) => onlyProviders == null || onlyProviders.contains(p);
    proxy = await startProxy(
      ProxyConfig(
        anthropicApiKey: on('claude') ? 'sk-real-claude' : null,
        geminiApiKey: on('gemini') ? 'real-gemini-key' : null,
        openaiApiKey: on('openai') ? 'sk-real-openai' : null,
        tokens: {token},
        anthropicUpstream: up,
        geminiUpstream: up,
        openaiUpstream: up,
        rateLimitPerMinute: 4,
        allowedOrigins: {'chrome-extension://abc'},
        maxBodyBytes: 2000,
      ),
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    base = 'http://127.0.0.1:${proxy.port}';
  }

  setUp(() => startAll());
  tearDown(() async {
    await proxy.close(force: true);
    await fakeUpstream.close(force: true);
  });

  Future<http.Response> post(String path, Object body,
          {String? auth = 'Bearer $token', Map<String, String>? extra}) =>
      http.post(Uri.parse('$base$path'),
          headers: {
            'content-type': 'application/json',
            if (auth != null) 'authorization': auth,
            ...?extra,
          },
          body: body is String ? body : jsonEncode(body));

  const claudePath = '/v1/messages';
  const openaiPath = '/openai/v1/chat/completions';
  String geminiPath([String m = 'gemini-2.5-flash']) => '/gemini/v1beta/models/$m:generateContent';

  final claude = {
    'model': 'claude-sonnet-5',
    'max_tokens': 100,
    'messages': [{'role': 'user', 'content': 'hi'}],
  };
  final openai = {
    'model': 'gpt-4o-mini',
    'max_completion_tokens': 100,
    'messages': [{'role': 'user', 'content': 'hi'}],
  };
  final gemini = {
    'contents': [
      {'role': 'user', 'parts': [{'text': 'hi'}]}
    ],
    'generationConfig': {'maxOutputTokens': 100, 'responseMimeType': 'application/json'},
  };

  test('rejects missing or wrong token on every route', () async {
    for (final (path, body) in [(claudePath, claude), (openaiPath, openai), (geminiPath(), gemini)]) {
      expect((await post(path, body, auth: null)).statusCode, 401);
      expect((await post(path, body, auth: 'Bearer nope')).statusCode, 401);
    }
    expect(seenBodies, isEmpty);
  });

  test('claude: forwards with real key the client never sent', () async {
    final r = await post(claudePath, claude);
    expect(r.statusCode, 200);
    expect(seenPaths.single, '/v1/messages');
    expect(seenHeaders.single.value('x-api-key'), 'sk-real-claude');
    expect(r.body.contains('sk-real-claude'), isFalse);
  });

  test('openai: forwards to chat/completions with Bearer real key', () async {
    final r = await post(openaiPath, openai);
    expect(r.statusCode, 200);
    expect(seenPaths.single, '/v1/chat/completions');
    expect(seenHeaders.single.value('authorization'), 'Bearer sk-real-openai');
    // The client's proxy token must not leak upstream.
    expect(seenHeaders.single.value('authorization')!.contains(token), isFalse);
  });

  test('gemini: model from path, x-goog-api-key real key, generationConfig kept', () async {
    final r = await post(geminiPath(), gemini);
    expect(r.statusCode, 200);
    expect(seenPaths.single, '/v1beta/models/gemini-2.5-flash:generateContent');
    expect(seenHeaders.single.value('x-goog-api-key'), 'real-gemini-key');
    final gen = seenBodies.single['generationConfig'] as Map;
    expect(gen['responseMimeType'], 'application/json');
    expect(gen['maxOutputTokens'], 100);
  });

  test('rejects disallowed models per provider', () async {
    expect((await post(claudePath, {...claude, 'model': 'claude-opus-9'})).statusCode, 400);
    expect((await post(openaiPath, {...openai, 'model': 'gpt-99'})).statusCode, 400);
    expect((await post(geminiPath('gemini-9-ultra'), gemini)).statusCode, 400);
    expect(seenBodies, isEmpty);
  });

  test('caps token limits', () async {
    await post(claudePath, {...claude, 'max_tokens': 999999});
    await post(openaiPath, {...openai, 'max_completion_tokens': 999999});
    await post(geminiPath(), {
      ...gemini,
      'generationConfig': {'maxOutputTokens': 999999},
    });
    expect(seenBodies[0]['max_tokens'], 4096);
    expect(seenBodies[1]['max_completion_tokens'], 4096);
    expect((seenBodies[2]['generationConfig'] as Map)['maxOutputTokens'], 8192);
  });

  test('drops unexpected fields (system, tools, safety, stream...)', () async {
    await post(claudePath, {...claude, 'system': 'x', 'tools': [{}], 'stream': true});
    await post(openaiPath, {...openai, 'tools': [{}], 'stream': true, 'response_format': {}});
    await post(geminiPath(), {
      ...gemini,
      'systemInstruction': {},
      'tools': [{}],
      'safetySettings': [{}],
    });
    expect(seenBodies[0].keys.toSet(), {'model', 'max_tokens', 'messages'});
    expect(seenBodies[1].keys.toSet(), {'model', 'max_completion_tokens', 'messages'});
    expect(seenBodies[2].keys.toSet(), {'contents', 'generationConfig'});
  });

  test('rate limits per token across providers', () async {
    for (var i = 0; i < 4; i++) {
      expect((await post(claudePath, claude)).statusCode, 200);
    }
    final r = await post(openaiPath, openai);
    expect(r.statusCode, 429);
    expect(r.headers['retry-after'], isNotNull);
  });

  test('rejects oversize body', () async {
    final big = {...claude, 'messages': [{'role': 'user', 'content': 'x' * 5000}]};
    expect((await post(claudePath, big)).statusCode, 413);
  });

  test('CORS only for allowed origins', () async {
    final good = await post(claudePath, claude, extra: {'origin': 'chrome-extension://abc'});
    expect(good.headers['access-control-allow-origin'], 'chrome-extension://abc');
    final bad = await post(claudePath, claude, extra: {'origin': 'https://evil.example'});
    expect(bad.headers['access-control-allow-origin'], isNull);
  });

  test('unknown paths 404 and healthz lists providers', () async {
    expect((await http.get(Uri.parse('$base/v1/other'))).statusCode, 404);
    final h = await http.get(Uri.parse('$base/healthz'));
    expect(h.statusCode, 200);
    expect(jsonDecode(h.body)['providers'], ['claude', 'gemini', 'openai']);
  });

  test('provider without a key is not configured', () async {
    await proxy.close(force: true);
    await fakeUpstream.close(force: true);
    await startAll(onlyProviders: {'claude'});
    expect((await post(geminiPath(), gemini)).statusCode, 404);
    expect((await post(openaiPath, openai)).statusCode, 404);
    expect((await post(claudePath, claude)).statusCode, 200);
  });
}
