# Esquema SQL 1.0.0 — Fase 3

Fonte: `sql/Init.sql`. Criação completa em banco vazio, com seeds; não é migração,
não apaga dados existentes e não deve ser reaplicada em cada deploy/startup.
Executar com `psql -X --set=ON_ERROR_STOP=on --single-transaction --file=sql/Init.sql`.
A versão está definida no cabeçalho do SQL; SSM v2 publica configuração esperada, sem release de prontidão.
O hash do esquema continua sendo SHA-256 dos bytes de `sql/Init.sql`.

O Job EKS usa `schema_initialization` como registro operacional: grava
`1.0.0`, SHA-256 e horário no mesmo commit do esquema/seeds. Essa tabela
não pertence ao domínio da API e não deve ser escrita pela aplicação. O
`Init.sql` executado manualmente apenas cria a tabela; o registro é gravado
pelo Job. Em uma ativação repetida, o Job exige exatamente um registro com
versão e hash atuais antes de provisionar os usuários/grants. Não há SQLs de smoke na operação declarativa.

## Contrato de persistência

- `users.role`: `Admin` ou `Mechanic`. UUIDs identificam os usuários. Seeds
  educacionais: `Admin` / `Admin@123` e `Mechanic` / `Mechanic@123`, com hashes
  PBKDF2-SHA256, 100.000 iterações, salt de 16 bytes e hash de 32 bytes.
- `customers.status`: `Active` (Ativo) ou `Inactive` (Inativo), obrigatório,
  padrão `Active`. A API deve sempre criar clientes ativos e não expor edição
  desse campo no PATCH genérico. A Lambda consulta esse valor junto do UUID
  e documento. Documento permanece canônico, mascarado e UNIQUE, aceitando
  CPF/CNPJ conforme validação do domínio.
- `orders.status` mantém o estado atual. `date_created`, `date_finished` e
  `duration` foram removidos; datas e durações devem ser projetadas pelo histórico.
- `order_status_history`: `id` UUID do evento, `order_id` UUID estável da OS,
  `sequence` inteiro, `previous_status` nullable, `new_status`,
  `occurred_at` TIMESTAMPTZ e `reason` opcional. O instante é explícito, sem
  data artificial; a aplicação envia UTC. A exibição pelo PostgreSQL depende
  do fuso da sessão. A aplicação consulta com `ORDER BY occurred_at, sequence`.

| Transição | Motivo obrigatório |
|---|---|
| criação → Received (sequence=1) | nenhum |
| Received → InDiagnosis | nenhum |
| InDiagnosis → WaitingForApproval | nenhum |
| WaitingForApproval → WaitingForExecution | nenhum |
| WaitingForExecution → InExecution | nenhum |
| InExecution → Finished | ServiceCompleted |
| WaitingForApproval → Finished | BudgetRejected |
| Finished → Delivered | nenhum |

Esses estados e motivos são regras da API; o SQL não os restringe com CHECK.
A aplicação também valida sequências positivas, únicas e sem saltos por OS,
instantes finitos e não regressivos. OS de demonstração devem ser geradas
pelos fluxos da API; não há seeds de OS nem histórico fabricado.

## Histórico, exclusão e concorrência

A pedido do usuário, o SQL não contém os CONSTRAINT nomeados de roles, status,
sequência, tempo ou transições, nem o índice do histórico. As chaves primárias,
FKs, NOT NULL e UNIQUE do esquema anterior permanecem; o novo histórico mantém
`id` como chave primária. A validação das regras de domínio e a prevenção de
sequências duplicadas são implementadas na aplicação. Sem índice, a consulta ao
histórico pode exigir varredura/ordenação; reavaliar com dados e métricas reais.

`order_status_history.order_id` não tem FK para `orders`. Isso é intencional:
excluir uma OS não pode apagar seu histórico, bloquear o DELETE ou perder o UUID
de correlação. As FKs existentes de clientes, veículos e itens são preservadas.
O SQL não implementa triggers de domínio nem uma FK alternativa que exija a
permanência da OS. Portanto a aplicação é responsável por:

1. Criar OS e evento Received com sequence=1 na mesma transação.
2. Bloquear a OS antes da transição (por exemplo SELECT FOR UPDATE), conferir
   estado atual/último evento e usar a próxima sequência, sem saltos.
3. Gravar novo status e evento na mesma transação. A API deve impedir
   sequências duplicadas e validar o estado anterior; o SQL não contém UNIQUE
   `(order_id, sequence)` nem CHECK de transições.
4. Rejeitar instantes regressivos, aceitar instantes iguais com desempate pela
   sequência e não inserir eventos para OS inexistentes/excluídas.
5. Não atualizar/apagar o histórico ao excluir a OS. A credencial atual da API
   possui SELECT/INSERT/UPDATE/DELETE nas tabelas de domínio, incluindo o histórico;
   a preservação é garantida pelo comportamento da aplicação, não por grants append-only.

