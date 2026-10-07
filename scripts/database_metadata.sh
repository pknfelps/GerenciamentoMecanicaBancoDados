#!/usr/bin/env bash
# SSM publication protocol. No secret reads, Terraform mutations or cluster calls.
set -euo pipefail

metadata_error() { echo "::error::$1" >&2; return 1; }
metadata_now() { date -u +'%Y-%m-%dT%H:%M:%S.%NZ'; }

metadata_setup() {
  local branch
  case "${TARGET_ENVIRONMENT:-}" in
    hom) branch='refs/heads/develop' ;;
    prd) branch='refs/heads/main' ;;
    *) metadata_error INVALID_METADATA_ENVIRONMENT; return 1 ;;
  esac
  if [[ "${GITHUB_REPOSITORY:-}" != 'pknfelps/GerenciamentoMecanicaBancoDados' ||
        "${GITHUB_REF:-}" != "$branch" || ! "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ||
        ! "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ||
        -z "${RUNNER_TEMP:-}" ]]; then
    metadata_error INVALID_METADATA_EXECUTION; return 1
  fi
  umask 077
  metadata_dir="$RUNNER_TEMP/database-metadata"
  mkdir -p "$metadata_dir"
  metadata_context="$metadata_dir/context.json"
  metadata_prefix="/mecanica/$TARGET_ENVIRONMENT/database/v1"
  metadata_deployment="$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-database"
  metadata_fields=(instance-arn endpoint port database-name security-group-id ssl-mode
                   api-secret-arn auth-secret-arn admin-secret-arn schema-version schema-sha256 initialized-at)
}

# Return 4 only for confirmed ParameterNotFound; never treat denial as absence.
metadata_read() {
  local name="$1" destination="$2"
  [[ "$name" == "$metadata_prefix/"* ]] || { metadata_error FOREIGN_PARAMETER; return 1; }
  if ! aws ssm get-parameter --name "$name" --region us-east-1 --output json --no-cli-pager \
      > "$metadata_dir/read.json" 2> "$metadata_dir/aws-error.log"; then
    if grep -Fq '(ParameterNotFound)' "$metadata_dir/aws-error.log"; then return 4; fi
    metadata_error SSM_READ_FAILED; return 1
  fi
  jq -e --arg name "$name" '
    .Parameter.Name == $name and .Parameter.Type == "String" and
    .Parameter.ARN == ("arn:aws:ssm:us-east-1:121754142617:parameter" + $name) and
    (.Parameter.Version | type == "number" and . > 0) and
    (.Parameter.Value | type == "string" and utf8bytelength <= 4096)
  ' "$metadata_dir/read.json" >/dev/null || { metadata_error INVALID_SSM_PARAMETER; return 1; }
  jq -jr '.Parameter.Value' "$metadata_dir/read.json" > "$destination"
}

metadata_expect_absent() {
  local code
  if metadata_read "$1" "$metadata_dir/unexpected-value"; then
    metadata_error SSM_PARAMETER_STILL_PRESENT; return 1
  else
    code=$?
    [[ "$code" == 4 ]] || return 1
  fi
}

metadata_delete() {
  local name="$1" attempt code
  [[ "$name" == "$metadata_prefix/"* ]] || { metadata_error FOREIGN_PARAMETER; return 1; }
  if ! aws ssm delete-parameter --name "$name" --region us-east-1 --output json --no-cli-pager \
      > "$metadata_dir/delete.json" 2> "$metadata_dir/aws-error.log"; then
    grep -Fq '(ParameterNotFound)' "$metadata_dir/aws-error.log" || { metadata_error SSM_DELETE_FAILED; return 1; }
  fi
  for attempt in {1..6}; do
    if metadata_read "$name" "$metadata_dir/deleted-value"; then
      :
    else
      code=$?
      [[ "$code" == 4 ]] && return 0
      return 1
    fi
    sleep 2
  done
  metadata_error SSM_DELETE_NOT_CONFIRMED
}

