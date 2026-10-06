mock_provider "aws" {}

variables {
  environment       = "hom"
  base_context_file = "tests/fixtures/hom-base.json"
}

run "hom_instance" {
  command = plan

  assert {
    condition = (aws_db_instance.database.identifier == "mecanica-hom-postgres" &&
      aws_db_instance.database.engine == "postgres" &&
      aws_db_instance.database.engine_version == "16.15" &&
      aws_db_instance.database.instance_class == "db.t3.micro" &&
      aws_db_instance.database.db_name == "mecanica" &&
      aws_db_instance.database.username == "mecanica_admin" &&
      aws_db_instance.database.manage_master_user_password &&
      aws_db_instance.database.port == 5432 &&
      aws_db_instance.database.allocated_storage == 20 &&
      aws_db_instance.database.storage_type == "gp3" &&
      aws_db_instance.database.storage_encrypted &&
    aws_db_instance.database.engine_lifecycle_support == "open-source-rds-extended-support-disabled")
    error_message = "RDS deve usar PostgreSQL 16.15, db.t3.micro, 20 GiB gp3 criptografados e senha gerenciada."
  }

  assert {
    condition = (aws_db_instance.database.publicly_accessible == false &&
      aws_db_instance.database.multi_az == false &&
      aws_db_instance.database.auto_minor_version_upgrade == false &&
      aws_db_instance.database.backup_retention_period == 1 &&
      aws_db_instance.database.skip_final_snapshot &&
    aws_db_instance.database.deletion_protection == false)
    error_message = "A instância educacional deve ser privada, Single-AZ e descartável por operação explícita."
  }

  assert {
    condition = (length(aws_db_subnet_group.database.subnet_ids) == 2 &&
      aws_security_group.database.vpc_id == "vpc-11111111" &&
      length(aws_vpc_security_group_ingress_rule.postgres) == 2 &&
      alltrue([for rule in values(aws_vpc_security_group_ingress_rule.postgres) :
        rule.from_port == 5432 && rule.to_port == 5432 && rule.ip_protocol == "tcp"
    ]))
    error_message = "RDS deve ficar nas subnets do banco e aceitar apenas os SGs de origem na porta 5432."
  }
}

run "prd_instance" {
  command = plan

  variables {
    environment       = "prd"
    base_context_file = "tests/fixtures/prd-base.json"
  }

  assert {
    condition = (aws_db_instance.database.identifier == "mecanica-prd-postgres" &&
      aws_db_subnet_group.database.name == "mecanica-prd-database" &&
      aws_security_group.database.name == "mecanica-prd-postgres" &&
    output.base_dependency.parameter == "/mecanica/prd/base/v1/database-release")
    error_message = "Produção deve ter nomes, rede e dependência próprios."
  }
}

run "cross_environment_snapshot_is_rejected" {
  command = plan
  variables {
    environment       = "prd"
    base_context_file = "tests/fixtures/hom-base.json"
  }
  expect_failures = [terraform_data.base_release]
}
