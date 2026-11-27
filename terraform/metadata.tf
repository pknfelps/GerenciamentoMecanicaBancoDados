locals {
  initialization_target = {
    instanceId         = aws_db_instance.database.resource_id
    operationalVersion = local.schema_version
    operationalSha256  = local.initialization_sql_sha256
    identityVersion    = local.identity_schema_version
    identitySha256     = local.identity_initialization_sql_sha256
  }
  configuration = {
    "instance-arn"          = aws_db_instance.database.arn
    "endpoint"              = aws_db_instance.database.address
    "port"                  = tostring(aws_db_instance.database.port)
    "database-name"         = aws_db_instance.database.db_name
    "security-group-id"     = aws_security_group.database.id
    "api-secret-arn"        = aws_secretsmanager_secret.application["api"].arn
    "api-db-user"           = local.application_users.api
    "auth-database-name"    = local.identity_database_name
    "auth-secret-arn"       = aws_secretsmanager_secret.application["auth"].arn
    "auth-db-user"          = local.application_users.auth
    "schema-version"        = local.schema_version
    "sql-sha256"            = local.initialization_sql_sha256
    "ssl-mode"              = "verify-full"
    "initialization-target" = jsonencode(local.initialization_target)
  }
}

# The provisioning workflow publishes the receipt after the initializer finishes.
resource "aws_ssm_parameter" "initialized" {
  name  = "/mecanica/${var.environment}/database/v2/initialized"
  type  = "String"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "configuration" {
  for_each = local.configuration
  name     = "/mecanica/${var.environment}/database/v2/${each.key}"
  type     = "String"
  value    = each.value
}
