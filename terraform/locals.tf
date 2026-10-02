locals {
  name_prefix = "mecanica-${var.environment}"

  # O snapshot é produzido pelo consumidor que verifica contrato, recursos e role real.
  base_context = jsondecode(file(var.base_context_file))
  base_release = local.base_context.manifest
  base_exports = local.base_release.exports

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

# Esta pré-condição falha antes de criar qualquer recurso quando o arquivo foi
# trocado, pertence a outro ambiente ou não representa a release requerida.
resource "terraform_data" "base_release" {
  input = {
    parameter     = local.base_context.parameter
    ssm_version   = local.base_context.ssmVersion
    deployment_id = local.base_release.deploymentId
    generation    = local.base_release.generation
    source_commit = local.base_release.source.commit
  }

  lifecycle {
    precondition {
      condition = try(
        local.base_context.parameter == "/mecanica/${var.environment}/base/v1/database-release" &&
        local.base_context.ssmVersion > 0 &&
        startswith(local.base_release.schemaVersion, "1.") &&
        tonumber(split(".", local.base_release.schemaVersion)[1]) >= 1 &&
        local.base_release.environment == var.environment &&
        local.base_release.component == "base" &&
        local.base_release.accountId == "121754142617" &&
        local.base_release.region == var.aws_region &&
        local.base_release.status == "ready" &&
        local.base_release.readinessProfile == "database" &&
        length(local.base_exports["database-subnet-ids"]) == 2 &&
        length(distinct(local.base_exports["database-subnet-ids"])) == 2 &&
        local.base_context.dependencies.base.parameter == local.base_context.parameter &&
        local.base_context.dependencies.base.deploymentId == local.base_release.deploymentId &&
        local.base_context.dependencies.base.generation == local.base_release.generation &&
        local.base_context.dependencies.base.sourceCommit == local.base_release.source.commit,
        false
      )
      error_message = "Snapshot da base invalido; capture e confira database-release do ambiente novamente."
    }
  }
}