metadata_put() {
  local name="$1" file="$2" attempt code
  [[ "$name" == "$metadata_prefix/"* ]] || { metadata_error FOREIGN_PARAMETER; return 1; }
  [[ "$(wc -c < "$file")" -le 4096 ]] || { metadata_error METADATA_TOO_LARGE; return 1; }
  aws ssm put-parameter --name "$name" --type String --tier Standard --data-type text --overwrite \
    --value "file://$file" --region us-east-1 --output json --no-cli-pager \
    > "$metadata_dir/write.json" 2> "$metadata_dir/aws-error.log" || { metadata_error SSM_WRITE_FAILED; return 1; }
  for attempt in {1..6}; do
    if metadata_read "$name" "$metadata_dir/read-value"; then
      cmp -s "$file" "$metadata_dir/read-value" && return 0
    else
      code=$?
      [[ "$code" == 4 ]] || return 1
    fi
    sleep 2
  done
  metadata_error SSM_WRITE_NOT_CONFIRMED
}

metadata_load_context() {
  [[ -f "$metadata_context" ]] || { metadata_error MISSING_METADATA_CONTEXT; return 1; }
  jq -e --arg env "$TARGET_ENVIRONMENT" --arg id "$metadata_deployment" --arg sha "$GITHUB_SHA" '
    .attempt.environment == $env and .attempt.deploymentId == $id and .attempt.source.commit == $sha and
    .attempt.component == "database" and .attempt.accountId == "121754142617" and .attempt.region == "us-east-1"
  ' "$metadata_context" >/dev/null || { metadata_error INVALID_METADATA_CONTEXT; return 1; }
}

metadata_record() {
  jq -cj '.attempt' "$metadata_context" > "$metadata_dir/attempt.json"
  metadata_put "$metadata_prefix/attempts/$metadata_deployment" "$metadata_dir/attempt.json"
}

