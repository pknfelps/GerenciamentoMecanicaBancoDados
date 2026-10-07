"""SSM lifecycle tests execute Bash against a local fake CLI, never AWS."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_database_manifest import JQ, ROOT, example_input
import test_database_manifest as manifest_tests

BACKEND = r'''
import json, sys
from pathlib import Path
directory = Path(sys.argv[1])
path = directory / 'fake-ssm.json'
state = json.loads(path.read_text(encoding='utf-8'))
args = sys.argv[2:]
def save():
    path.write_text(json.dumps(state), encoding='utf-8')
if args[0] == 'clock':
    print(state['clock']); sys.exit(0)
if args[0] == 'sleep':
    state['clock'] += int(args[1]); state['sleeps'].append(int(args[1])); save(); sys.exit(0)
assert args[0] == 'ssm', 'Only fake SSM is permitted'
action = args[1]
assert action in ('get-parameter', 'put-parameter', 'delete-parameter')
def option(name):
    return args[args.index(name) + 1]
assert option('--region') == 'us-east-1' and '--no-cli-pager' in args
name = option('--name')
state['calls'].append([action, name])
if action == state.get('fail_action') and name == state.get('fail_name'):
    if state.get('fail_once'):
        state.pop('fail_action')
    save(); print('(AccessDeniedException) synthetic denied', file=sys.stderr); sys.exit(254)
if action == 'put-parameter':
    assert option('--type') == 'String' and option('--tier') == 'Standard'
    assert option('--data-type') == 'text' and '--overwrite' in args
    uri = option('--value')
    assert uri.startswith('file://')
    value = Path(uri[7:]).read_text(encoding='utf-8')
    assert len(value.encode('utf-8')) <= 4096
    old_version = state['parameters'].get(name, {}).get('version', 0)
    state['parameters'][name] = {'value': value, 'version': old_version + 1}
    state['writes'].append([name, value])
    save(); print(json.dumps({'Version': old_version + 1})); sys.exit(0)
if action == 'delete-parameter':
    if name not in state['parameters']:
        save(); print('(ParameterNotFound)', file=sys.stderr); sys.exit(254)
    del state['parameters'][name]
    save(); print('{}'); sys.exit(0)
save()
if name.endswith('/base/v1/database-release') and name not in state['parameters']:
    snapshot = json.loads((directory / 'base.json').read_text(encoding='utf-8'))
    state['parameters'][name] = {'value': json.dumps(snapshot['manifest']), 'version': snapshot['ssmVersion']}
    save()
if name not in state['parameters']:
    print('(ParameterNotFound)', file=sys.stderr); sys.exit(254)
item = state['parameters'][name]
value = 'synthetic wrong readback' if name == state.get('wrong_readback_name') else item['value']
print(json.dumps({'Parameter': {'Name': name, 'ARN': 'arn:aws:ssm:us-east-1:121754142617:parameter' + name,
                               'Type': 'String', 'Version': item['version'], 'Value': value}}))
'''

DRIVER = r'''
jq() { "$JQ_BIN" "$@"; }
aws() { "$TEST_PYTHON" "$TEST_BACKEND" "$RUNNER_TEMP" "$@"; }
sleep() { "$TEST_PYTHON" "$TEST_BACKEND" "$RUNNER_TEMP" sleep "$1"; }
date() {
  if [[ "$*" == '+%s' ]]; then "$TEST_PYTHON" "$TEST_BACKEND" "$RUNNER_TEMP" clock
  else command date "$@"; fi
}
source "$METADATA_SCRIPT"
metadata_main "$@"
'''

FIELDS = ['instance-arn', 'endpoint', 'port', 'database-name', 'security-group-id', 'ssl-mode',
          'api-secret-arn', 'auth-secret-arn', 'admin-secret-arn', 'schema-version', 'schema-sha256', 'initialized-at']


class MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = os.environ.get('BASH_BIN') or shutil.which('bash')
        if not cls.bash or not JQ:
            raise RuntimeError('Bash and jq required; set BASH_BIN/JQ_BIN when necessary')

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name)
        (self.temp / 'backend.py').write_text(BACKEND, encoding='utf-8')
        self.state = dict(parameters={}, calls=[], writes=[], sleeps=[], clock=1000)
        self.save_state()

    def save_state(self):
        (self.temp / 'fake-ssm.json').write_text(json.dumps(self.state), encoding='utf-8')

    def read_state(self):
        self.state = json.loads((self.temp / 'fake-ssm.json').read_text(encoding='utf-8'))
        return self.state

    def prepare(self, environment='hom'):
        value = example_input(environment)
        result = manifest_tests.ManifestTests().assemble(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.manifest = json.loads(result.stdout)
        (self.temp / 'ready.json').write_text(result.stdout, encoding='utf-8')
        (self.temp / 'base.json').write_text(json.dumps(value['baseContext']), encoding='utf-8')
        self.prefix = f'/mecanica/{environment}/database/v1'
        self.attempt = self.prefix + '/attempts/456-1-database'
        self.env = dict(os.environ, TARGET_ENVIRONMENT=environment,
                        GITHUB_REF='refs/heads/develop' if environment == 'hom' else 'refs/heads/main',
                        GITHUB_REPOSITORY=value['execution']['repository'], GITHUB_SHA=value['execution']['commit'],
                        GITHUB_RUN_ID='456', GITHUB_RUN_ATTEMPT='1', RUNNER_TEMP=self.temp.as_posix(),
                        JQ_BIN=Path(JQ).as_posix(), TEST_PYTHON=Path(sys.executable).as_posix(),
                        TEST_BACKEND=(self.temp / 'backend.py').as_posix(),
                        METADATA_SCRIPT=(ROOT / 'scripts/database_metadata.sh').as_posix())
        # Git Bash must pass SSM names as strings, not translate /mecanica into Windows paths.
        self.env['MSYS2_ARG_CONV_EXCL'] = '*'

    def run_action(self, action, filename=None, success=True):
        args = [self.bash, '--noprofile', '--norc', '-c', DRIVER, 'metadata-test', action]
        if filename:
            args.append((self.temp / filename).as_posix())
        result = subprocess.run(args, env=self.env, cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.read_state()
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def parameter(self, name, value):
        self.state['parameters'][name] = dict(value=value, version=1)
        self.save_state()

    def test_publish_hom_and_prd_fields_then_ready_attempt_then_release(self):
        # Each environment gets an independent runner/context.
        for environment in ('hom', 'prd'):
            with self.subTest(environment=environment):
                self.prepare(environment)
                if (self.temp / 'database-metadata/context.json').exists():
                    (self.temp / 'database-metadata/context.json').unlink()
                self.state = dict(parameters={}, calls=[], writes=[], sleeps=[], clock=1000)
                self.save_state()
                self.parameter(self.prefix + '/release', json.dumps(self.manifest))
                self.run_action('begin-provision', 'base.json')
                self.assertNotIn(self.prefix + '/release', self.state['parameters'])
                self.assertEqual(json.loads(self.state['parameters'][self.attempt]['value'])['status'], 'running')
                self.run_action('publish', 'ready.json')
                writes = self.state['writes']
                self.assertEqual([name for name, _ in writes[1:-2]], [self.prefix + '/' + field for field in FIELDS])
                self.assertEqual([name for name, _ in writes[-2:]], [self.attempt, self.prefix + '/release'])
                self.assertEqual(json.loads(writes[-1][1]), self.manifest)
                self.assertEqual(writes[-1][1], writes[-2][1])
                self.assertGreaterEqual(sum(self.state['sleeps']), 30)

    def test_failed_publication_keeps_readiness_absent(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        self.state.update(fail_action='put-parameter', fail_name=self.prefix + '/schema-version')
        self.save_state()
        self.run_action('publish', 'ready.json', success=False)
        self.run_action('failed')
        self.assertNotIn(self.prefix + '/release', self.state['parameters'])
        self.assertEqual(json.loads(self.state['parameters'][self.attempt]['value'])['status'], 'failed')

    def test_unconfirmed_release_write_is_invalidated(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        self.state['wrong_readback_name'] = self.prefix + '/release'
        self.save_state()
        self.run_action('publish', 'ready.json', success=False)
        self.run_action('failed')
        self.assertNotIn(self.prefix + '/release', self.state['parameters'])
        self.assertEqual(json.loads(self.state['parameters'][self.attempt]['value'])['status'], 'failed')

    def test_failure_before_invalidation_preserves_previous_ready_release(self):
        self.prepare()
        previous = json.dumps(self.manifest)
        self.parameter(self.prefix + '/release', previous)
        self.state.update(fail_action='put-parameter', fail_name=self.attempt, fail_once=True)
        self.save_state()
        self.run_action('begin-provision', 'base.json', success=False)
        self.run_action('failed')
        self.assertEqual(self.state['parameters'][self.prefix + '/release']['value'], previous)
        self.assertFalse(any(action == 'delete-parameter' for action, _ in self.state['calls']))

    def test_denial_is_not_treated_as_absence_and_cleanup_failure_is_reported(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        self.state.update(fail_action='get-parameter', fail_name=self.prefix + '/release')
        self.save_state()
        self.run_action('publish', 'ready.json', success=False)
        self.run_action('failed', success=False)
        attempt = json.loads(self.state['parameters'][self.attempt]['value'])
        self.assertEqual(attempt['errorCode'], 'RELEASE_INVALIDATION_FAILED')
        self.assertEqual(attempt['status'], 'failed')

    def test_wrong_generation_cannot_be_published(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        self.manifest['generation'] = '11111111-1111-4111-8111-111111111111'
        (self.temp / 'ready.json').write_text(json.dumps(self.manifest), encoding='utf-8')
        self.run_action('publish', 'ready.json', success=False)
        self.assertEqual(len(self.state['writes']), 1)

    def test_base_revision_changed_during_field_writes_blocks_readiness(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        snapshot = json.loads((self.temp / 'base.json').read_text())
        # Same JSON with another SSM version is still a changed dependency.
        self.state['parameters'][snapshot['parameter']] = dict(value=json.dumps(snapshot['manifest']), version=2)
        self.save_state()
        self.run_action('publish', 'ready.json', success=False)
        self.run_action('failed')
        self.assertNotIn(self.prefix + '/release', self.state['parameters'])
        statuses = [json.loads(value)['status'] for name, value in self.state['writes'] if name == self.attempt]
        self.assertEqual(statuses, ['running', 'failed'])

    def test_failed_handler_before_begin_has_no_aws_calls(self):
        self.prepare()
        self.run_action('failed')
        self.assertEqual(self.state['calls'], [])

    def test_wrong_branch_is_rejected_before_aws(self):
        self.prepare()
        self.env['GITHUB_REF'] = 'refs/heads/main'
        self.run_action('begin-provision', 'base.json', success=False)
        self.assertEqual(self.state['calls'], [])

    def test_post_publication_dependency_failure_removes_ready_release(self):
        self.prepare()
        self.run_action('begin-provision', 'base.json')
        (self.temp / 'database-release.json').write_text((self.temp / 'ready.json').read_text(), encoding='utf-8')
        self.env.update(BASE_CONTEXT=(self.temp / 'base.json').as_posix(),
                        GITHUB_STEP_SUMMARY=(self.temp / 'summary.md').as_posix())
        workflow = (ROOT / '.github/workflows/database-provision.yml').read_text(encoding='utf-8')
        step = workflow.split('      - name: Publish database metadata in SSM\n', 1)[1]
        body = step.split('        run: |\n', 1)[1].split('      - name:', 1)[0]
        script = '\n'.join(line[10:] for line in body.splitlines())
        wrappers = r'''
bash() {
  [[ "$1" == 'scripts/database_metadata.sh' ]] || return 90
  shift; metadata_main "$@"
}
python3() {
  [[ "$*" == "scripts/consume_database_release.py recheck --environment $TARGET_ENVIRONMENT --context $BASE_CONTEXT" ]] || return 90
  echo recheck >> "$RUNNER_TEMP/rechecks"
  [[ "$(wc -l < "$RUNNER_TEMP/rechecks")" == 1 ]]
}
'''
        prefix = DRIVER.rsplit('metadata_main "$@"', 1)[0]
        result = subprocess.run([self.bash, '--noprofile', '--norc', '-c', prefix + wrappers + script],
                                cwd=ROOT, env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.read_state()
        self.assertIn(self.prefix + '/release', self.state['parameters'])
        # The workflow's failure/cancellation handler performs this cleanup.
        self.run_action('failed')
        self.assertNotIn(self.prefix + '/release', self.state['parameters'])
        self.assertEqual(json.loads(self.state['parameters'][self.attempt]['value'])['status'], 'failed')

    def test_empty_state_destroy_recovers_generation_from_own_release(self):
        self.prepare()
        self.parameter(self.prefix + '/release', json.dumps(self.manifest))
        (self.temp / 'plan.json').write_text('{}', encoding='utf-8')
        self.run_action('begin-destroy', 'plan.json')
        self.run_action('destroyed')
        attempt = json.loads(self.state['parameters'][self.attempt]['value'])
        self.assertEqual(attempt['generation'], self.manifest['generation'])
        self.assertEqual(attempt['status'], 'destroyed')

    def test_destroy_cleans_fields_preserves_history_and_other_namespaces(self):
        self.prepare()
        for field in FIELDS:
            self.parameter(self.prefix + '/' + field, str(self.manifest['exports'][field]))
        self.parameter(self.prefix + '/release', json.dumps(self.manifest))
        history = self.prefix + '/attempts/123-1-database'
        check = self.prefix + '/base-access-check'
        foreign = '/mecanica/prd/database/v1/release'
        for name in (history, check, foreign):
            self.parameter(name, 'preserve')
        plan = {'prior_state': {'values': {'outputs': {'base_dependency': {'value': self.manifest['dependencies']['base']}},
                                          'root_module': {'resources': [{'address': 'terraform_data.base_release'}]}}}}
        (self.temp / 'plan.json').write_text(json.dumps(plan), encoding='utf-8')
        self.run_action('begin-destroy', 'plan.json')
        self.run_action('destroyed')
        self.assertTrue(all(self.prefix + '/' + field not in self.state['parameters'] for field in FIELDS))
        self.assertNotIn(self.prefix + '/release', self.state['parameters'])
        self.assertTrue(all(name in self.state['parameters'] for name in (history, check, foreign)))
        self.assertEqual(json.loads(self.state['parameters'][self.attempt]['value'])['status'], 'destroyed')

    def test_empty_state_destroy_records_null_generation(self):
        self.prepare()
        (self.temp / 'plan.json').write_text('{}', encoding='utf-8')
        self.run_action('begin-destroy', 'plan.json')
        self.run_action('destroyed')
        attempt = json.loads(self.state['parameters'][self.attempt]['value'])
        self.assertEqual(attempt['status'], 'destroyed')
        self.assertIsNone(attempt['generation'])

    def test_destroy_generation_mismatch_preserves_release(self):
        self.prepare()
        self.parameter(self.prefix + '/release', json.dumps(self.manifest))
        dependency = dict(self.manifest['dependencies']['base'], generation='11111111-1111-4111-8111-111111111111')
        (self.temp / 'plan.json').write_text(json.dumps({'prior_state': {'values': {'outputs': {'base_dependency': {'value': dependency}}}}}), encoding='utf-8')
        self.run_action('begin-destroy', 'plan.json', success=False)
        self.assertIn(self.prefix + '/release', self.state['parameters'])
        self.assertFalse(any(action != 'get-parameter' for action, _ in self.state['calls']))


if __name__ == '__main__':
    unittest.main()
