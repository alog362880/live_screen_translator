# Screen Translate proxy

Small Dart server between the clients (Flutter app, Chrome extension) and the Anthropic
Messages API. The real `ANTHROPIC_API_KEY` exists only in this process's environment;
clients hold a revocable bearer token instead.

What it enforces on `POST /v1/messages`:

- `Authorization: Bearer <token>` must match one of `PROXY_TOKENS` (constant-time compare).
- Per-token rate limit (`RATE_LIMIT_PER_MIN`, default 20).
- `model` must be in `ALLOWED_MODELS`; `max_tokens` is capped at 4096.
- The upstream body is rebuilt from `model`, `max_tokens` and `messages` only, so `system`,
  `tools`, `stream` and the like are dropped and a leaked token can't be used as a general-purpose key.
- Body size limit (12 MB, since screenshots arrive as base64).
- CORS only for exact origins in `ALLOWED_ORIGINS`.

## Run

```bash
cp .env.example .env      # git-ignored; put your real ANTHROPIC_API_KEY and tokens in it
dart run bin/server.dart  # listens on :8080 (PORT to change)
```

`.env` is read from the current directory. Real environment variables override it, so production/Docker
config is unaffected. Generate tokens with `openssl rand -hex 24` (comma-separate to issue several).
Set `ALLOWED_ORIGINS` only if you serve the Flutter Web build.

Docker: `docker build -t translate-proxy . && docker run -p 8080:8080 -e ANTHROPIC_API_KEY -e PROXY_TOKENS translate-proxy`

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
