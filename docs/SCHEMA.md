# Esquemas PostgreSQL

A mesma instância RDS contém dois databases. O Job aplica [Init.sql](../sql/Init.sql) 2.1.0 a mecanica e [InitIdentity.sql](../sql/InitIdentity.sql) 1.0.0 a mecanica_identity, cada um em uma transação com seeds e o próprio schema_initialization. O marcador contém versão, SHA-256 e horário. A reexecução verifica os dois marcadores antes de provisionar os grants. Os workflows consumidores comparam initialization-target e initialized no SSM. Para executar um SQL localmente, usar psql -X --set=ON_ERROR_STOP=on --single-transaction --file apontado ao database vazio correspondente.

## Contrato de persistência

- Em mecanica_identity, `users.role`: `Admin` ou `Mechanic`. UUIDs identificam os usuários. Seeds
  educacionais: `Admin` / `Admin@123` e `Mechanic` / `Mechanic@123`, com hashes
  PBKDF2-SHA256, 100.000 iterações, salt de 16 bytes e hash de 32 bytes.
- `customers.status`: `Active` (Ativo) ou `Inactive` (Inativo), obrigatório,
  padrão `Active`. A API deve sempre criar clientes ativos e não expor edição
  desse campo no PATCH genérico. O documento canônico e mascarado é UNIQUE e
  aceita CPF/CNPJ conforme validação do domínio. `customer_access_sync` mantém
  UUID, revisão, operação e pendência da sincronização com a AuthFunction.
- Em mecanica_identity, `customer_access` guarda UUID, nome, documento, e-mail,
  situação e revisão. Uma revogação mantém apenas UUID, revisão e situação.
  A AuthFunction consulta a cópia local para autenticação por código.
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
A inspeção SQL direta de histórico e cliente Inativo foi concluída em hom. Em
02/11/2026, na revisão anterior à separação dos databases, os fluxos HTTP de autenticação e OS foram conferidos em hom e prd,
com as duas instâncias RDS disponíveis, privadas e criptografadas. SQL direto,
retenção após DELETE e descarte não foram repetidos em prd. A conferência é
pontual e não garante disponibilidade futura ou recuperação dos dados.

Conferir os dois marcadores e o resultado Complete do Job em novas execuções. O ConfigMap preserva LF e o workflow confirma os hashes dos dois arquivos versionados. O ambiente é reconstruído a partir dos seeds, com planos aprovados e as pipelines de cada repositório.

## Modelo físico e limites

mecanica tem customers, customer_access_sync, vehicles, orders, order_status_history, stock, catalog, order_materials, order_services e schema_initialization. mecanica_identity tem users, customer_access, customer_auth_challenges, customer_auth_request_limits e schema_initialization. [Diagramas físicos](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/diagramas/DADOS.md).

Clientes/veículos se relacionam pelas chaves naturais document/vehicle_license_plate. Itens de OS guardam snapshots dos dados de material/serviço; seus ids são FKs para stock/catalog, sem PK ou unicidade composta declarada. O histórico tem PK própria, sem FK para orders. schema_initialization não tem PK e não recebe grants de API/auth. Não há exclusão em cascata declarada, CHECK de estados ou UNIQUE por sequência do histórico. Não atribuir ao banco garantias implementadas apenas na aplicação.

A credencial mecanica_api possui DML nas nove tabelas operacionais. mecanica_auth possui DML nas quatro tabelas de identidade. O Job concede conexão somente ao database correspondente e conserva schema_initialization sob seu controle.

## Desafios e limites em mecanica_identity

customer_auth_challenges guarda UUID próprio e do cliente, salt/verificador binários, instantes, estado e tentativas. customer_auth_request_limits usa customer_id como PK e guarda janela, quantidade e última solicitação. Chaves primárias, tipos, nulabilidade/defaults e três índices comuns; sem CHECKs, UNIQUE condicionado ao estado, FK de cliente ou cascata. Toda regra de estado, validade, tamanho criptográfico, tentativas, substituição e consumo pertence ao C# da autenticação, que já usa transações/locks/operações condicionais no código da autenticação.

Cliente inexistente é identificado na consulta inicial e retorna sem gravar desafio/limite/auditoria ou executar limpeza/envio; registrar a tentativa somente no log sanitizado. Limites só são persistidos para cliente encontrado/elegível, pelo UUID, sem HMAC/HKDF do documento.
