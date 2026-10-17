# Terraform do RDS e inicialização

RDS/rede mantêm nomes/endereços atuais; postgres16.15, db.t3.micro Single-AZ privado/criptografado, 20GiB gp3, backup um dia, sem upgrade minor automático, sem Extended Support/snapshot final/proteção de descarte. Cada ambiente mantém backend próprio e SG de PostgreSQL com origens API/Job e Lambda publicadas pela base. Set de IDs preserva endereços das regras existentes.

Base consumida por SSM v2, provider Kubernetes obtém endpoint/CA via aws_eks_cluster e token por exec aws eks get-token. Namespace pertence ao manifesto da base e deve existir antes do plan do banco. ConfigMap contém SQL/host/hash/CA pública; Secret usa somente data_wo/revisão positiva. Não usar data comum para senha.

Credenciais API/auth no Secrets Manager: metadados e versões write-only gerenciados pelo Terraform. A adoção hom foi concluída em 2026-10-08 preservando as senhas; seus blocos de importação, leitura de adoção e opção de workflow foram removidos. Novos ambientes geram senha criptográfica ephemeral de 40 caracteres. Versão write-only fixa evita rotação por apply; Secrets Kubernetes recebem AWSCURRENT persistido, não a senha aleatória regenerada. Segredo administrativo continua gerenciado pelo RDS.

Workflows/cleanup/execução local em [README](../README.md). [Job e esquema](SCHEMA.md); [SSM](MANIFESTO_BANCO.md). SQL não é alterado pela reformulação. Bundle público RDS us-east-1 versionado em k8s/rds-ca.pem; atualizar explicitamente esse arquivo em PR quando a AWS mudar autoridades, mantendo verify-full.

Planos normais devem preservar RDS/VPC/EKS e versões de credenciais; a recriação dos três Secrets temporários após cleanup é esperada. Hom foi recuperado e inicializado em 2026-10-08 com plano salvo aprovado. Se a base for recriada em outra VPC, um grupo de subnets RDS antigo precisa ser substituído em plano específico, pois ModifyDBSubnetGroup não aceita transferi-lo entre VPCs. Retirada SSM v1 por import e plano dedicado após migrar consumidores, mantendo históricos.

## Bloqueios de dependência no descarte — 17/10/2026

database-destroy verifica somente API e autenticação: Deployment deploy-gerenciamento-api, HPA hpa-gerenciamento-api, ServiceAccount gerenciamento-api, pods e ReplicaSets da API ausentes em default; Lambda mecanica-<ambiente>-auth, ENIs e regras de saída no SG auth ausentes. Não repete a consulta ao Gateway, já exigida pelos destroys de API/auth. API pode ter zero réplicas e ainda bloquear. SG auth isolado pode permanecer, pois é da base.

As checagens usam AWS CLI/kubectl/jq no workflow, sem scripts ou marcadores SSM. Consulta JSON inválida, falha AWS/Kubernetes ou falta de permissão interrompe. A ausência do cluster só dispensa a inspeção dos objetos da API; o Terraform atual continua dependendo de EKS/SSM para descarte normal. Recuperação após perda indevida dessas dependências exige procedimento separado.

Plan e apply fazem a mesma conferência; no apply ela ocorre antes de remover Job, Secrets ou aplicar o plano salvo. A etapa always de Secrets exige sucesso da checagem e da configuração de acesso Kubernetes, impedindo alterações quando o bloqueio falha. Sem espera automática de ENIs: aguardar a limpeza e repetir a execução quando necessário.

Publicar bootstrap com as permissões de inspeção e autorização da base; aplicar a associação AmazonEKSViewPolicy em default na base; só então utilizar estes workflows. Manter Edit restrito a database-init. Ordem: Gateway -> API/auth -> banco -> base. Base confere RDS, DB subnet group e SG do banco, inclusive recursos residuais de descarte parcial. Nenhum esquema, SQL, credencial, estado ou recurso AWS alterado nesta implementação.
