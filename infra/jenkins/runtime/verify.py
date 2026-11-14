#!/usr/bin/env python3
"""Check the local Jenkins agent and validate Jenkinsfile without exposing credentials."""
import base64
import http.cookiejar
import json
from pathlib import Path
import urllib.error
import urllib.request
import uuid


def client():
    runtime = Path(__file__).resolve().parent
    env = dict(line.split('=', 1) for line in (runtime / '.env').read_text().splitlines()
               if line and not line.startswith('#'))
    url = f"http://127.0.0.1:{int(env.get('JENKINS_PORT', '8080'))}"
    auth = base64.b64encode(f"{env['JENKINS_ADMIN_USER']}:{env['JENKINS_ADMIN_PASSWORD']}".encode()).decode()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(path, data=None, headers=None):
        request_headers = {'Authorization': 'Basic ' + auth, **(headers or {})}
        return opener.open(urllib.request.Request(url + path, data=data, headers=request_headers), timeout=30).read()

    return request


def main():
    root = Path(__file__).resolve().parents[3]
    request = client()

    status = json.loads(request('/computer/api/json?tree=computer[displayName,offline]'))
    agents = [node for node in status['computer'] if node['displayName'] == 'devloom-agent']
    if len(agents) != 1 or agents[0]['offline']:
        raise SystemExit('The devloom-agent is offline; inspect the agent logs.')
    print('PASS: devloom-agent is connected.')

    crumb = json.loads(request('/crumbIssuer/api/json'))
    boundary = 'devloom-' + uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="jenkinsfile"\r\n'
            'Content-Type: text/plain\r\n\r\n').encode()
    body += (root / 'Jenkinsfile').read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
    result = request('/pipeline-model-converter/validate', data=body, headers={
        'Content-Type': 'multipart/form-data; boundary=' + boundary,
        crumb['crumbRequestField']: crumb['crumb'],
    }).decode().strip()
    print(result)
    if 'Jenkinsfile successfully validated' not in result:
        raise SystemExit(1)


if __name__ == '__main__':
    try:
        main()
    except (OSError, urllib.error.URLError, KeyError, ValueError) as error:
        # Never print request headers or the .env contents.
        raise SystemExit(f'Local Jenkins verification failed: {type(error).__name__}') from None
