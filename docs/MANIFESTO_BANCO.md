# Manifesto da release do banco

O formato segue as seções 4.2 e 7 do [contrato central](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md). A definição de montagem está em [manifests/database-release.jq](../manifests/database-release.jq). Ela recebe JSON local, valida os dados e gera o manifesto compacto. Não chama AWS, não consulta senhas e não publica parâmetros.

Este bloco implementa somente a montagem. A coleta das entradas, a integração com provision/destroy, os registros de tentativas e a escrita/verificação no SSM serão implementados em seguida. Gerar um arquivo local com `status: ready` não comprova uma publicação nem substitui os checks reais.

## Entradas

Um arquivo JSON reúne exclusivamente as sete propriedades abaixo. A futura integração deve coletá-las após os checks do banco, na mesma execução que criou e validou o Job.

| Propriedade | Origem e conteúdo |
|---|---|
| `execution` | `environment`, `repository`, `commit` completo, `runId` e `runAttempt` como strings, `recordedAt` UTC. Repositório produtor: `pknfelps/GerenciamentoMecanicaBancoDados`. |
| `baseContext` | Snapshot já validado por `consume_database_release.py`: `parameter`, `ssmVersion`, `manifest` e `dependencies`. |
| `outputs` | JSON de `terraform -chdir=terraform output -json`, mantendo os envelopes `{value: ...}`. Somente os sete outputs previstos são utilizados. |
| `credentials` | Somente `apiSecretArn` e `authSecretArn`, obtidos dos metadados dos Secrets. Nenhum valor de credencial. O ARN administrativo vem do output Terraform. |
| `schema` | Array com exatamente um registro de `schema_initialization`: `version`, `sha256`, `initialized_at`. |
| `job` | JSON do `kubectl -n default get job database-init -o json`, coletado após a espera de conclusão. |
| `verification` | Nomes dos checks efetivamente aprovados: `rds-private`, `tls-verify-full`, `schema-seeds`, `api-login-permissions`, `auth-login-permissions`. |

O montador verifica formato, ambiente/conta/região, referências, coerência da geração e revisão da base, conclusão do Job e compatibilidade do marcador SQL. Não repete consultas aos recursos reais. O chamador continua responsável pela validação completa da base, origem dos dados/checks, vínculo do Job com a execução atual e nova conferência da dependência antes de publicar.

O registro do schema pode ser obtido pelo administrador dentro do Job com uma consulta de leitura, sem alterar o `Init.sql`:

```sql
SELECT COALESCE(json_agg(json_build_object(
    'version', version,
    'sha256', sha256,
    'initialized_at', to_char(initialized_at AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
)), '[]'::json)
FROM public.schema_initialization;
```

Essa coleta ainda precisa ser integrada ao Job. `initialized-at` preserva a data registrada no banco; repetir as verificações não a substitui pela data do novo Job. `recordedAt` registra a montagem da release atual.

## Montagem local

Com as entradas coletadas em `manifest-input.json`, executar no diretório do repositório:

```bash
sql_sha256="$(sha256sum sql/Init.sql | cut -d' ' -f1)"
jq -cej --arg schema_version '1.0.0' --arg sql_sha256 "$sql_sha256" \
  -f manifests/database-release.jq manifest-input.json > database-release.json.tmp \
  && mv database-release.json.tmp database-release.json
```

O comando não deve ser usado para publicar um arquivo anterior se a montagem falhar. A opção `-j` evita o byte extra de quebra de linha. O montador limita o JSON UTF-8 compacto a 4096 bytes, conforme o contrato Standard.

O manifesto usa `schemaVersion: 1.1.0`, inclui o caminho explícito `base/v1/database-release` em `dependencies` e reutiliza sua geração. A versão do SQL é separada: `exports.schema-version: 1.0.0`. A porta é um inteiro, TLS é `VerifyFull` e os três Secrets aparecem somente como ARNs. `artifacts` e `compatibility` ficam vazios neste bloco: não existe bundle SQL publicado no S3 nem consumo de pacote/HTTP pelo banco. A identidade do SQL é seu SHA-256 e o commit do produtor.

Os 12 exports são: `instance-arn`, `endpoint`, `port`, `database-name`, `security-group-id`, `ssl-mode`, `api-secret-arn`, `auth-secret-arn`, `admin-secret-arn`, `schema-version`, `schema-sha256`, `initialized-at`. A futura publicação grava os campos individuais e, por último, o manifesto em `/mecanica/<hom|prd>/database/v1/release`.

## Verificação sem AWS

```bash
python3 -m unittest discover -s tests -p 'test_database_manifest.py' -v
```

Requer `jq` no PATH, como no runner Ubuntu; alternativamente, informar seu caminho em `JQ_BIN`. A descoberta de testes já existente no CI inclui este teste, sem mudança no workflow. Os testes usam recursos sintéticos e verificam hom/prd, geração/dependência, tipos, datas, hash/versão SQL, falhas do Job, checks ausentes, limite de tamanho e prevenção de exportação de senhas.

O [exemplo de saída](examples/database-release.json) usa identificadores sintéticos e não representa uma release pronta na AWS. Não utilizá-lo como entrada de consumidores nem publicá-lo no SSM.
