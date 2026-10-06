# Esquema SQL 1.0.0 — Fase 3

Fonte: `sql/Init.sql`. Criação completa em banco vazio, com seeds; não é migração,
não apaga dados existentes e não deve ser reaplicada em cada deploy/startup.
Executar com `psql -X --set=ON_ERROR_STOP=on --single-transaction --file=sql/Init.sql`.
A versão está definida no cabeçalho do SQL; ainda não há release SSM publicada.
O hash do esquema continua sendo SHA-256 dos bytes de `sql/Init.sql`.

O Job EKS usa `schema_initialization` como registro operacional: grava
`1.0.0`, SHA-256 e horário no mesmo commit do esquema/seeds. Essa tabela
não pertence ao domínio da API e não deve ser escrita pela aplicação. O
`Init.sql` executado manualmente apenas cria a tabela; o registro é gravado
pelo Job. Em uma ativação repetida, o Job exige exatamente um registro com
versão e hash atuais antes de repetir o smoke.

## Contrato de persistência

- `users.role`: `Admin` ou `Mechanic`. UUIDs identificam os usuários. Seeds
  educacionais: `Admin` / `Admin@123` e `Mechanic` / `Mechanic@123`, com hashes
  PBKDF2-SHA256, 100.000 iterações, salt de 16 bytes e hash de 32 bytes.
- `customers.status`: `Active` (Ativo) ou `Inactive` (Inativo), obrigatório,
  padrão `Active`. A API deve sempre criar clientes ativos e não expor edição
  desse campo no PATCH genérico. A Lambda consultará esse valor junto do UUID
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
sequências duplicadas passam à aplicação na E4. Sem índice, a consulta ao
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
5. Não atualizar/apagar o histórico ao excluir a OS. As permissões da futura
   credencial da API devem refletir o uso de inserção/leitura do histórico.

Abertura deriva do evento sequence=1; conclusão deriva de Finished com
ServiceCompleted; entrega deriva de Delivered. BudgetRejected fica fora do tempo
de execução/total de serviços concluídos. Eventos permanecem enquanto o banco
existir, inclusive após DELETE da OS. Destruir o banco encerra esse histórico.

## Compatibilidade e validação

**A API atual ainda não é compatível com esse esquema.** A E4 precisa adaptar
OrdersRepository/OrderDb/domínio/projeções, gravar histórico transacionalmente,
adicionar status do cliente e trocar os perfis User/Manager por Admin/Mechanic.
Não implantar a API antiga contra esse esquema esperando compatibilidade.

`tests/smoke.sql` valida seeds/perfis, status padrão e fixture Inactive, relações,
unicidade de documento, ausência das colunas antigas, registros dos dois caminhos,
instantes equivalentes em UTC, ordenação explícita com empate, tempo total sem
entrega e retenção após DELETE. Tudo termina
em ROLLBACK. O CI executa o SQL em PostgreSQL 16.

Validação inicial em 2026-10-06: Init e smoke aprovados em PostgreSQL 18.3
temporário. Após retirar os CONSTRAINT nomeados e o índice a pedido do usuário,
o SQL foi testado novamente na mesma versão; PostgreSQL 16 fica para o CI.
Job Kubernetes, credenciais/grants separados e publicação SSM continuam pendentes.
