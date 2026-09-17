# GerenciamentoMecanicaBancoDados

Responsável por esquema/seeds, inicialização e infraestrutura do banco do sistema de oficina. Repositório separado na E1.2 do Tech Challenge Fase 3.

## Estado atual

- `sql/Init.sql`: fonte do esquema/seeds existente da Fase 2, transferida sem alteração funcional. Destinada a banco vazio; não é uma migração incremental nem um script para cada startup.
- `legacy/kubernetes/`: arquivo histórico dos recursos PostgreSQL/EBS usados na fase anterior. Esses manifestos não integram o Kustomize ativo da aplicação.
- `docs/origem-fase2.json`: origem, commit, caminhos e hashes dos arquivos transferidos (UTF-8/LF).

Aurora Serverless v2, Terraform do banco, credenciais de leitura da função, Job de inicialização e modelo de histórico/status serão implementados em E2/E4. O SQL atual ainda não contém essas alterações. Os registros iniciais são os dados de demonstração já usados no projeto educacional.

## Desenvolvimento local

A aplicação mantém uma cópia versionada de `sql/Init.sql` para seu Docker Compose funcionar sem outro checkout. Alterações devem começar aqui e ser importadas pela aplicação usando um SHA de commit completo:

```powershell
# Na raiz do repositório da aplicação:
./scripts/Sync-DatabaseSnapshot.ps1 -DatabaseRepository ../GerenciamentoMecanicaBancoDados -Commit <SHA-completo>
./scripts/Sync-DatabaseSnapshot.ps1 -Verify
```

O manifesto local registra commit/caminho/hash; a pipeline da aplicação verifica a integridade da cópia. Não editar duas fontes de SQL independentemente. O comando de sincronização não executa SQL nem remove dados. A execução completa da API/PostgreSQL/smtp4dev continua no Compose da aplicação.

## Referências

- [Aplicação e plano central](https://github.com/pknfelps/GerenciamentoMecanicaSistema)
- [Infraestrutura](https://github.com/pknfelps/GerenciamentoMecanicaInfraestrutura)
- [Autenticação](https://github.com/pknfelps/GerenciamentoMecanicaAutenticacao)

Consultar `PLANO_FASE_3.md`, E2/E4 e D08 no repositório da aplicação, na branch da implementação enquanto o PR não estiver integrado. A distribuição de artefatos S3/SSM da arquitetura AWS será implementada nas tarefas próprias. README completo, ER e pipeline seguem em E1.3/E2/E7.