Abertura deriva do evento sequence=1; conclusão deriva de Finished com
ServiceCompleted; entrega deriva de Delivered. BudgetRejected fica fora do tempo
de execução/total de serviços concluídos. Eventos permanecem enquanto o banco
existir, inclusive após DELETE da OS. Destruir o banco encerra esse histórico.

## Compatibilidade e validação

A API foi adaptada ao esquema: status Active/Inactive, perfis Admin/Mechanic e
projeções pelo histórico estão implementados. A consolidação E4 protege a leitura
e decisão por bloqueio transacional da OS/material, torna todo DELETE atômico e
representa conclusão/duração ausentes com null. Não modifica este esquema ou seeds.
A inspeção SQL direta de histórico e cliente Inativo foi concluída em hom, junto
à validação HTTP integrada. Prd não foi validado. O ambiente foi posteriormente
destruído; a existência de evidências não significa disponibilidade atual.

A validacao operacional agora usa ferramentas padrao e o Job: conferir marcador
1.0.0/hash/data, mensagem de inicializacao ou repeticao e resultado Complete.
SQLs de smoke e scripts de teste foram removidos conforme ADR 008. As evidencias
de hom e do fluxo declarativo estão consolidadas no [encerramento E6](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/ENCERRAMENTO_E6_E_CUSTOS_2026-10-21.md). Novas execuções continuam exigindo planos aprovados e pipelines.

O conteudo entregue ao ConfigMap usa LF, como o arquivo versionado no Git;
Terraform calcula SHA-256 desse mesmo conteudo. Isso preserva o marcador entre
checkouts Windows/Linux, sem criar diferenças artificiais de hash entre plataformas. A revisão AE.3 acrescenta as duas tabelas ao próprio Init.sql e, portanto, altera seu hash esperado.

## Modelo físico e limites

O Init.sql possui doze tabelas: users, customers, vehicles, orders, order_status_history, stock, catalog, order_materials, order_services, schema_initialization, customer_auth_challenges e customer_auth_request_limits. [ER completo](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/diagramas/DADOS.md) e [justificativa PostgreSQL/RDS](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/BANCO_E_MODELO.md).

Clientes/veículos se relacionam pelas chaves naturais document/vehicle_license_plate. Itens de OS guardam snapshots dos dados de material/serviço; seus ids são FKs para stock/catalog, sem PK ou unicidade composta declarada. O histórico tem PK própria, sem FK para orders. schema_initialization não tem PK e não recebe grants de API/auth. Não há exclusão em cascata declarada, CHECK de estados ou UNIQUE por sequência do histórico. Não atribuir ao banco garantias implementadas apenas na aplicação.

A autenticação tem SELECT restrito às colunas id/name/document/status/email de customers e DML somente nas duas tabelas customer_auth_challenges/customer_auth_request_limits. O usuário da API possui DML nas nove tabelas de domínio; não administra o marcador. A execução do Job e a conferência de grants preservam essa separação.


## AE.3 — desafios e limites no Init.sql

As duas tabelas fazem parte da criação completa do banco vazio. Não há migrations, SQL adicional ou integração incremental pendente. Terraform entrega o Init.sql ao ConfigMap e calcula seu SHA-256; o Job existente cria as doze tabelas/seeds e grava o novo hash no marcador. Reexecução com marcador idêntico continua preservando os dados. Banco de outra revisão/hash é recusado; o projeto usa destroy e nova inicialização, sem adaptação automática.

customer_auth_challenges guarda UUID próprio e do cliente, salt/verificador binários, instantes, estado e tentativas. customer_auth_request_limits usa customer_id como PK e guarda janela, quantidade e última solicitação. Chaves primárias, tipos, nulabilidade/defaults e três índices comuns; sem CHECKs, UNIQUE condicionado ao estado, FK de cliente ou cascata. Toda regra de estado, validade, tamanho criptográfico, tentativas, substituição e consumo pertence ao C# da autenticação, que já usa transações/locks/operações condicionais no código preparado AE.3/AE.6.

Cliente inexistente é identificado na consulta inicial e retorna sem gravar desafio/limite/auditoria ou executar limpeza/envio; registrar a tentativa somente no log sanitizado. Limites só são persistidos para cliente encontrado/elegível, pelo UUID, sem HMAC/HKDF do documento. Nenhum grant foi ampliado nesta etapa. [DDL atual, decisões e conferência local](AE3_TABELAS_AUTENTICACAO_2026-10-22.md).

AE.9 — 23/10/2026: Init.sql e ProvisionApiUser.sql/ProvisionAuthUser.sql reais executados em banco Docker vazio/descartável na conferência conjunta de código/JWT/API/envio. Grants restritos de ambas as aplicações utilizados. Nenhuma mudança de SQL/seeds/grants ou migrations nesta etapa; sem RDS/AWS. [Resultados e limites](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/AE9_VALIDACAO_LOCAL_E_DOCUMENTACAO.md).
