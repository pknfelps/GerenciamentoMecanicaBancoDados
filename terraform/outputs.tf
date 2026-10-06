output "instance_arn" {
  description = "Identidade da instância RDS PostgreSQL."
  value       = aws_db_instance.database.arn
}

output "endpoint" {
  description = "Hostname privado da instância, sem porta ou credenciais."
  value       = aws_db_instance.database.address
}

output "port" {
  value = aws_db_instance.database.port
}

output "database_name" {
  value = aws_db_instance.database.db_name
}

output "security_group_id" {
  value = aws_security_group.database.id
}

output "admin_secret_arn" {
  description = "Referencia ao segredo gerenciado pelo RDS; o valor nao entra no Terraform."
  value       = aws_db_instance.database.master_user_secret[0].secret_arn
}

output "base_dependency" {
  description = "Referencia exata da release consumida para o futuro manifesto do banco."
  value       = local.base_context.dependencies.base
}
