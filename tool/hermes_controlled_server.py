"""Local official Hermes HTTP server with a non-inferencing agent.

Run only in a fresh subprocess with an isolated HERMES_HOME. The HTTP routing,
capability discovery, run admission/idempotency, SSE, status and controls are the
original server implementation, not reimplemented fixture responses. This is not
canonical Gateway/TurnRunner or production-provider verification.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
parser.add_argument('--home', required=True)
args = parser.parse_args()
home = Path(args.home).resolve()
home.mkdir(parents=True, exist_ok=True)
if any(home.iterdir()):
    raise SystemExit('Controlled home must be empty')
os.environ.clear()
os.environ.update(HOME=str(home), HERMES_HOME=str(home), PATH='/usr/bin:/bin',
                  HERMES_DISABLE_TELEMETRY='1')
sys.path.insert(0, args.source)

from aiohttp import web
from gateway.config import PlatformConfig
from gateway.platforms.api_server import APIServerAdapter
from hermes_state import SessionDB

KEY = 'controlled-local-runtime-key-not-a-production-secret'


class ControlledAgent:
    def __init__(self, db, **kwargs):
        self.db = db
        self.session_id = kwargs['session_id']
        self.callback = kwargs['stream_delta_callback']
        self.guidance = threading.Event()
        self.stopped = False
        self.model = 'controlled-model'
        self.provider = 'controlled-runtime'
        self.memory_manager = None

    def steer(self, text):
        self.guidance.set()
        return True

    def interrupt(self, reason=None, **kwargs):
        self.stopped = True
        self.guidance.set()

    def run_conversation(self, user_message, conversation_history, **kwargs):
        assert self.session_id == 'external_chat'
        assert any(m.get('content') == 'External context' for m in conversation_history)
        self.db.append_message(self.session_id, 'user', user_message)
        self.callback('Official controlled text')
        if not self.guidance.wait(60):
            return {'failed': True, 'error': 'Test did not guide or stop the controlled agent'}
        if self.stopped:
            return {'interrupted': True, 'completed': False}
        text = 'Official controlled final response'
        self.db.append_message(self.session_id, 'assistant', text)
        return {'completed': True, 'final_response': text}


async def main():
    adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={
        'key': KEY, 'host': '127.0.0.1', 'port': 0, 'model_name': 'controlled-model'}))
    db = SessionDB(home / 'state.db')
    db.create_session('external_chat', 'api_server', model='controlled-model')
    db.set_session_title('external_chat', 'External chat')
    db.append_message('external_chat', 'user', 'External context')
    db.append_message('external_chat', 'assistant', 'Existing reply')
    adapter._session_db = db
    adapter._create_agent = lambda **kwargs: ControlledAgent(db, **kwargs)
    app = web.Application()
    for method, path, handler in adapter._http_route_table():
        app.router.add_route(method, path, handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '127.0.0.1', 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    print(json.dumps({'url': f'http://127.0.0.1:{port}', 'key': KEY}), flush=True)
    try:
        await asyncio.Event().wait()
    finally:
        await runner.cleanup()
        db.close()


asyncio.run(main())
