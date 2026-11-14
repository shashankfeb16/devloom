#!/usr/bin/env python3
"""Run the actual Jenkinsfile against a local snapshot, without committing or pushing."""
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import urllib.error

from verify import client


def main():
    runtime = Path(__file__).resolve().parent
    root = runtime.parents[2]
    request = client()
    job = '/job/devloom-local-test'

    def post(path, data=b'', content_type='application/x-www-form-urlencoded'):
        crumb = json.loads(request('/crumbIssuer/api/json'))
        return request(path, data=data, headers={
            'Content-Type': content_type, crumb['crumbRequestField']: crumb['crumb']})

    previous = 0
    try:
        status = json.loads(request(job + '/api/json?tree=inQueue,lastBuild[number,building]'))
        if status['inQueue'] or (status.get('lastBuild') or {}).get('building'):
            raise SystemExit('devloom-local-test is already running; wait for it to finish.')
        previous = (status.get('lastBuild') or {}).get('number', 0)
        exists = True
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        exists = False

    compose = ['docker', 'compose', '--env-file', str(runtime / '.env'),
               '-f', str(runtime / 'compose.yaml')]

    def agent(script):
        subprocess.run([*compose, 'exec', '-T', '--user', 'jenkins', 'agent',
                        'bash', '-ec', script], check=True)

    # Git's ignore rules keep local passwords, Terraform state, build outputs,
    # and .git metadata out of this temporary snapshot. Nothing is published.
    files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others',
                                     '--exclude-standard'], cwd=root).decode().split('\0')
    with tempfile.TemporaryDirectory(prefix='devloom-jenkins-snapshot-') as temporary:
        archive = Path(temporary) / 'source.tar'
        with tarfile.open(archive, 'w') as tar:
            for name in files:
                path = Path(name)
                excluded = any(part in {'.git', '.terraform', '.jenkins-deploy', '__pycache__',
                                       'node_modules', '_build', 'deps'} for part in path.parts)
                excluded = excluded or (path.name.startswith('.env') and path.name != '.env.example')
                excluded = excluded or path.name.endswith(('.tfstate', '.tfstate.backup', '.tfvars',
                                                           '.tfvars.json', '.tfplan', '.pem', '.key', '.p12', '.pfx'))
                if name and not excluded and (root / name).is_file():
                    tar.add(root / name, arcname=name, recursive=False)
        agent('mkdir -p /tmp/devloom-ci/local-test')
        subprocess.run([*compose, 'cp', str(archive), 'agent:/tmp/devloom-ci/local-test/source.tar'], check=True)
    # compose cp preserves the host user's ownership; normalize this one file.
    subprocess.run([*compose, 'exec', '-T', '--user', 'root', 'agent', 'chown',
                    'jenkins:jenkins', '/tmp/devloom-ci/local-test/source.tar'], check=True)
    agent('''
        cd /tmp/devloom-ci/local-test
        rm -rf source repository
        mkdir source repository
        tar -xf source.tar -C source
        rm source.tar
        git -C source init --initial-branch=main --quiet
        git -C source -c user.name='Local Jenkins Test' -c user.email='jenkins@localhost' add .
        git -C source -c user.name='Local Jenkins Test' -c user.email='jenkins@localhost' commit --quiet -m 'Local CI snapshot'
        git clone --quiet --bare source repository/devloom.git
        git --git-dir=repository/devloom.git update-server-info
    ''')
    # This server is reachable only inside the Jenkins Compose network. It is
    # stopped after the build and never exposes a port on the Mac.
    server_code = '''
import os
from pathlib import Path
import runpy
import sys
Path('/tmp/devloom-ci/local-test/server.pid').write_text(str(os.getpid()))
sys.argv = ['http.server', '8765', '--bind', '0.0.0.0', '--directory', '/tmp/devloom-ci/local-test/repository']
runpy.run_module('http.server', run_name='__main__')
'''
    server = subprocess.Popen([*compose, 'exec', '-T', '--user', 'jenkins', 'agent',
                               'python3', '-c', server_code],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        agent('''python3 - <<'PY'
import time
import urllib.request
for attempt in range(30):
    try:
        urllib.request.urlopen('http://localhost:8765/devloom.git/HEAD', timeout=1).read()
        break
    except OSError:
        time.sleep(1)
else:
    raise SystemExit('Temporary Git server did not become ready.')
PY''')
        if server.poll() is not None:
            raise SystemExit('Temporary Git server exited; check for a conflicting local test.')
        xml = b'''<flow-definition>
          <description>Local working-copy snapshot. VPS deployment is disabled. Recreate with local-test.py.</description>
          <keepDependencies>false</keepDependencies><properties/>
          <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition">
            <scm class="hudson.plugins.git.GitSCM"><configVersion>2</configVersion>
              <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>http://docker:8765/devloom.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
              <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
              <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations><extensions/>
            </scm><scriptPath>Jenkinsfile</scriptPath><lightweight>true</lightweight>
          </definition><triggers/><disabled>false</disabled>
        </flow-definition>'''
        post(job + '/config.xml' if exists else '/createItem?name=devloom-local-test', xml, 'application/xml')
        post(job + '/build')
        print('Started devloom-local-test. Open its build in Jenkins to watch each stage.', flush=True)
        last_stage = None
        deadline = time.monotonic() + 5500
        while time.monotonic() < deadline:
            build = json.loads(request(job + '/api/json?tree=lastBuild[number,building,result,url]')).get('lastBuild')
            if build and build['number'] > previous:
                try:
                    flow = json.loads(request(job + f"/{build['number']}/wfapi/describe"))
                    stages = [(stage['name'], stage['status']) for stage in flow.get('stages', [])]
                    if stages and stages != last_stage:
                        print(' | '.join(f'{name}: {status}' for name, status in stages), flush=True)
                        last_stage = stages
                except urllib.error.HTTPError:
                    pass
                if not build['building']:
                    print(f"Build #{build['number']}: {build['result']} — {build['url']}", flush=True)
                    if build['result'] != 'SUCCESS':
                        raise SystemExit('Open Console Output in Jenkins to inspect the failure.')
                    return
            time.sleep(5)
        raise SystemExit('Timed out waiting for Jenkins. Inspect the build in the dashboard.')
    finally:
        # Prevent SCM polling against a temporary snapshot server after this run.
        try:
            post(job + '/disable')
        except (OSError, urllib.error.URLError):
            print('Could not disable the snapshot job; disable it in Jenkins before leaving it unattended.')
        try:
            agent('''python3 - <<'PY'
import os
from pathlib import Path
import signal
pid_file = Path('/tmp/devloom-ci/local-test/server.pid')
if pid_file.exists():
    try:
        pid = int(pid_file.read_text())
        command = Path(f'/proc/{pid}/cmdline').read_bytes()
        if b'/tmp/devloom-ci/local-test/server.pid' in command:
            os.kill(pid, signal.SIGTERM)
    except (ProcessLookupError, FileNotFoundError):
        pass
    pid_file.unlink()
PY''')
        finally:
            server.terminate()
            server.wait(timeout=10)


if __name__ == '__main__':
    identity = hashlib.sha256(str(Path(__file__).resolve()).encode()).hexdigest()[:16]
    with (Path(tempfile.gettempdir()) / f'devloom-jenkins-test-{identity}.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another local snapshot test is already running.') from None
        main()
