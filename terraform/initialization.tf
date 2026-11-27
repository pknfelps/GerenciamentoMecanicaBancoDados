resource "kubernetes_config_map_v1" "initialization" {
  metadata {
    name      = "database-init-input"
    namespace = local.base_exports["init-namespace"]
  }
  data = {
    PGHOST                       = aws_db_instance.database.address
    PGDATABASE                   = aws_db_instance.database.db_name
    SCHEMA_VERSION               = local.schema_version
    SQL_SHA256                   = local.initialization_sql_sha256
    IDENTITY_DATABASE            = local.identity_database_name
    IDENTITY_SCHEMA_VERSION      = local.identity_schema_version
    IDENTITY_SQL_SHA256          = local.identity_initialization_sql_sha256
    "Init.sql"                   = local.initialization_sql
    "InitIdentity.sql"           = local.identity_initialization_sql
    "InitializeDatabase.sql"     = file("${path.module}/../sql/InitializeDatabase.sql")
    "CreateIdentityDatabase.sql" = file("${path.module}/../sql/CreateIdentityDatabase.sql")
    "ProvisionApiUser.sql"       = file("${path.module}/../sql/ProvisionApiUser.sql")
    "ProvisionAuthUser.sql"      = file("${path.module}/../sql/ProvisionAuthUser.sql")
    "rds-ca.pem"                 = file("${path.module}/../k8s/rds-ca.pem")
  }
}

# Removidos por kubectl ao terminar o Job; o refresh os recria no proximo apply.
resource "kubernetes_secret_v1" "admin" {
  metadata {
    name      = "database-init-admin"
    namespace = local.base_exports["init-namespace"]
  }
  type             = "Opaque"
  data_wo_revision = 1
  data_wo          = { password = jsondecode(ephemeral.aws_secretsmanager_secret_version.admin.secret_string).password }
}

resource "kubernetes_secret_v1" "application" {
  for_each = local.application_users
  metadata {
    name      = "database-init-${each.key}"
    namespace = local.base_exports["init-namespace"]
  }
  type             = "Opaque"
  data_wo_revision = 1
  data_wo          = { password = jsondecode(ephemeral.aws_secretsmanager_secret_version.application[each.key].secret_string).password }
}
