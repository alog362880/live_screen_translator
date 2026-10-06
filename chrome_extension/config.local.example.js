// Template for chrome_extension/config.local.js, which is git-ignored.
//   cp config.local.example.js config.local.js   (then fill in the values)
// Used as defaults so you don't have to type them into the popup. Values saved
// in the popup take precedence.
self.LOCAL_CONFIG = {
  proxyUrl: 'http://localhost:8080',
  proxyToken: 'paste-a-proxy-token-here',
  // Optional: which provider to default to: 'claude' | 'gemini' | 'openai'.
  provider: 'claude',
  // Optional: prefill "bring your own key" mode (still off by default — the
  // popup's checkbox must be turned on to use it). One key per provider.
  keys: { claude: '', gemini: '', openai: '' },
};