metadata_begin() {
  local operation="$1" input="$2" code
  [[ ! -e "$metadata_context" ]] || { metadata_error METADATA_CONTEXT_EXISTS; return 1; }
  if [[ "$operation" == provision ]]; then
    jq -ce --arg env "$TARGET_ENVIRONMENT" '
      .dependencies.base as $dep
      | if .parameter != ("/mecanica/" + $env + "/base/v1/database-release") or
           .manifest.environment != $env or .manifest.status != "ready" or .manifest.component != "base" or
           .manifest.readinessProfile != "database" or .manifest.accountId != "121754142617" or
           .manifest.region != "us-east-1" or $dep.parameter != .parameter or
           $dep.generation != .manifest.generation or $dep.deploymentId != .manifest.deploymentId or
           $dep.sourceCommit != .manifest.source.commit
        then error("INVALID_BASE_CONTEXT") else {generation: .manifest.generation, dependencies: .dependencies} end
    ' "$input" > "$metadata_dir/identity.json"
  else
    # Use only the approved plan's prior-state dependency, never the fake destroy fixture.
    jq -ce --arg env "$TARGET_ENVIRONMENT" '
      .prior_state.values as $prior | $prior.outputs.base_dependency.value as $dep
      | if $dep != null then
          if $dep.parameter != ("/mecanica/" + $env + "/base/v1/database-release") then error("FOREIGN_BASE_DEPENDENCY")
          else {generation: $dep.generation, dependencies: {base: $dep}} end
        elif (($prior.root_module.resources // []) | length) > 0 then error("MISSING_STATE_GENERATION")
        else {generation: null, dependencies: {}} end
    ' "$input" > "$metadata_dir/identity.json"
    if metadata_read "$metadata_prefix/release" "$metadata_dir/previous-release.json"; then
      jq -ce --slurpfile identity "$metadata_dir/identity.json" --arg env "$TARGET_ENVIRONMENT" '
        if .environment != $env or .component != "database" or .accountId != "121754142617" or .region != "us-east-1" or
           ($identity[0].generation != null and .generation != $identity[0].generation)
        then error("PREVIOUS_RELEASE_IDENTITY_MISMATCH")
        else if $identity[0].generation == null then {generation: .generation, dependencies: .dependencies}
             else $identity[0] end end
      ' "$metadata_dir/previous-release.json" > "$metadata_dir/identity.tmp"
      mv "$metadata_dir/identity.tmp" "$metadata_dir/identity.json"
    else
      code=$?
      [[ "$code" == 4 ]] || return 1
    fi
  fi
  jq -e --arg operation "$operation" --arg env "$TARGET_ENVIRONMENT" '
    (.generation == null and $operation == "destroy" and .dependencies == {}) or
    ((.generation | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") and
      . != "00000000-0000-0000-0000-000000000000") and
     (.dependencies | keys) == ["base"] and .dependencies.base.generation == .generation and
     .dependencies.base.parameter == ("/mecanica/" + $env + "/base/v1/database-release") and
     (.dependencies.base.deploymentId | test("^[1-9][0-9]*-[1-9][0-9]*-base$")) and
     (.dependencies.base.sourceCommit | test("^[0-9a-f]{40}$")))
  ' "$metadata_dir/identity.json" >/dev/null || { metadata_error INVALID_GENERATION; return 1; }
  jq -ncj --slurpfile identity "$metadata_dir/identity.json" --arg operation "$operation" \
    --arg env "$TARGET_ENVIRONMENT" --arg id "$metadata_deployment" --arg commit "$GITHUB_SHA" --arg now "$(metadata_now)" '
    {operation: $operation, invalidating: false, notBefore: 0,
     attempt: {schemaVersion: "1.1.0", environment: $env, component: "database", accountId: "121754142617",
               region: "us-east-1", deploymentId: $id, generation: $identity[0].generation,
               source: {repository: "pknfelps/GerenciamentoMecanicaBancoDados", commit: $commit}, status: "running",
               recordedAt: $now, exports: {}, dependencies: $identity[0].dependencies,
               artifacts: [], compatibility: {}, verification: []}}
  ' > "$metadata_context"
  if [[ "$operation" == provision ]]; then
    jq -cj --slurpfile base "$input" '.baseSnapshot = $base[0]' "$metadata_context" > "$metadata_dir/context.tmp"
    mv "$metadata_dir/context.tmp" "$metadata_context"
  fi
  metadata_record
  jq -cj '.invalidating = true' "$metadata_context" > "$metadata_dir/context.tmp"
  mv "$metadata_dir/context.tmp" "$metadata_context"
  metadata_delete "$metadata_prefix/release"
  # Conservatively covers an absent release recently deleted by an interrupted run.
  jq -cj --argjson deadline "$(( $(date +%s) + 31 ))" '.notBefore = $deadline' \
    "$metadata_context" > "$metadata_dir/context.tmp"
  mv "$metadata_dir/context.tmp" "$metadata_context"
}

metadata_check_base() {
  local name="/mecanica/$TARGET_ENVIRONMENT/base/v1/database-release"
  aws ssm get-parameter --name "$name" --region us-east-1 --output json --no-cli-pager \
    > "$metadata_dir/base-read.json" 2> "$metadata_dir/aws-error.log" || { metadata_error BASE_RELEASE_CHANGED_OR_UNAVAILABLE; return 1; }
  jq -e --slurpfile context "$metadata_context" --arg name "$name" '
    .Parameter.Name == $name and .Parameter.Type == "String" and
    .Parameter.ARN == ("arn:aws:ssm:us-east-1:121754142617:parameter" + $name) and
    .Parameter.Version == $context[0].baseSnapshot.ssmVersion and
    (.Parameter.Value | fromjson) == $context[0].baseSnapshot.manifest
  ' "$metadata_dir/base-read.json" >/dev/null || { metadata_error BASE_RELEASE_CHANGED_OR_UNAVAILABLE; return 1; }
}

metadata_publish() {
  local manifest="$1" field remaining
  metadata_load_context
  jq -e --slurpfile context "$metadata_context" --argjson fields "$(printf '%s\n' "${metadata_fields[@]}" | jq -R . | jq -s .)" '
    $context[0].operation == "provision" and $context[0].invalidating == true and $context[0].attempt.status == "running" and
    .status == "ready" and .schemaVersion == "1.1.0" and
    .environment == $context[0].attempt.environment and .component == "database" and
    .accountId == "121754142617" and .region == "us-east-1" and
    .deploymentId == $context[0].attempt.deploymentId and .source == $context[0].attempt.source and
    .generation == $context[0].attempt.generation and .generation != null and
    .dependencies == $context[0].attempt.dependencies and
    (.exports | keys) == ($fields | sort) and
    (.verification | index("initialization-job-complete") != null) and
    (keys == ["accountId", "artifacts", "compatibility", "component", "dependencies", "deploymentId", "environment",
              "exports", "generation", "recordedAt", "region", "schemaVersion", "source", "status", "verification"])
  ' "$manifest" >/dev/null || { metadata_error INVALID_READY_MANIFEST; return 1; }
  [[ "$(wc -c < "$manifest")" -le 4096 ]] || { metadata_error METADATA_TOO_LARGE; return 1; }
  metadata_expect_absent "$metadata_prefix/release"
  for field in "${metadata_fields[@]}"; do
    jq -jr --arg field "$field" '.exports[$field] | tostring' "$manifest" > "$metadata_dir/field-value"
    metadata_put "$metadata_prefix/$field" "$metadata_dir/field-value"
  done
  remaining="$(( $(jq -r '.notBefore' "$metadata_context") - $(date +%s) ))"
  if (( remaining > 0 )); then sleep "$remaining"; fi
  # Re-read after field writes and any recreation delay, immediately before readiness.
  metadata_check_base
  jq -cj --slurpfile ready "$manifest" '.attempt = $ready[0]' "$metadata_context" > "$metadata_dir/context.tmp"
  mv "$metadata_dir/context.tmp" "$metadata_context"
  metadata_record
  metadata_put "$metadata_prefix/release" "$manifest"
  metadata_check_base
}

metadata_destroyed() {
  local field
  metadata_load_context
  jq -e '.operation == "destroy" and .invalidating == true' "$metadata_context" >/dev/null || { metadata_error INVALID_DESTROY_CONTEXT; return 1; }
  metadata_expect_absent "$metadata_prefix/release"
  for field in "${metadata_fields[@]}"; do metadata_delete "$metadata_prefix/$field"; done
  metadata_expect_absent "$metadata_prefix/release"
  jq -cj --arg now "$(metadata_now)" '
    .attempt.status = "destroyed" | .attempt.recordedAt = $now |
    .attempt.verification = ["terraform-state-empty", "rds-subnet-group-sg-absent", "ssm-active-fields-absent"]
  ' "$metadata_context" > "$metadata_dir/context.tmp"
  mv "$metadata_dir/context.tmp" "$metadata_context"
  metadata_record
}

metadata_failed() {
  local invalidation_failed=false
  [[ -e "$metadata_context" ]] || return 0
  metadata_load_context
  if jq -e '.invalidating == true' "$metadata_context" >/dev/null; then
    if ! metadata_delete "$metadata_prefix/release"; then invalidation_failed=true; fi
  fi
  jq -cj --arg now "$(metadata_now)" --arg invalidation_failed "$invalidation_failed" '
    .attempt.status = "failed" | .attempt.recordedAt = $now |
    .attempt.errorCode = (if $invalidation_failed == "true" then "RELEASE_INVALIDATION_FAILED" else "DATABASE_OPERATION_FAILED" end) |
    .attempt.message = "Database operation failed; inspect this workflow run."
  ' "$metadata_context" > "$metadata_dir/context.tmp"
  mv "$metadata_dir/context.tmp" "$metadata_context"
  metadata_record
  [[ "$invalidation_failed" == false ]] || { metadata_error RELEASE_INVALIDATION_FAILED; return 1; }
}

metadata_main() {
  metadata_setup
  case "${1:-}" in
    begin-provision) metadata_begin provision "${2:?Base snapshot required}" ;;
    begin-destroy) metadata_begin destroy "${2:?Approved plan JSON required}" ;;
    publish) metadata_publish "${2:?Ready manifest required}" ;;
    destroyed) metadata_destroyed ;;
    failed) metadata_failed ;;
    *) metadata_error INVALID_METADATA_ACTION ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then metadata_main "$@"; fi
