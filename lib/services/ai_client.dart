import 'dart:convert';
import 'package:http/http.dart' as http;

import 'ai_config.dart';

/// One round trip to whichever provider [config] points at; returns the
/// model's text answer. Shared by the OCR and text-translation clients.
Future<String> aiComplete(
  AiConfig config, {
  required String prompt,
  String? imageBase64,
  int maxTokens = 4096,
}) async {
  if (!config.isConfigured) {
    throw AiRequestException(
      'AI provider not configured. Set a proxy (lib/secrets.dart) or add your '
      'own ${config.provider.label} API key in Settings.',
    );
  }
  final response = await http.post(
    config.uri,
    headers: config.headers,
    body: jsonEncode(config.body(prompt: prompt, imageBase64: imageBase64, maxTokens: maxTokens)),
  );
  if (response.statusCode != 200) {
    final via = config.isDirect ? config.provider.label : 'proxy';
    throw AiRequestException('$via request failed (${response.statusCode}): ${response.body}');
  }
  return config.extractText(jsonDecode(response.body) as Map<String, dynamic>);
}

/// Parses a JSON array out of model output, tolerating ```json fences and
/// stray prose around the array.
List<Map<String, dynamic>> parseJsonArray(String raw) {
  var text = raw.trim().replaceAll(RegExp(r'^```(?:json)?|```$'), '').trim();
  final start = text.indexOf('[');
  final end = text.lastIndexOf(']');
  if (start >= 0 && end > start) text = text.substring(start, end + 1);
  return (jsonDecode(text) as List).cast<Map<String, dynamic>>();
}
