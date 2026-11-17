"""Isolated official canonical authority/WS/one-use bootstrap with a stub agent.

Only the agent execution boundary is replaced. No packaged Hermes file is edited.
Requires an empty scratch home, local TLS certificate/key and explicit source.
Invites are written owner-only, never logged. No provider or tool is called.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import socket
import sys
import time

started_at = time.monotonic()
def stage(label):
    print(f'canonical-stage {label} elapsed={time.monotonic()-started_at:.3f}s', file=sys.stderr, flush=True)

p = argparse.ArgumentParser()
p.add_argument('--source', required=True)
p.add_argument('--home', required=True)
p.add_argument('--cert', required=True)
p.add_argument('--key', required=True)
p.add_argument('--resume', action='store_true', help='Reopen this controlled probe home after process death')
p.add_argument('--port', type=int, default=0)
a = p.parse_args()
home = Path(a.home).resolve()
home.mkdir(parents=True, exist_ok=True)
if any(home.iterdir()) and not a.resume:
    raise SystemExit('Controlled home must be empty')
if a.resume and not (home / 'probe-session-id').is_file():
    raise SystemExit('Resume requires an existing controlled probe session')
os.environ.clear()
os.environ.update(HOME=str(home), HERMES_HOME=str(home), PATH='/usr/bin:/bin', HERMES_DISABLE_TELEMETRY='1')
protocol_stdout = sys.stdout
sys.path.insert(0, a.source)

import uvicorn
from starlette.applications import Starlette
from gateway.config import GatewayConfig
from gateway.run import GatewayRunner
from gateway.runtime_bootstrap import TicketStore
from gateway.session_authority import initialize_session_authority
from gateway.session_controls import AuthorityConnection
from gateway.run_api import GatewayRuntimeAPI
from hermes_state import SessionDB


class StubAgent:
    """Explicit non-inferencing execution; no tools, provider, credentials or model."""
    def __init__(self, release):
        self.release = release
        self.stopped = False

    def steer(self, text):
        return True

    def redirect(self, text):
        return True

    def interrupt(self, reason=None, **kwargs):
        self.stopped = True

    async def run(self, authority, sid, text, event):
        from gateway.response_filters import persisted_user_metadata_for_event
        generation = authority.executing[sid]
        authority.adopt_agent(sid, generation, self)
        # Use the official submission_turn_scope projection, not a fabricated ID.
        metadata = persisted_user_metadata_for_event(event)
        authority.db.append_message(sid, 'user', text, display_metadata=metadata)
        authority.publish_execution(sid, generation, 'message.delta', {'text': 'Canonical stub streaming'})
        await asyncio.wait_for(self.release.wait(), 60)
        answer = 'Canonical stub final answer'
        authority.db.append_message(sid, 'assistant', answer)
        return answer


class NullTransport:
    desktop_local = True
    def write(self, obj):
        return True


async def main():
    stage('imports-ready')
    runner = GatewayRunner(GatewayConfig())
    stage('runner-ready')
    db = SessionDB(home / 'state.db')
    authority = await initialize_session_authority(runner, profile_id=str(home), instance_id='controlled-canonical', db=db)
    stage('authority-ready')
    runner.session_runtime_descriptor = {'state': 'ready'}
    runner.session_ticket_store = TicketStore(authority.instance_id, frozenset({authority.profile_id}))
    release = asyncio.Event()
    async def execute(event):
        sid = next(sid for sid, live in authority.sessions.items() if live.source is event.source)
        return await StubAgent(release).run(authority, sid, event.text, event)
    runner._handle_message = execute
    # An external Desktop-owned session is created by the official create handler,
    # not by fabricating a DB row, then mobile resumes the resulting exact id.
    caps = frozenset({'session:create','session:read','session:submit','session:control','session:approve','session:respond'})
    desktop = AuthorityConnection(authority, NullTransport(), {
        'user_id':'controlled-host-user', 'provider':'local', 'profile_id':str(home),
        'instance_id':authority.instance_id, 'native_bootstrap':True, 'capabilities':caps}, operator=True)
    if a.resume:
        sid = (home / 'probe-session-id').read_text()
        stage('existing-desktop-session-reopened')
    else:
        created = await desktop.create(None, {'request_id':'external-desktop', 'title':'Canonical external session', 'source':'gui',
            'model':'explicit-stub', 'provider':'openai', 'cwd':str(home), 'toolsets':[]})
        stage('desktop-session-created')
        sid = created['session_id']
        (home / 'probe-session-id').write_text(sid)
        db.append_message(sid, 'user', 'External Desktop context')
        db.append_message(sid, 'assistant', 'External Desktop answer')
    app = Starlette()
    app.state.bound_host = '127.0.0.1'
    app.state.auth_required = False
    app.state.trusted_public_hosts = []
    wrapped = GatewayRuntimeAPI(app, runner, app)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', a.port))
    listener.listen()
    port = listener.getsockname()[1]
    config = uvicorn.Config(wrapped, host='127.0.0.1', port=port, log_level='error',
        ssl_certfile=a.cert, ssl_keyfile=a.key, proxy_headers=False, lifespan='off')
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve(sockets=[listener]))
    while not server.started:
        if task.done(): await task
        await asyncio.sleep(.02)
    url = f'wss://localhost:{port}/api/ws'
    invite_path = home / 'invite.json'
    def mint():
        ticket = runner.session_ticket_store.mint(profile_id=str(home), subject='controlled-host-user', purpose='interactive')
        value = {'state':'ready', 'url':url, 'protocol':'hermes-gateway-v1',
            'protocols':['hermes-gateway-v1', 'hermes-gateway-ticket.' + ticket], 'ticket':ticket,
            'endpoint':{'instance_id':authority.instance_id, 'profile_id':str(home)}}
        invite_path.write_text(json.dumps(value))
        invite_path.chmod(0o600)
    mint()
    stage('fresh-ticket-issued')
    print(json.dumps({'url':url, 'invitePath':str(invite_path), 'sessionId':sid}), file=protocol_stdout, flush=True)
    external_id = 0
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line or line.strip() == 'stop': break
            if line.strip() == 'external':
                from gateway.session_contract import SessionRef
                external_id += 1
                await desktop.submit(SessionRef(authority.profile_id, sid), {
                    'session_id':sid, 'text':'External client followup', 'input_id':f'external-followup-{external_id}'})
            if line.strip() == 'hold':
                release.clear()
                print('{"held":true}', file=protocol_stdout, flush=True)
            if line.strip() == 'finish':
                release.set()
            if line.strip() in {'mint', 'expire'}:
                runner.session_ticket_store.TTL_SECONDS = -1 if line.strip() == 'expire' else 30
                mint()
                runner.session_ticket_store.TTL_SECONDS = 30
                print('{"minted":true}', file=protocol_stdout, flush=True)
    finally:
        server.should_exit = True
        await task
        await desktop.close()
        db.close()

asyncio.run(main())
