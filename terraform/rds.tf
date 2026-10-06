# Uma instância PostgreSQL por ambiente. O banco educacional é recriado a partir
# de SQL em vazio; o descarte continua sendo uma operação explícita e aprovada.
resource "aws_db_instance" "database" {
  identifier     = "${local.name_prefix}-postgres"
  engine         = "postgres"
  engine_version = "16.15"
  instance_class = "db.t3.micro"

  db_name                     = "mecanica"
  username                    = "mecanica_admin"
  manage_master_user_password = true
  port                        = 5432

  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.database.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = false

  auto_minor_version_upgrade = false
  engine_lifecycle_support   = "open-source-rds-extended-support-disabled"
  backup_retention_period    = 1
  skip_final_snapshot        = true
  deletion_protection        = false

  tags = { Name = "${local.name_prefix}-postgres" }

  depends_on = [aws_vpc_security_group_ingress_rule.postgres]
}
