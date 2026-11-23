# Mandatory Security Scenarios & Remediation Notes (Task 3)

Dokumen ini berisi analisis mendalam dan solusi remediasi untuk **Task 3: Terraform and AWS IAM Security - Mandatory Security Scenarios**.

---

## Scenario A: Overly Permissive IAM Policy

### 1. The Vulnerable Policy Proposed
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
```

### 2. Mengapa Policy Ini Sangat Berbahaya?
- **Pelanggaran Prinsip Least Privilege**: Memberikan izin Administrator penuh (`AdministratorAccess`). Principal dapat membuat, memodifikasi, dan menghapus resource AWS apapun di akun tersebut.
- **Privilege Escalation**: Pipeline deployment atau penyerang yang berhasil mengompromikan pipeline dapat membuat akun IAM baru, backdoor admin, menonaktifkan CloudTrail/GuardDuty, atau menghapus seluruh infrastruktur produksi.
- **Blast Radius yang Tidak Terbatas**: Jika CI/CD credential bocor (misalnya via command injection di runner atau dependency compromise), seluruh akun AWS berada dalam bahaya total.
- **Compliance Breach**: Melanggar standar industri (CIS AWS Foundations Benchmark, SOC 2, ISO 27001, PCI-DSS).

### 3. Solusi & Pendekatan yang Aman (Proposed Safer Approach)

Pendekatan aman menerapkan prinsip **Defense-in-Depth**:

#### a. Pemisahan Deployment Role vs Application Runtime Role
- **Deployment Role (digunakan oleh CI/CD Runner)**: Hanya memiliki izin untuk mengunggah image ke ECR dan memperbarui service ECS / task definition. Role ini **tidak boleh** digunakan oleh aplikasi saat berjalan.
- **Application Runtime Role (digunakan oleh container di Fargate)**: Terbagi menjadi dua:
  - **Task Execution Role**: Digunakan oleh ECS agent untuk pull image ECR, mengirim log ke CloudWatch, dan membaca secret dari Secrets Manager.
  - **Task Role**: Digunakan oleh proses aplikasi di dalam container untuk mengakses AWS resource yang dibutuhkan saat runtime (misal: S3 bucket, DynamoDB, dll).

#### b. Resource-Level Permissions
Membatasi `Action` hanya pada ARN resource spesifik, bukan `Resource: "*"`.

Contoh Policy Deployment CI/CD yang aman (Least Privilege):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPushOperations",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:ap-southeast-1:123456789012:repository/devsecops-home-test"
    },
    {
      "Sid": "ECSDeployment",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": [
        "arn:aws:ecs:ap-southeast-1:123456789012:cluster/devsecops-home-test",
        "arn:aws:ecs:ap-southeast-1:123456789012:service/devsecops-home-test/devsecops-home-test-service",
        "arn:aws:ecs:ap-southeast-1:123456789012:task-definition/devsecops-home-test:*"
      ]
    },
    {
      "Sid": "PassRoleToECS",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::123456789012:role/devsecops-home-test-execution-role",
        "arn:aws:iam::123456789012:role/devsecops-home-test-task-role"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    }
  ]
}
```

#### c. Short-Lived Credentials via OIDC (Tanpa Static Long-lived Keys)
Tidak lagi menyimpan `AWS_ACCESS_KEY_ID` dan `AWS_SECRET_ACCESS_KEY` di repository secrets. Menggunakan OpenID Connect (OIDC) federation antara GitHub Actions / GitLab CI dan AWS IAM:
- CI/CD menukarkan JSON Web Token (JWT) yang ditandatangani untuk mendapatkan token STS sementara (berlaku maksimum 1 jam).
- IAM Trust Policy mengunci `sub` (subject claim) hanya untuk branch `main` dan environment `production` dari repositori yang sah:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:org/devsecops-home-test:environment:production"
        }
      }
    }
  ]
}
```

#### d. Cross-Account Access
Di lingkungan enterprise, gunakan arsitektur multi-account (misal: CI/CD Shared Services Account terpisah dari Production Account):
1. CI/CD Runner berada di Management/Build Account.
2. Melakukan `sts:AssumeRole` ke Role di Production Account yang dibatasi oleh ExternalId dan IP / VPC Conditions.
3. Service Control Policies (SCP) di level AWS Organizations memblokir modifikasi guardrail keamanan (CloudTrail, GuardDuty, SCPs) meskipun role lokal mencoba melakukannya.

---

## Scenario B: Publicly Accessible Database (`0.0.0.0/0`)

### 1. The Scenario
Developer mengubah kode Terraform dan membuat RDS database dapat diakses langsung dari internet (`publicly_accessible = true` dan Security Group ingress port 5432 dibuka ke `0.0.0.0/0`).

### 2. Cara Pipeline Mendeteksi & Memblokir Sebelum Deployment

Pendekatan "Shift-Left" mendeteksi dan menggagalkan skenario ini di berbagai lapisan:

#### Lapisan 1: Pre-Commit & Local IDE Linting
- Developer menggunakan `checkov` / `trivy config` di pre-commit hooks.
- Feedback instan mencegah kode masuk ke Git history.

#### Lapisan 2: CI/CD Pipeline Gate (Automated IaC Security Scanning)
Pada stage `terraform-scan`, Checkov dijalankan secara otomatis dengan `soft_fail: false` (atau Trivy config dengan `--exit-code 1`):
- **Checkov Rule `CKV_AWS_17`**: *"Ensure RDS DB instances are not publicly accessible"*
  - Rule ini mengecek atribut `publicly_accessible == true`. Jika true, checkov menghasilkan status `FAILED`.
- **Checkov Rule `CKV_AWS_260`**: *"Ensure no security groups allow ingress from 0.0.0.0/0 to target ports like 5432 (PostgreSQL)"*
  - Rule ini mendeteksi ingress CIDR `0.0.0.0/0` pada port database.
- **Pipeline Failure**: Karena flag `soft_fail: false` atau exit code `1`, job `terraform-scan` langsung **FAIL**.
- Pipeline menghentikan stage selanjutnya (Build, Container scan, DAST, dan Deploy). Tidak ada `terraform apply` yang dapat dieksekusi.

#### Lapisan 3: Policy as Code (Conftest / Open Policy Agent - OPA)
Jika menggunakan OPA / Conftest di pipeline:
```rego
package terraform.security

