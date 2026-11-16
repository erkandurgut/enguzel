# 1. Aşama: Derleme (Build Stage)
FROM dart:stable AS build

WORKDIR /app

# Paket bağımlılıklarını kopyala ve indir
COPY pubspec.* ./
RUN dart pub get

# Kaynak kodları kopyala ve AOT (Ahead-of-Time) binary olarak derle
COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/server.dart -o bin/server

# 2. Aşama: Çalışma Zamanı (Runtime Stage)
# debian:bookworm-slim: Tam glibc, eksiksiz DNS/NSS desteği (Docker konteyner isimlerini çözmek için) ve CA sertifikaları.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/server /app/bin/

EXPOSE 8080

CMD ["/app/bin/server"]
