# GerenciamentoMecanicaBancoDados

Responsável por esquema/seeds, inicialização e infraestrutura do banco do sistema de oficina. Repositório separado na E1.2 do Tech Challenge Fase 3.

## Estado atual

- `sql/Init.sql`: fonte do esquema/seeds existente da Fase 2, transferida sem alteração funcional. Destinada a banco vazio; não é uma migração incremental nem um script para cada startup.
- `legacy/kubernetes/`: arquivo histórico dos recursos PostgreSQL/EBS usados na fase anterior. Esses manifestos não integram o Kustomize ativo da aplicação.
- `docs/origem-fase2.json`: origem, commit, caminhos e hashes dos arquivos transferidos (UTF-8/LF).

Aurora Serverless v2, Terraform do banco, credenciais de leitura da função, Job de inicialização e modelo de histórico/status serão implementados em E2/E4. O SQL atual ainda não contém essas alterações. Os registros iniciais são os dados de demonstração já usados no projeto educacional.

## Desenvolvimento local

O uso principal será a API publicada na AWS. Se precisar de Docker local, prepare manualmente o esquema e os dados do PostgreSQL a partir de `sql/Init.sql`, usando seu cliente SQL e um banco vazio.

A API mantém um Compose opcional para API/PostgreSQL/smtp4dev, mas não armazena cópia do SQL, manifesto de versão ou sincronizador e não monta scripts de inicialização. Inicie o banco, prepare o esquema manualmente e então use a API. A inicialização AWS continua sob responsabilidade deste repositório, pelo Job/pipeline previsto na E2.

## Referências

- [Aplicação e plano central](https://github.com/pknfelps/GerenciamentoMecanicaSistema)
- [Infraestrutura](https://github.com/pknfelps/GerenciamentoMecanicaInfraestrutura)
- [Autenticação](https://github.com/pknfelps/GerenciamentoMecanicaAutenticacao)

Consultar `PLANO_FASE_3.md`, E2/E4 e D08 no repositório da aplicação, na branch da implementação enquanto o PR não estiver integrado. A distribuição de artefatos S3/SSM da arquitetura AWS será implementada nas tarefas próprias. README completo, ER e pipeline seguem em E1.3/E2/E7.
