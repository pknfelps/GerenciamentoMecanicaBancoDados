"""Offline contract tests for the jq manifest; no AWS or database operations."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
JQ = os.environ.get("JQ_BIN") or shutil.which("jq")


def example_input(environment="hom"):
    generation = "88b99473-a7b0-4bf6-9e8d-3593135a12b4"
    dependency = dict(parameter=f"/mecanica/{environment}/base/v1/database-release",
                      deploymentId="123-1-base", generation=generation, sourceCommit="a" * 40)
    base = dict(schemaVersion="1.1.0", environment=environment, component="base",
                accountId="121754142617", region="us-east-1", status="ready", readinessProfile="database",
                deploymentId=dependency["deploymentId"], generation=generation,
                source=dict(repository="pknfelps/GerenciamentoMecanicaInfraestrutura", commit="a" * 40),
                recordedAt="2026-01-01T00:00:00Z", exports={"namespace": "default"})
    secret_prefix = "arn:aws:secretsmanager:us-east-1:121754142617:secret:"
    outputs = dict(instance_arn=f"arn:aws:rds:us-east-1:121754142617:db:mecanica-{environment}-postgres",
                   endpoint=f"mecanica-{environment}-postgres.example123.us-east-1.rds.amazonaws.com",
                   port=5432, database_name="mecanica", security_group_id="sg-11111111",
                   admin_secret_arn=secret_prefix + "rds!db-11111111-1111-4111-8111-111111111111-AbCd12",
                   base_dependency=dependency)
    return dict(execution=dict(environment=environment, repository="pknfelps/GerenciamentoMecanicaBancoDados",
                               commit="b" * 40, runId="456", runAttempt="1", recordedAt="2026-01-02T00:00:00Z"),
                baseContext=dict(parameter=dependency["parameter"], ssmVersion=1, manifest=base,
                                 dependencies={"base": dependency}),
                outputs={key: {"value": value} for key, value in outputs.items()},
                credentials=dict(apiSecretArn=secret_prefix + f"/mecanica/{environment}/database/api-AbCd12",
                                 authSecretArn=secret_prefix + f"/mecanica/{environment}/database/auth-EfGh34"),
                schema=[dict(version="1.0.0", sha256=hashlib.sha256((ROOT / "sql/Init.sql").read_bytes()).hexdigest(),
                             initialized_at="2026-01-01T12:00:00.123456Z")],
                job=dict(apiVersion="batch/v1", kind="Job",
                         metadata=dict(name="database-init", namespace="default",
                                       uid="99999999-9999-4999-8999-999999999999", creationTimestamp="2026-01-01T11:59:59Z"),
                         status=dict(startTime="2026-01-01T12:00:00Z", completionTime="2026-01-01T12:00:03Z",
                                     succeeded=1, conditions=[dict(type="Complete", status="True")])),
                verification=["rds-private", "tls-verify-full", "schema-seeds", "api-login-permissions", "auth-login-permissions"])


class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not JQ:
            raise RuntimeError("jq is required; set JQ_BIN when it is not on PATH")

    def assemble(self, value):
        digest = hashlib.sha256((ROOT / "sql/Init.sql").read_bytes()).hexdigest()
        return subprocess.run([JQ, "-cej", "--arg", "schema_version", "1.0.0", "--arg", "sql_sha256", digest,
                               "-f", str(ROOT / "manifests/database-release.jq")],
                              input=json.dumps(value), capture_output=True, text=True, encoding="utf-8", timeout=10)

    def test_build_hom_and_prd_with_typed_exports(self):
        for environment in ("hom", "prd"):
            with self.subTest(environment=environment):
                source = example_input(environment)
                result = self.assemble(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads(result.stdout)
                self.assertEqual(manifest["schemaVersion"], "1.1.0")
                self.assertEqual(manifest["status"], "ready")
                self.assertEqual(manifest["deploymentId"], "456-1-database")
                self.assertEqual(manifest["environment"], environment)
                self.assertEqual(manifest["generation"], manifest["dependencies"]["base"]["generation"])
                self.assertEqual(manifest["dependencies"], source["baseContext"]["dependencies"])
                self.assertEqual(len(manifest["exports"]), 12)
                self.assertEqual(type(manifest["exports"]["port"]), int)
                self.assertEqual(manifest["exports"]["initialized-at"], source["schema"][0]["initialized_at"])
                self.assertEqual(manifest["exports"]["ssl-mode"], "VerifyFull")
                self.assertLessEqual(len(result.stdout.rstrip().encode("utf-8")), 4096)
                self.assertNotIn("job", manifest)
                self.assertNotIn("outputs", manifest)

    def test_reject_inconsistent_or_incomplete_evidence_without_output(self):
        cases = [
            ("wrong environment", ("execution", "environment"), "dev"),
            ("wrong repository", ("execution", "repository"), "other/repository"),
            ("short commit", ("execution", "commit"), "b" * 7),
            ("invalid run", ("execution", "runId"), "0"),
            ("non UTC", ("execution", "recordedAt"), "2026-01-02T00:00:00-03:00"),
            ("invalid date", ("execution", "recordedAt"), "2026-02-31T00:00:00Z"),
            ("future date", ("execution", "recordedAt"), "2099-01-01T00:00:00Z"),
            ("unready base", ("baseContext", "manifest", "status"), "failed"),
            ("wrong base profile", ("baseContext", "manifest", "readinessProfile"), "full"),
            ("other environment base", ("baseContext", "parameter"), "/mecanica/prd/base/v1/database-release"),
            ("other account", ("baseContext", "manifest", "accountId"), "000000000000"),
            ("zero generation", ("baseContext", "manifest", "generation"), "00000000-0000-0000-0000-000000000000"),
            ("changed generation", ("outputs", "base_dependency", "value", "generation"), "11111111-1111-4111-8111-111111111111"),
            ("missing snapshot version", ("baseContext", "ssmVersion"), None),
            ("wrong instance", ("outputs", "instance_arn", "value"), "arn:aws:rds:us-east-1:121754142617:db:mecanica-prd-postgres"),
            ("endpoint with credentials", ("outputs", "endpoint", "value"), "postgres://user:password@db:5432/mecanica"),
            ("string port", ("outputs", "port", "value"), "5432"),
            ("invalid SG", ("outputs", "security_group_id", "value"), "sg-placeholder"),
            ("foreign auth secret", ("credentials", "authSecretArn"), "arn:aws:secretsmanager:us-east-1:121754142617:secret:/mecanica/prd/database/auth-EfGh34"),
            ("changed SQL", ("schema", 0, "sha256"), "0" * 64),
            ("changed schema version", ("schema", 0, "version"), "2.0.0"),
            ("missing marker", ("schema",), []),
            ("duplicate marker", ("schema",), example_input()["schema"] * 2),
            ("failed Job", ("job", "status", "failed"), 1),
            ("active Job", ("job", "status", "active"), 1),
            ("missing completion", ("job", "status", "conditions"), []),
            ("Job precedes initialization", ("job", "status", "completionTime"), "2026-01-01T12:00:00Z"),
            ("Job after manifest", ("job", "status", "completionTime"), "2026-01-03T00:00:00Z"),
            ("wrong namespace", ("job", "metadata", "namespace"), "other"),
            ("invalid Job UID", ("job", "metadata", "uid"), "-" * 36),
            ("missing base namespace", ("baseContext", "manifest", "exports", "namespace"), None),
            ("Job start precedes creation", ("job", "status", "startTime"), "2026-01-01T11:59:58Z"),
            ("missing auth check", ("verification",), ["rds-private", "tls-verify-full", "schema-seeds", "api-login-permissions"]),
            ("oversized manifest", ("execution", "recordedAt"), "2026-01-02T00:00:00." + "0" * 4096 + "Z"),
        ]
        for name, path, replacement in cases:
            with self.subTest(name=name):
                value = example_input()
                target = value
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                result = self.assemble(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_secret_values_cannot_be_accidentally_exported(self):
        for path in ((), ("credentials",), ("execution",), ("schema", 0)):
            with self.subTest(path=path):
                value = example_input()
                target = value
                for key in path:
                    target = target[key]
                target["password"] = "never-export-this-synthetic-value"
                result = self.assemble(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("never-export-this-synthetic-value", result.stdout + result.stderr)

    def test_only_selected_outputs_are_exported(self):
        value = example_input()
        value["outputs"]["unexpected_secret"] = {"value": "never-export-this-synthetic-value"}
        value["job"]["spec"] = {"fake_private_data": "never-export-this-synthetic-value"}
        result = self.assemble(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("never-export-this-synthetic-value", result.stdout)


if __name__ == "__main__":
    unittest.main()
