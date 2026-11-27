# Gerenciamento Mecânica — Banco de dados

RDS PostgreSQL privado provisionado por Terraform, com esquema/seeds SQL e Job Kubernetes de inicialização.

## Fontes e arquitetura

~~~mermaid
flowchart LR
    BASE["Base: rede e EKS / SSM"] -.-> TF
    subgraph REPO["Repositorio do banco"]
        TF["Terraform"]
        SQL["Init.sql, InitIdentity.sql e grants"] --> JOB["Job database-init"]
        TF -.->|ConfigMap e Secrets temporarios| JOB
        TF --> META["Catalogo SSM database/v2"]
    end
    subgraph RDS["RDS PostgreSQL privado"]
        DB[("mecanica")]
        ID[("mecanica_identity")]
    end
    TF -->|provisiona| RDS
    JOB -->|esquema, seeds e grants| DB
    JOB -->|esquema, seeds e grants| ID
    API["API / mecanica_api"] -->|TLS VerifyFull| DB
    AUTH["AuthFunction / mecanica_auth"] -->|TLS VerifyFull| ID
    META -.->|metadados| API
    META -.->|metadados| AUTH
~~~

| Fonte | Responsabilidade |
|---|---|
| [terraform](terraform) | RDS/rede, credenciais, catálogo SSM database/v2 e entradas temporárias do Job |
| [Init.sql](sql/Init.sql) | Esquema operacional 2.1.0 e seeds de mecanica |
| [InitIdentity.sql](sql/InitIdentity.sql) | Esquema 1.0.0 e seeds de mecanica_identity |
| [ProvisionApiUser.sql](sql/ProvisionApiUser.sql) | Credencial e permissões da API |
| [ProvisionAuthUser.sql](sql/ProvisionAuthUser.sql) | Credencial e permissões do database de identidade |
| [database-init.yaml](k8s/database-init.yaml) | Job no namespace database-init |
| [SCHEMA.md](docs/SCHEMA.md) | Estrutura, inicialização e permissões |

A API usa mecanica_api em mecanica. AuthFunction usa mecanica_auth em mecanica_identity, com contas internas, cópia de acesso do cliente, desafios e limites. O Job usa credencial administrativa temporária para criar e conferir os esquemas e conceder os grants. Os serviços correlacionam o cliente pelo UUID da aplicação.

RDS PostgreSQL 16.15/db.t3.micro, Single-AZ, 20 GiB gp3, privado/criptografado e TLS VerifyFull. Terraform 1.15.9 e providers fixados no lockfile. A base fornece rede/EKS/namespace por SSM; o banco não lê estado Terraform de outro repositório.

[Justificativa, relacionamentos e ER](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/BANCO_E_MODELO.md) · [Contratos entre repositórios](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md).

O banco não expõe HTTP. [Swagger/Postman da API](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/postman/README.md) e [contrato da autenticação](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/contracts/openapi.json) pertencem aos respectivos consumidores. Não há Dockerfile próprio; o Job usa a imagem oficial PostgreSQL.

## Execução local

Iniciar PostgreSQL pelo Compose da API e aplicar o SQL em banco vazio, ajustando usuário/porta/database:

~~~bash
psql -h localhost -p 5432 -U postgres -d postgres -W -X -v ON_ERROR_STOP=1 --single-transaction -f sql/Init.sql
~~~

Digitar a senha no prompt. Para ensaio do SQL de identidade, criar um database vazio dedicado e aplicar InitIdentity.sql com as mesmas opções de psql. O Job AWS preenche o marcador de cada database. Usar bancos vazios em novas inicializações.

## Validação e deploy

~~~bash
terraform -chdir=terraform fmt -check
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
kubectl kustomize k8s
~~~

| Workflow | Responsabilidade |
|---|---|
| [ci](.github/workflows/ci.yml) | Valida Terraform/Kustomize em PR, sem provisionar |
| [database-provision](.github/workflows/database-provision.yml) | Plano salvo → aprovação → apply; aguarda o Job, remove Secrets temporários e publica initialized para os dois esquemas |
| [database-destroy](.github/workflows/database-destroy.yml) | Verifica API/auth e resíduos antes do plano/aplicação de descarte |
| [aws-oidc-check](.github/workflows/aws-oidc-check.yml) | Diagnóstico de autenticação OIDC |

database-provision inicia automaticamente por push/merge em develop/hom ou main/prd, mantendo plano salvo → aprovação → apply. O disparo manual permanece disponível; destroy e diagnóstico continuam manuais. AWS_ROLE_ARN nos Environments. Região us-east-1, conta 121754142617. A base deve existir antes do plan do banco. Estados separados por ambiente, locking e aplicação exclusiva do plano aprovado.

Passwords usam recursos ephemeral/write-only; não publicar valores, estados ou TF_LOG. O Job remove suas três credenciais Kubernetes temporárias também em falha. Inicializa somente banco vazio; marcador incompatível interrompe sem reset ou migração automática.

## Ciclo de vida

Provisionar base → banco → Serverless (email antes de auth) → API → Gateway. Descartar Gateway → API/auth → banco/email → base.

skip_final_snapshot=true e ausência de proteção de exclusão refletem banco demonstrativo descartável. O destroy perde cadastros, OSs, histórico e desafios; não há preservação automática por snapshot final. Recursos persistentes do bootstrap têm ciclo independente.
