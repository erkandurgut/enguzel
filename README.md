# Dart JWT Kimlik Doğrulama & PostgreSQL Servisi

Bu proje, Docker üzerinde çalışan; JWT (JSON Web Token) tabanlı kimlik doğrulama, kullanıcı kayıt/giriş arayüzü, karşılama ekranı ve PostgreSQL veritabanı entegrasyonu sunan modern bir Dart backend uygulamasıdır.

## Mimari
* **Dart Backend (`app:8080`)**: `shelf`, `shelf_router`, `dart_jsonwebtoken` ve `postgres` ile geliştirilmiş REST API ve yerleşik modern SPA web arayüzü.
* **PostgreSQL (`postgres:5432`)**: Kullanıcıları (`users`) ve iptal edilebilir refresh token kayıtlarını (`refresh_tokens`) saklayan ilişkisel veritabanı (Yalnızca iç ağda).
* **Caddy Ters Vekil (`caddy:80/443`)**: Uygulamadan tamamen bağımsız, `caddy/` klasöründe 7/24 kesintisiz çalışan otomatik SSL sunucusu.

---

## Kurulum ve Dağıtım Adımları

### 1. Ortak Docker Ağı (İlk Seferde Bir Kez Yapılır):
```bash
docker network create caddy_net
```

### 2. Caddy Konteynerini Başlatma (Bağımsız Katman):
```bash
cd caddy
docker compose up -d --build
cd ..
```
*(Caddy bir kez ayağa kalktıktan sonra uygulama güncellemelerinden asla etkilenmez).*

### 3. Uygulama ve Veritabanını Başlatma / Güncelleme:
```bash
docker compose up -d --build
```

---

## API Uç Noktaları

| Yöntem | Uç Nokta | Açıklama |
| :--- | :--- | :--- |
| `GET` | `/` | Kullanıcı Kayıt / Giriş ve Karşılama Ekranı (Web SPA) |
| `POST` | `/api/auth/register` | Yeni kullanıcı kaydı (`first_name`, `last_name`, `email`, `password`) |
| `POST` | `/api/auth/login` | Kullanıcı girişi -> Access Token (15 dk) ve Refresh Token (7 gün) |
| `POST` | `/api/auth/refresh` | Süresi dolan Access Token'ı Refresh Token ile yenileme |
| `POST` | `/api/auth/logout` | Oturumu kapatma (Refresh Token iptal edilir) |
| `GET` | `/api/user/me` | Giriş yapmış kullanıcının profil bilgileri (`Bearer <access_token>`) |
