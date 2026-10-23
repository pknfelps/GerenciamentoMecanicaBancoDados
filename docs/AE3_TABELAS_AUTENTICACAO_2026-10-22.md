# AE.3 — Tabelas de autenticação do cliente

**22/10/2026 — revisão do mantenedor aplicada e validada localmente.** Duas tabelas diretamente no [Init.sql](../sql/Init.sql), para criação do banco vazio. Pasta migrations removida. Sem aplicação AWS pelo agente. O mantenedor confirmou posteriormente, em 22/10/2026, a exclusão do snapshot manual histórico mecanica-hom-postgres-snapshot; pendência encerrada por confirmação, sem nova consulta AWS pelo agente.

O banco demonstrativo é descartado com o ambiente. Novo provisionamento cria o esquema/seeds a partir do Init.sql; não há mecanismo de migração de dados entre revisões. O código existente do Terraform normaliza LF, calcula o novo SHA-256 e entrega o SQL ao ConfigMap. O Job existente cria o esquema e grava o marcador na mesma transação. Nenhum passo de workflow/Job foi acrescentado.

## Estrutura

### customer_auth_challenges

| Campo | Tipo SQL | Finalidade |
|---|---|---|
| id | UUID PRIMARY KEY | Identificador do desafio |
| customer_id | UUID NOT NULL | Cliente encontrado antes da gravação |
| code_salt | BYTEA NOT NULL | Salt produzido pelo C# |
| code_verifier | BYTEA NOT NULL | Verificador PBKDF2 produzido pelo C# |
| created_at | TIMESTAMPTZ NOT NULL | Criação; padrão CURRENT_TIMESTAMP |
| expires_at | TIMESTAMPTZ NOT NULL | Expiração calculada/validada no C# |
| state | VARCHAR(50) NOT NULL | Estado validado no C#; padrão Pending |
| failed_attempts | INTEGER NOT NULL | Tentativas validadas no C#; padrão zero |
| consumed_at | TIMESTAMPTZ | Instante de consumo |
| invalidated_at | TIMESTAMPTZ | Instante de invalidação |

Índices comuns por (customer_id, created_at) e (expires_at, id). Não há UNIQUE por estado, CHECK de validade/tentativas/tamanho/estado, FK de cliente, cascata ou trigger. A aplicação deve tratar estados e registros após exclusão de cliente; o banco não executa esse fluxo automaticamente.

### customer_auth_request_limits

| Campo | Tipo SQL | Finalidade |
|---|---|---|
| customer_id | UUID PRIMARY KEY | Cliente existente/elegível |
| window_started_at | TIMESTAMPTZ NOT NULL | Início da janela |
| window_expires_at | TIMESTAMPTZ NOT NULL | Fim da janela |
| request_count | INTEGER NOT NULL | Solicitações admitidas |
| last_requested_at | TIMESTAMPTZ NOT NULL | Última solicitação admitida |

Índice comum por (window_expires_at, customer_id). Não há document_key, HMAC/HKDF do documento ou novo Secret para esse controle. Cooldown de 60 segundos, cinco solicitações/hora e duração da janela são regras C#. O PBKDF2-HMAC-SHA256 do código continua previsto, com salt de 16 bytes/600.000 iterações/verificador de 32 bytes; esses valores não são constraints do banco.

## Cliente inexistente e regras C#

Na futura request-code, validar/normalizar a entrada e consultar o cliente primeiro. Se ausente, retornar imediatamente a resposta genérica 202 com challengeId opaco somente em memória e registrar log com mensagem fixa Solicitação de autenticação para cliente não encontrado. Sem CPF/e-mail/código/payload no log.

Esse caminho não grava desafio, limite ou auditoria no banco e não executa limpeza, geração do código ou envio. Falha da consulta continua técnica, não é ausência de cliente. Para cliente existente/elegível, o limite é identificado pelo UUID. Cliente Inactive/sem e-mail utilizável também não recebe desafio/envio.

O C# deve validar os tamanhos criptográficos, oito dígitos/cinco minutos/cinco tentativas, transições, instantes e elegibilidade antes da persistência. Usar transações curtas, locks por cliente e operações condicionais para substituir/ativar/consumir, evitando consumo duplicado entre instâncias. Nada disso é certificado somente pelo DDL. O fluxo novo da Lambda ainda será implementado na AE.6; esta revisão consolida sua especificação.

## Execução e grants

O comando local existente continua sendo suficiente, em banco vazio:

```bash
psql -h localhost -p 5432 -U postgres -d postgres -W -X -v ON_ERROR_STOP=1 --single-transaction -f sql/Init.sql
```

Digitar senha no prompt. Não reaplicar Init.sql para adaptar banco com dados. O Job grava versão 1.0.0 e o hash atual do arquivo; mesmo marcador permite reexecução sem reinicializar. Hash de outra revisão é recusado; o projeto recria o banco pelo ciclo de destroy/provisionamento autorizado.

