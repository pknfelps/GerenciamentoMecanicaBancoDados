# Gerenciamento Mecânica — Banco de dados

**Estado em 21/10/2026:** fluxo de hom implantado, conferido e posteriormente destruído pelo mantenedor. E5/E6 encerradas no escopo acordado; prd não foi validado. [Encerramento e custos](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/ENCERRAMENTO_E6_E_CUSTOS_2026-10-21.md).

RDS PostgreSQL privado em Terraform; SQL versionado e Job Kubernetes em manifesto próprio. Sem publicadores/wrappers/scripts de teste ou smokes. [Contrato v2](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md).

| Fonte | Responsabilidade |
|---|---|
| terraform | RDS/rede, SSM v2, metadados/versões write-only de credenciais, ConfigMap/Secrets temporários |
| sql/Init.sql | Esquema/seeds 1.0.0, marcador e duas tabelas de autenticação AE.3; banco vazio, sem migrations |
| sql/ProvisionApiUser.sql, ProvisionAuthUser.sql | Usuários/grants já existentes |
| k8s/database-init.yaml | Job estático, namespace reservado database-init |
| k8s/database-access.yaml | Pod temporário de acesso SQL manual; não integra o provisionamento |
| k8s/rds-ca.pem | Bundle público AWS us-east-1 para verify-full |

Terraform 1.15.9/providers AWS 6.58.0, Kubernetes 3.3.0 e random 3.7.2, fixados no lock Windows/Linux. RDS postgres16.15/db.t3.micro/Single-AZ/20GiB gp3; nomes/backends/recursos atuais preservados. Base deve publicar SSM v2 e criar namespace antes do plan do banco. Não consumir estado remoto da base.

## Arquitetura

