import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import consume_database_release as m


def release(environment="hom"):
    return dict(schemaVersion="1.1.0", environment=environment, accountId=m.ACCOUNT,
                region=m.REGION, component="base", readinessProfile="database", status="ready",
                deploymentId="123-1-base", generation="88b99473-a7b0-4bf6-9e8d-3593135a12b4",
                source=dict(repository=m.PRODUCER, commit="a" * 40), recordedAt="2026-01-01T00:00:00Z",
                dependencies={}, artifacts=[], compatibility={}, verification=sorted(m.VERIFICATIONS),
                exports={"vpc-id": "vpc-11111111", "workload-subnet-ids": ["subnet-11111111", "subnet-22222222"],
                         "database-subnet-ids": ["subnet-33333333", "subnet-44444444"],
                         "cluster-name": f"mecanica-{environment}-eks",
                         "cluster-arn": f"arn:aws:eks:{m.REGION}:{m.ACCOUNT}:cluster/mecanica-{environment}-eks",
                         "namespace": "default", "api-security-group-id": "sg-11111111",
                         "init-security-group-id": "sg-11111111", "auth-security-group-id": "sg-22222222"})


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.environment = "hom"
        self.value = release()
        self.version = 1
        self.calls = []
        self.reads = 0
        self.change = None
        self.denied = False
        self.resource_fault = None
        self.role = "database"
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.context = Path(self.temp.name) / "base.json"
        env = patch.dict(os.environ, GITHUB_REPOSITORY=m.REPOSITORY, GITHUB_REF="refs/heads/develop")
        env.start()
        self.addCleanup(env.stop)
        for target, callback in (("aws", self.aws), ("run", self.fake_run)):
            mock = patch.object(m, target, side_effect=callback)
            mock.start()
            self.addCleanup(mock.stop)

    def aws(self, *args, **kwargs):
        self.calls.append(args)
        e = self.value["exports"]
        tags = [{"Key": k, "Value": v} for k, v in dict(Project="mecanica", Environment=self.environment, ManagedBy="Terraform").items()]
        if args[:2] == ("sts", "get-caller-identity"):
            result = dict(Account=m.ACCOUNT, Arn=f"arn:aws:sts::{m.ACCOUNT}:assumed-role/mecanica-{self.environment}-{self.role}-github/test")
        elif args[:2] == ("ssm", "get-parameter"):
            self.reads += 1
            if self.change and self.reads > 1:
                self.change()
            name = m.parameter(self.environment)
            result = {"Parameter": dict(Name=name, ARN=f"arn:aws:ssm:{m.REGION}:{m.ACCOUNT}:parameter{name}",
                                        Type="String", Version=self.version, Value=m.packed(self.value))}
        elif args[:2] == ("ec2", "describe-vpcs"):
            result = {"Vpcs": [dict(VpcId=e["vpc-id"], State="available", OwnerId=m.ACCOUNT, Tags=tags)]}
        elif args[:2] == ("ec2", "describe-subnets"):
            result = {"Subnets": [dict(SubnetId=s, VpcId=e["vpc-id"], OwnerId=m.ACCOUNT, State="available",
                                      MapPublicIpOnLaunch=False, AvailabilityZone=f"us-east-1{az}", Tags=tags)
                                   for s, az in zip(args[3:], "ab")]}
        elif args[:2] == ("ec2", "describe-route-tables"):
            routes = [dict(GatewayId="local", State="active")]
            if args[3].split("=")[-1] in e["workload-subnet-ids"]:
                routes.append(dict(DestinationCidrBlock="0.0.0.0/0", NatGatewayId="nat-11111111", State="active"))
            result = {"RouteTables": [dict(VpcId=e["vpc-id"], Routes=routes)]}
        elif args[:2] == ("eks", "describe-cluster"):
            result = {"cluster": dict(status="ACTIVE", arn=e["cluster-arn"], resourcesVpcConfig=dict(
                vpcId=e["vpc-id"], subnetIds=e["workload-subnet-ids"], clusterSecurityGroupId=e["api-security-group-id"]))}
        elif args[:2] == ("ec2", "describe-security-groups"):
            result = {"SecurityGroups": [dict(GroupId=s, VpcId=e["vpc-id"], OwnerId=m.ACCOUNT, Tags=tags,
                                               GroupName=f"mecanica-{self.environment}-auth") for s in args[3:]]}
        else:
            self.fail(f"Unexpected or mutating AWS call: {args}")
        if self.resource_fault:
            self.resource_fault(args, result)
        return result

    def fake_run(self, *args, **kwargs):
        if "can-i" in args:
            return "no" if self.denied else "yes"
        if "serviceaccount" in args:
            return '{"metadata":{"namespace":"default"}}'
        return "{}"

    def consume(self, recheck=False):
        return m.consume(self.environment, self.context, recheck)

    def test_capture_and_recheck_hom_without_full_release(self):
        captured = self.consume()
        self.assertEqual(captured["dependencies"]["base"], dict(parameter=m.parameter("hom"), deploymentId="123-1-base",
                         generation=self.value["generation"], sourceCommit="a" * 40))
        self.assertEqual(json.loads(self.context.read_text()), captured)
        before = self.context.read_bytes()
        self.consume(recheck=True)
        self.assertEqual(self.context.read_bytes(), before)
        self.assertEqual({c[3] for c in self.calls if c[:2] == ("ssm", "get-parameter")}, {m.parameter("hom")})

    def test_prd_is_independent(self):
        self.environment = "prd"
        self.value = release("prd")
        with patch.dict(os.environ, GITHUB_REF="refs/heads/main"):
            self.assertEqual(self.consume()["parameter"], m.parameter("prd"))

    def test_manifest_rejections(self):
        changes = [("schemaVersion", "1.0.0"), ("schemaVersion", "2.0.0"), ("schemaVersion", "1.1.0-beta"),
                   ("environment", "prd"), ("accountId", "000000000000"), ("region", "us-west-2"),
                   ("component", "database"), ("readinessProfile", "full"), ("status", "blocked"),
                   ("generation", None), ("generation", "not-a-uuid"), ("deploymentId", "latest"),
                   ("source", {"repository": "other", "commit": "a" * 40}), ("recordedAt", "2099-01-01T00:00:00Z"),
                   ("verification", []), ("dependencies", {"api": {}}), ("artifacts", {}), ("compatibility", [])]
        for field, value in changes:
            with self.subTest(field=field, value=value):
                candidate = release()
                candidate[field] = value
                with self.assertRaises((m.ReleaseError, ValueError)):
                    m.validate_manifest(candidate, "hom")

    def test_missing_fields_and_wrong_export_types(self):
        for field in m.FIELDS:
            for invalid in (None, {}, [], 123, "placeholder"):
                with self.subTest(field=field, invalid=invalid):
                    value = release()
                    value["exports"][field] = invalid
                    with self.assertRaises(m.ReleaseError): m.validate_manifest(value, "hom")
            value = release()
            del value["exports"][field]
            with self.assertRaises(m.ReleaseError): m.validate_manifest(value, "hom")

    def test_optional_future_fields_and_minor_are_accepted(self):
        self.value.update(schemaVersion="1.2.3", future="optional")
        self.value["exports"]["future"] = "optional"
        self.consume()

    def test_duplicate_json_and_nonfinite_numbers_rejected(self):
        for raw in ('{"status":"ready","status":"blocked"}', '{"x":NaN}'):
            with self.assertRaises(m.ReleaseError): m.decode(raw)

    def test_duplicate_and_overlapping_subnets(self):
        for ids in (["subnet-33333333"] * 2, self.value["exports"]["workload-subnet-ids"]):
            self.value["exports"]["database-subnet-ids"] = ids
            with self.assertRaises(m.ReleaseError): self.consume()

    def test_wrong_role_or_branch_before_resource_access(self):
        self.role = "base"
        with self.assertRaisesRegex(m.ReleaseError, "INVALID_DATABASE_ROLE"): self.consume()
        self.role = "database"
        with patch.dict(os.environ, GITHUB_REF="refs/heads/main"):
            with self.assertRaisesRegex(m.ReleaseError, "INVALID_REPOSITORY_OR_BRANCH"): self.consume()
        self.assertFalse(self.context.exists())

    def test_changes_during_capture_do_not_write_context(self):
        for field, value in (("generation", "12345678-abcd-4000-8000-123456789abc"), ("deploymentId", "124-1-base")):
            self.value = release()
            self.reads = 0
            self.change = lambda: self.value.update({field: value})
            with self.assertRaisesRegex(m.ReleaseError, "BASE_RELEASE_CHANGED"): self.consume()
            self.assertFalse(self.context.exists())

    def test_changed_version_rejected_even_with_same_manifest(self):
        self.consume()
        self.version += 1
        with self.assertRaisesRegex(m.ReleaseError, "BASE_RELEASE_CHANGED"): self.consume(True)

    def test_invalidation_during_capture_or_recheck_blocks(self):
        def absent():
            raise m.ReleaseError("BASE_NOT_READY")
        self.change = absent
        with self.assertRaisesRegex(m.ReleaseError, "BASE_NOT_READY"): self.consume()
        self.assertFalse(self.context.exists())
        self.change = None
        self.consume()
        self.change = absent
        with self.assertRaisesRegex(m.ReleaseError, "BASE_NOT_READY"): self.consume(True)

    def test_parameter_type_size_and_identity_rejected(self):
        for field, value in (("Type", "SecureString"), ("Version", True), ("Value", "x" * 4097),
                             ("Name", "/mecanica/prd/base/v1/database-release"), ("ARN", "foreign")):
            with self.subTest(field=field):
                self.resource_fault = lambda args, result: result["Parameter"].update({field: value}) if args[0] == "ssm" else None
                with self.assertRaises(m.ReleaseError): self.consume()
                self.assertFalse(self.context.exists())

    def test_changed_exports_without_new_revision_rejected(self):
        self.consume()
        self.value["exports"]["auth-security-group-id"] = "sg-33333333"
        with self.assertRaisesRegex(m.ReleaseError, "BASE_RELEASE_CHANGED"): self.consume(True)

    def test_saved_dependency_tampering_rejected(self):
        saved = self.consume()
        saved["dependencies"]["base"]["parameter"] = "/mecanica/hom/base/v1/release"
        self.context.write_text(m.packed(saved))
        with self.assertRaisesRegex(m.ReleaseError, "INVALID_SNAPSHOT"): self.consume(True)

    def test_permission_denial(self):
        self.denied = True
        with self.assertRaisesRegex(m.ReleaseError, "JOB_PERMISSION_MISSING"): self.consume()
        self.assertFalse(self.context.exists())

    def test_real_resource_mismatches(self):
        cases = [
            ("describe-vpcs", lambda r: r["Vpcs"][0].update(OwnerId="000000000000")),
            ("describe-vpcs", lambda r: r["Vpcs"][0].update(Tags=[])),
            ("describe-subnets", lambda r: r["Subnets"][0].update(VpcId="vpc-ffffffff")),
            ("describe-subnets", lambda r: r["Subnets"][0].update(MapPublicIpOnLaunch=True)),
            ("describe-subnets", lambda r: r["Subnets"][0].update(AvailabilityZone=r["Subnets"][1]["AvailabilityZone"])),
            ("describe-route-tables", lambda r: r["RouteTables"][0]["Routes"].append(dict(GatewayId="igw-11111111", State="active"))),
            ("describe-cluster", lambda r: r["cluster"].update(status="DELETING")),
            ("describe-cluster", lambda r: r["cluster"]["resourcesVpcConfig"].update(clusterSecurityGroupId="sg-ffffffff")),
            ("describe-security-groups", lambda r: r["SecurityGroups"][0].update(VpcId="vpc-ffffffff")),
        ]
        for operation, fault in cases:
            with self.subTest(operation=operation):
                self.resource_fault = lambda args, result: fault(result) if args[1] == operation else None
                with self.assertRaises(m.ReleaseError): self.consume()
                self.assertFalse(self.context.exists())

    def test_missing_and_access_denied_have_distinct_errors(self):
        # Exercise the real subprocess wrapper, not the fake AWS adapter.
        for stderr, code in (("(ParameterNotFound)", "BASE_NOT_READY"), ("(AccessDeniedException) sensitive", "DEPENDENCY_QUERY_FAILED")):
            with patch.object(m.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", stderr)):
                original = self.run_pure
                with self.assertRaisesRegex(m.ReleaseError, code): original("aws", "ssm", missing=True)


ConsumerTests.run_pure = staticmethod(m.run)

if __name__ == "__main__":
    unittest.main()
