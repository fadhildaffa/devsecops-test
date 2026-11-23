# Security Incident Response & Troubleshooting Runbook (Task 5)

Dokumen ini mendokumentasikan investigasi langkah demi langkah, kemungkinan akar masalah (*likely root causes*), dan tindakan perbaikan (*corrective actions*) untuk skenario insiden produksi.

---

## Scenario A: Pipeline Security Failure (Critical Base Image Vulnerability)

### 1. Deskripsi Situasi
Pipeline CI/CD gagal (*broken build*) karena Trivy mendeteksi kerentanan **Critical** pada base image container. Tim developer menyatakan aplikasi berfungsi normal di lokal dan meminta izin untuk segera deploy (*bypass*) ke environment produksi karena target rilis mendesak.

### 2. Tindakan dan Pendirian DevSecOps Engineer: **Tolak Permintaan Bypass Langsung**
Sebagai DevSecOps Engineer, kita **tidak boleh meloloskan rilis tanpa analisis risiko formal**. Permintaan "bypass cepat" secara informal melanggar tata kelola keamanan dan membuka celah eksploitasi di lingkungan produksi.

### 3. Alur Kerja Evaluasi & Remediasi (Step-by-Step)

#### Langkah 1: Penilaian Risiko (Risk Assessment)
Lakukan analisis teknis terhadap CVE yang dilaporkan:
- **Reachability & Exploitability**: Apakah fungsi atau library yang rentan di base image benar-benar dipanggil atau dieksekusi oleh aplikasi Go kita? Karena aplikasi kita dikompilasi secara statis (`CGO_ENABLED=0`) dan menggunakan base image distroless, periksa apakah kerentanan ada di layer OS atau library sistem.
- **Ketersediaan Exploit (PoC / In-the-Wild)**: Periksa database NVD, CISA KEV (Known Exploited Vulnerabilities), dan GitHub Advisory. Apakah sudah ada exploit publik atau serangan aktif?
- **Network Exposure**: Apakah aplikasi menghadap publik (*internet-facing*) atau berada di subnet internal terlindung?
- **CVSS Vector**: Analisis vektor serangan (misal: apakah membutuhkan hak akses lokal atau dapat dipicu secara remote melalui unauthenticated HTTP request).

#### Langkah 2: Remediasi Cepat (Preferred Path)
1. **Perbarui Base Image**: Cek apakah upstream base image (misalnya `golang:alpine` atau `gcr.io/distroless/static-debian12`) memiliki patch rilis terbaru.
2. **Rebuild & Rescan**: Trigger ulang build pipeline dengan image versi terbaru. Dalam banyak kasus, memperbarui digest base image menyelesaikan temuan dalam hitungan menit tanpa mengubah kode aplikasi.
3. **Alternatif Base Image**: Jika base image lama ditinggalkan maintainer, ganti ke distroless (`gcr.io/distroless/static-debian12:nonroot`) atau Chainguard minimal image yang bebas CVE.

#### Langkah 3: Kebijakan Pengecualian Sementara (Exception & Emergency Release Process)
Jika **TIDAK ADA patch yang tersedia** dan bisnis menuntut rilis darurat:
- **Terapkan Compensating Controls**:
  - Aktifkan rule spesifik di AWS WAF (misal: virtual patching atau rate limiting) untuk memblokir pola payload yang menargetkan CVE tersebut.
  - Batasi akses ingress network atau matikan fitur spesifik yang rentan.
  - Aktifkan pemantauan real-time dan deteksi anomali di GuardDuty / CloudWatch.
- **Dokumentasi Exception Form**:
  - ID CVE, skor CVSS, nama komponen, dan deskripsi teknis.
  - Alasan bisnis mengapa rilis harus berjalan.
  - Kompensasi keamanan yang dipasang.
  - Target tanggal remediasi permanen dan tanggal kadaluarsa izin (maksimum 7–14 hari).
- **Otorisasi Rilis (Release Authorization)**:
  - Wajib disetujui secara tertulis (*sign-off*) oleh **CISO, Head of Security, atau Product Owner yang memiliki wewenang risiko**.
  - Developer atau engineer tidak berhak melakukan bypass sepihak.

---

## Scenario B: ECS Fargate Task Fails to Retrieve Secrets from AWS Secrets Manager

### 1. Deskripsi Situasi
Task ECS Fargate gagal dijalankan (*CrashLoopBackOff* atau langsung *STOPPED*) dengan error status seperti `CannotPullContainerError` atau error saat menginjeksi secret dari AWS Secrets Manager.

### 2. Investigasi Komponen AWS & Izin Terkait

