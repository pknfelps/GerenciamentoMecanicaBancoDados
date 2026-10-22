# AE.3 — Permissões SQL da autenticação

**22/10/2026 — SQL preparado e validado localmente; sem aplicação AWS.**

O `sql/ProvisionAuthUser.sql` mantém a criação/reutilização de `mecanica_auth`, a recusa de roles administrativas ou com memberships e a configuração da senha pelo ambiente do Job. Após revogar os grants anteriores, concede:

| Recurso | Permissões |
|---|---|
| Banco atual / schema public | CONNECT / USAGE |
| customers | SELECT somente id, name, document, status e email |
| customer_auth_challenges | SELECT, INSERT, UPDATE, DELETE |
| customer_auth_request_limits | SELECT, INSERT, UPDATE, DELETE |

Não concede leitura de phone, escrita em customers, acesso a OSs/usuários internos/marcador, TRUNCATE, DDL ou privilégios administrativos. O REVOKE explícito nas colunas de customers remove grants antigos por coluna, que não são removidos pelo REVOKE da tabela. Não acrescenta regras de negócio ao banco.

`ProvisionApiUser.sql` permanece intacto; a API não recebe acesso às tabelas novas. EmailFunction não recebe credencial de banco. `Init.sql`, hash do esquema, Terraform, Job e workflows permanecem intactos nesta etapa. O Job já executa os provisionamentos depois de inicializar/conferir o esquema; não há migration ou novo passo operacional.

## Conferência local

PostgreSQL 16.15 em Docker descartável, sem portas publicadas, rede externa ou volumes persistentes, com credenciais exclusivamente fictícias:

- Executados os arquivos reais Init.sql, ProvisionAuthUser.sql e ProvisionApiUser.sql.
- Acrescentados somente no banco local grants indevidos de SELECT phone, UPDATE email e SELECT users; reaplicado ProvisionAuthUser.sql e confirmada sua remoção.
- Conferida a matriz completa de privilégios de tabela/coluna no schema public, ausência de memberships/atributos administrativos e de CREATE no schema/banco; API sem acesso às duas tabelas de autenticação.
- Conexão autenticada como mecanica_auth por TCP, leitura das cinco colunas e SELECT/INSERT/UPDATE/DELETE nas duas tabelas novas, com rollback dos dados fictícios.
- Dez operações recusadas com SQLSTATE 42501: SELECT phone; UPDATE/DELETE/INSERT customers; SELECT users/orders/schema_initialization; TRUNCATE da tabela de desafios; CREATE public; ALTER da tabela de desafios.
- Container removido ao final. Evidências locais em artifacts/ae3/grants no repositório da API, fora do Git. Não foram criados scripts operacionais ou suítes novas de testes.

Essa conferência valida o SQL real de provisionamento localmente, separadamente dos 309 testes C# da preparação anterior. Não comprova aplicação no RDS nem composição do novo fluxo HTTP. Na AE.3 resta a limpeza oportunista limitada; ligação HTTP/envio permanece na AE.6.
