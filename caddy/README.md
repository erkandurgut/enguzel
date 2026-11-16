# Caddy Bağımsız Ters Vekil (Reverse Proxy)

Bu klasör, uygulama konteynerlerinden tamamen bağımsız olarak 7/24 kesintisiz çalışması gereken Caddy sunucusunun yapılandırmasını içerir.

Caddy'yi ana uygulamadan ayırmanın avantajı:
- Uygulama (`app`) güncellendiğinde, yeniden derlendiğinde veya yeniden başlatıldığında Caddy ve SSL bağlantıları asla kesintiye uğramaz.
- Portainer (`portainer.enguzelisimler.online`) gibi diğer servisler 7/24 erişilebilir kalır.

---

## 1. Hazırlık: Ortak Docker Ağını Oluşturma (Tek Seferlik)

Caddy ile uygulamaların konuşabilmesi için bağımsız bir Docker ağı oluşturulur:

```bash
docker network create caddy_net
```

---

## 2. Seçenek A: Doğrudan Dockerfile ile Derleyip Çalıştırma (Saf Docker)

### İmajı Derleyin:
```bash
cd caddy
docker build -t caddy-proxy .
```

### Konteyneri Başlatın:
```bash
docker run -d \
  --name caddy \
  --restart unless-stopped \
  -p 80:80 \
  -p 443:443 \
  -p 443:443/udp \
  --network caddy_net \
  --add-host host.docker.internal:host-gateway \
  -v caddy_data:/data \
  -v caddy_config:/config \
  caddy-proxy
```

---

## 3. Seçenek B: Ayrı Docker Compose ile Çalıştırma (Önerilen)

`caddy` klasörü içerisinde bağımsız olarak çalıştırmak için:

```bash
cd caddy
docker compose up -d --build
```

---

## 4. Caddy Ayarlarını Yenileme (Downtime Olmadan)

Eğer `Caddyfile` dosyasında yeni bir alan adı veya yönlendirme kuralı eklerseniz, Caddy konteynerini kapatıp açmadan ayarları canlı yükleyebilirsiniz:

```bash
docker exec -w /etc/caddy caddy caddy reload
```
