mock_provider "aws" {}

variables {
  environment       = "hom"
  base_context_file = "tests/fixtures/hom-base.json"
}

run "hom_cluster" {
  command = plan

  assert {
    condition = (aws_rds_cluster.database.cluster_identifier == "mecanica-hom-aurora" &&
      aws_rds_cluster.database.engine == "aurora-postgresql" &&
      aws_rds_cluster.database.engine_mode == "provisioned" &&
      aws_rds_cluster.database.engine_version == "16.15" &&
      aws_rds_cluster.database.storage_type == "aurora" &&
      aws_rds_cluster.database.storage_encrypted &&
      aws_rds_cluster.database.manage_master_user_password &&
      aws_rds_cluster.database.serverlessv2_scaling_configuration[0].min_capacity == 0 &&
      aws_rds_cluster.database.serverlessv2_scaling_configuration[0].max_capacity == 2 &&
    aws_rds_cluster.database.serverlessv2_scaling_configuration[0].seconds_until_auto_pause == 300)
    error_message = "O cluster deve usar Aurora PostgreSQL Serverless v2 Standard, 0–2 ACUs e senha gerenciada."
  }

  assert {
    condition = (aws_rds_cluster_instance.writer.instance_class == "db.serverless" &&
    aws_rds_cluster_instance.writer.publicly_accessible == false)
    error_message = "Somente um writer privado db.serverless deve existir."
  }

  assert {
    condition = (length(aws_db_subnet_group.database.subnet_ids) == 2 &&
      aws_security_group.aurora.vpc_id == "vpc-11111111" &&
      length(aws_vpc_security_group_ingress_rule.postgres) == 2 &&
      alltrue([for rule in values(aws_vpc_security_group_ingress_rule.postgres) :
        rule.from_port == 5432 && rule.to_port == 5432 && rule.ip_protocol == "tcp"
    ]))
    error_message = "Aurora deve ficar nas subnets do banco e aceitar apenas os SGs de origem na porta 5432."
  }
}

run "prd_cluster" {
  command = plan
  variables {
    environment       = "prd"
    base_context_file = "tests/fixtures/prd-base.json"
  }
  assert {
    condition = (aws_rds_cluster.database.cluster_identifier == "mecanica-prd-aurora" &&
      aws_db_subnet_group.database.name == "mecanica-prd-database" &&
      aws_security_group.aurora.name == "mecanica-prd-aurora" &&
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
