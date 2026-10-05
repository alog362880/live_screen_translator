FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o /app/server

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
ENV PORT=8080
EXPOSE 8080
# Terminate TLS in front (Caddy, Cloudflare, Fly, Cloud Run, ...); the proxy speaks plain HTTP.
CMD ["/server"]
