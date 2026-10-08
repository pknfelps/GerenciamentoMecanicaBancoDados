# Gerenciamento Mecanica — Banco

RDS PostgreSQL privado em Terraform; SQL versionado e Job Kubernetes em manifesto próprio. Sem publicadores/wrappers/scripts de teste ou smokes. [Contrato v2](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md).

| Fonte | Responsabilidade |
|---|---|
| terraform | RDS/rede, SSM v2, metadados/versões write-only de credenciais, ConfigMap/Secrets temporários |
| sql/Init.sql | Esquema/seeds 1.0.0 e tabela schema_initialization, preservados |
| sql/ProvisionApiUser.sql, ProvisionAuthUser.sql | Usuários/grants já existentes |
| k8s/database-init.yaml | Job estático, namespace reservado database-init |
| k8s/rds-ca.pem | Bundle público AWS us-east-1 para verify-full |

Terraform 1.15.9/providers AWS 6.58.0, Kubernetes 3.3.0 e random 3.7.2, fixados no lock Windows/Linux. RDS postgres16.15/db.t3.micro/Single-AZ/20GiB gp3; nomes/backends/recursos atuais preservados. Base deve publicar SSM v2 e criar namespace antes do plan do banco. Não consumir estado remoto da base.

## Provisionamento

PR/CI: fmt, init sem backend, validate e Kustomize; sem aplicação. Workflow manual database-provision: plan salvo/texto → aprovação protegida hom-approval/prd-approval, sem AWS → apply exato, com OIDC novo e mesmo commit/artefato. Retenção sete dias; estado alterado exige nova execução. Hom/develop, prd/main; AWS_ROLE_ARN no Environment e conta 121754142617/us-east-1.

**Credenciais:** a adoção de API/auth em hom foi concluída em 2026-10-08, preservando as senhas. O fluxo normal não tem opção de adoção. Revisão write-only fixa em 1 preserva a versão gerenciada e evita rotação em cada execução; ambientes novos recebem credenciais geradas por recurso ephemeral. Secrets Kubernetes usam AWSCURRENT persistido. Nunca importar versões comuns de Secret nem usar data source comum para seus valores.

Apply entrega ConfigMap e Secrets administrativos/API/auth temporários. kubectl remove Job antigo, aplica YAML e aguarda Complete; falha exibe logs/describe. Cleanup always remove os três Secrets, também em erro. Terraform detecta ausência no refresh seguinte e os recria com AWSCURRENT. Senhas não aparecem em plano/estado/outputs; não habilitar TF_LOG nem imprimir credenciais. A role da API só tem Edit em default, sem acessar database-init.

Para operação local autorizada, usar os mesmos comandos diretos após init/plan/revisão/apply salvo, com AWS autenticado no ambiente e kubeconfig isolado:

```bash
aws eks update-kubeconfig --region us-east-1 --name mecanica-hom-eks --kubeconfig ./database-kubeconfig
kubectl --kubeconfig ./database-kubeconfig -n database-init delete job database-init --ignore-not-found=true --wait=true
kubectl --kubeconfig ./database-kubeconfig apply -f k8s/database-init.yaml
kubectl --kubeconfig ./database-kubeconfig -n database-init wait --for=condition=complete job/database-init --timeout=900s
kubectl --kubeconfig ./database-kubeconfig -n database-init logs job/database-init
# Executar ao final tambem em caso de erro nas etapas anteriores:
kubectl --kubeconfig ./database-kubeconfig -n database-init delete secret database-init-admin database-init-api database-init-auth --ignore-not-found=true
```

Não deixar credenciais temporárias após apply local que não execute o Job. Falha de conexão Kubernetes não autoriza imprimir Secret; recuperar acesso e executar cleanup.

## Dados e descarte

Job inicializa apenas banco vazio. Marcador idêntico preserva initialized_at e evita seeds repetidos; SQL incompatível/tabelas sem marcador interrompem. Depois provisiona API/auth com grants atuais. Sem teste SQL adicional e sem migração incremental em startup. [Esquema](docs/SCHEMA.md).

database-destroy também tem plan/approval/apply; remove Job antes do apply. RDS de demonstração mantém skip_final_snapshot=true; exclusão é explícita e perde dados. Descartar consumidores antes, base depois. Não executar destroy para testar a reformulação.

- [Terraform e credenciais](docs/RDS_TERRAFORM.md)
- [Consumo da base](docs/CONSUMO_BASE.md)
- [Configuração publicada](docs/MANIFESTO_BANCO.md)
- [Migração](https://github.com/pknfelps/GerenciamentoMecanicaInfraestrutura/blob/develop/docs/MIGRACAO_DECLARATIVA.md)

Recuperação hom concluída em 2026-10-08 com plano aprovado: grupo de subnets recriado na VPC nova, RDS disponível, Job concluído e credenciais temporárias removidas. A retirada da opção de adoção está validada localmente e segue pelo fluxo de PR/pipeline do usuário.