O banco não expõe HTTP, Swagger ou Postman. Esses contratos pertencem à [API](https://github.com/pknfelps/GerenciamentoMecanicaSistema) e à [autenticação](https://github.com/pknfelps/GerenciamentoMecanicaServerless). Não há Dockerfile próprio: o Job usa a imagem oficial PostgreSQL. A modelagem completa, o ER e a justificativa da escolha estão em [Banco e modelo](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/BANCO_E_MODELO.md).

## Execução local opcional

Para desenvolver localmente, iniciar o PostgreSQL pelo Compose da API. Em banco vazio, a partir deste repositório, aplicar o SQL com o cliente padrão; ajustar porta, usuário e banco à configuração local:

```bash
psql -h localhost -p 5432 -U postgres -d postgres -W -X -v ON_ERROR_STOP=1 --single-transaction -f sql/Init.sql
```

Digitar a senha no prompt. O SQL contém seeds educacionais; não o reaplicar sobre dados existentes. A execução manual cria a tabela de inicialização, mas não seu registro operacional: esse registro pertence ao Job AWS. Não confundir a preparação local com execução do provisionamento remoto.

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

## Acesso SQL temporário

Com base/banco inicializados, o manifesto `k8s/database-access.yaml` disponibiliza somente o cliente psql no namespace `database-init`. Reutiliza endpoint e certificado público do ConfigMap `database-init-input`, com usuário `mecanica_api` e TLS `verify-full`. Não executa Init.sql, não provisiona usuários e não altera o deploy da API. Não é incluído no Kustomize ou nos workflows.

```bash
aws eks update-kubeconfig --profile mecanica --region us-east-1 --name mecanica-hom-eks --kubeconfig ./database-kubeconfig
kubectl --kubeconfig ./database-kubeconfig apply -f k8s/database-access.yaml
kubectl --kubeconfig ./database-kubeconfig -n database-init wait --for=condition=Ready pod/database-access --timeout=120s
kubectl --kubeconfig ./database-kubeconfig -n database-init exec -it database-access -- psql -X -W
```

Na sessão manual, obter a senha atual de `/mecanica/hom/database/api` no console Secrets Manager com uma identidade autorizada e digitá-la somente no prompt do psql. Não salvar no YAML, argumento de comando ou documentação. O acesso EKS do usuário IAM `mecanica` não concede automaticamente leitura do Secret; autenticação e grants PostgreSQL continuam separados. O usuário de banco da API já permite SELECT no histórico e UPDATE em customers; não é necessário usar o administrador para essas validações.

Encerrar o psql com `\q` e remover o Pod, inclusive se a validação falhar:

```bash
kubectl --kubeconfig ./database-kubeconfig -n database-init delete pod database-access --ignore-not-found=true --wait=true
```

O Pod tem limite de execução de uma hora; após o prazo pode permanecer como objeto concluído/falho, portanto a exclusão explícita continua necessária. Não cria Service, porta pública, volume persistente, identidade AWS ou Secret Kubernetes. Na execução automatizada autorizada, a senha pode ser entregue apenas pela entrada da sessão exec, mantendo-a fora do manifesto e dos logs. No Windows, essa entrada deve preservar os bytes, sem acrescentar CR à senha por conversão CRLF. Alterações SQL confirmadas permanecem após excluir o Pod.

Conferência hom em 14/10/2026: conexão mecanica_api/TLSv1.3, inativação de cliente fictício, bloqueio de nova autenticação sem revogar JWT anterior e 44 eventos históricos de doze OSs conferidos, incluindo preservação após DELETE. Foram aprovadas 141 verificações, com 29 chamadas pelo Gateway. Pod removido, nenhum Secret temporário criado; sem novo deploy da API ou alteração de grants/esquema/IAM. A execução não comprova prd ou acesso administrativo geral ao banco.

## Dados e descarte

Job inicializa apenas banco vazio. Marcador idêntico preserva initialized_at e evita seeds repetidos; SQL incompatível/tabelas sem marcador interrompem. Depois provisiona API/auth com grants atuais. Sem teste SQL adicional e sem migração incremental em startup. [Esquema](docs/SCHEMA.md).

database-destroy também tem plan/approval/apply; remove Job antes do apply. RDS de demonstração mantém skip_final_snapshot=true; exclusão é explícita e perde dados. Descartar consumidores antes, base depois. Não executar destroy para testar a reformulação.

- [Terraform e credenciais](docs/RDS_TERRAFORM.md)
- [Consumo da base](docs/CONSUMO_BASE.md)
- [Configuração publicada](docs/MANIFESTO_BANCO.md)
- [Migração](https://github.com/pknfelps/GerenciamentoMecanicaInfraestrutura/blob/develop/docs/MIGRACAO_DECLARATIVA.md)

O fluxo declarativo, a inicialização e as credenciais foram conferidos em hom nas execuções registradas. A conferência SQL direta confirmou histórico e cliente Inativo. O [encerramento E6](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/ENCERRAMENTO_E6_E_CUSTOS_2026-10-21.md) registra o descarte e os resíduos persistentes; não há endpoint RDS ativo a publicar neste README.

## Bloqueios no database-destroy — 17/10/2026

O workflow verifica somente recursos Kubernetes da API e autenticação antes do plan e novamente antes das exclusões no apply. Não consulta Gateway, cuja remoção é exigida nos destroys de API/auth. Função auth, ENIs ou regras de saída remanescentes bloqueiam imediatamente. Erros de consulta não são tratados como ausência. A limpeza always dos Secrets só pode executar depois de as dependências serem aprovadas e o acesso Kubernetes estar configurado.

Pré-requisito: bootstrap revisado aplicado e base com AmazonEKSViewPolicy em default para esta pipeline, preservando Edit somente em database-init. EKS permanece até a base ser descartada; API com zero réplicas ainda bloqueia enquanto seus recursos existirem. [Procedimento](docs/RDS_TERRAFORM.md). Esta alteração não automatiza recuperação do banco quando EKS/SSM já desapareceram.

## Ordem operacional e evidências

Provisionar base → banco/Job → API e autenticação → Gateway. Destruir Gateway → API e autenticação → banco → base; API e autenticação podem ser removidas independentemente depois do Gateway. Os bloqueios não coordenam execuções concorrentes. Bootstrap, artefatos, dashboards e demais recursos persistentes não pertencem a este destroy.

- [Esquema e relacionamentos](docs/SCHEMA.md)
- [Revisão documental E7](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/REVISAO_DOCUMENTACAO_E7_2026-10-21.md)
- [Validação integrada e limites aceitos da E5](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/ENCERRAMENTO_E5_2026-10-21.md)

As definições hom/prd são versionadas, mas isso não comprova operação em prd ou coexistência. Não há promessa de recuperação dos dados após destroy; o snapshot manual histórico identificado no encerramento tem ciclo de vida próprio.


## Extra planejado — desafios de autenticação

AE.3 revisada em 22/10/2026: [duas tabelas diretamente no Init.sql e índices comuns](docs/AE3_TABELAS_AUTENTICACAO_2026-10-22.md), sem migrations, CHECKs de negócio, unicidade por estado ou cascata. Limites usam customer_id; cliente inexistente encerra antes de qualquer gravação, com log sanitizado na autenticação. O Job/ConfigMap já carregam Init.sql e calculam seu novo hash; sem novos passos de workflow. Grants e operações C# permanecem pendentes. Nenhuma aplicação AWS; EmailFunction continua sem acesso ao banco. [Plano extra](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/PLANO_EXTRA_AUTENTICACAO_E_EMAIL.md).
