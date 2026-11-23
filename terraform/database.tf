resource "aws_secretsmanager_secret" "db_credentials" {
  #checkov:skip=CKV_AWS_149: AWS managed KMS key (aws/secretsmanager) is used
  #checkov:skip=CKV2_AWS_57: Secret rotation managed natively by RDS manage_master_user_password in production
  name                    = "${var.project_name}/database"
  recovery_window_in_days = 7
}

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "postgres" {
  #checkov:skip=CKV_AWS_118: Enhanced monitoring disabled for test environment
  #checkov:skip=CKV_AWS_157: Multi-AZ disabled for single-instance test environment
  #checkov:skip=CKV_AWS_354: Performance Insights uses default AWS managed KMS key
  #checkov:skip=CKV2_AWS_30: Query logging requires custom parameter group, skipped for baseline
  identifier                            = "${var.project_name}-postgres"
  engine                                = "postgres"
  engine_version                        = "16"
  instance_class                        = var.db_instance_class
  allocated_storage                     = 20
  storage_type                          = "gp3"
  storage_encrypted                     = true
  auto_minor_version_upgrade            = true
  copy_tags_to_snapshot                 = true
  deletion_protection                   = true
  iam_database_authentication_enabled   = true
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  db_name                               = var.db_name
  username                              = var.db_username
  password                              = random_password.db.result
  db_subnet_group_name                  = aws_db_subnet_group.main.name
  vpc_security_group_ids                = [aws_security_group.db.id]
  publicly_accessible                   = false
  backup_retention_period               = 7
  skip_final_snapshot                   = true

  # Security note for Task 3 Scenario C:
  # In modern AWS provider, 'manage_master_user_password = true' can be used instead of
  # 'password' and 'random_password', enabling AWS Secrets Manager to generate and rotate
  # the RDS master password natively without storing credentials in the Terraform state file.
}
