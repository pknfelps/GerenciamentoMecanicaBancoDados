locals {
  application_users = { api = "mecanica_api", auth = "mecanica_auth" }
}

resource "aws_secretsmanager_secret" "application" {
  for_each                = local.application_users
  name                    = "/mecanica/${var.environment}/database/${each.key}"
  recovery_window_in_days = 0
}

ephemeral "random_password" "application" {
  for_each    = local.application_users
  length      = 40
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

resource "aws_secretsmanager_secret_version" "application" {
  for_each                 = local.application_users
  secret_id                = aws_secretsmanager_secret.application[each.key].id
  secret_string_wo_version = 1
  # A revisao fixa preserva a versao existente e evita rotacao em cada execucao.
  secret_string_wo = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.database.address
    port     = aws_db_instance.database.port
    dbname   = aws_db_instance.database.db_name
    username = each.value
    password = ephemeral.random_password.application[each.key].result
  })
}

ephemeral "aws_secretsmanager_secret_version" "application" {
  for_each      = local.application_users
  secret_id     = aws_secretsmanager_secret.application[each.key].arn
  version_stage = "AWSCURRENT"
  # Lê a senha persistida, inclusive depois de criar o secret em ambiente novo.
  depends_on = [aws_secretsmanager_secret_version.application]
}

ephemeral "aws_secretsmanager_secret_version" "admin" {
  secret_id     = aws_db_instance.database.master_user_secret[0].secret_arn
  version_stage = "AWSCURRENT"
}
