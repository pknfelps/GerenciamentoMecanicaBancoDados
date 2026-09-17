# Referência da Fase 2 — PostgreSQL no EKS

Manifestos preservados para rastrear a separação; não compõem o deploy da Fase 3 e não devem ser aplicados isoladamente. O Deployment depende do Secret `db-secrets`, do ConfigMap `postgres-init-script`, do PVC e do driver EBS.

O script original agora está em `sql/Init.sql` na raiz deste repositório. Não há uma segunda cópia de SQL nem Kustomize ativo para esses recursos. O destino de nuvem é Aurora, a implementar em E2; o desenvolvimento local continua no Docker Compose da aplicação.
