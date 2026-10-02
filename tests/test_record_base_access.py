import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import record_base_access as m


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.candidate = dict(schemaVersion="1.0.0", environment="hom", accountId=m.ACCOUNT, region=m.REGION,
                              generation="88b99473-a7b0-4bf6-9e8d-3593135a12b4", exports={
                                  "cluster-name": "mecanica-hom-eks", "namespace": "default", "cluster-arn": "eks-arn", "vpc-id": "vpc-11111111"})
        self.writes = []
        self.denied = False
        self.changed = False
        self.reads = 0
        self.role = "database"
        def aws(*args, **kwargs):
            if args[:2] == ("sts", "get-caller-identity"):
                return {"Account": m.ACCOUNT, "Arn": f"arn:aws:sts::{m.ACCOUNT}:assumed-role/mecanica-hom-{self.role}-github/test"}
            if args[:2] == ("eks", "describe-cluster"):
                return {"cluster": {"status": "ACTIVE", "arn": "eks-arn", "resourcesVpcConfig": {"vpcId": "vpc-11111111"}}}
            if args[:2] == ("ssm", "get-parameter"):
                if args[3].endswith("base-access-check"):
                    return {"Parameter": {"Value": self.writes[-1]}}
                self.reads += 1
                return {"Parameter": {"Value": "{}" if self.changed and self.reads > 1 else json.dumps(self.candidate)}}
            if args[:2] == ("ssm", "put-parameter"):
                self.writes.append(args[-1])
                return {}
            raise AssertionError(args)
        def run(*args):
            if "can-i" in args:
                return "no" if self.denied else "yes"
            return "{}"
        for target, value in (("aws", aws), ("run", run)):
            p = patch.object(m, target, side_effect=value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.dict(os.environ, GITHUB_REPOSITORY="pknfelps/GerenciamentoMecanicaBancoDados", GITHUB_REF="refs/heads/develop", GITHUB_RUN_ID="123")
        p.start()
        self.addCleanup(p.stop)

    def test_actual_role_permission_check_publishes_evidence(self):
        m.check("hom")
        self.assertEqual(json.loads(self.writes[0])["checks"], m.CHECKS)
        self.assertEqual(len(json.loads(self.writes[0])["candidateSha256"]), 64)

    def test_wrong_role_does_not_publish(self):
        self.role = "base"
        with self.assertRaises(ValueError): m.check("hom")
        self.assertEqual(self.writes, [])

    def test_permission_denied_does_not_publish(self):
        self.denied = True
        with self.assertRaises(ValueError): m.check("hom")
        self.assertEqual(self.writes, [])

    def test_candidate_changes_during_check(self):
        self.changed = True
        with self.assertRaises(ValueError): m.check("hom")
        self.assertEqual(self.writes, [])

    def test_other_environment_refused(self):
        with self.assertRaises(ValueError): m.check("prd")
        self.assertEqual(self.writes, [])


if __name__ == "__main__":
    unittest.main()
