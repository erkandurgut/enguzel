FROM caddy:2-alpine

# Caddyfile ve upstream yapılandırma dosyasını imaj içerisine kopyala
COPY Caddyfile /etc/caddy/Caddyfile
COPY upstream.caddy /etc/caddy/upstream.caddy

# HTTP ve HTTPS portları
EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
