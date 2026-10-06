import 'package:flutter_test/flutter_test.dart';
import 'package:screen_translate_app/services/ai_client.dart';
import 'package:screen_translate_app/services/ai_config.dart';
import 'package:screen_translate_app/services/ai_vision_ocr_client.dart';

AiConfig direct(AiProvider p) => AiConfig.direct(provider: p, apiKey: 'KEY', model: p.defaultModel);
AiConfig proxy(AiProvider p) =>
    AiConfig.proxy(provider: p, proxyUrl: 'https://px.example.com/', proxyToken: 'TOK', model: p.defaultModel);

void main() {
  group('request building', () {
    test('direct endpoints and auth headers per provider', () {
      expect(direct(AiProvider.claude).uri.toString(), 'https://api.anthropic.com/v1/messages');
      expect(direct(AiProvider.claude).headers['x-api-key'], 'KEY');
      expect(direct(AiProvider.gemini).uri.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent');
      expect(direct(AiProvider.gemini).headers['x-goog-api-key'], 'KEY');
      expect(direct(AiProvider.openai).uri.toString(), 'https://api.openai.com/v1/chat/completions');
      expect(direct(AiProvider.openai).headers['authorization'], 'Bearer KEY');
    });

    test('proxy routes carry the proxy token only', () {
      expect(proxy(AiProvider.claude).uri.toString(), 'https://px.example.com/v1/messages');
      expect(proxy(AiProvider.openai).uri.toString(),
          'https://px.example.com/openai/v1/chat/completions');
      expect(proxy(AiProvider.gemini).uri.toString(),
          'https://px.example.com/gemini/v1beta/models/gemini-2.5-flash:generateContent');
      for (final p in AiProvider.values) {
        expect(proxy(p).headers['authorization'], 'Bearer TOK');
        expect(proxy(p).headers.containsKey('x-api-key'), isFalse);
      }
    });

    test('image bodies use each provider\'s native shape', () {
      final c = direct(AiProvider.claude).body(prompt: 'p', imageBase64: 'B64');
      expect(((c['messages'] as List).first['content'] as List).first['type'], 'image');

      final g = direct(AiProvider.gemini).body(prompt: 'p', imageBase64: 'B64');
      final parts = ((g['contents'] as List).first['parts'] as List);
      expect(parts.first['inlineData']['data'], 'B64');
      expect(g['generationConfig']['responseMimeType'], 'application/json');
      expect(g.containsKey('model'), isFalse);

      final o = direct(AiProvider.openai).body(prompt: 'p', imageBase64: 'B64');
      final content = ((o['messages'] as List).first['content'] as List);
      expect(content.first['image_url']['url'], 'data:image/png;base64,B64');
      expect(o['max_completion_tokens'], 4096);
    });

    test('text-only bodies send a plain prompt', () {
      final c = direct(AiProvider.claude).body(prompt: 'hello');
      expect((c['messages'] as List).first['content'], 'hello');
      final o = direct(AiProvider.openai).body(prompt: 'hello');
      expect((o['messages'] as List).first['content'], 'hello');
    });
  });

  group('response parsing', () {
    test('claude', () {
      final t = direct(AiProvider.claude).extractText({
        'content': [{'type': 'text', 'text': '[1]'}]
      });
      expect(t, '[1]');
    });

    test('gemini joins parts and skips thoughts', () {
      final t = direct(AiProvider.gemini).extractText({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'thinking...', 'thought': true},
                {'text': '[2]'},
              ]
            }
          }
        ]
      });
      expect(t, '[2]');
    });

    test('gemini blocked prompt gives a clear error', () {
      expect(
        () => direct(AiProvider.gemini).extractText({
          'promptFeedback': {'blockReason': 'SAFETY'}
        }),
        throwsA(isA<AiRequestException>()),
      );
    });

    test('openai', () {
      final t = direct(AiProvider.openai).extractText({
        'choices': [
          {'message': {'content': '[3]'}}
        ]
      });
      expect(t, '[3]');
    });
  });

  group('model output parsing', () {
    test('parseJsonArray tolerates fences and prose', () {
      expect(parseJsonArray('```json\n[{"a":1}]\n```'), [{'a': 1}]);
      expect(parseJsonArray('Here you go: [{"a":1}] hope it helps'), [{'a': 1}]);
    });

    test('box_2d normalized coords convert to pixels', () {
      final blocks = AiVisionOcrClient.parseBlocks(
        '[{"text":"Hi","translated":"Xin chao","box_2d":[100,200,300,600]},'
        '{"text":"bad","translated":"x"}]',
        pixelWidth: 2000,
        pixelHeight: 1000,
      );
      expect(blocks, hasLength(1)); // item without a box is skipped
      final b = blocks.single;
      expect(b.left, 400); // xmin 200/1000 * 2000
      expect(b.top, 100); // ymin 100/1000 * 1000
      expect(b.width, 800); // (600-200)/1000 * 2000
      expect(b.height, 200); // (300-100)/1000 * 1000
      expect(b.translatedText, 'Xin chao');
    });
  });
}
