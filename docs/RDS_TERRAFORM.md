# Terraform do RDS e inicialização

RDS/rede mantêm nomes/endereços atuais; postgres16.15, db.t3.micro Single-AZ privado/criptografado, 20GiB gp3, backup um dia, sem upgrade minor automático, sem Extended Support/snapshot final/proteção de descarte. Cada ambiente mantém backend próprio e SG de PostgreSQL com origens API/Job e Lambda publicadas pela base. Set de IDs preserva endereços das regras existentes.

Base consumida por SSM v2, provider Kubernetes obtém endpoint/CA via aws_eks_cluster e token por exec aws eks get-token. Namespace pertence ao manifesto da base e deve existir antes do plan do banco. ConfigMap contém SQL/host/hash/CA pública; Secret usa somente data_wo/revisão positiva. Não usar data comum para senha.

Credenciais API/auth no Secrets Manager: metadados importáveis sem valores; primeira adoção preserva AWSCURRENT com leitura ephemeral e gravação secret_string_wo. Novos ambientes geram senha criptográfica ephemeral de 40 caracteres. Versão write-only fixa evita rotação por apply; Secrets Kubernetes recebem AWSCURRENT persistido, não a senha aleatória regenerada. Segredo administrativo continua gerenciado pelo RDS.

Workflows/cleanup/execução local em [README](../README.md). [Job e esquema](SCHEMA.md); [SSM](MANIFESTO_BANCO.md). SQL não é alterado pela reformulação. Bundle público RDS us-east-1 versionado em k8s/rds-ca.pem; atualizar explicitamente esse arquivo em PR quando a AWS mudar autoridades, mantendo verify-full.

Primeiro plan deve preservar RDS/VPC/EKS; novos objetos temporários esperados. Sem planos/applies remotos nesta implementação. Retirada SSM v1 por import e plano dedicado após migrar consumidores, mantendo históricos.
