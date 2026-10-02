"""Record a real database-role Kubernetes check against the base candidate."""
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ACCOUNT = "121754142617"
REGION = "us-east-1"
CHECKS = ["create jobs.batch", "get jobs.batch", "list jobs.batch", "watch jobs.batch",
          "delete jobs.batch", "get pods", "list pods", "get pods/log",
          "create serviceaccounts", "get serviceaccounts"]


def run(*args, missing=False):
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        if missing and "(ParameterNotFound)" in result.stderr:
            return None
        raise ValueError("Access verification command failed")
    return result.stdout


def aws(*args, missing=False):
    raw = run("aws", *args, "--region", REGION, "--output", "json", missing=missing)
    return None if raw is None else json.loads(raw or "{}")


def check(environment):
    if environment not in ("hom", "prd"):
        raise ValueError("Invalid environment")
    expected_ref = "refs/heads/develop" if environment == "hom" else "refs/heads/main"
    if os.environ.get("GITHUB_REPOSITORY") != "pknfelps/GerenciamentoMecanicaBancoDados" or os.environ.get("GITHUB_REF") != expected_ref:
        raise ValueError("Invalid repository or branch")
    identity = aws("sts", "get-caller-identity")
    if identity["Account"] != ACCOUNT or not identity["Arn"].startswith(f"arn:aws:sts::{ACCOUNT}:assumed-role/mecanica-{environment}-database-github/"):
        raise ValueError("Invalid database identity")
    prefix = f"/mecanica/{environment}"
    candidate_name = f"{prefix}/base/v1/database-candidate"
    result = aws("ssm", "get-parameter", "--name", candidate_name, missing=True)
    if result is None:
        print("Acesso diagnosticado; sem candidato da base para registrar evidência SSM.")
        return
    raw = result["Parameter"]["Value"]
    candidate = json.loads(raw)
    if candidate.get("schemaVersion") != "1.0.0" or candidate.get("environment") != environment or candidate.get("accountId") != ACCOUNT or candidate.get("region") != REGION:
        raise ValueError("Invalid base candidate")
    exports = candidate["exports"]
    cluster_name = f"mecanica-{environment}-eks"
    if exports["cluster-name"] != cluster_name or exports["namespace"] != "default":
        raise ValueError("Unexpected cluster or namespace")
    cluster = aws("eks", "describe-cluster", "--name", cluster_name)["cluster"]
    if cluster["status"] != "ACTIVE" or cluster["arn"] != exports["cluster-arn"] or cluster["resourcesVpcConfig"]["vpcId"] != exports["vpc-id"]:
        raise ValueError("Base candidate resources no longer match")
    run("aws", "eks", "update-kubeconfig", "--name", cluster_name, "--region", REGION)
    # Every command executes with the database role obtained by this repository's OIDC.
    run("kubectl", "--request-timeout=30s", "auth", "whoami", "-o", "json")
    for permission in CHECKS:
        verb, resource = permission.split()
        if run("kubectl", "--request-timeout=30s", "auth", "can-i", verb, resource, "--namespace", "default").strip() != "yes":
            raise ValueError("Required Job permission missing")
    run("kubectl", "--request-timeout=30s", "get", "jobs", "--namespace", "default", "-o", "json")
    if aws("ssm", "get-parameter", "--name", candidate_name)["Parameter"]["Value"] != raw:
        raise ValueError("Base candidate changed during verification")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[0-9]+", run_id):
        raise ValueError("Invalid workflow run")
    canonical = json.dumps(candidate, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    evidence = dict(schemaVersion="1.0.0", environment=environment, generation=candidate["generation"],
                    candidateSha256=hashlib.sha256(canonical.encode()).hexdigest(),
                    roleArn=f"arn:aws:iam::{ACCOUNT}:role/mecanica/pipelines/mecanica-{environment}-database-github",
                    recordedAt=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                    runId=run_id, checks=CHECKS)
    value = json.dumps(evidence, separators=(",", ":"), sort_keys=True)
    if len(value.encode()) > 4096:
        raise ValueError("Evidence exceeds Standard parameter size")
    name = f"{prefix}/database/v1/base-access-check"
    aws("ssm", "put-parameter", "--name", name, "--type", "String", "--tier", "Standard", "--overwrite", "--value", value)
    if aws("ssm", "get-parameter", "--name", name)["Parameter"]["Value"] != value:
        raise ValueError("Evidence publication not confirmed")
    print("Evidência do acesso da role do banco registrada; a base ainda precisa publicar database-release.")


if __name__ == "__main__":
    try:
        check(os.environ.get("TARGET_ENVIRONMENT", ""))
    except (ValueError, KeyError, OSError):
        print("Falha ao verificar/registrar o acesso do banco. Nenhuma release foi publicada.", file=sys.stderr)
        sys.exit(1)
