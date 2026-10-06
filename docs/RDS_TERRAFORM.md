# RDS PostgreSQL por ambiente — Terraform

O módulo `terraform/` define uma instância RDS for PostgreSQL 16.15 `db.t3.micro` Single-AZ por ambiente, com 20 GiB gp3 criptografados. O DB subnet group usa as duas subnets de banco de `base/v1/database-release`; a instância fica em uma AZ, sem acesso público. O SG próprio aceita TCP 5432 somente dos SGs efetivos de API, função e Job publicados pela base. Não há réplica, RDS Proxy ou auto-pause. O RDS gera e gerencia a senha administrativa no Secrets Manager; Terraform expõe apenas seu ARN.

O banco é educacional e descartável: backup por um dia, sem proteção contra exclusão e sem snapshot final no destroy aprovado. Isso não remove snapshots alheios. O Terraform fixa `auto_minor_version_upgrade=false` e desabilita a inscrição automática no RDS Extended Support. Em 2026-10-05, `DescribeOrderableDBInstanceOptions` confirmou na conta `121754142617`, região `us-east-1`, a combinação `postgres` 16.15 + `db.t3.micro` + gp3 em VPC. Essa consulta de catálogo não substitui o plano nem o apply aprovado.

## Entradas, saídas e validação

- `environments/hom.tfvars` e `environments/prd.tfvars` fixam ambiente e região. Os backends S3 separam estados por ambiente e componente.
- `base_context_file` é o snapshot temporário de `scripts/consume_database_release.py capture`. A pré-condição confere ambiente, conta, região, perfil e geração da base antes da criação.
- Outputs: `instance_arn`, `endpoint` (hostname, sem porta), `port`, `database_name`, `security_group_id`, `admin_secret_arn` e `base_dependency`. `instance_arn` substituirá o antigo campo `cluster-arn` da **release do banco**; os campos `cluster-name`/`cluster-arn` da **base** continuam sendo do EKS.
- `terraform fmt -check -recursive`, `init -backend=false`, `validate` e `test` devem passar. Os testes usam provider simulado e não criam recursos AWS.

## Próximas dependências

IAM e workflows RDS estão adaptados (infraestrutura ea3bdf8; banco 145ae28 integrado em 5b8edcf). O mantenedor confirmou provisionamento e destroy com sucesso em 06/10/2026. Não há necessidade de refazer a migração Aurora. O esquema da Fase 3 está em [SCHEMA.md](SCHEMA.md), com Init.sql e smoke atualizados; a API antiga ainda precisa de adaptação.

Depois do apply aprovado, a instância vazia ainda não é uma release pronta. Faltam Job SQL/seeds, usuários limitados da API/função, conexão TLS `VerifyFull`, smoke SQL e publicação de `database/v1/release`. Medir CPU, memória e conexões do micro com probes/HPA e concorrência da função.

Fontes: [versões PostgreSQL no RDS](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html), [classes/versões disponíveis por região](https://docs.aws.amazon.com/cli/latest/reference/rds/describe-orderable-db-instance-options.html), [criação em VPC](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.html), [SSL no PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html).
