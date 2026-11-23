# Dynamic Application Security Testing (DAST) & OWASP Top 10 Integration (Task 6)

Dokumen ini menjelaskan strategi integrasi DAST (Dynamic Application Security Testing) menggunakan **OWASP ZAP (Zed Attack Proxy)** ke dalam pipeline CI/CD, penanganan autentikasi, manajemen risiko pengujian, serta mitigasi terhadap risiko **OWASP Top 10**.

---

## 1. DAST Implementation in CI/CD Pipeline

### Pertanyaan 1: Bagaimana aplikasi disediakan di safe test environment?
Aplikasi **tidak pernah** diuji langsung di environment produksi! Untuk memastikan pengujian yang aman, terisolasi, dan dapat diulang:
1. **Ephemeral Local Container di CI Runner (Shift-Left DAST)**:
   - Pada stage `dast` di GitHub Actions / GitLab CI, pipeline menjalankan container aplikasi Go yang baru dibangun di background pada runner runner terisolasi:
     ```bash
     docker run -d --name sample-api -p 8080:8080 devsecops-home-test:${{ github.sha }}
     ```
   - Script melakukan polling ke health check endpoint (`http://127.0.0.1:8080/health`) hingga mengembalikan status `200 OK`.
2. **Ephemeral Staging Environment di AWS (Staging DAST)**:
   - Alternatif untuk integrasi penuh: deploy ke isolated ECS staging cluster yang memiliki subnet dan database mock terisolasi (disposable environment yang di-teardown otomatis setelah scan selesai).

---

