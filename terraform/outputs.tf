output "alb_dns_name" {
  description = "ALB DNS hostname. Add TLS/ACM and WAF before production."
  value       = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "db_endpoint" {
  value     = aws_db_instance.postgres.address
  sensitive = true
}
