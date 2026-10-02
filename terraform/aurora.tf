# Aurora Serverless v2 usa engine_mode provisioned e uma instancia db.serverless.
# A senha administrativa é gerada/rotacionada pelo RDS no Secrets Manager.
resource "aws_rds_cluster" "database" {
  cluster_identifier          = "${local.name_prefix}-aurora"
  engine                      = "aurora-postgresql"
  engine_mode                 = "provisioned"
  engine_version              = "16.15"
  database_name               = "mecanica"
  master_username             = "mecanica_admin"
  manage_master_user_password = true

  port                   = 5432
  db_subnet_group_name   = aws_db_subnet_group.database.name
  vpc_security_group_ids = [aws_security_group.aurora.id]
  storage_type           = "aurora"
  storage_encrypted      = true

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 2
    seconds_until_auto_pause = 300
  }

  # Banco educacional recriado a partir de SQL em vazio; descarte é operação
  # explícita e coordenada depois dos consumidores, sem snapshot final.
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "${local.name_prefix}-aurora" }

  depends_on = [aws_vpc_security_group_ingress_rule.postgres]
}

resource "aws_rds_cluster_instance" "writer" {
  identifier                 = "${local.name_prefix}-aurora-writer"
  cluster_identifier         = aws_rds_cluster.database.id
  instance_class             = "db.serverless"
  engine                     = aws_rds_cluster.database.engine
  engine_version             = aws_rds_cluster.database.engine_version
  db_subnet_group_name       = aws_db_subnet_group.database.name
  publicly_accessible        = false
  auto_minor_version_upgrade = false

  tags = { Name = "${local.name_prefix}-aurora-writer" }
}
