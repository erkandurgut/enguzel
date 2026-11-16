#!/usr/bin/env bash
set -e

# Renkler
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Sıfır Kesinti (Zero-Downtime) Dağıtım Başlıyor ===${NC}"

# Proje dizinine geçiş
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ortak Docker ağını kontrol et (yoksa oluştur)
if ! docker network inspect caddy_net >/dev/null 2>&1; then
    echo -e "${YELLOW}caddy_net ağı bulunamadı, oluşturuluyor...${NC}"
    docker network create caddy_net
fi

# Caddy upstream dosyasının varlığını kontrol et
CADDY_UPSTREAM_FILE="$SCRIPT_DIR/caddy/upstream.caddy"
if [ ! -f "$CADDY_UPSTREAM_FILE" ]; then
    echo "reverse_proxy app_blue:8080" > "$CADDY_UPSTREAM_FILE"
fi

# PostgreSQL servisinin ayakta olduğundan emin ol
echo -e "${YELLOW}PostgreSQL servisi kontrol ediliyor...${NC}"
docker compose up -d postgres

# Aktif konteyneri tespit et (app_blue veya app_green)
if docker ps --format '{{.Names}}' | grep -q "^app_blue$"; then
    CURRENT_APP="app_blue"
    TARGET_APP="app_green"
    CURRENT_LABEL="${BLUE}BLUE (app_blue)${NC}"
    TARGET_LABEL="${GREEN}GREEN (app_green)${NC}"
else
    CURRENT_APP="app_green"
    TARGET_APP="app_blue"
    CURRENT_LABEL="${GREEN}GREEN (app_green)${NC}"
    TARGET_LABEL="${BLUE}BLUE (app_blue)${NC}"
fi

echo -e "Şu an aktif çalışan servis: ${CURRENT_LABEL}"
echo -e "Yeni dağıtım yapılacak servis: ${TARGET_LABEL}"

# Yeni imajı çek (Varsa GHCR'den çeker, yoksa yerel derler)
echo -e "${YELLOW}En güncel imaj kontrol ediliyor ($TARGET_APP)...${NC}"
if ! docker compose pull "$TARGET_APP"; then
    echo -e "${YELLOW}GHCR üzerinde hazır imaj bulunamadı veya henüz yüklenmedi, yerel olarak derleniyor...${NC}"
    docker compose build "$TARGET_APP"
fi

# Hedef konteyneri başlat
echo -e "${YELLOW}$TARGET_APP başlatılıyor...${NC}"
docker compose up -d "$TARGET_APP"

# Sağlık kontrolünü bekle (Healthcheck)
echo -e "${YELLOW}$TARGET_APP servisinin hazır ve sağlıklı olması bekleniyor...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    STATUS=$(docker inspect --format='{{json .State.Health.Status}}' "$TARGET_APP" 2>/dev/null || echo "starting")
    if [ "$STATUS" = "\"healthy\"" ]; then
        HEALTHY=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Sağlık durumu: $STATUS (Kontrol $RETRY_COUNT/$MAX_RETRIES). Bekleniyor..."
    sleep 2
done

if [ "$HEALTHY" = false ]; then
    echo -e "${RED}HATA: $TARGET_APP sağlık kontrolünden geçemedi!${NC}"
    echo -e "${RED}Dağıtım iptal ediliyor. Eski versiyon ($CURRENT_APP) çalışmaya devam ediyor.${NC}"
    docker compose stop "$TARGET_APP"
    docker compose logs --tail=50 "$TARGET_APP"
    exit 1
fi

echo -e "${GREEN}Tebrikler! $TARGET_APP sağlık kontrolünden başarıyla geçti.${NC}"

# Caddy upstream yönlendirmesini güncelle
echo -e "${YELLOW}Caddy yönlendirmesi $TARGET_APP olarak güncelleniyor...${NC}"
echo "reverse_proxy $TARGET_APP:8080" > "$CADDY_UPSTREAM_FILE"

# Caddy'ye sıfır kesintiyle reload emri ver
if docker ps --format '{{.Names}}' | grep -q "^caddy$"; then
    echo -e "${YELLOW}Caddy yapılandırması kesintisiz yeniden yükleniyor (caddy reload)...${NC}"
    docker exec caddy caddy reload -c /etc/caddy/Caddyfile
else
    echo -e "${YELLOW}Caddy konteyneri çalışmıyor, başlatılıyor...${NC}"
    cd caddy && docker compose up -d && cd ..
fi

# Caddy reload sonrası mevcut bağlantıların tamamlanması için bekleme (Graceful drain)
echo -e "${YELLOW}Eski servisteki açık bağlantıların tamamlanması bekleniyor (5 saniye)...${NC}"
sleep 5

# Eski konteyneri durdur
if docker ps --format '{{.Names}}' | grep -q "^$CURRENT_APP$"; then
    echo -e "${YELLOW}Eski servis ($CURRENT_APP) güvenle durduruluyor...${NC}"
    docker compose stop "$CURRENT_APP"
fi

# Kullanılmayan eski Docker imajlarını temizle (opsiyonel)
docker image prune -f >/dev/null 2>&1 || true

echo -e "${GREEN}=== Sıfır Kesintiyle Dağıtım Başarıyla Tamamlandı! ===${NC}"
echo -e "Şu an aktif servis: ${TARGET_LABEL}"
