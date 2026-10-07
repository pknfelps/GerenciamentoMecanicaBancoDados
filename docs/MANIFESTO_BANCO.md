# Manifesto da release do banco

O formato segue as seções 4.2 e 7 do [contrato central](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md). A definição de montagem está em [manifests/database-release.jq](../manifests/database-release.jq). Ela recebe JSON local, valida os dados e gera o manifesto compacto. Não chama AWS, não consulta senhas e não publica parâmetros.

A montagem e a coleta das entradas estão integradas ao `database-provision`, após o Job. O resultado é disponibilizado como artefato da execução para revisão. O protocolo de tentativas, invalidação, publicação/verificação SSM e limpeza dos campos no destroy está implementado em [scripts/database_metadata.sh](../scripts/database_metadata.sh), aguardando a validação remota do fluxo completo. Gerar um arquivo local com `status: ready` não comprova uma publicação nem substitui os checks reais.

## Entradas

Um arquivo JSON reúne exclusivamente as sete propriedades abaixo. O workflow coleta essas entradas após os checks do banco, na mesma execução que criou e validou o Job.

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

O registro do schema é obtido pelo administrador dentro do Job com [sql/ReadInitialization.sql](../sql/ReadInitialization.sql), sem alterar o `Init.sql`:

```sql
SELECT COALESCE(json_agg(json_build_object(
    'version', version,
    'sha256', sha256,
    'initialized_at', to_char(initialized_at AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
)), '[]'::json)
FROM public.schema_initialization;
```

Depois dos smokes, o Job grava esse JSON em `/dev/termination-log`, com `terminationMessagePolicy: File`. O workflow lê somente a mensagem do container `initialize` encerrado com código 0. Esse mecanismo é descrito na [documentação Kubernetes](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/). A mensagem contém apenas versão/hash/data do SQL. O workflow registra o UID retornado na criação do Job, compara com o Job concluído e seleciona o pod pelo UID do controller; não reutiliza evidência de outra execução. `initialized-at` preserva a data registrada no banco; repetir as verificações não a substitui pela data do novo Job. `recordedAt` registra a montagem da release atual.

## Montagem local

Com as entradas coletadas em `manifest-input.json`, executar no diretório do repositório:

```bash
sql_sha256="$(sha256sum sql/Init.sql | cut -d' ' -f1)"
jq -cej --arg schema_version '1.0.0' --arg sql_sha256 "$sql_sha256" \
  -f manifests/database-release.jq manifest-input.json > database-release.json.tmp \
  && mv database-release.json.tmp database-release.json
```

O comando não deve ser usado para publicar um arquivo anterior se a montagem falhar. A opção `-j` evita o byte extra de quebra de linha. O montador limita o JSON UTF-8 compacto a 4096 bytes, conforme o contrato Standard.

Os timestamps do Job têm precisão de segundos; o marcador SQL mantém microssegundos. A comparação com a conclusão do Job considera essa diferença, sem alterar o timestamp exportado. O workflow registra `recordedAt` com fração de segundo.

O manifesto usa `schemaVersion: 1.1.0`, inclui o caminho explícito `base/v1/database-release` em `dependencies` e reutiliza sua geração. A versão do SQL é separada: `exports.schema-version: 1.0.0`. A porta é um inteiro, TLS é `VerifyFull` e os três Secrets aparecem somente como ARNs. `artifacts` e `compatibility` ficam vazios neste bloco: não existe bundle SQL publicado no S3 nem consumo de pacote/HTTP pelo banco. A identidade do SQL é seu SHA-256 e o commit do produtor.

Os 12 exports são: `instance-arn`, `endpoint`, `port`, `database-name`, `security-group-id`, `ssl-mode`, `api-secret-arn`, `auth-secret-arn`, `admin-secret-arn`, `schema-version`, `schema-sha256`, `initialized-at`. A publicação grava os campos individuais e, por último, o manifesto em `/mecanica/<hom|prd>/database/v1/release`.

## Verificação sem AWS

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Requer `jq` no PATH, como no runner Ubuntu; alternativamente, informar seu caminho em `JQ_BIN`. Os testes do fluxo também exigem Bash; alternativamente, informar seu caminho em `BASH_BIN`. A descoberta de testes já existente no CI inclui estes testes, sem mudança no workflow de CI. Os testes usam recursos sintéticos e verificam hom/prd, geração/dependência, tipos, datas, hash/versão SQL, falhas do Job, checks ausentes, limite de tamanho e prevenção de exportação de senhas.

## Integração no provisionamento

Depois de `Initialize schema in EKS`, a etapa `Assemble verified database manifest` confere RDS disponível/privado, VPC, SG ativo, endpoint, porta, database e ARN administrativo contra os outputs e a base capturada. Confere também o UID do Job, pod proprietário, saída do container e configuração TLS. Revalida a release da base antes da coleta e depois da montagem; qualquer divergência impede a geração do arquivo final.