### Pertanyaan 2: Pemeriksaan DAST apa yang dijalankan secara otomatis?
Di dalam pipeline CI/CD otomatis, kita menjalankan **OWASP ZAP Baseline Scan** (`zap-baseline.py`) atau **ZAP API Scan** (`zap-api-scan.py` menggunakan spesifikasi OpenAPI / Swagger):
- **Passive Security Checks**:
  - Missing Security Headers: `Content-Security-Policy` (CSP), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Strict-Transport-Security` (HSTS).
  - Cookie Security Flags: Memastikan `HttpOnly`, `Secure`, dan `SameSite` diterapkan pada session cookies.
  - Information Leakage: Mendeteksi header `Server: ...`, `X-Powered-By: ...`, atau stack trace error di response body yang membocorkan versi teknologi backend.
  - CORS Misconfiguration: Mengecek `Access-Control-Allow-Origin: *` pada endpoint sensitif.
  - Insecure HTTP Methods: Mengecek apakah method `TRACE`, `OPTIONS`, atau `PUT` terbuka secara tidak aman.
- **Active / Target-Specific Checks (pada API Scan)**:
  - Input Validation Fuzzing: Parameter pollution, boundary values, format string injection.
  - Path Traversal & Directory Browsing.

---

### Pertanyaan 3: Bagaimana autentikasi ditangani selama pengujian?
API modern umumnya membutuhkan autentikasi (misal Bearer JWT Token atau API Key). Strategi penanganannya di OWASP ZAP:
1. **ZAP Replacer Rule (Header Injection)**:
   - Pipeline menghasilkan test token sementara (mock JWT) atau memanggil endpoint `/api/v1/auth/login` menggunakan kredensial dummy test user.
   - Token tersebut disuntikkan secara otomatis ke setiap request scanner menggunakan parameter ZAP:
     ```bash
     docker run --rm --network host -v $(pwd):/zap/wrk/:rw ghcr.io/zaproxy/zaproxy:stable \
       zap-api-scan.py -t openapi.json -f openapi \
       -z "-config replacer.full_list(0).description=AuthHeader \
           -config replacer.full_list(0).enabled=true \
           -config replacer.full_list(0).matchtype=REQ_HEADER \
           -config replacer.full_list(0).matchstr=Authorization \
           -config replacer.full_list(0).replacement='Bearer eyJhbGciOi...'"
     ```
2. **ZAP Context Authentication Script**:
   - Untuk skenario form login berbasis session/cookie, gunakan ZAP Script-based Authentication (JavaScript/Python) yang menangani flow CSRF token, login form submission, dan pembaruan cookie secara otomatis.

---

### Pertanyaan 4: Temuan DAST apa yang wajib memblokir rilis (*Release Gate*)?
- **BLOCK RELEASE (Fail Build)**:
  - **High & Critical Vulnerabilities**: SQL Injection, Remote Code Execution (RCE), Server-Side Request Forgery (SSRF), Authentication/Authorization Bypass, Path Traversal.
- **PASS WITH WARNING (Track via Jira / GitHub Issue)**:
  - **Medium / Low**: Missing `Strict-Transport-Security` pada localhost dev environment, informational server header tokens, missing anti-clickjacking header pada response JSON API murni (karena JSON endpoint tidak rentan clickjacking iframe).
- Flag ZAP: `zap-baseline.py` menggunakan exit code:
  - Exit code `0`: Pass.
  - Exit code `1`: Paling sedikit ada 1 temuan WARN.
  - Exit code `2`: Paling sedikit ada 1 temuan FAIL (High/Critical).
  - Pipeline diatur untuk gagal (`exit 1`) jika ada temuan FAIL.

---

### Pertanyaan 5: Bagaimana mencegah pengujian keamanan mengganggu sistem produksi?
1. **Network Isolation**: DAST dijalankan di dalam Docker bridge network internal pada runner CI atau private subnet staging. Tidak ada konektivitas jaringan ke VPC produksi.
2. **Target URL Validation**: Skrip scan memverifikasi bahwa target URL hanya mengarah ke `127.0.0.1`, `localhost`, atau `staging-api.internal.company.com`. Skrip otomatis abort jika target URL berisi domain produksi (`api.company.com`).
3. **No Destructive Payloads in Automated Pipeline**:
   - Pipeline otomatis hanya menggunakan **Passive Scan** atau **Targeted API Scan**.
   - Active scanning yang destruktif (seperti fuzzing database `DELETE /users/*` atau DoS stress testing) dilarang berjalan di CI reguler; hanya dijalankan secara terjadwal di dedicated sandbox environment.
4. **Mocked Third-Party APIs**: Integrasi ke payment gateway (Stripe/Xendit) atau email provider (SendGrid) di-mock agar ZAP scan tidak memicu transaksi finansial atau spamming ke user nyata.

---

## 2. Analisis & Mitigasi Tiga Risiko OWASP Top 10 (2021)

Berikut adalah tiga risiko OWASP Top 10 yang paling relevan dengan backend API containerized di AWS beserta cara deteksi dan mitigasinya:

### 1. A01:2021 - Broken Access Control
- **Deskripsi Risiko**: Pengguna dapat mengakses endpoint, data, atau resource yang bukan haknya (misalnya IDOR - Insecure Direct Object References, atau user biasa memanggil API endpoint admin `/api/admin/delete-user`).
- **Deteksi**:
  - **DAST**: OWASP ZAP mengirim request ke resource User A menggunakan JWT/session User B untuk mengecek apakah data tetap dikembalikan (BOLA / IDOR detection).
  - **SAST**: Semgrep mendeteksi missing authorization middleware pada routing handler.
- **Mitigasi**:
  - Menerapkan **Role-Based Access Control (RBAC)** atau Attribute-Based Access Control (ABAC) yang ketat di level middleware aplikasi.
  - Verifikasi ownership resource di setiap query database: `SELECT * FROM orders WHERE id = ? AND user_id = ?`.
  - Disable directory listing dan tolak akses default (*Deny by default*).

---

### 2. A03:2021 - Injection (SQLi, Command Injection)
- **Deskripsi Risiko**: Data yang tidak terpercaya disisipkan langsung ke interpreter SQL, OS shell, atau sistem lain, memungkinkan penyerang mengeksekusi query database ilegal atau perintah arbitrary di container.
- **Deteksi**:
  - **SAST**: Semgrep mendeteksi string concatenation dalam query SQL (`fmt.Sprintf("SELECT * FROM users WHERE name='%s'", input)`).
  - **DAST**: OWASP ZAP menyuntikkan payload SQLi (seperti `' OR '1'='1`) dan karakter perintah shell (seperti `; ls -la`, `| cat /etc/passwd`) ke query string and JSON body.
- **Mitigasi**:
  - Gunakan **Parameterized Queries / Prepared Statements** atau ORM yang aman.
  - **Container Hardening**: Gunakan base image **Distroless** (`gcr.io/distroless/static-debian12:nonroot`) yang **tidak memiliki binary OS shell (`/bin/sh`, `/bin/bash`) dan utility Linux (`curl`, `nc`)**. Sekalipun ada celah command injection di kode aplikasi, penyerang tidak dapat mengeksekusi shell perintah Linux!
  - Aktifkan **Read-only Root Filesystem** (`readonlyRootFilesystem = true` di ECS Task Definition) sehingga penyerang tidak dapat mengunduh malware atau web shell ke disk.
  - **AWS WAF**: Gunakan `AWSManagedRulesSQLiRuleSet` pada ALB untuk memblokir payload SQLi sebelum mencapai aplikasi backend.

---

### 3. A05:2021 - Security Misconfiguration
- **Deskripsi Risiko**: Konfigurasi keamanan default yang tidak diubah, port terbuka yang tidak perlu, header HTTP yang hilang, directory listing, atau pesan error verbose yang menampilkan stack trace sensitif.
- **Deteksi**:
  - **IaC Scanning**: Checkov mendeteksi Security Group yang membuka port ke `0.0.0.0/0`, ALB tanpa drop header invalid, atau RDS yang tidak dienkripsi.
  - **DAST**: OWASP ZAP mendeteksi ketiadaan header keamanan (`X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`), metode HTTP yang tidak aman, atau kebocoran header versi server.
- **Mitigasi**:
  - Hardening HTTP Header di kode aplikasi (telah diimplementasikan di `app/src/main.go`):
    ```go
    w.Header().Set("X-Content-Type-Options", "nosniff")
    w.Header().Set("X-Frame-Options", "DENY")
    ```
  - Otomasi pemeriksaan IaC dengan Checkov di setiap commit untuk memastikan konfigurasi cloud mengikuti CIS Benchmark.
  - Menghilangkan banner versi server di web server / reverse proxy.
  - Menangani error secara generik tanpa menampilkan stack trace internal ke pengguna luar.
