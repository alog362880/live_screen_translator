// Shared by background.js (importScripts) and popup.html (<script>).
// Mirrors lib/services/ai_config.dart: one entry per AI provider with its
// endpoint, auth header, request body and response parsing.
self.PROVIDERS = {
  claude: {
    label: 'Claude (Anthropic)',
    defaultModel: 'claude-sonnet-5',
    keyHint: 'sk-ant-...',
    origin: 'https://api.anthropic.com/*',
    directUrl: () => 'https://api.anthropic.com/v1/messages',
    proxyPath: () => '/v1/messages',
    directHeaders: (key) => ({
      'content-type': 'application/json',
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    }),
    body: (model, prompt, b64) => ({
      model,
      max_tokens: 4096,
      messages: [{
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/png', data: b64 } },
          { type: 'text', text: prompt },
        ],
      }],
    }),
    extract: (json) => {
      const text = (json.content || []).filter((p) => p.type === 'text').map((p) => p.text).join('');
      if (!text) throw new Error('Empty response from Claude.');
      return text;
    },
  },

  gemini: {
    label: 'Gemini (Google)',
    defaultModel: 'gemini-2.5-flash',
    keyHint: 'AIza...',
    origin: 'https://generativelanguage.googleapis.com/*',
    directUrl: (model) =>
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    proxyPath: (model) => `/gemini/v1beta/models/${model}:generateContent`,
    directHeaders: (key) => ({ 'content-type': 'application/json', 'x-goog-api-key': key }),
    // Model is in the URL. 2.5 "thinking" tokens count against maxOutputTokens.
    body: (_model, prompt, b64) => ({
      contents: [{
        role: 'user',
        parts: [{ inlineData: { mimeType: 'image/png', data: b64 } }, { text: prompt }],
      }],
      generationConfig: { maxOutputTokens: 8192, temperature: 0, responseMimeType: 'application/json' },
    }),
    extract: (json) => {
      const cand = (json.candidates || [])[0];
      if (!cand) {
        const why = json.promptFeedback?.blockReason;
        throw new Error(`Gemini returned no answer${why ? ` (blocked: ${why})` : ''}.`);
      }
      const text = (cand.content?.parts || [])
        .filter((p) => !p.thought && typeof p.text === 'string')
        .map((p) => p.text).join('');
      if (!text) throw new Error('Empty response from Gemini.');
      return text;
    },
  },

  openai: {
    label: 'ChatGPT (OpenAI)',
    defaultModel: 'gpt-4o-mini',
    keyHint: 'sk-...',
    origin: 'https://api.openai.com/*',
    directUrl: () => 'https://api.openai.com/v1/chat/completions',
    proxyPath: () => '/openai/v1/chat/completions',
    directHeaders: (key) => ({ 'content-type': 'application/json', authorization: `Bearer ${key}` }),
    body: (model, prompt, b64) => ({
      model,
      max_completion_tokens: 4096,
      messages: [{
        role: 'user',
        content: [
          { type: 'image_url', image_url: { url: `data:image/png;base64,${b64}`, detail: 'high' } },
          { type: 'text', text: prompt },
        ],
      }],
    }),
    extract: (json) => {
      const text = json.choices?.[0]?.message?.content;
      if (typeof text !== 'string' || !text) throw new Error('Empty response from ChatGPT.');
      return text;
    },
  },
};
