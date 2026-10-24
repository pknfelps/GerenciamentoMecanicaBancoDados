# Referência da Fase 2 — PostgreSQL no EKS

Manifestos preservados para rastrear a separação; não compõem o deploy da Fase 3 e não devem ser aplicados isoladamente. O Deployment depende do Secret `db-secrets`, do ConfigMap `postgres-init-script`, do PVC e do driver EBS.

O script original agora está em `sql/Init.sql` na raiz deste repositório. Não há uma segunda cópia de SQL nem Kustomize ativo para esses recursos. A implantação vigente usa RDS PostgreSQL privado e inicialização pelo Job `database-init`, conforme o [README principal](../../README.md). O desenvolvimento local usa o Docker Compose da aplicação; estes manifestos históricos não participam desse fluxo.
