# Consumo da base

`terraform/locals.tf` lê via data.aws_ssm_parameter `/mecanica/<ambiente>/base/v2/`: vpc-id, database-subnet-ids, cluster-name, init-namespace, api-security-group-id, auth-security-group-id, init-security-group-id. Subnets usam JSON; IDs públicos podem ser retirados da marca sensitive com nonsensitive.

Sem snapshot JSON, consumidor Python, candidato, release ou evidência de acesso. Base deve ter apply bem-sucedido e namespace database-init disponível antes do plan. O workflow/Job comprovam acesso operacional; parâmetros não declaram prontidão.

Banco tem AmazonEKSEditPolicy apenas em database-init; API apenas em default. SGs efetivos API/Job ainda podem coincidir; isolamento Kubernetes de Secrets não equivale a isolamento de rede por namespace. Banco administra entrada PostgreSQL 5432, Lambda usa seu SG reservado.

Não ler terraform_remote_state de outro repositório. Mantenedor serializa operações do ambiente; mudança de base exige novo plan do banco. Adoção/retirada v1 segue [migração](https://github.com/pknfelps/GerenciamentoMecanicaInfraestrutura/blob/develop/docs/MIGRACAO_DECLARATIVA.md).
