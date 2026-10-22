# Banco — desafios de autenticação

**22/10/2026 — revisão do mantenedor aplicada ao DDL/contratos; sem aplicação AWS.** [Plano extra AE](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/PLANO_EXTRA_AUTENTICACAO_E_EMAIL.md), independente dos aceites E5/E6/E7.

## Estrutura e responsabilidades

- As tabelas customer_auth_challenges e customer_auth_request_limits são criadas diretamente no Init.sql, em banco vazio. Não há migrations ou atualização de banco existente.
- Desafios: UUID próprio e do cliente, salt/verificador do código, instantes, estado e tentativas. Limites: customer_id, janela, quantidade e última solicitação.
- Não armazenar código/documento em texto puro nessas tabelas. O C# gera/verifica PBKDF2-HMAC-SHA256 com salt de 16 bytes, 600.000 iterações e verificador de 32 bytes; regras de oito dígitos/cinco minutos/cinco tentativas ficam na Lambda.
- Limites usam UUID do cliente encontrado, não chave HMAC/HKDF do documento. Cooldown de 60 segundos e cinco solicitações por hora para cliente existente/elegível são validados no C#.
- Manter chaves primárias, tipos/nulabilidade/defaults e índices comuns de consulta/limpeza; sem CHECKs de negócio, UNIQUE por estado, FK nova de cliente ou cascata.
- C# da persistência deve revalidar cadastro/Active, estados, prazos e tentativas, ordenar locks e consumir/substituir condicionalmente na transação. Sem funções/triggers de negócio ou locks mantidos durante Invoke/SMTP. Não depender da memória da Lambda.

## Cliente inexistente

Após validação/normalização do documento, consultar o cadastro primeiro. Se ausente, retornar imediatamente 202 genérico com identificador opaco em memória e registrar somente log técnico fixo sanitizado. Não inserir/atualizar/apagar desafios, limites ou auditoria, não gerar código e não invocar envio/limpeza. Cliente Inactive/sem e-mail utilizável também não recebe desafio/envio. Uma falha técnica de consulta continua sendo erro, não ausência de cadastro.

## Grants e ciclo de vida

Próximo passo AE.3: acrescentar SELECT email de customers e SELECT/INSERT/UPDATE/DELETE somente nas duas tabelas novas para mecanica_auth. Grants existentes permanecem nesta etapa, sem escrita em customers, acesso a orders/usuários internos ou privilégios administrativos. EmailFunction não recebe credencial SQL.

Destroy remove o RDS demonstrativo; novo banco é criado vazio com o Init.sql. Sem reaplicação do SQL sobre banco com dados para evoluir o esquema. SMTP4dev tem mensagens efêmeras; desafios persistem entre invocações enquanto o banco existir. Snapshot manual é cópia independente e não é removido implicitamente por esse destroy; a revisão de 22/10 identificou um snapshot histórico, sem excluí-lo.

## Estado da AE.3

[Tabelas e validação atual](AE3_TABELAS_AUTENTICACAO_2026-10-22.md). Pasta migrations e constraints anteriores removidas; a antiga conferência de 34 constraints não certifica o SQL simplificado. AE.3 continua parcial até grants e operações transacionais em C#. Endpoints, JWT e transporte são das etapas AE.5/AE.6/AE.7. Nenhuma alteração de infraestrutura AWS, workflow ou estado remoto nesta revisão.

## AE.3 — operações transacionais preparadas

Componentes C# de criação/substituição Pending, ativação Ready, invalidação e confirmação/consumo preparados em ICustomerAccessStore/PostgreSqlCustomerAccessStore, com regras em CustomerAccessChallenge/CustomerAccessRequestLimit. Cliente inexistente retorna antes de gerar código ou acessar as tabelas de autenticação, registrando somente mensagem Information fixa. Limites por UUID do cliente encontrado, 60 segundos/cinco pedidos por hora; negativas não adiam o cooldown.

Advisory lock transacional por cliente, locks das linhas novas e relógio UTC do PostgreSQL; sem FOR UPDATE/escrita em customers, constraints de negócio, migrations ou transação aberta durante envio. Tentativa incorreta/documento divergente de Ready válido é persistida com commit; quinta invalida. Assinatura ocorre antes do consumo/commit e token só retorna após confirmação. Substituído/encerrado não é reativado. Cancelamento/falha provoca rollback preservando a exceção original.

Restore/build Release, regressão de 309 testes (40 novos: 11 regras C# e 29 PostgreSQL), zero falhas/ignorados. Testes locais usam PostgreSQL 16.15/Testcontainers e grants explicitamente preparados na fixture; não comprovam grants de produção ainda não alterados. Detalhes, nomes de testes e limites: [operações transacionais](https://github.com/pknfelps/GerenciamentoMecanicaServerless/blob/develop/docs/AE3_OPERACOES_TRANSACIONAIS.md).

O store ainda não está ligado ao handler/casos de uso HTTP, e não chama EmailFunction. Isso permanece na AE.6. Resultado de criação contém código/e-mail somente para uso interno e não deve ser serializado ou registrado no HTTP/log; a resposta pública será montada separadamente. Grants e limpeza oportunista continuam pendentes na AE.3. Nenhuma alteração AWS, SQL/grants, IAM ou workflows nesta preparação.
