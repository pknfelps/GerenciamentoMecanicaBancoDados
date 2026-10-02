"""Capture and recheck the database profile using AWS CLI and the database role.

No SSM writes, secret reads, Terraform state access or workload mutations.
The saved snapshot is an input to a future database operation, not its release.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone
from uuid import UUID

from record_base_access import ACCOUNT, REGION, CHECKS

REPOSITORY = "pknfelps/GerenciamentoMecanicaBancoDados"
PRODUCER = "pknfelps/GerenciamentoMecanicaInfraestrutura"
FIELDS = ("vpc-id", "workload-subnet-ids", "database-subnet-ids", "cluster-name",
          "cluster-arn", "namespace", "api-security-group-id", "auth-security-group-id",
          "init-security-group-id")
VERIFICATIONS = {"eks-health", "private-network", "effective-security-groups", "namespace",
                 "database-access-policy", "database-role-kubernetes-access"}


class ReleaseError(Exception):
    """A sanitized, stable diagnostic code."""


def require(condition, code):
    if not condition:
        raise ReleaseError(code)


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def packed(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "DUPLICATE_JSON_KEY")
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda _: require(False, "INVALID_JSON_NUMBER"))


def run(*args, missing=False):
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", timeout=90)
    if result.returncode:
        if missing and "(ParameterNotFound)" in result.stderr:
            raise ReleaseError("BASE_NOT_READY")
        raise ReleaseError("DEPENDENCY_QUERY_FAILED")
    return result.stdout


def aws(*args, missing=False):
    return decode(run("aws", *args, "--region", REGION, "--output", "json",
                      "--no-cli-pager", missing=missing))


def kubectl(*args):
    return run("kubectl", "--request-timeout=30s", *args)


def parameter(environment):
    require(environment in ("hom", "prd"), "INVALID_ENVIRONMENT")
    return f"/mecanica/{environment}/base/v1/database-release"


def validate_manifest(value, environment):
    parameter(environment)
    require(isinstance(value, dict), "INVALID_MANIFEST")
    version = value.get("schemaVersion")
    require(matches(r"1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version)
            and int(version.split(".")[1]) >= 1, "UNSUPPORTED_SCHEMA")
    require(value.get("environment") == environment and value.get("accountId") == ACCOUNT
            and value.get("region") == REGION and value.get("component") == "base", "MANIFEST_IDENTITY_MISMATCH")
    require(value.get("readinessProfile") == "database" and value.get("status") == "ready", "BASE_NOT_READY")
    generation = value.get("generation")
    require(isinstance(generation, str) and str(UUID(generation)) == generation
            and UUID(generation).int != 0, "INVALID_GENERATION")
    require(matches(r"[1-9][0-9]*-[1-9][0-9]*-base", value.get("deploymentId")), "INVALID_DEPLOYMENT")
    source = value.get("source")
    require(isinstance(source, dict) and source.get("repository") == PRODUCER
            and matches(r"[0-9a-f]{40}", source.get("commit")), "INVALID_SOURCE")
    recorded = value.get("recordedAt")
    require(matches(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z", recorded), "INVALID_TIMESTAMP")
    require(datetime.fromisoformat(recorded.replace("Z", "+00:00")) <= datetime.now(timezone.utc), "FUTURE_TIMESTAMP")
    require(value.get("dependencies") == {}, "UNEXPECTED_BASE_DEPENDENCIES")
    require(isinstance(value.get("artifacts"), list) and isinstance(value.get("compatibility"), dict), "INVALID_MANIFEST")
    checks = value.get("verification")
    require(isinstance(checks, list) and all(isinstance(c, str) for c in checks)
            and VERIFICATIONS.issubset(checks), "MISSING_BASE_VERIFICATION")
    exports = value.get("exports")
    require(isinstance(exports, dict) and all(field in exports for field in FIELDS), "MISSING_EXPORT")
    require(matches(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})", exports["vpc-id"]), "INVALID_VPC")
    for field in ("workload-subnet-ids", "database-subnet-ids"):
        ids = exports[field]
        require(isinstance(ids, list) and len(ids) == 2
                and all(matches(r"subnet-(?:[0-9a-f]{8}|[0-9a-f]{17})", v) for v in ids)
                and len(set(ids)) == 2, "INVALID_SUBNETS")
    require(not set(exports["workload-subnet-ids"]) & set(exports["database-subnet-ids"]), "SUBNET_LAYERS_OVERLAP")
    name = f"mecanica-{environment}-eks"
    require(exports["cluster-name"] == name and exports["cluster-arn"] == f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/{name}", "INVALID_CLUSTER")
    require(exports["namespace"] == "default", "INVALID_NAMESPACE")
    for field in FIELDS:
        if field.endswith("security-group-id"):
            require(matches(r"sg-(?:[0-9a-f]{8}|[0-9a-f]{17})", exports[field]), "INVALID_SECURITY_GROUP")
    return value


def read_release(environment):
    name = parameter(environment)
    result = aws("ssm", "get-parameter", "--name", name, missing=True)["Parameter"]
    require(result["Name"] == name and result["Type"] == "String"
            and result["ARN"] == f"arn:aws:ssm:{REGION}:{ACCOUNT}:parameter{name}", "INVALID_PARAMETER")
    raw = result["Value"]
    require(isinstance(raw, str) and len(raw.encode("utf-8")) <= 4096, "INVALID_PARAMETER_SIZE")
    require(type(result["Version"]) is int and result["Version"] > 0, "INVALID_PARAMETER_VERSION")
    return {"parameter": name, "ssmVersion": result["Version"],
            "manifest": validate_manifest(decode(raw), environment)}


def check_identity(environment):
    parameter(environment)
    branch = "develop" if environment == "hom" else "main"
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_REF") == f"refs/heads/{branch}", "INVALID_REPOSITORY_OR_BRANCH")
    identity = aws("sts", "get-caller-identity")
    require(identity["Account"] == ACCOUNT and matches(
        rf"arn:aws:sts::{ACCOUNT}:assumed-role/mecanica-{environment}-database-github/[^/]+", identity["Arn"]), "INVALID_DATABASE_ROLE")


def tags_match(resource, environment):
    tags = {tag["Key"]: tag["Value"] for tag in resource.get("Tags", [])}
    return all(tags.get(k) == v for k, v in
               {"Project": "mecanica", "Environment": environment, "ManagedBy": "Terraform"}.items())


def check_resources(exports, environment):
    vpc_id = exports["vpc-id"]
    vpcs = aws("ec2", "describe-vpcs", "--vpc-ids", vpc_id)["Vpcs"]
    require(len(vpcs) == 1 and vpcs[0]["VpcId"] == vpc_id and vpcs[0]["OwnerId"] == ACCOUNT
            and vpcs[0]["State"] == "available" and tags_match(vpcs[0], environment), "VPC_NOT_READY")
    for layer in ("workload", "database"):
        ids = exports[f"{layer}-subnet-ids"]
        subnets = aws("ec2", "describe-subnets", "--subnet-ids", *ids)["Subnets"]
        require(len(subnets) == 2 and {s["SubnetId"] for s in subnets} == set(ids)
                and len({s["AvailabilityZone"] for s in subnets}) == 2, "INVALID_SUBNET_AZS")
        for subnet in subnets:
            require(subnet["VpcId"] == vpc_id and subnet["OwnerId"] == ACCOUNT
                    and subnet["State"] == "available" and subnet["MapPublicIpOnLaunch"] is False
                    and tags_match(subnet, environment), "INVALID_PRIVATE_SUBNET")
            tables = aws("ec2", "describe-route-tables", "--filters",
                         f"Name=association.subnet-id,Values={subnet['SubnetId']}")["RouteTables"]
            require(len(tables) == 1 and tables[0]["VpcId"] == vpc_id, "INVALID_ROUTE_TABLE")
            routes = tables[0]["Routes"]
            require(bool(routes), "MISSING_ROUTES")
            if layer == "database":
                require(all(r.get("GatewayId") == "local" and r.get("State") == "active" for r in routes), "DATABASE_NOT_ISOLATED")
            else:
                require(not any(str(r.get("GatewayId", "")).startswith("igw-") for r in routes)
                        and any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and r.get("NatGatewayId")
                                and r.get("State") == "active" for r in routes), "INVALID_WORKLOAD_ROUTES")
    cluster = aws("eks", "describe-cluster", "--name", exports["cluster-name"])["cluster"]
    config = cluster["resourcesVpcConfig"]
    require(cluster["status"] == "ACTIVE" and cluster["arn"] == exports["cluster-arn"]
            and config["vpcId"] == vpc_id and set(config["subnetIds"]) == set(exports["workload-subnet-ids"]), "CLUSTER_MISMATCH")
    require(exports["api-security-group-id"] == exports["init-security-group-id"] == config["clusterSecurityGroupId"], "POD_SECURITY_GROUP_MISMATCH")
    group_ids = {exports[f] for f in FIELDS if f.endswith("security-group-id")}
    groups = aws("ec2", "describe-security-groups", "--group-ids", *sorted(group_ids))["SecurityGroups"]
    require(len(groups) == len(group_ids) and {g["GroupId"] for g in groups} == group_ids
            and all(g["VpcId"] == vpc_id and g["OwnerId"] == ACCOUNT for g in groups), "SECURITY_GROUP_MISMATCH")
    auth = next(g for g in groups if g["GroupId"] == exports["auth-security-group-id"])
    require(auth["GroupName"] == f"mecanica-{environment}-auth" and tags_match(auth, environment), "AUTH_SECURITY_GROUP_MISMATCH")
    run("aws", "eks", "update-kubeconfig", "--name", exports["cluster-name"], "--region", REGION)
    kubectl("auth", "whoami", "-o", "json")
    for permission in CHECKS:
        verb, resource = permission.split()
        require(kubectl("auth", "can-i", verb, resource, "--namespace", exports["namespace"]).strip() == "yes", "JOB_PERMISSION_MISSING")
    # A namespace-scoped identity need not have permission to GET namespaces.
    account = decode(kubectl("get", "serviceaccount", "default", "--namespace", exports["namespace"], "-o", "json"))
    require(account["metadata"]["namespace"] == exports["namespace"], "NAMESPACE_NOT_READY")
    kubectl("get", "jobs", "--namespace", exports["namespace"], "-o", "json")


def dependency(snapshot):
    manifest = snapshot["manifest"]
    return {"base": {"parameter": snapshot["parameter"], "deploymentId": manifest["deploymentId"],
                     "generation": manifest["generation"], "sourceCommit": manifest["source"]["commit"]}}


def consume(environment, context, recheck=False):
    check_identity(environment)
    context = Path(context)
    current = read_release(environment)
    if recheck:
        saved = decode(context.read_text(encoding="utf-8"))
        validate_manifest(saved["manifest"], environment)
        require(saved["parameter"] == parameter(environment)
                and saved.get("dependencies") == dependency(saved), "INVALID_SNAPSHOT")
        require({key: saved[key] for key in current} == current, "BASE_RELEASE_CHANGED")
    check_resources(current["manifest"]["exports"], environment)
    require(read_release(environment) == current, "BASE_RELEASE_CHANGED")
    current["dependencies"] = dependency(current)
    if not recheck:
        context.parent.mkdir(parents=True, exist_ok=True)
        temporary = context.with_name(context.name + ".tmp")
        temporary.write_text(packed(current) + "\n", encoding="utf-8")
        temporary.replace(context)
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("capture", "recheck"))
    parser.add_argument("--environment", required=True, choices=("hom", "prd"))
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    try:
        consume(args.environment, args.context, args.action == "recheck")
    except ReleaseError as error:
        print(f"Consumo bloqueado: {error}.", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError, OSError, StopIteration, subprocess.TimeoutExpired):
        print("Consumo bloqueado: INVALID_DEPENDENCY_OR_QUERY. Nenhuma implantação executada.", file=sys.stderr)
        return 1
    print("database-release validada com a role do banco; nenhum Aurora ou esquema foi implantado.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
