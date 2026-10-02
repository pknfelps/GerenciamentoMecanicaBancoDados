# Aurora por ambiente

`terraform/` define um cluster Aurora PostgreSQL 16.15 Serverless v2 Standard por ambiente, com um writer `db.serverless`, 0–2 ACUs e pausa após 300 segundos sem conexões. O cluster usa as duas subnets isoladas publicadas em `base/v1/database-release`, um security group próprio e acesso PostgreSQL 5432 somente dos security groups de API, função e Job publicados pela base. Não há reader, RDS Proxy ou acesso público. A senha administrativa é gerenciada pelo RDS no Secrets Manager; o Terraform expõe apenas o ARN do segredo.

## Entradas e estado

- `environments/hom.tfvars` e `environments/prd.tfvars` fixam o ambiente e a região.
- `backends/<ambiente>.hcl` usa o bucket compartilhado de estado, mas a chave `<ambiente>/database/terraform.tfstate` isola o banco da base e do outro ambiente. O lock é o arquivo S3 nativo.
- `base_context_file` aponta ao JSON gerado por `scripts/consume_database_release.py capture` na **mesma execução**. O arquivo é temporário, não versionado e não contém senhas.
- A role OIDC `mecanica-<ambiente>-database-github` é a identidade permitida pelo consumidor. Ela precisa de permissões de gerenciamento de Aurora/SG aplicadas no bootstrap antes do plano real.

Não aplicar o Terraform contra uma base ausente. Primeiro executar `base-provision` e publicar `database-release` no ambiente escolhido. A release precisa estar `ready`, com perfil `database`; o consumidor confere VPC, subnets, SGs, EKS, Kubernetes e a role real.

## Validação local sem AWS

```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform test -no-color
```

Os testes usam o provider AWS simulado e fixtures. Não criam recursos nem verificam a conta real.

## Preparação de um plano real

No runner da branch `develop` para `hom` ou `main` para `prd`, com a role OIDC correspondente:

```bash
environment=hom
context="$RUNNER_TEMP/base.json"
python3 scripts/consume_database_release.py capture --environment "$environment" --context "$context"
terraform -chdir=terraform init -backend-config="backends/$environment.hcl"
terraform -chdir=terraform plan -var-file="environments/$environment.tfvars" -var="base_context_file=$context" -out="$RUNNER_TEMP/database.tfplan"
python3 scripts/consume_database_release.py recheck --environment "$environment" --context "$context"
```

O recheck precisa ocorrer de novo imediatamente antes de qualquer `terraform apply` e antes de publicar metadados do banco. Um plano aprovado deve ser refeito se a versão SSM ou qualquer campo da release mudar. A pipeline de aprovação/aplicação ainda não existe; os comandos acima documentam somente a preparação. Não aplicar o plano manualmente como substituto dessa pipeline.

## Limites desta etapa

O cluster vazio não comprova que o banco está pronto para consumidores. O Job de esquema/seeds, as credenciais específicas da API/função, TLS VerifyFull, smoke SQL e publicação de `database/v1/release` permanecem para E2.5/E2.12/E2.14. Não publicar release `ready` com apenas o Terraform aplicado. O banco educacional tem retenção de backup de um dia, proteção contra exclusão desativada e descarte sem snapshot final, conforme a decisão de recriação a partir de SQL.