deny[msg] {
    resource := input.resource_changes[_]
    resource.type == "aws_db_instance"
    resource.change.after.publicly_accessible == true
    msg := sprintf("Security Gate Violation: RDS '%v' must not be publicly accessible!", [resource.name])
}

deny[msg] {
    resource := input.resource_changes[_]
    resource.type == "aws_security_group_rule"
    resource.change.after.from_port <= 5432
    resource.change.after.to_port >= 5432
    resource.change.after.cidr_blocks[_] == "0.0.0.0/0"
    msg := sprintf("Security Gate Violation: SG rule allows 0.0.0.0/0 access to PostgreSQL port 5432", [])
}
```

#### Lapisan 4: Cloud Guardrails (AWS Preventive & Detective Controls)
- **VPC Subnet Architecture**: Database ditempatkan pada `aws_subnet.db` yang terhubung ke route table tanpa route `0.0.0.0/0` ke Internet Gateway (Isolated Private Subnet). Meskipun flag `publicly_accessible = true` diaktifkan di RDS, database tidak memiliki rute jaringan ke internet.
- **AWS Config Rule**: Rule `rds-instance-public-access-check` aktif mendeteksi dan memicu auto-remediation (AWS Systems Manager Automation) untuk mengembalikan setting ke private jika lolos secara out-of-band.
- **AWS Organizations SCP**: Membatasi permission untuk melampirkan Internet Gateway ke VPC database atau membuat public subnet di VPC data.

---

## Scenario C: Secret Exposure in Terraform Variables & State File

### 1. The Scenario
Sebuah application password tersimpan di dalam Terraform variable (`terraform.tfvars` atau CLI arguments) dan masuk ke file Terraform state (`terraform.tfstate`).

### 2. Bahaya Terraform State File
Terraform state menyimpan seluruh metadata resource dan atribut yang dihasilkan, termasuk nilai yang ditandai `sensitive = true`, dalam format **plaintext JSON**. Siapapun yang memiliki akses read ke state file dapat membaca password tersebut.

### 3. Immediate Containment & Remediation (Langkah Penanganan Cepat)
1. **Rotate Credential Seketika**: Anggap password sudah bocor. Ubah password database langsung di database / AWS Secrets Manager ke nilai baru yang acak dan kuat.
2. **Invalidasi Sesi Aktif**: Putuskan koneksi database yang mencurigakan atau revoke token yang berkaitan.
3. **Audit Akses**: Periksa CloudTrail dan access logs database untuk mendeteksi apakah password yang terekspos sempat digunakan oleh pihak luar.

### 4. Handling Exposed Credential in Git & State File
1. **Jika State File Masuk ke Git Repository**:
   - Jangan sekadar menghapus file di commit baru (karena history Git tetap menyimpannya).
   - Gunakan `git-filter-repo` atau BFG Repo-Cleaner untuk menghapus file state dan commit historis secara permanen.
   - Force push ke remote dan informasikan tim untuk clone ulang repository.
2. **Sanitasi State File yang Ada**:
   - Jika state disimpan di remote S3, aktifkan S3 Versioning deletion untuk memusnahkan versi lama state yang menyimpan password plaintext.

### 5. Pencegahan Permanen (Prevention & Architecture Redesign)

#### Strategi 1: AWS Managed Master User Password (Modern Best Practice)
Di AWS RDS terbaru, gunakan fitur `manage_master_user_password = true`. Dengan fitur ini, AWS RDS secara otomatis membuat password acak dan menyimpannya langsung di AWS Secrets Manager.
**Terraform sama sekali tidak pernah melihat atau menyimpan password tersebut di state file!**
```hcl
resource "aws_db_instance" "postgres" {
  identifier                  = "app-postgres"
  engine                      = "postgres"
  manage_master_user_password = true # AWS Secrets Manager mengelola password secara native
  master_user_secret_kms_key_id = aws_kms_key.db.arn
  # Tidak ada atribut 'password' sama sekali di kode Terraform!
}
```

#### Strategi 2: Penggunaan AWS Secrets Manager + Dynamic Rotation
Jika aplikasi membutuhkan credentials non-master:
- Buat secret di Secrets Manager.
- ECS Task Execution Role membaca secret langsung saat startup via ARN tanpa meletakkan plaintext di variable Terraform.
- Aktifkan auto-rotation Lambda di Secrets Manager setiap 30/60/90 hari.

#### Strategi 3: Pengamanan Terraform Remote State (Defense-in-Depth)
- **Remote Backend S3**: Jangan pernah menyimpan state di local disk.
- **KMS Encryption**: Enkripsi bucket S3 state dengan AWS KMS Customer Managed Key (CMK) dengan key policy yang ketat.
- **Strict IAM & Bucket Policy**: Hanya CI/CD deployment role dan lead DevOps yang memiliki akses read/write ke S3 backend.
- **DynamoDB State Locking**: Mencegah race condition dan penulisan state simultan.
- **Pre-commit Gitleaks**: Memblokir commit jika ada pola API keys/passwords atau file `.tfstate`.