[Grants preparados e validados localmente](AE3_PERMISSOES_AUTENTICACAO_2026-10-22.md): mecanica_auth recebe SELECT email de customers e DML restrito nas tabelas novas. A API e a EmailFunction não recebem acesso novo nesta revisão. Publicação/aplicação AWS continuam posteriores.

## Validação local atual

PostgreSQL 16.15 em Docker descartável, sem rede externa, porta publicada ou volume persistente:

- Comparação com o Init.sql anterior confirmou as dez tabelas e seeds originais preservados; apenas duas tabelas/índices acrescentados.
- O conteúdo real do Job existente inicializou banco vazio com doze tabelas e o novo hash e reconheceu a segunda execução como Matching schema already initialized.
- Doze verificações de estrutura, chaves/tipos, três índices comuns, ausência de CHECK/FK/trigger/cascata/unicidade condicional, grants anteriores, seeds e timestamps. Dados de teste revertidos ao final.
- SQL direto de teste aceitou valores fora das regras de estado/tentativas/validade e múltiplos Pending por cliente, confirmando que essas validações não foram deixadas no banco. Isso não comprova validação C# já implementada.
- O Job recusou o hash antigo, sem alterar o marcador ou os dados.
- Estado final: duas tabelas novas vazias, doze tabelas totais, marcador com o hash atual. Container removido ao final.

Evidências locais ignoradas em artifacts/ae3/review no repositório da API. A conferência anterior de 34 constraints/migração foi substituída e não certifica o SQL atual. Operações C# e grants preparados e validados localmente; [Limpeza oportunista implementada e validada](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/docs/AE3_LIMPEZA_EXPIRADOS.md); AE.3 concluída no escopo local. A resposta antecipada/log do novo fluxo e sua ausência de gravações serão comprovadas pelos testes C# da autenticação, sem tratar SQL direto como teste da Lambda.

## AE.3 — operações transacionais preparadas

Componentes C# de criação/substituição Pending, ativação Ready, invalidação e confirmação/consumo preparados em ICustomerAccessStore/PostgreSqlCustomerAccessStore, com regras em CustomerAccessChallenge/CustomerAccessRequestLimit. Cliente inexistente retorna antes de gerar código ou acessar as tabelas de autenticação, registrando somente mensagem Information fixa. Limites por UUID do cliente encontrado, 60 segundos/cinco pedidos por hora; negativas não adiam o cooldown.

Advisory lock transacional por cliente, locks das linhas novas e relógio UTC do PostgreSQL; sem FOR UPDATE/escrita em customers, constraints de negócio, migrations ou transação aberta durante envio. Tentativa incorreta/documento divergente de Ready válido é persistida com commit; quinta invalida. Assinatura ocorre antes do consumo/commit e token só retorna após confirmação. Substituído/encerrado não é reativado. Cancelamento/falha provoca rollback preservando a exceção original.

Restore/build Release, regressão de 309 testes (40 novos: 11 regras C# e 29 PostgreSQL), zero falhas/ignorados. Testes locais usam PostgreSQL 16.15/Testcontainers e grants explicitamente preparados na fixture; não substituem a conferência separada do SQL real, agora registrada em [permissões da autenticação](AE3_PERMISSOES_AUTENTICACAO_2026-10-22.md). Detalhes, nomes de testes e limites: [operações transacionais](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/docs/AE3_OPERACOES_TRANSACIONAIS.md).

O store ainda não está ligado ao handler/casos de uso HTTP, e não chama EmailFunction. Isso permanece na AE.6. Resultado de criação contém código/e-mail somente para uso interno e não deve ser serializado ou registrado no HTTP/log; a resposta pública será montada separadamente. Grants preparados e validados localmente; [Limpeza oportunista implementada e validada](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/docs/AE3_LIMPEZA_EXPIRADOS.md), sem retenção extra de 24 horas; AE.3 concluída no escopo local. Nenhuma alteração AWS, SQL/grants, IAM ou workflows nesta preparação.

## Reconferência PostgreSQL local — 22/10/2026

[Registro consolidado](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/VALIDACAO_AE3_POSTGRESQL_LOCAL_2026-10-22.md): Job atual inicializa banco vazio, reconhece repetição e recusa hash divergente/banco não vazio sem marcador, sem alterar dados. Estrutura/seeds/instantes e grants reais conferidos em PostgreSQL 16.15 descartável. Nova regressão Serverless: 309 testes aprovados, zero falhas/ignorados; restore/build Release sem avisos/erros. Sem migração, regras de negócio no SQL, alteração de produção ou acesso AWS. Nessa reconferência anterior, limpeza ainda estava pendente. [Implementação e validação posteriores](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/docs/AE3_LIMPEZA_EXPIRADOS.md) encerraram a AE.3 no escopo local.
