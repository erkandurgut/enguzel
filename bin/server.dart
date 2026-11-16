import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

// --- VERİTABANI BAĞLANTISI ---
late final Pool dbPool;
late final String jwtSecret;
bool isDbReady = false;

// --- ŞİFRELEME YARDIMCILARI ---
String generateRandomHex(int length) {
  final random = Random.secure();
  final values = List<int>.generate(length, (_) => random.nextInt(256));
  return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String hashPassword(String password, String salt) {
  final bytes = utf8.encode('$salt:$password');
  final digest = sha256.convert(bytes);
  return digest.toString();
}

bool verifyPassword(String password, String storedHash) {
  final parts = storedHash.split('\$');
  if (parts.length != 2) return false;
  final salt = parts[0];
  final hash = parts[1];
  final computed = hashPassword(password, salt);
  return computed == hash;
}

// --- JWT YARDIMCILARI ---
String createAccessToken(int userId, String email, String firstName, String lastName) {
  final jwt = JWT({
    'userId': userId,
    'email': email,
    'firstName': firstName,
    'lastName': lastName,
  });
  return jwt.sign(SecretKey(jwtSecret), expiresIn: const Duration(minutes: 15));
}

JWT? verifyAccessToken(String token) {
  try {
    return JWT.verify(token, SecretKey(jwtSecret));
  } catch (_) {
    return null;
  }
}

// --- YARDIMCI CEVAP FONKSİYONLARI ---
Response jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(data),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );
}

Response errorResponse(String message, {int statusCode = 400}) {
  return jsonResponse({'error': message}, statusCode: statusCode);
}