#### a. ECS Task Execution Role vs. ECS Task Role
Ini adalah titik kebingungan paling umum di AWS ECS:
- **ECS Task Execution Role (`execution_role_arn`)**: Digunakan oleh **AWS ECS Container Agent** (infrastruktur) sebelum container aplikasi berjalan. Peran ini bertugas untuk:
  - Mengambil container image dari private Amazon ECR (`ecr:GetAuthorizationToken`, `ecr:BatchGetImage`).
  - Mengirim log stdout/stderr ke Amazon CloudWatch Logs (`logs:CreateLogStream`, `logs:PutLogEvents`).
  - Mengambil secret dari Secrets Manager / Parameter Store saat task definition mendefinisikan blok `secrets: [{ name: "DB_SECRET", valueFrom: "arn:aws:secretsmanager:..." }]`.
- **ECS Task Role (`task_role_arn`)**: Digunakan oleh **aplikasi di dalam container** saat runtime (misal: kode Go memanggil `aws-sdk-go` untuk query S3 bucket atau Secrets Manager).
- **Akar Masalah Umum**: Izin `secretsmanager:GetSecretValue` diletakkan di Task Role, padahal secret diinjeksi via Task Definition `secrets` (yang membutuhkan Task Execution Role), atau sebaliknya!

#### b. Secrets Manager Resource & Permissions
- Periksa policy pada Task Execution Role: Apakah memiliki aksi `secretsmanager:GetSecretValue`?
- Periksa Resource ARN: Pastikan ARN secret di Task Definition cocok persis dengan ARN di Secrets Manager (termasuk suffix 6 karakter acak AWS Secrets Manager jika diperlukan).
- Resource-based policy pada Secret: Jika Secret memiliki resource policy, pastikan tidak ada `Explicit Deny` yang memblokir Task Execution Role.

#### c. AWS KMS Permissions (Jika Menggunakan Customer-Managed Key / CMK)
- Jika secret dienkripsi menggunakan custom KMS key (bukan default `aws/secretsmanager`), Task Execution Role **wajib** memiliki izin:
  ```json
  {
    "Effect": "Allow",
    "Action": [
      "kms:Decrypt",
      "kms:DescribeKey"
    ],
    "Resource": "arn:aws:kms:ap-southeast-1:123456789012:key/your-cmk-key-id"
  }
  ```
- KMS Key Policy juga harus mengizinkan Task Execution Role untuk melakukan operasi decrypt.

#### d. Konektivitas Jaringan (Network Connectivity & VPC Endpoints)
ECS Fargate berjalan di dalam private subnet (`assign_public_ip = false`):
- Fargate agent **harus memiliki jalur jaringan** untuk menghubungi endpoint AWS Secrets Manager (`secretsmanager.<region>.amazonaws.com`) dan KMS (`kms.<region>.amazonaws.com`).
- Jalur 1: **NAT Gateway** di public subnet dengan route `0.0.0.0/0` pada private subnet route table.
- Jalur 2: **VPC Endpoints (AWS PrivateLink)**:
  - Interface Endpoint untuk `com.amazonaws.<region>.secretsmanager`
  - Interface Endpoint untuk `com.amazonaws.<region>.kms`
  - Pastikan Security Group VPC Endpoint mengizinkan **Inbound TCP 443** dari Security Group ECS Task!
  - Pastikan opsi VPC `enable_dns_hostnames = true` dan `enable_dns_support = true` aktif agar resolusi DNS mengarah ke private IP endpoint.

#### e. CloudWatch Logs & ECS Task Events
- Buka AWS Management Console -> ECS -> Cluster -> Tasks -> pilih Task yang stopped.
- Buka tab **Details** dan baca bagian **Stopped reason**.
  - Contoh pesan error informatif:
    - `"ResourceInitializationError: unable to pull secrets or registry auth: execution resource retrieval failed: unable to retrieve secret from asm: service call has been blocked by network configuration"` -> Masalah jaringan / VPC Endpoint / NAT!
    - `"AccessDeniedException: User: arn:aws:sts:... is not authorized to perform: secretsmanager:GetSecretValue on resource: ..."` -> Masalah IAM Execution Role!
    - `"AccessDeniedException: The ciphertext refers to a customer master key that does not exist or you do not have permission to access: kms:Decrypt"` -> Masalah KMS Key!

### 3. Cara Mengisolasi Masalah Tanpa Memberikan Izin Administrator
**Prinsip Keamanan: Jangan pernah mendiagnosis masalah dengan menempelkan `AdministratorAccess`!**
1. **Analisis Error Message Presisi**: Gunakan `aws ecs describe-tasks --tasks <task-id>` untuk membaca `stoppedReason` yang memberikan nama permission spesifik yang hilang.
2. **Uji Permission dengan IAM Policy Simulator**:
   Gunakan AWS CLI IAM Policy Simulator:
   ```bash
   aws iam simulate-principal-policy \
     --policy-source-arn arn:aws:iam::123456789012:role/devsecops-home-test-execution-role \
     --action-names secretsmanager:GetSecretValue kms:Decrypt \
     --resource-arns arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:app/database
   ```
3. **Uji Konektivitas Jaringan**:
   Jalankan container diagnostik sementara (bastion/debug task) di subnet dan security group yang sama, lalu uji resolusi DNS dan koneksi TCP:
   ```bash
   nslookup secretsmanager.ap-southeast-1.amazonaws.com
   nc -zv secretsmanager.ap-southeast-1.amazonaws.com 443
   ```
