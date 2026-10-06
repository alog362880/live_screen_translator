# Screen Translate proxy

Small Dart server between the clients (Flutter app, Chrome extension) and the Claude, Gemini and
OpenAI APIs. The real provider keys (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`) exist
only in this process's environment; clients hold a revocable bearer token instead. A provider is
enabled only if its key is set (`GET /healthz` lists the enabled ones).

Routes (each takes the provider's native request format):

| Route | Provider |
|---|---|
| `POST /v1/messages` | Claude |
| `POST /gemini/v1beta/models/<model>:generateContent` | Gemini |
| `POST /openai/v1/chat/completions` | ChatGPT / OpenAI |

What it enforces on every route:

- `Authorization: Bearer <token>` must match one of `PROXY_TOKENS` (constant-time compare).
- Per-token rate limit (`RATE_LIMIT_PER_MIN`, default 20).
- The model must be in the per-provider allowlist (`ALLOWED_MODELS_CLAUDE` / `_GEMINI` / `_OPENAI`); token limits are capped (4096, or 8192 for Gemini since its thinking tokens count).
- The upstream body is rebuilt from an allowlist of fields per provider, so `system`, `tools`,
  `stream`, `safetySettings` and the like are dropped and a leaked token can't be used as a
  general-purpose key.
- Body size limit (12 MB, since screenshots arrive as base64).
- CORS only for exact origins in `ALLOWED_ORIGINS`.

## Run

```bash
cp .env.example .env      # git-ignored; put your real provider key(s) and tokens in it
dart run bin/server.dart  # listens on :8080 (PORT to change)
```

`.env` is read from the current directory. Real environment variables override it, so production/Docker
config is unaffected. Generate tokens with `openssl rand -hex 24` (comma-separate to issue several).
Set `ALLOWED_ORIGINS` only if you serve the Flutter Web build.

Docker: `docker build -t translate-proxy . && docker run -p 8080:8080 -e ANTHROPIC_API_KEY -e GEMINI_API_KEY -e OPENAI_API_KEY -e PROXY_TOKENS translate-proxy`

**Put TLS in front** (Caddy, Cloudflare, Fly, Cloud Run, ...). The server speaks plain HTTP,
and without HTTPS the bearer token travels in the clear.

Tests: `dart test`.

## Limits

- The token is embedded in a distributed app or typed into the extension, so it can still be
  extracted. What you gain over a raw key is that it can be revoked, rate-limited and
  restricted to translate-style calls. For real per-user security, issue one token per user
  and rotate them.
- Rate limiting is in-memory and per-process: it resets on restart and isn't shared across replicas.
- Set a monthly spend limit on the Anthropic key itself as a backstop.
