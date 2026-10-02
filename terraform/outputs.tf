output "cluster_arn" {
  description = "Identidade publica do cluster Aurora."
  value       = aws_rds_cluster.database.arn
}

output "writer_endpoint" {
  description = "Endpoint privado do writer, sem credenciais."
  value       = aws_rds_cluster.database.endpoint
}

output "port" {
  value = aws_rds_cluster.database.port
}

output "database_name" {
  value = aws_rds_cluster.database.database_name
}

output "security_group_id" {
  value = aws_security_group.aurora.id
}

output "admin_secret_arn" {
  description = "Referencia ao segredo gerenciado pelo RDS; o valor nao entra no Terraform."
  value       = aws_rds_cluster.database.master_user_secret[0].secret_arn
}

output "base_dependency" {
  description = "Referencia exata da release consumida para o futuro manifesto do banco."
  value       = local.base_context.dependencies.base
}