O artefato `database-manifest-<ambiente>-<runId>-<runAttempt>` contém somente `database-release.json`, com retenção de sete dias. Não inclui inputs completos, estado/plano Terraform, senhas ou logs de pod. A ação `plan` não executa essa etapa. Após o upload, a etapa `Publish database metadata in SSM` publica e confere os parâmetros. A release SSM é a fonte de prontidão; baixar o artefato de uma execução que falhou não comprova uma release pronta.

O [exemplo de saída](examples/database-release.json) usa identificadores sintéticos e não representa uma release pronta na AWS. Não utilizá-lo como entrada de consumidores nem publicá-lo no SSM.


## Publicação, falhas e descarte

O helper Bash usa somente AWS CLI para metadados SSM e `jq` para JSON. Não consulta Secrets Manager nem cria recursos. O bootstrap já declara `ssm:GetParameter`, `ssm:PutParameter` e `ssm:DeleteParameter` para a role do banco; escrita fica restrita ao namespace `database/v1` do próprio ambiente. Nenhuma policy nova é necessária para este código.

Em `database-provision` / `activate`:

1. Após aprovação e comparação do plano, registrar `attempts/<runId>-<runAttempt>-database` como `running`, usando a geração/dependência da base capturada.
2. Invalidar `release` e confirmar sua ausência antes do apply. Uma falha anterior à invalidação preserva a release existente. Revalidar a base antes de alterar o RDS.
3. Executar apply, Job, smokes, coleta e montagem do manifesto. Disponibilizar o JSON como artefato.
4. Revalidar a base; gravar os 12 campos individuais como `String`, tier `Standard`, com valores tipados convertidos conforme o contrato. Confirmar cada escrita por leitura e comparação dos bytes.
5. Depois das escritas individuais e da espera de recriação, reler o manifesto/versão SSM da base contra o snapshot. Registrar a tentativa `ready`; publicar `release` por último e confirmar os bytes lidos. Revalidar novamente a base antes de reportar sucesso, tanto no helper quanto no consumidor completo do workflow.

Uma leitura `AccessDenied` não equivale a parâmetro ausente. Apenas `ParameterNotFound` é aceito como ausência. Leituras/escritas/exclusões usam conferências limitadas; erro de confirmação interrompe o fluxo. O helper respeita pelo menos 30 segundos após invalidação antes de recriar `release`, inclusive recuperação de release já ausente; ver [DeleteParameter](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_DeleteParameter.html).

Em falha/cancelamento, o handler invalida a prontidão quando a invalidação já foi iniciada e registra `failed` com código/mensagem sanitizados. Se a invalidação não puder ser confirmada, registra `RELEASE_INVALIDATION_FAILED` e falha explicitamente; não anuncia limpeza bem-sucedida. Uma interrupção completa do runner pode impedir o handler e deixar `running`; a próxima operação deve recuperar o estado e repetir as verificações. Não restaurar a release antiga automaticamente.

Em `database-destroy` / `destroy`, depois da aprovação/replan, o helper usa a dependência no estado anterior do plano aprovado, nunca a fixture usada para planejar a exclusão. Se o estado estiver vazio, pode recuperar a geração da release própria existente; se ambos estiverem ausentes, registra geração `null`, conforme a exceção do contrato. Gerações conflitantes bloqueiam o descarte antes da invalidação.

O destroy invalida/confere a release antes de excluir recursos. Depois das verificações existentes de estado vazio e RDS/subnet group/SG ausentes, remove/confere os 12 campos ativos e registra `destroyed`. Preserva `attempts/*`, `base-access-check`, Secrets Manager, namespace da base e o outro ambiente. Limpeza também ocorre com estado vazio. O modo `plan` não modifica SSM.

As operações do mesmo ambiente permanecem sequenciais. `concurrency` do repositório e a releitura da dependência não oferecem uma trava global entre repositórios; coordenação completa continua pendente em E2.14.

## Validação remota do fluxo completo

Fazer o fluxo de PR e executar `database-provision` em `hom / activate`. Conferir o artefato, a etapa de publicação e `/mecanica/hom/database/v1/release`: status `ready`, geração/dependência corretas e exports esperados. A tentativa correspondente deve estar `ready` e seus dados devem coincidir com o manifesto.

O banco já inicializado pode ser reutilizado: `Init.sql` e seu hash não foram alterados pela publicação. O Job repete as verificações e preserva `initialized-at`.

Quando o descarte já estiver previsto pelo mantenedor, validar `database-destroy` / `destroy`: release e campos ativos ausentes, tentativa `destroyed` e histórico preservado. Não descartar o ambiente apenas para esta implementação. Os testes offline já exercitam publicação/falha/limpeza com SSM simulado; implantação e descarte reais são executados pelo usuário.
