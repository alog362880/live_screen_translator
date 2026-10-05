// Template for lib/secrets.dart, which is git-ignored.
//   cp lib/secrets.example.dart lib/secrets.dart   (then fill in the values)
//
// These are only DEFAULTS: --dart-define=PROXY_URL=... / PROXY_TOKEN=... still
// override them (handy for CI or release builds).
class Secrets {
  /// Base URL of your proxy (see /proxy), e.g. https://proxy.example.com
  static const proxyUrl = 'http://localhost:8080';

  /// One of the tokens in the proxy's PROXY_TOKENS. NOT the Anthropic key.
  static const proxyToken = 'paste-a-proxy-token-here';
}
