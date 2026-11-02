locals {
  configuration = {
    "instance-arn"      = aws_db_instance.database.arn
    "endpoint"          = aws_db_instance.database.address
    "port"              = tostring(aws_db_instance.database.port)
    "database-name"     = aws_db_instance.database.db_name
    "security-group-id" = aws_security_group.database.id
    "api-secret-arn"    = aws_secretsmanager_secret.application["api"].arn
    "api-db-user"       = local.application_users.api
    "auth-secret-arn"   = aws_secretsmanager_secret.application["auth"].arn
    "auth-db-user"      = local.application_users.auth
    "schema-version"    = "1.0.0"
    "sql-sha256"        = local.initialization_sql_sha256
    "ssl-mode"          = "verify-full"
  }
}

resource "aws_ssm_parameter" "configuration" {
  for_each = local.configuration
  name     = "/mecanica/${var.environment}/database/v2/${each.key}"
  type     = "String"
  value    = each.value
}
