"""Real canonical WSS probe, independent of Flutter scheduling. No model calls."""
import asyncio
import json
from pathlib import Path
import ssl
import sys
import tempfile
import websockets

async def main():
    with tempfile.TemporaryDirectory(prefix='canonical-probe-', dir='.dart_tool') as root:
        root = Path(root).resolve()
        cert, key = root / 'cert.pem', root / 'key.pem'
        openssl = await asyncio.create_subprocess_exec('openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost',
            '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1',stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
        assert await openssl.wait() == 0
        server = await asyncio.create_subprocess_exec(sys.executable,'tool/hermes_canonical_server.py',
            '--source','/opt/hermes','--home',str(root/'home'),'--cert',str(cert),'--key',str(key),
            stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        assert server.stdin is not None and server.stdout is not None and server.stderr is not None
        errors=[]
        async def stderr():
            async for line in server.stderr: errors.append(line.decode())
        log=asyncio.create_task(stderr())
        try:
            while True:
                line = await asyncio.wait_for(server.stdout.readline(),120)
                if not line: raise RuntimeError('Host startup failed: '+''.join(errors))
                if line.startswith(b'{'): break
            ready=json.loads(line)
            invite=json.loads(Path(ready['invitePath']).read_text())
            context=ssl.create_default_context(cafile=str(cert))
            async with websockets.connect(ready['url'],subprotocols=invite['protocols'],ssl=context) as ws:
                events=[]
                async def rpc(method,params):
                    rid=method
                    await ws.send(json.dumps({'jsonrpc':'2.0','id':rid,'method':method,'params':params}))
                    while True:
                        for line in (await asyncio.wait_for(ws.recv(),30)).splitlines():
                            frame=json.loads(line)
                            if frame.get('method')=='event': events.append(frame['params'])
                            if frame.get('id')==rid:
                                if 'error' in frame: raise RuntimeError(method+' refused: '+json.dumps(frame['error']))
                                return frame['result']
                runtime=await rpc('runtime.describe',{})
                assert runtime['instance_id']==invite['endpoint']['instance_id']
                live=await rpc('session.list',{'scope':'live','limit':200})
                stored=await rpc('session.list',{'scope':'stored','limit':200})
                assert any(r.get('session_id',r.get('id'))==ready['sessionId'] for r in live['sessions'])
                snapshot=await rpc('session.resume',{'session_id':ready['sessionId'],'display_projection':True})
                assert any(r.get('content')=='External Desktop context' for r in snapshot['messages'])
                receipt=await rpc('prompt.submit',{'session_id':ready['sessionId'],'text':'Probe canonical input','input_id':'probe-one'})
                server.stdin.write(b'finish\n')
                await server.stdin.drain()
                for _ in range(80):
                    status=await rpc('prompt.receipt',{'session_id':ready['sessionId'],'admission_id':receipt['admission_id']})
                    if status['status']=='terminal': break
                    await asyncio.sleep(.1)
                assert status['status']=='terminal', (status, ''.join(errors))
                assert status['outcome']=='completed', (status, ''.join(errors))
                final=await rpc('session.resume',{'session_id':ready['sessionId'],'display_projection':True})
                assert final['session_id']==ready['sessionId']
                assert sum(r.get('content')=='Probe canonical input' for r in final['messages'])==1, final
                assert sum(r.get('content')=='Canonical stub final answer' for r in final['messages'])==1, (final,''.join(errors))
                submitted = next(r for r in final['messages'] if r.get('content')=='Probe canonical input')
                assert submitted.get('display_metadata', {}).get('submission_id') == 'probe-one', submitted
                assert any(e['type']=='message.delta' for e in events), events
                print(json.dumps({'canonical_wss':True,'tls_verified':True,'live_sessions':len(live['sessions']),
                    'stored_sessions':len(stored['sessions']),'same_session':True,'one_input':True,'authoritative_answer':True,'terminal':status['outcome']}))
            try:
                async with websockets.connect(ready['url'],subprotocols=invite['protocols'],ssl=context):
                    raise AssertionError('Spent ticket accepted twice')
            except websockets.exceptions.InvalidStatus:
                print('one_use_ticket_rejected_on_reconnect=true')
            server.stdin.write(b'expire\n')
            await server.stdin.drain()
            await asyncio.wait_for(server.stdout.readline(),10)
            expired=json.loads(Path(ready['invitePath']).read_text())
            try:
                async with websockets.connect(ready['url'],subprotocols=expired['protocols'],ssl=context):
                    raise AssertionError('Expired host ticket accepted')
            except websockets.exceptions.InvalidStatus:
                print('expired_host_ticket_rejected=true')
            server.stdin.write(b'mint\n')
            await server.stdin.drain()
            await asyncio.wait_for(server.stdout.readline(),10)
            fresh=json.loads(Path(ready['invitePath']).read_text())
            async with websockets.connect(ready['url'],subprotocols=fresh['protocols'],ssl=context) as reconnect:
                await reconnect.send(json.dumps({'jsonrpc':'2.0','id':'reconnect','method':'runtime.describe','params':{}}))
                while True:
                    frames=[json.loads(line) for line in (await reconnect.recv()).splitlines()]
                    response=next((f for f in frames if f.get('id')=='reconnect'),None)
                    if response is not None:
                        assert response['result']['profile_id']==runtime['profile_id']
                        break
                print('fresh_host_grant_reconnect_same_profile=true')
            # Lose the admission ACK deliberately: close without reading it,
            # discard the original socket and reconnect with a fresh host ticket.
            server.stdin.write(b'hold\nmint\n')
            await server.stdin.drain()
            await asyncio.wait_for(server.stdout.readline(),10)
            await asyncio.wait_for(server.stdout.readline(),10)
            fresh=json.loads(Path(ready['invitePath']).read_text())
            async with websockets.connect(ready['url'],subprotocols=fresh['protocols'],ssl=context) as ws:
                await rpc('session.resume',{'session_id':ready['sessionId'],'omit_messages':True})
                await ws.send(json.dumps({'jsonrpc':'2.0','id':'deliberately-unread-ack','method':'prompt.submit',
                    'params':{'session_id':ready['sessionId'],'text':'Lost ACK canonical input','input_id':'lost-ack-exact'}}))
                await asyncio.sleep(.15)
            server.stdin.write(b'mint\n')
            await server.stdin.drain()
            await asyncio.wait_for(server.stdout.readline(),10)
            fresh=json.loads(Path(ready['invitePath']).read_text())
            async with websockets.connect(ready['url'],subprotocols=fresh['protocols'],ssl=context) as ws:
                exact=[]
                recovered={}
                status={}
                for _ in range(40):
                    recovered=await rpc('session.resume',{'session_id':ready['sessionId'],'omit_messages':True})
                    exact=[r for r in recovered['pending'] if r.get('input_id')=='lost-ack-exact']
                    if exact: break
                    await asyncio.sleep(.05)
                assert len(exact)==1, recovered
                recovered_id=exact[0]['admission_id']
                server.stdin.write(b'finish\n')
                await server.stdin.drain()
                for _ in range(80):
                    status=await rpc('prompt.receipt',{'session_id':ready['sessionId'],'admission_id':recovered_id})
                    if status['status']=='terminal': break
                    await asyncio.sleep(.1)
                assert status['status']=='terminal' and status['outcome']=='completed', status
                cursor=None
                transcript=[]
                for _ in range(20):
                    page=await rpc('session.transcript',{'session_id':ready['sessionId'],'order':'oldest',
                        'limit':1,'inline_images':False,**({'cursor':cursor} if cursor else {})})
                    if page['reset']: transcript=[]
                    transcript.extend(page['rows'])
                    cursor=page['next_cursor']
                    if not page['rows']: break
                attributed=[r for r in transcript if r.get('display_metadata',{}).get('submission_id')=='lost-ack-exact']
                assert len(attributed)==1, transcript
                assert attributed[0].get('text')=='Lost ACK canonical input', attributed
                print('lost_ack_reconnect_exact_pending_input_id_receipt_and_stored_submission_metadata=true')
        finally:
            server.terminate()
            await server.wait()
            await log

asyncio.run(main())
