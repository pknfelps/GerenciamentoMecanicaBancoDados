resource "aws_db_subnet_group" "database" {
  name        = "${local.name_prefix}-database"
  description = "Subnets isoladas do RDS PostgreSQL ${var.environment}"
  subnet_ids  = local.base_exports["database-subnet-ids"]

  tags = { Name = "${local.name_prefix}-database" }

  depends_on = [terraform_data.base_release]
}

# Nenhuma regra de egress é criada. O provider remove o egress amplo que a AWS
# adiciona ao criar um SG; respostas a conexões autorizadas são stateful.
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-postgres"
  description = "RDS PostgreSQL privado ${var.environment}"
  vpc_id      = local.base_exports["vpc-id"]

  tags = { Name = "${local.name_prefix}-postgres" }

  depends_on = [terraform_data.base_release]
}

# API e Job usam atualmente o mesmo SG do cluster EKS. O set evita regra duplicada.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = local.postgres_sources

  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL da origem publicada pela base"

  tags = { Name = "${local.name_prefix}-postgres-from-${each.value}" }
}