4. **Terapkan Izin Minimal Saja**: Tambahkan hanya permission `secretsmanager:GetSecretValue` dan `kms:Decrypt` pada ARN secret spesifik.

---

## Scenario C: Unauthorized AWS API Activity from Deployment Pipeline IAM Principal

### 1. Deskripsi Situasi
Layanan deteksi ancaman (AWS CloudTrail / Amazon GuardDuty) mencatat aktivitas API AWS yang tidak wajar dan mencurigakan dari IAM Principal yang biasanya hanya digunakan oleh CI/CD deployment pipeline (misal: `CreateUser`, `AttachUserPolicy`, `DescribeInstances` di luar jam kerja, atau panggilan dari IP address publik asing yang bukan milik runner GitHub/GitLab).

### 2. Immediate Containment Actions (Isolasi & Mitigasi Cepat)
1. **Revoke Active Sessions Seketika**:
   - Jika role menggunakan STS temporary credentials, lampirkan inline policy yang menolak semua sesi sebelum waktu insiden:
     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Deny",
           "Action": "*",
           "Resource": "*",
           "Condition": {
             "DateLessThan": {
               "aws:TokenIssueTime": "2026-11-23T10:00:00Z"
             }
           }
         }
       ]
     }
     ```
2. **Kunci / Nonaktifkan IAM Role & OIDC Trust**:
   - Ubah trust relationship role untuk sementara waktu menjadi `Principal: { "AWS": "arn:aws:iam::123456789012:root" }` dengan kondisi `Deny`, sehingga runner CI/CD tidak dapat melakukan `AssumeRole`.
3. **Hentikan Pipeline CI/CD**:
   - Batalkan workflow yang sedang berjalan dan pause GitHub Actions runner / GitLab CI pipeline.
4. **Isolasi Long-Lived Credentials (Jika ada)**:
   - Jika pipeline menggunakan `AWS_ACCESS_KEY_ID` statis, segera nonaktifkan (`Inactive`) dan delete access key tersebut dari IAM console.

### 3. Investigation Process (Investigasi Forensik)
1. **Analisis Audit Trail (CloudTrail)**:
   - Jalankan query Amazon Athena pada CloudTrail logs atau gunakan CloudTrail Event History:
     ```sql
     SELECT eventTime, eventName, userIdentity.arn, sourceIPAddress, userAgent, requestParameters, responseElements
     FROM cloudtrail_logs
     WHERE userIdentity.sessionContext.sessionIssuer.userName = 'devsecops-deploy-role'
       AND eventTime >= '2026-11-23T00:00:00Z'
     ORDER BY eventTime DESC;
     ```
   - Identifikasi:
     - Sumber IP (apakah berasal dari IP resmi GitHub Hosted Runner ASN 36459 atau IP luar negeri/VPN).
     - User Agent pemanggil.
     - Aksi berbahaya (misal: eksfiltrasi secret, pembuatan IAM user backdoor, modifikasi security group).
2. **Investigasi CI/CD Platform (GitHub/GitLab Audit Logs)**:
   - Periksa apakah ada commit mencurigakan, pull request berbahaya dari fork yang mengeksekusi pipeline, atau modifikasi file workflow `.github/workflows/devsecops.yml`.
   - Cek environment secrets: Apakah secret OIDC atau kredensial sempat dicetak (*echo*) ke log runner?
3. **Identifikasi Blast Radius (Cakupan Dampak)**:
   - Periksa apakah data sensitif (RDS, S3, Secrets Manager) telah diakses atau dibaca.

### 4. Recovery & Post-Incident Steps (Pemulihan & Penguatan)
1. **Rotasi Seluruh Kredensial yang Berpotensi Terpapar**:
   - Rotasi semua password database, secret API, dan token yang dapat diakses oleh role tersebut.
2. **Hapus Resource Ilegal**:
   - Hapus user IAM, policy, snapshot, atau instance yang dibuat tanpa izin oleh penyerang.
3. **Migrasi Penuh ke OIDC dengan Kondisi Ketat**:
   - Pastikan tidak ada kredensial statis.
   - Perketat kondisi `sub` pada OIDC Trust Policy:
     Hanya izinkan commit SHA dari branch `main` pada environment yang telah disetujui reviewer (`StringEquals: { "token.actions.githubusercontent.com:sub": "repo:org/repo:environment:production" }`).
4. **Perketat Guardrails & Alerting**:
   - Konfigurasi AWS GuardDuty untuk memberi alert instan jika ada `IAMUser/AnomalousBehavior`.
   - Pasang Amazon EventBridge rule untuk alert Slack/PagerDuty saat ada panggilan API sensitif (`CreateAccessKey`, `CreateUser`, `StopLogging`).
5. **Post-Mortem & Blameless Review**:
   - Dokumentasikan timeline insiden, root cause, dampak, serta actionable follow-up items untuk mencegah keberulangan.