// --- VERİTABANI TABLOLARINI OLUŞTURMA ---
Future<void> initDatabase() async {
  print('Veritabanı tabloları kontrol ediliyor...');
  // PostgreSQL prepared statement protokolü tek sorguda birden fazla komuta izin vermez.
  // Bu nedenle tablolar ayrı ayrı sorgularla oluşturulmalıdır:
  await dbPool.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      first_name VARCHAR(100) NOT NULL,
      last_name VARCHAR(100) NOT NULL,
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
    )
  ''');

  await dbPool.execute('''
    CREATE TABLE IF NOT EXISTS refresh_tokens (
      id SERIAL PRIMARY KEY,
      user_id INT REFERENCES users(id) ON DELETE CASCADE,
      token TEXT UNIQUE NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      revoked BOOLEAN DEFAULT FALSE,
      created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
    )
  ''');

  isDbReady = true;
  print('Veritabanı tabloları başarıyla oluşturuldu ve hazır.');
}

// --- ANA SUNUCU DÖNGÜSÜ ---
Future<void> main() async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dbHost = Platform.environment['DB_HOST'] ?? 'postgres';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '5432');
  final dbName = Platform.environment['DB_NAME'] ?? 'auth_db';
  final dbUser = Platform.environment['DB_USER'] ?? 'auth_user';
  final dbPassword = Platform.environment['DB_PASSWORD'] ?? 'auth_secure_password_2026';
  jwtSecret = Platform.environment['JWT_SECRET'] ?? 'default_jwt_secret_change_in_production_2026';

  print('Veritabanı havuzu oluşturuluyor: $dbHost:$dbPort/$dbName ...');

  dbPool = Pool.withEndpoints(
    [
      Endpoint(
        host: dbHost,
        port: dbPort,
        database: dbName,
        username: dbUser,
        password: dbPassword,
      ),
    ],
    settings: const PoolSettings(
      sslMode: SslMode.disable,
      connectTimeout: Duration(seconds: 10),
    ),
  );

  // Veritabanı bağlantısını arka planda dene (Sunucunun çökmesini engeller)
  Future<void> connectWithRetry() async {
    for (var i = 1; i <= 30; i++) {
      try {
        await initDatabase();
        return;
      } catch (e) {
        print('Veritabanı bağlantı denemesi $i ($e). 2 saniye sonra tekrar deneniyor...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    print('UYARI: Veritabanına bağlanılamadı. İstek geldiğinde tekrar denenecektir.');
  }

  // Arka planda başlat
  connectWithRetry();

  final router = Router();

  // --- API: KAYIT OL (SIGN-UP) ---
  router.post('/api/auth/register', (Request req) async {
    try {
      if (!isDbReady) {
        await initDatabase();
      }

      final payload = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final firstName = (payload['first_name'] as String?)?.trim() ?? '';
      final lastName = (payload['last_name'] as String?)?.trim() ?? '';
      final email = (payload['email'] as String?)?.trim().toLowerCase() ?? '';
      final password = (payload['password'] as String?) ?? '';

      if (firstName.isEmpty || lastName.isEmpty) {
        return errorResponse('Ad ve soyad alanları boş bırakılamaz.');
      }
      if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
        return errorResponse('Geçerli bir e-posta adresi giriniz.');
      }
      if (password.length < 6) {
        return errorResponse('Şifre en az 6 karakter olmalıdır.');
      }

      // E-posta kontrolü
      final existing = await dbPool.execute(
        r'SELECT id FROM users WHERE LOWER(email) = $1',
        parameters: [email],
      );
      if (existing.isNotEmpty) {
        return errorResponse('Bu e-posta adresi ile zaten kayıtlı bir hesap var.', statusCode: 409);
      }

      // Şifreyi tuzla ve özetle
      final salt = generateRandomHex(16);
      final hash = hashPassword(password, salt);
      final storedPassword = '$salt\$$hash';

      await dbPool.execute(
        r'INSERT INTO users (first_name, last_name, email, password_hash) VALUES ($1, $2, $3, $4)',
        parameters: [firstName, lastName, email, storedPassword],
      );

      return jsonResponse({
        'message': 'Kayıt başarıyla tamamlandı. Şimdi giriş yapabilirsiniz.',
      }, statusCode: 201);
    } catch (e) {
      return errorResponse('Kayıt işlemi sırasında hata oluştu: $e', statusCode: 500);
    }
  });

  // --- API: GİRİŞ YAP (LOGIN) ---
  router.post('/api/auth/login', (Request req) async {
    try {
      if (!isDbReady) {
        await initDatabase();
      }

      final payload = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final email = (payload['email'] as String?)?.trim().toLowerCase() ?? '';
      final password = (payload['password'] as String?) ?? '';

      if (email.isEmpty || password.isEmpty) {
        return errorResponse('E-posta ve şifre gereklidir.');
      }

      final result = await dbPool.execute(
        r'SELECT id, first_name, last_name, email, password_hash FROM users WHERE LOWER(email) = $1',
        parameters: [email],
      );

      if (result.isEmpty) {
        return errorResponse('E-posta adresi veya şifre hatalı.', statusCode: 401);
      }

      final row = result.first;
      final userId = row[0] as int;
      final firstName = row[1] as String;
      final lastName = row[2] as String;
      final userEmail = row[3] as String;
      final passwordHash = row[4] as String;

      if (!verifyPassword(password, passwordHash)) {
        return errorResponse('E-posta adresi veya şifre hatalı.', statusCode: 401);
      }

      // Token üretimi
      final accessToken = createAccessToken(userId, userEmail, firstName, lastName);
      final refreshToken = generateRandomHex(32);
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 7));

      // Refresh token'ı veritabanına kaydet
      await dbPool.execute(
        r'INSERT INTO refresh_tokens (user_id, token, expires_at) VALUES ($1, $2, $3)',
        parameters: [userId, refreshToken, expiresAt],
      );

      return jsonResponse({
        'message': 'Giriş başarılı.',
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'user': {
          'id': userId,
          'first_name': firstName,
          'last_name': lastName,
          'email': userEmail,
        },
      });
    } catch (e) {
      return errorResponse('Giriş sırasında hata oluştu: $e', statusCode: 500);
    }
  });

  // --- API: TOKEN YENİLEME (REFRESH) ---
  router.post('/api/auth/refresh', (Request req) async {
    try {
      final payload = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final refreshToken = (payload['refresh_token'] as String?)?.trim() ?? '';

      if (refreshToken.isEmpty) {
        return errorResponse('Refresh token gereklidir.', statusCode: 401);
      }

      final result = await dbPool.execute(
        r'''
        SELECT r.user_id, r.expires_at, r.revoked, u.first_name, u.last_name, u.email 
        FROM refresh_tokens r
        JOIN users u ON r.user_id = u.id
        WHERE r.token = $1
        ''',
        parameters: [refreshToken],
      );

      if (result.isEmpty) {
        return errorResponse('Geçersiz refresh token.', statusCode: 401);
      }

      final row = result.first;
      final userId = row[0] as int;
      final expiresAt = (row[1] as DateTime).toUtc();
      final revoked = row[2] as bool;
      final firstName = row[3] as String;
      final lastName = row[4] as String;
      final email = row[5] as String;

      if (revoked || DateTime.now().toUtc().isAfter(expiresAt)) {
        return errorResponse('Refresh token süresi dolmuş veya iptal edilmiş.', statusCode: 401);
      }

      // Yeni access token üret
      final newAccessToken = createAccessToken(userId, email, firstName, lastName);

      return jsonResponse({
        'access_token': newAccessToken,
      });
    } catch (e) {
      return errorResponse('Token yenileme hatası: $e', statusCode: 500);
    }
  });

  // --- API: ÇIKIŞ YAP (LOGOUT) ---
  router.post('/api/auth/logout', (Request req) async {
    try {
      final payload = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final refreshToken = (payload['refresh_token'] as String?)?.trim() ?? '';

      if (refreshToken.isNotEmpty) {
        await dbPool.execute(
          r'UPDATE refresh_tokens SET revoked = true WHERE token = $1',
          parameters: [refreshToken],
        );
      }

      return jsonResponse({'message': 'Başarıyla çıkış yapıldı.'});
    } catch (_) {
      return jsonResponse({'message': 'Çıkış yapıldı.'});
    }
  });

  // --- API: KULLANICI BİLGİSİ (ME) ---
  router.get('/api/user/me', (Request req) async {
    final authHeader = req.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return errorResponse('Yetkilendirme başlığı eksik veya geçersiz.', statusCode: 401);
    }

    final token = authHeader.substring(7);
    final verified = verifyAccessToken(token);
    if (verified == null) {
      return errorResponse('Oturum süresi dolmuş veya geçersiz token.', statusCode: 401);
    }

    final payload = verified.payload as Map<String, dynamic>;
    return jsonResponse({
      'user': {
        'id': payload['userId'],
        'first_name': payload['firstName'],
        'last_name': payload['lastName'],
        'email': payload['email'],
      },
    });
  });

  // --- ÖN YÜZ: MODERN WEB ARAYÜZÜ (SPA) ---
  router.get('/', (Request req) {
    return Response.ok(
      _buildIndexHtml(),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  });

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  print('Dart Auth Sunucusu çalışıyor: http://${server.address.host}:${server.port}');
}

// --- HTML / CSS / JAVASCRIPT ARAYÜZ ŞABLONU ---
String _buildIndexHtml() {
  return '''<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Kullanıcı Giriş & Karşılama Paneli</title>
  <style>
    :root {
      --primary: #4f46e5;
      --primary-hover: #4338ca;
      --success: #10b981;
      --error: #ef4444;
      --bg: #0f172a;
      --card-bg: #1e293b;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --border: #334155;
    }
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    body {
      background-color: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 1.5rem;
    }
    .container {
      width: 100%;
      max-width: 440px;
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 1rem;
      padding: 2rem;
      box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.4), 0 8px 10px -6px rgba(0, 0, 0, 0.4);
    }
    .header {
      text-align: center;
      margin-bottom: 1.75rem;
    }
    .header h1 {
      font-size: 1.75rem;
      font-weight: 700;
      margin-bottom: 0.5rem;
      background: linear-gradient(to right, #818cf8, #c084fc);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .header p {
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .tabs {
      display: flex;
      background: #0f172a;
      border-radius: 0.5rem;
      padding: 0.25rem;
      margin-bottom: 1.5rem;
    }
    .tab-btn {
      flex: 1;
      background: none;
      border: none;
      color: var(--text-muted);
      padding: 0.6rem;
      border-radius: 0.375rem;
      cursor: pointer;
      font-weight: 600;
      font-size: 0.9rem;
      transition: all 0.2s;
    }
    .tab-btn.active {
      background: var(--card-bg);
      color: var(--text);
      box-shadow: 0 2px 4px rgba(0,0,0,0.2);
    }
    .form-group {
      margin-bottom: 1.25rem;
    }
    .form-row {
      display: flex;
      gap: 0.75rem;
    }
    .form-row .form-group {
      flex: 1;
    }
    label {
      display: block;
      font-size: 0.85rem;
      font-weight: 500;
      margin-bottom: 0.4rem;
      color: #cbd5e1;
    }
    input {
      width: 100%;
      background: #0f172a;
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      padding: 0.7rem 0.9rem;
      color: var(--text);
      font-size: 0.95rem;
      outline: none;
      transition: border-color 0.2s;
    }
    input:focus {
      border-color: var(--primary);
      box-shadow: 0 0 0 2px rgba(79, 70, 229, 0.2);
    }
    .btn {
      width: 100%;
      background: var(--primary);
      color: white;
      border: none;
      border-radius: 0.5rem;
      padding: 0.75rem;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
      transition: background-color 0.2s;
      margin-top: 0.5rem;
    }
    .btn:hover {
      background: var(--primary-hover);
    }
    .btn-secondary {
      background: #334155;
      margin-top: 1rem;
    }
    .btn-secondary:hover {
      background: #475569;
    }
    .alert {
      padding: 0.75rem;
      border-radius: 0.5rem;
      margin-bottom: 1.25rem;
      font-size: 0.875rem;
      display: none;
    }
    .alert-error {
      background: rgba(239, 68, 68, 0.15);
      border: 1px solid var(--error);
      color: #fca5a5;
    }
    .alert-success {
      background: rgba(16, 185, 129, 0.15);
      border: 1px solid var(--success);
      color: #86efac;
    }
    .welcome-panel {
      display: none;
      text-align: center;
    }
    .avatar {
      width: 72px;
      height: 72px;
      background: linear-gradient(135deg, #4f46e5, #9333ea);
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 1.25rem auto;
      font-size: 2rem;
      color: white;
    }
    .welcome-title {
      font-size: 1.6rem;
      font-weight: 700;
      margin-bottom: 0.5rem;
      color: #f8fafc;
    }
    .user-email {
      color: var(--text-muted);
      font-size: 0.95rem;
      margin-bottom: 1.5rem;
    }
    .info-box {
      background: #0f172a;
      border: 1px solid var(--border);
      border-radius: 0.5rem;
      padding: 1rem;
      margin-bottom: 1.5rem;
      text-align: left;
    }
    .info-row {
      display: flex;
      justify-content: space-between;
      font-size: 0.85rem;
      padding: 0.3rem 0;
      border-bottom: 1px solid #1e293b;
    }
    .info-row:last-child {
      border-bottom: none;
    }
    .info-label {
      color: var(--text-muted);
    }
    .info-value {
      font-weight: 600;
      color: #cbd5e1;
    }
    .badge-jwt {
      background: rgba(16, 185, 129, 0.2);
      color: #34d399;
      padding: 0.2rem 0.5rem;
      border-radius: 0.25rem;
      font-size: 0.75rem;
      font-weight: 600;
    }
  </style>
</head>
<body>

<div class="container">
  <div class="card">
    <div id="alertBox" class="alert"></div>

    <!-- 1. GİRİŞ & KAYIT FORMU ALANI -->
    <div id="authArea">
      <div class="header">
        <h1>Hoş Geldiniz</h1>
        <p>Hesabınıza giriş yapın veya yeni bir hesap oluşturun</p>
      </div>

      <div class="tabs">
        <button id="tabLogin" class="tab-btn active" onclick="switchTab('login')">Giriş Yap</button>
        <button id="tabRegister" class="tab-btn" onclick="switchTab('register')">Kayıt Ol</button>
      </div>

      <!-- Giriş Formu -->
      <form id="loginForm" onsubmit="handleLogin(event)">
        <div class="form-group">
          <label for="loginEmail">E-posta Adresi</label>
          <input type="email" id="loginEmail" required placeholder="ornek@alanadi.com">
        </div>
        <div class="form-group">
          <label for="loginPassword">Şifre</label>
          <input type="password" id="loginPassword" required placeholder="••••••••">
        </div>
        <button type="submit" class="btn" id="loginBtn">Giriş Yap</button>
      </form>

      <!-- Kayıt Formu -->
      <form id="registerForm" style="display: none;" onsubmit="handleRegister(event)">
        <div class="form-row">
          <div class="form-group">
            <label for="regFirstName">Ad</label>
            <input type="text" id="regFirstName" required placeholder="Ahmet">
          </div>
          <div class="form-group">
            <label for="regLastName">Soyad</label>
            <input type="text" id="regLastName" required placeholder="Yılmaz">
          </div>
        </div>
        <div class="form-group">
          <label for="regEmail">E-posta Adresi</label>
          <input type="email" id="regEmail" required placeholder="ornek@alanadi.com">
        </div>
        <div class="form-group">
          <label for="regPassword">Şifre (En az 6 karakter)</label>
          <input type="password" id="regPassword" required minlength="6" placeholder="••••••••">
        </div>
        <button type="submit" class="btn" id="registerBtn">Hesap Oluştur</button>
      </form>
    </div>

    <!-- 2. KARŞILAMA / DASHBOARD EKRANI -->
    <div id="welcomeArea" class="welcome-panel">
      <div class="avatar" id="userAvatar">👤</div>
      <h2 class="welcome-title" id="welcomeMessage">Hoş geldin!</h2>
      <p class="user-email" id="displayEmail"></p>

      <div class="info-box">
        <div class="info-row">
          <span class="info-label">Oturum Durumu</span>
          <span class="badge-jwt">Aktif (JWT)</span>
        </div>
        <div class="info-row">
          <span class="info-label">Erişim Anahtarı</span>
          <span class="info-value">15 Dakika (Oto-Yenilemeli)</span>
        </div>
        <div class="info-row">
          <span class="info-label">Yenileme Anahtarı</span>
          <span class="info-value">7 Gün (PostgreSQL)</span>
        </div>
      </div>

      <button type="button" class="btn btn-secondary" onclick="handleLogout()">Oturumu Kapat</button>
    </div>
  </div>
</div>

<script>
  let currentTab = 'login';

  function showAlert(msg, isSuccess = false) {
    const alertBox = document.getElementById('alertBox');
    alertBox.textContent = msg;
    alertBox.className = 'alert ' + (isSuccess ? 'alert-success' : 'alert-error');
    alertBox.style.display = 'block';
  }

  function hideAlert() {
    document.getElementById('alertBox').style.display = 'none';
  }

  function switchTab(tab) {
    currentTab = tab;
    hideAlert();
    document.getElementById('tabLogin').classList.toggle('active', tab === 'login');
    document.getElementById('tabRegister').classList.toggle('active', tab === 'register');
    document.getElementById('loginForm').style.display = tab === 'login' ? 'block' : 'none';
    document.getElementById('registerForm').style.display = tab === 'register' ? 'block' : 'none';
  }

  async function handleRegister(e) {
    e.preventDefault();
    hideAlert();
    const btn = document.getElementById('registerBtn');
    btn.disabled = true;
    btn.textContent = 'Kaydediliyor...';

    const data = {
      first_name: document.getElementById('regFirstName').value.trim(),
      last_name: document.getElementById('regLastName').value.trim(),
      email: document.getElementById('regEmail').value.trim(),
      password: document.getElementById('regPassword').value,
    };

    try {
      const res = await fetch('/api/auth/register', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || 'Kayıt başarısız');

      showAlert('Kayıt başarılı! Lütfen giriş yapınız.', true);
      document.getElementById('loginEmail').value = data.email;
      document.getElementById('registerForm').reset();
      switchTab('login');
    } catch (err) {
      showAlert(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Hesap Oluştur';
    }
  }

  async function handleLogin(e) {
    e.preventDefault();
    hideAlert();
    const btn = document.getElementById('loginBtn');
    btn.disabled = true;
    btn.textContent = 'Giriş yapılıyor...';

    const data = {
      email: document.getElementById('loginEmail').value.trim(),
      password: document.getElementById('loginPassword').value,
    };

    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || 'Giriş başarısız');

      localStorage.setItem('access_token', result.access_token);
      localStorage.setItem('refresh_token', result.refresh_token);
      localStorage.setItem('user', JSON.stringify(result.user));

      showWelcome(result.user);
    } catch (err) {
      showAlert(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Giriş Yap';
    }
  }

  async function refreshTokenIfNeeded() {
    const refreshToken = localStorage.getItem('refresh_token');
    if (!refreshToken) return null;

    try {
      const res = await fetch('/api/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: refreshToken }),
      });
      if (!res.ok) throw new Error('Token süresi doldu');
      const data = await res.json();
      localStorage.setItem('access_token', data.access_token);
      return data.access_token;
    } catch (_) {
      handleLogout();
      return null;
    }
  }

  function showWelcome(user) {
    document.getElementById('authArea').style.display = 'none';
    document.getElementById('welcomeArea').style.display = 'block';
    hideAlert();

    const initial = (user.first_name || 'U').charAt(0).toUpperCase();
    document.getElementById('userAvatar').textContent = initial;
    document.getElementById('welcomeMessage').textContent = `Hoş geldin \${user.first_name} \${user.last_name}`;
    document.getElementById('displayEmail').textContent = user.email;
  }

  async function handleLogout() {
    const refreshToken = localStorage.getItem('refresh_token');
    if (refreshToken) {
      try {
        await fetch('/api/auth/logout', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refresh_token: refreshToken }),
        });
      } catch (_) {}
    }

    localStorage.removeItem('access_token');
    localStorage.removeItem('refresh_token');
    localStorage.removeItem('user');

    document.getElementById('welcomeArea').style.display = 'none';
    document.getElementById('authArea').style.display = 'block';
    document.getElementById('loginPassword').value = '';
    hideAlert();
  }

  // Sayfa açılışında kayıtlı oturum kontrolü
  window.addEventListener('DOMContentLoaded', async () => {
    const storedUser = localStorage.getItem('user');
    const accessToken = localStorage.getItem('access_token');

    if (storedUser && accessToken) {
      try {
        const user = JSON.parse(storedUser);
        showWelcome(user);

        // Arka planda token doğrulaması yap
        const res = await fetch('/api/user/me', {
          headers: { 'Authorization': 'Bearer ' + accessToken },
        });

        if (!res.ok) {
          // Access token bitmiş olabilir, refresh dene
          const newToken = await refreshTokenIfNeeded();
          if (!newToken) {
            handleLogout();
          }
        }
      } catch (_) {
        handleLogout();
      }
    }
  });
</script>

</body>
</html>
''';
}
