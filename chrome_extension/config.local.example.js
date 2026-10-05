// Template for chrome_extension/config.local.js, which is git-ignored.
//   cp config.local.example.js config.local.js   (then fill in the values)
// Used as defaults so you don't have to type them into the popup. Values saved
// in the popup take precedence.
self.LOCAL_CONFIG = {
  proxyUrl: 'http://localhost:8080',
  proxyToken: 'paste-a-proxy-token-here',
  // Optional: prefill "bring your own key" mode too (still off by default —
  // the popup's checkbox still needs to be turned on to actually use it).
  personalApiKey: '',
};
