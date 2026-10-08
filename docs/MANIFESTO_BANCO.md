# Configuração SSM do banco — v2

O antigo manifesto de release foi substituído por recursos aws_ssm_parameter em terraform/metadata.tf. Namespace `/mecanica/<hom|prd>/database/v2/<campo>`, String/Standard, sem senha.

Campos: instance-arn, endpoint, port, database-name, security-group-id, api-secret-arn, api-db-user, auth-secret-arn, auth-db-user, schema-version, sql-sha256, ssl-mode. O ARN administrativo não é publicado aos consumidores. Schema/hash são configuração esperada; initialized_at original permanece apenas no banco.

Sem release.json, jq, publicador, status ready, tentativa, fingerprint ou invalidação prévia por script. SSM não é garantia de conclusão do SQL: consultar resultado do workflow/Job. Configuração pode ter sido criada antes de um Job que falhou; resolver a falha antes de implantar consumidores.

Terraform remove parâmetros v2 no destroy aprovado. Parâmetros v1 ativos serão importados e retirados em planos dedicados após adoção v2; históricos de tentativas preservados. API/função leem data sources Terraform de seu ambiente e resolvem apenas suas credenciais restritas.
