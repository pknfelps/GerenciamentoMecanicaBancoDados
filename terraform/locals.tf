locals {
  initialization_sql                 = replace(file("${path.module}/../sql/Init.sql"), "\r\n", "\n")
  initialization_sql_sha256          = sha256(local.initialization_sql)
  schema_version                     = "2.0.0"
  identity_database_name             = "mecanica_identity"
  identity_initialization_sql        = replace(file("${path.module}/../sql/InitIdentity.sql"), "\r\n", "\n")
  identity_initialization_sql_sha256 = sha256(local.identity_initialization_sql)
  identity_schema_version            = "1.0.0"
  name_prefix                        = "mecanica-${var.environment}"
  base_fields = toset([
    "vpc-id", "database-subnet-ids", "cluster-name", "init-namespace",
    "api-security-group-id", "auth-security-group-id", "init-security-group-id"
  ])
  base_exports = { for field, parameter in data.aws_ssm_parameter.base : field => nonsensitive(parameter.value) }
  # Preserva as chaves/enderecos das regras ja existentes no estado.
  postgres_sources = toset([
    local.base_exports["api-security-group-id"],
    local.base_exports["auth-security-group-id"],
    local.base_exports["init-security-group-id"],
  ])
  common_tags = {
    Project     = "mecanica"
    Environment = var.environment
    Component   = "database"
    ManagedBy   = "Terraform"
  }
}

data "aws_ssm_parameter" "base" {
  for_each        = local.base_fields
  name            = "/mecanica/${var.environment}/base/v2/${each.key}"
  with_decryption = false
}
