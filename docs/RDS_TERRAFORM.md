# RDS PostgreSQL por ambiente — Terraform

O módulo `terraform/` define uma instância RDS for PostgreSQL 16.15 `db.t3.micro` Single-AZ por ambiente, com 20 GiB gp3 criptografados. O DB subnet group usa as duas subnets de banco de `base/v1/database-release`; a instância fica em uma AZ, sem acesso público. O SG próprio aceita TCP 5432 somente dos SGs efetivos de API, função e Job publicados pela base. Não há réplica, RDS Proxy ou auto-pause. O RDS gera e gerencia a senha administrativa no Secrets Manager; Terraform expõe apenas seu ARN.

O banco é educacional e descartável: backup por um dia, sem proteção contra exclusão e sem snapshot final no destroy aprovado. Isso não remove snapshots alheios. O Terraform fixa `auto_minor_version_upgrade=false` e desabilita a inscrição automática no RDS Extended Support. Em 2026-10-05, `DescribeOrderableDBInstanceOptions` confirmou na conta `121754142617`, região `us-east-1`, a combinação `postgres` 16.15 + `db.t3.micro` + gp3 em VPC. Essa consulta de catálogo não substitui o plano nem o apply aprovado.

## Entradas, saídas e validação

- `environments/hom.tfvars` e `environments/prd.tfvars` fixam ambiente e região. Os backends S3 separam estados por ambiente e componente.
- `base_context_file` é o snapshot temporário de `scripts/consume_database_release.py capture`. A pré-condição confere ambiente, conta, região, perfil e geração da base antes da criação.
- Outputs: `instance_arn`, `endpoint` (hostname, sem porta), `port`, `database_name`, `security_group_id`, `admin_secret_arn` e `base_dependency`. `instance_arn` substituirá o antigo campo `cluster-arn` da **release do banco**; os campos `cluster-name`/`cluster-arn` da **base** continuam sendo do EKS.
- `terraform fmt -check -recursive`, `init -backend=false`, `validate` e `test` devem passar. Os testes usam provider simulado e não criam recursos AWS.

## Inicialização no EKS

Após o apply do RDS, `database-provision` usa os comandos Bash do próprio workflow para preparar e esperar o Job definido em [k8s/database-init.yaml](../k8s/database-init.yaml). O workflow confere endpoint, banco e ARN do segredo com a instância RDS, baixa o bundle CA oficial, cria um ConfigMap temporário com `Init.sql`/smoke/CA e uma Secret Kubernetes temporária com a senha administrativa. Antes de cada execução, remove o Job anterior para que o Kubernetes crie um novo pod. O bootstrap da infraestrutura deve aplicar `bootstrap/database-init-secret-read.tf` antes da primeira ativação com Job.

O único container PostgreSQL 16.15 recebe a senha pela Secret Kubernetes, conecta com `verify-full`, aplica o SQL e grava `1.0.0` mais SHA-256 na mesma transação; depois executa `tests/smoke.sql`. A senha passa pelo runner durante o workflow, mas não entra em Terraform, ConfigMap, manifesto versionado ou logs. O workflow remove os arquivos temporários, o ConfigMap e a Secret ao terminar; o Job expira após um dia.

Se o registro corresponder ao SQL atual, o Job só repete o smoke. Se houver tabelas sem registro, hash diferente ou smoke com erro, a ativação falha sem publicar release pronta. Examine `kubectl -n default describe job/database-init` e os logs do Job para diagnosticar. O banco continua educacional e descartável; alterações de esquema exigem recriação explícita, não migração automática.

## Próximas dependências

IAM e workflows RDS estão adaptados (infraestrutura ea3bdf8; banco 145ae28 integrado em 5b8edcf). O mantenedor confirmou provisionamento e destroy com sucesso em 06/10/2026. Não há necessidade de refazer a migração Aurora. O esquema da Fase 3 está em [SCHEMA.md](SCHEMA.md), com Init.sql e smoke atualizados; a API antiga ainda precisa de adaptação.

O Job e o smoke estão integrados ao apply, mas ainda precisam de execução real no runner após aplicar o bootstrap. Usuários limitados da API/função, validação da conexão dos consumidores e publicação de `database/v1/release` seguem pendentes. Medir CPU, memória e conexões do micro com probes/HPA e concorrência da função.

Fontes: [versões PostgreSQL no RDS](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html), [classes/versões disponíveis por região](https://docs.aws.amazon.com/cli/latest/reference/rds/describe-orderable-db-instance-options.html), [criação em VPC](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.html), [SSL no PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html).
