# Offline assembly only. Input sources and live checks are collected by the caller.
# This filter never reads credentials, calls AWS or publishes a release.
def require($condition; $code):
  if $condition then . else error($code) end;
def matches($pattern):
  if type == "string" then test($pattern) else false end;
def utc_epoch:
  . as $original
  | require(matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"); "INVALID_UTC_TIMESTAMP")
  | sub("\\.[0-9]+Z$"; "Z") as $seconds
  | (try ($seconds | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null) as $epoch
  | require($epoch != null; "INVALID_UTC_TIMESTAMP")
  | require(($epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) == $seconds; "INVALID_UTC_TIMESTAMP")
  | $epoch + (if $original | test("\\.") then
      ($original | capture("\\.(?<fraction>[0-9]+)Z$").fraction | "0." + . | tonumber)
    else 0 end);
def output_value($name):
  .outputs[$name].value;

require(type == "object" and
    (keys == ["baseContext", "credentials", "execution", "job", "outputs", "schema", "verification"]);
    "INVALID_INPUT_FIELDS")
| .execution as $execution
| $execution.environment as $environment
| require($environment == "hom" or $environment == "prd"; "INVALID_ENVIRONMENT")
| require(($execution | keys) == ["commit", "environment", "recordedAt", "repository", "runAttempt", "runId"];
    "INVALID_EXECUTION_FIELDS")
| require($execution.repository == "pknfelps/GerenciamentoMecanicaBancoDados" and
    ($execution.commit | matches("^[0-9a-f]{40}$")); "INVALID_SOURCE")
| require(($execution.runId | matches("^[1-9][0-9]*$")) and
    ($execution.runAttempt | matches("^[1-9][0-9]*$")); "INVALID_DEPLOYMENT")
| ($execution.recordedAt | utc_epoch) as $recorded
| require($recorded <= now; "FUTURE_TIMESTAMP")
| .baseContext as $context
| $context.manifest as $base
| require($context.parameter == "/mecanica/\($environment)/base/v1/database-release" and
    ($context.ssmVersion | type) == "number" and $context.ssmVersion > 0 and
    ($context.ssmVersion | floor) == $context.ssmVersion; "INVALID_BASE_CONTEXT")
| require($base.component == "base" and $base.environment == $environment and
    $base.accountId == "121754142617" and $base.region == "us-east-1" and
    $base.status == "ready" and $base.readinessProfile == "database" and
    ($base.schemaVersion | matches("^1\\.([1-9][0-9]*)\\.(0|[1-9][0-9]*)$")); "BASE_NOT_READY")
| require($base.exports.namespace == "default"; "INVALID_NAMESPACE")
| require(($base.generation | matches("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    $base.generation != "00000000-0000-0000-0000-000000000000"; "INVALID_GENERATION")
| require(($base.deploymentId | matches("^[1-9][0-9]*-[1-9][0-9]*-base$")) and
    $base.source.repository == "pknfelps/GerenciamentoMecanicaInfraestrutura" and
    ($base.source.commit | matches("^[0-9a-f]{40}$")); "INVALID_BASE_SOURCE")
| require(($base.recordedAt | utc_epoch) <= $recorded; "BASE_TIMESTAMP_MISMATCH")
| {parameter: $context.parameter, deploymentId: $base.deploymentId,
    generation: $base.generation, sourceCommit: $base.source.commit} as $dependency
| require($context.dependencies == {base: $dependency} and
    (output_value("base_dependency")) == $dependency; "BASE_DEPENDENCY_MISMATCH")
| require((.credentials | keys) == ["apiSecretArn", "authSecretArn"]; "INVALID_CREDENTIAL_FIELDS")
| "mecanica-\($environment)-postgres" as $instance
| require((output_value("instance_arn")) == "arn:aws:rds:us-east-1:121754142617:db:\($instance)";
    "INVALID_INSTANCE_ARN")
| require((output_value("endpoint") | matches("^" + $instance + "\\.[a-z0-9]+\\.us-east-1\\.rds\\.amazonaws\\.com$"));
    "INVALID_ENDPOINT")
| require((output_value("port")) == 5432 and (output_value("database_name")) == "mecanica";
    "INVALID_DATABASE_CONNECTION")
| require((output_value("security_group_id") | matches("^sg-([0-9a-f]{8}|[0-9a-f]{17})$"));
    "INVALID_SECURITY_GROUP")
| "arn:aws:secretsmanager:us-east-1:121754142617:secret:" as $secret_prefix
| require((.credentials.apiSecretArn | matches("^" + $secret_prefix + "/mecanica/" + $environment + "/database/api-[A-Za-z0-9]{6}$")) and
    (.credentials.authSecretArn | matches("^" + $secret_prefix + "/mecanica/" + $environment + "/database/auth-[A-Za-z0-9]{6}$")) and
    (output_value("admin_secret_arn") | matches("^" + $secret_prefix + "rds!db-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[A-Za-z0-9]{6}$"));
    "INVALID_SECRET_ARN")
| require((.schema | type) == "array" and (.schema | length) == 1; "INVALID_SCHEMA_MARKER")
| .schema[0] as $schema
| require(($schema | keys) == ["initialized_at", "sha256", "version"] and $schema.version == "1.0.0" and
    $schema.version == $schema_version and ($schema.sha256 | matches("^[0-9a-f]{64}$")) and
    $schema.sha256 == $sql_sha256; "SCHEMA_MISMATCH")
| ($schema.initialized_at | utc_epoch) as $initialized
| require($initialized <= $recorded; "INITIALIZATION_TIMESTAMP_MISMATCH")
| .job as $job
| require($job.apiVersion == "batch/v1" and $job.kind == "Job" and
    $job.metadata.name == "database-init" and $job.metadata.namespace == $base.exports.namespace and
    ($job.metadata.uid | matches("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and $job.status.succeeded == 1 and
    (($job.status.failed // 0) == 0) and (($job.status.active // 0) == 0) and
    any($job.status.conditions[]?; .type == "Complete" and .status == "True") and
    (any($job.status.conditions[]?; .type == "Failed" and .status == "True") | not);
    "JOB_NOT_COMPLETE")
| ($job.status.completionTime | utc_epoch) as $completed
| require(($job.metadata.creationTimestamp | utc_epoch) <= $completed and
    ($job.metadata.creationTimestamp | utc_epoch) <= ($job.status.startTime | utc_epoch) and
    ($job.status.startTime | utc_epoch) <= $completed and
    # Kubernetes Job timestamps have second precision; the SQL marker has microseconds.
    ($initialized | floor) <= $completed and $completed <= $recorded; "JOB_TIMESTAMP_MISMATCH")
| ["api-login-permissions", "auth-login-permissions", "rds-private", "schema-seeds", "tls-verify-full"] as $checks
| require((.verification | type) == "array" and (.verification | sort) == $checks;
    "MISSING_VERIFICATION")
| {
    schemaVersion: "1.1.0",
    environment: $environment,
    component: "database",
    accountId: "121754142617",
    region: "us-east-1",
    deploymentId: "\($execution.runId)-\($execution.runAttempt)-database",
    generation: $base.generation,
    source: {repository: $execution.repository, commit: $execution.commit},
    status: "ready",
    recordedAt: $execution.recordedAt,
    exports: {
      "instance-arn": output_value("instance_arn"),
      endpoint: output_value("endpoint"),
      port: output_value("port"),
      "database-name": output_value("database_name"),
      "security-group-id": output_value("security_group_id"),
      "ssl-mode": "VerifyFull",
      "api-secret-arn": .credentials.apiSecretArn,
      "auth-secret-arn": .credentials.authSecretArn,
      "admin-secret-arn": output_value("admin_secret_arn"),
      "schema-version": $schema.version,
      "schema-sha256": $schema.sha256,
      "initialized-at": $schema.initialized_at
    },
    dependencies: {base: $dependency},
    artifacts: [],
    compatibility: {},
    verification: ($checks + ["initialization-job-complete"])
  }
| require((tojson | utf8bytelength) <= 4096; "MANIFEST_TOO_LARGE")
