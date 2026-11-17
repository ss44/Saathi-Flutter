"""Serialized official WSS lost-ACK probes with real Dart process death.

Only a test TLS forwarding peer drops the admission response; the installed
GatewayRuntimeAPI and authority are unmodified. Each Flutter child has a new
process and the journal is on disk. No provider, production key or broker.
"""
import asyncio
import json
import os
from pathlib import Path
import ssl
import sys
import tempfile
from urllib.parse import urlsplit
import websockets

FLUTTER = '/opt/data/tools/flutter/bin/flutter'

async def scenario(root, restart_backend):
    cert, key = root / 'cert.pem', root / 'key.pem'
    p = await asyncio.create_subprocess_exec('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    assert await p.wait() == 0
    errors = []
    drains = []
    async def launch(resume=False, port=0):
        args = [sys.executable, 'tool/hermes_canonical_server.py', '--source', '/opt/hermes',
            '--home', str(root/'home'), '--cert', str(cert), '--key', str(key), '--port', str(port)]
        if resume: args.append('--resume')
        process = await asyncio.create_subprocess_exec(*args, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        async def drain():
            async for line in process.stderr:
                errors.append(line.decode())
        drains.append(asyncio.create_task(drain()))
        while True:
            line = await asyncio.wait_for(process.stdout.readline(), 180)
            if not line: raise RuntimeError('Official startup failed: '+''.join(errors))
            if line.startswith(b'{'): return process, json.loads(line)
    backend, ready = await launch()
    context = ssl.create_default_context(cafile=str(cert))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    submits = 0
    dropped = 0
    async def proxy(client):
        nonlocal submits, dropped
        protocols = [p.strip() for p in client.request.headers['Sec-WebSocket-Protocol'].split(',')]
        print('restart-probe proxy-connect', flush=True)
        async with websockets.connect(ready['url'], subprotocols=protocols, ssl=context) as upstream:
            print('restart-probe upstream-ready', flush=True)
            drop_id = None
            async def upload():
                nonlocal submits, drop_id
                async for frame in client:
                    packet = json.loads(frame)
                    print('restart-probe rpc '+str(packet.get('method')), flush=True)
                    if packet.get('method') == 'prompt.submit':
                        submits += 1
                        drop_id = packet['id']
                    await upstream.send(frame)
            async def download():
                nonlocal dropped
                async for frame in upstream:
                    retained = []
                    for line in frame.splitlines():
                        packet = json.loads(line)
                        if packet.get('id') == drop_id and drop_id is not None:
                            dropped += 1
                        else:
                            retained.append(line)
                    if retained: await client.send('\n'.join(retained))
            jobs = [asyncio.create_task(upload()), asyncio.create_task(download())]
            try:
                done, pending = await asyncio.wait(jobs, return_when=asyncio.FIRST_COMPLETED)
                for job in done: job.result()
            finally:
                for job in jobs: job.cancel()
                await asyncio.gather(*jobs, return_exceptions=True)
    async def mint():
        backend.stdin.write(b'mint\n'); await backend.stdin.drain()
        answer = json.loads(await asyncio.wait_for(backend.stdout.readline(), 10))
        assert answer['minted']
    async def dart(phase, proxy_url):
        await mint()
        (root/'ready.json').write_text(json.dumps({**ready, 'proxyUrl': proxy_url}))
        env = {**os.environ, 'CANONICAL_RESTART_ROOT': str(root), 'CANONICAL_RESTART_PHASE': phase}
        child = await asyncio.create_subprocess_exec(FLUTTER, 'test', '--no-pub',
            'test/integration/canonical_restart_phase.dart', '--timeout', '60s',
            env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        output, _ = await asyncio.wait_for(child.communicate(), 120)
        print(output.decode(), flush=True)
        assert child.returncode == 0, f'Dart phase {phase} failed; host: {"".join(errors)}'
    try:
        async with websockets.serve(proxy, '127.0.0.1', 0, ssl=tls, subprotocols=['hermes-gateway-v1']) as forwarding:
            proxy_url = f'wss://localhost:{forwarding.sockets[0].getsockname()[1]}/api/ws'
            await dart('send', proxy_url)
            assert submits == 1 and dropped == 1
            if restart_backend:
                old_pid = backend.pid
                backend.kill(); await backend.wait()
                old_ready = ready
                backend, ready = await launch(True, urlsplit(old_ready['url']).port)
                assert backend.pid != old_pid
                assert ready['sessionId'] == old_ready['sessionId']
                await dart('backend-restart', proxy_url)
            else:
                await dart('receipt', proxy_url)
                backend.stdin.write(b'finish\n'); await backend.stdin.drain()
                # The terminal phase polls via official receipt; no arbitrary state fabrication.
                await asyncio.sleep(.1)
                await dart('terminal', proxy_url)
            assert submits == 1, 'Recovery replayed inference'
            print(json.dumps({'backend_process_restart': restart_backend,
                'dart_owner_process_restart': True, 'actual_prompt_submits': submits,
                'actual_admission_responses_dropped': dropped, 'no_replay': True}), flush=True)
    finally:
        if backend.returncode is None:
            backend.stdin.write(b'stop\n'); await backend.stdin.drain()
            try:
                await asyncio.wait_for(backend.wait(), 5)
            except asyncio.TimeoutError:
                backend.kill(); await backend.wait()
        await asyncio.gather(*drains)
        if errors: print('HOST DIAGNOSTICS '+''.join(errors)[-12000:], flush=True)

async def main():
    for restart in ((False,) if '--owner-only' in sys.argv else (True,) if '--backend-only' in sys.argv else (False, True)):
        with tempfile.TemporaryDirectory(prefix='canonical-restart-', dir='.dart_tool') as path:
            await scenario(Path(path).resolve(), restart)

if __name__ == '__main__':
    asyncio.run(main())
