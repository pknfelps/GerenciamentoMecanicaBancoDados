"""Execute the workflow's manifest step with fake AWS/Kubernetes/Terraform calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_database_manifest import JQ, ROOT, example_input


def workflow_script():
    text = (ROOT / ".github/workflows/database-provision.yml").read_text(encoding="utf-8")
    step = text.split("      - name: Assemble verified database manifest\n", 1)[1]
    body = step.split("        run: |\n", 1)[1].split("      - name:", 1)[0]
    return "\n".join(line[10:] for line in body.splitlines())


FAKE_COMMANDS = r'''
jq() { "$JQ_BIN" "$@"; }
python3() {
  if [[ "$*" != "scripts/consume_database_release.py recheck --environment $TARGET_ENVIRONMENT --context $BASE_CONTEXT" ]]; then
    echo 'Unexpected python command' >&2; return 90
  fi
  echo recheck >> "$RUNNER_TEMP/rechecks"
  if [[ "$(wc -l < "$RUNNER_TEMP/rechecks")" == "${FAIL_RECHECK:-0}" ]]; then return 91; fi
}
terraform() {
  [[ "$*" == '-chdir=terraform output -json' ]] || return 90
  cat "$RUNNER_TEMP/fake-outputs.json"
}
aws() {
  [[ "$1 $2" == 'rds describe-db-instances' ]] || return 90
  [[ "$4" == "mecanica-$TARGET_ENVIRONMENT-postgres" ]] || return 90
  cat "$RUNNER_TEMP/fake-instance.json"
}
kubectl() {
  if [[ "$*" == '-n default get job database-init -o json' ]]; then
    cat "$RUNNER_TEMP/fake-job.json"
  elif [[ "$*" == "-n default get pods -l batch.kubernetes.io/controller-uid=$INITIALIZATION_JOB_UID -o json" ]]; then
    cat "$RUNNER_TEMP/fake-pods.json"
  else echo 'Unexpected kubectl command' >&2; return 90; fi
}
'''


class WorkflowManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = os.environ.get("BASH_BIN") or shutil.which("bash")
        if not cls.bash or not JQ:
            raise RuntimeError("bash and jq are required; set BASH_BIN/JQ_BIN when necessary")

    def run_step(self, environment="hom", fault=None):
        value = example_input(environment)
        value["baseContext"]["manifest"]["exports"]["vpc-id"] = "vpc-11111111"
        outputs = value["outputs"]
        instance = dict(arn=outputs["instance_arn"]["value"], endpoint=outputs["endpoint"]["value"],
                        port=5432, database="mecanica", status="available", public=False, engine="postgres",
                        vpc="vpc-11111111", adminSecret=outputs["admin_secret_arn"]["value"],
                        groups=[dict(Status="active", VpcSecurityGroupId=outputs["security_group_id"]["value"])])
        uid = value["job"]["metadata"]["uid"]
        pod = dict(metadata=dict(namespace="default", ownerReferences=[dict(kind="Job", controller=True, uid=uid)]),
                   spec=dict(containers=[dict(name="initialize", env=[dict(name="PGSSLMODE", value="verify-full")])]),
                   status=dict(phase="Succeeded", containerStatuses=[dict(name="initialize",
                     state=dict(terminated=dict(exitCode=0, message=json.dumps(value["schema"]))))]))
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            env = dict(os.environ, RUNNER_TEMP=temp.as_posix(), BASE_CONTEXT=(temp / "base.json").as_posix(),
                       GITHUB_STEP_SUMMARY=(temp / "summary.md").as_posix(), TARGET_ENVIRONMENT=environment,
                       GITHUB_REPOSITORY=value["execution"]["repository"], GITHUB_SHA=value["execution"]["commit"],
                       GITHUB_RUN_ID="456", GITHUB_RUN_ATTEMPT="1", INITIALIZATION_JOB_UID=uid,
                       API_SECRET_ARN=value["credentials"]["apiSecretArn"], AUTH_SECRET_ARN=value["credentials"]["authSecretArn"],
                       JQ_BIN=Path(JQ).as_posix())
            if fault:
                fault(value, instance, pod, env)
            for filename, data in (("base.json", value["baseContext"]), ("fake-outputs.json", outputs),
                                   ("fake-instance.json", instance), ("fake-job.json", value["job"]),
                                   ("fake-pods.json", {"items": [pod]})):
                (temp / filename).write_text(json.dumps(data), encoding="utf-8")
            # A stale local candidate must never survive a failed assembly.
            (temp / "database-release.json").write_text('stale candidate', encoding="utf-8")
            result = subprocess.run([self.bash, "--noprofile", "--norc", "-c", FAKE_COMMANDS + workflow_script()],
                                    cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", timeout=15)
            manifest = temp / "database-release.json"
            output = manifest.read_text(encoding="utf-8") if manifest.exists() else None
            rechecks = (temp / "rechecks").read_text().splitlines() if (temp / "rechecks").exists() else []
            return result, output, rechecks

    def test_hom_and_prd_collect_and_generate_after_two_rechecks(self):
        for environment in ("hom", "prd"):
            with self.subTest(environment=environment):
                result, output, rechecks = self.run_step(environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads(output)
                self.assertEqual(manifest["environment"], environment)
                self.assertEqual(manifest["exports"]["initialized-at"], "2026-01-01T12:00:00.123456Z")
                self.assertEqual(rechecks, ["recheck", "recheck"])
                self.assertNotIn("fake-", output)

    def test_failures_do_not_leave_a_reviewable_manifest(self):
        cases = {
            "base changed before collecting": lambda v, r, p, e: e.update(FAIL_RECHECK="1"),
            "base changed after assembling": lambda v, r, p, e: e.update(FAIL_RECHECK="2"),
            "public RDS": lambda v, r, p, e: r.update(public=True),
            "wrong RDS endpoint": lambda v, r, p, e: r.update(endpoint="foreign-db.example.com"),
            "wrong VPC": lambda v, r, p, e: r.update(vpc="vpc-22222222"),
            "wrong admin secret": lambda v, r, p, e: r.update(adminSecret="foreign-secret"),
            "inactive SG": lambda v, r, p, e: r["groups"][0].update(Status="inactive"),
            "replaced Job": lambda v, r, p, e: v["job"]["metadata"].update(uid="88888888-8888-4888-8888-888888888888"),
            "foreign pod": lambda v, r, p, e: p["metadata"]["ownerReferences"][0].update(uid="88888888-8888-4888-8888-888888888888"),
            "failed container": lambda v, r, p, e: p["status"]["containerStatuses"][0]["state"]["terminated"].update(exitCode=1),
            "invalid SQL marker": lambda v, r, p, e: p["status"]["containerStatuses"][0]["state"]["terminated"].update(message="not JSON"),
            "empty SQL marker": lambda v, r, p, e: p["status"]["containerStatuses"][0]["state"]["terminated"].update(message="[]"),
            "TLS disabled": lambda v, r, p, e: p["spec"]["containers"][0]["env"][0].update(value="disable"),
        }
        for name, fault in cases.items():
            with self.subTest(name=name):
                result, output, _ = self.run_step(fault=fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(output)


if __name__ == "__main__":
    unittest.main()
