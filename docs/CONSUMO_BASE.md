# Consumo da base pelo banco

O consumidor implementa o contrato central 1.1.0, seções 4.1.1 e 7.2:
[Contratos entre repositórios](https://github.com/pknfelps/GerenciamentoMecanicaSistema/blob/develop/docs/arquitetura/CONTRATOS_ENTRE_REPOSITORIOS.md).

## Execução no GitHub

1. Publicar as alterações do banco em `develop`; disponibilizar o workflow na branch padrão
   para habilitar o botão Run workflow. Promoção para `main` corresponde a produção.
2. No repositório Infraestrutura, revisar o plano de bootstrap e aplicar a nova policy
   `database-metadata-read` de hom/prd antes do primeiro check. Ela só acrescenta
   `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeRouteTables` e
   `ec2:DescribeSecurityGroups` em `us-east-1`. SSM e DescribeCluster já pertencem
   ao bootstrap. Este bloco não aplica permissões automaticamente.
3. A base precisa ter publicado `database-release`. Se houver somente candidato,
   concluir `aws-oidc-check` com `check_kubernetes=true` e nova ativação da base.
4. Executar `database-base-check`: branch `develop`/ambiente `hom` ou `main`/`prd`.
   As variáveis do Environment são `AWS_REGION=us-east-1` e `AWS_ROLE_ARN` da role database.
5. Conferir os passos de captura e releitura e o resumo. Ausência de release ou erro
   de autorização encerra com falha; não há sucesso de deploy quando a base está bloqueada.

Esse workflow consulta recursos e produz um snapshot temporário no runner. Não executa
Terraform, SQL, criação de Job, leitura de secrets nem escrita SSM. O check anterior
`aws-oidc-check` continua responsável pela evidência do candidato; não depende da release
pronta, evitando dependência circular na primeira ativação.

## Uso pelo futuro provisionamento

Com AWS CLI, Python 3 e kubectl instalados, executar na raiz do repositório, usando
o contexto de branch/repositório do GitHub e credenciais OIDC da role database:

```bash
python3 scripts/consume_database_release.py capture --environment hom --context "$RUNNER_TEMP/base.json"
# Preparar o plano com os exports deste snapshot.
python3 scripts/consume_database_release.py recheck --environment hom --context "$RUNNER_TEMP/base.json"
# Só então iniciar a operação que usa a base. Repetir o recheck antes de publicar resultados.
```

O script retorna código diferente de zero em falha. O chamador deve interromper a operação
nesse caso. O snapshot só é gravado após a captura bem-sucedida e não substitui a releitura
imediatamente antes de uma mutação. Não reutilizar snapshot de outra execução/aprovação.

O arquivo contém `parameter`, `ssmVersion`, `manifest` completo e `dependencies.base`:

- `parameter`: `/mecanica/<ambiente>/base/v1/database-release`;
- `deploymentId` e `generation`: identidade da base efetivamente consumida;
- `sourceCommit`: commit da infraestrutura.

O futuro manifesto do banco deve incorporar esse mapa `dependencies` e a geração
consumida. Os nove exports do manifesto são o snapshot autoritativo para configurar
rede, SGs e Job. O consumidor não lê parâmetros avulsos, `database-candidate`, a release
full ou o estado Terraform da base como alternativa.

## Validações

- JSON sem chaves duplicadas, tamanho até 4 KB, schema estável `1.1.0` ou minor/patch
  posterior do major 1; campos adicionais opcionais são aceitos.
- Produtor, conta, região, ambiente, perfil database, status ready, UUID da geração,
  revisão/commit, timestamp UTC, verificações e nove exports obrigatórios.
- VPC e subnets com dono/tags do ambiente, duas AZs, subnets privadas, rotas de banco
  isoladas e workloads via NAT; SGs na VPC e cluster ACTIVE com referências coincidentes.
- SG de API/Job corresponde ao SG do cluster, conforme a topologia atual da base;
  a verificação das interfaces dos nós permanece no publicador.
- Role real database, permissões de Jobs/pods/logs/service accounts e leitura do
  service account `default` no namespace, sem exigir acesso global a namespaces.
- Releitura compara versão SSM e manifesto completo, incluindo recursos. Uma mudança
  durante as verificações ou desde a captura bloqueia o consumo, mesmo se conservar a geração.

As quatro consultas EC2 usam `Resource: "*"` porque não suportam escopo por ARN
nessas ações; a policy limita a região e o consumidor verifica conta/ambiente dos
recursos retornados. Referência: [autorização EC2](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html).

## Limites e validação local

Operações da base/banco/API/auth/gateway do mesmo ambiente continuam sequenciais.
A releitura detecta mudanças, mas não é trava entre repositórios. A concurrency
`database-<ambiente>` só serializa este repositório. A coordenação global segue pendente.

```bash
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

Os testes simulam AWS/Kubernetes e incluem hom/prd, contrato incompatível, ausência,
AccessDenied, permissões insuficientes, rede incompatível e mudanças durante o consumo.
Não comprovam o ciclo real no runner. O módulo Terraform do Aurora foi implementado
e testado localmente. Deploy, esquema/seeds, publicação da release database e
integração desses guardas ao deploy seguem na E2.2/E2.5.
