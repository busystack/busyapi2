"""Explicit compatibility probes on repository-owned fixtures, never user projects.
Exit 0: every functional assertion passed. Exit 2: at least one failing/not-executed.
"""
import pathlib,json,tempfile,subprocess,socket,time,urllib.request,os,sys
root=pathlib.Path(__file__).resolve().parents[2];probes=root/'tools/probes';fixtures=root/'fixtures/compatibility'
results=[]
cli=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else root/'build/linux/x64/release/bundle/busyapi'
def run(command,timeout=45):
    result=subprocess.run([str(x) for x in command],capture_output=True,text=True,timeout=timeout,cwd=root,
                          env=dict(os.environ,REDOCLY_TELEMETRY='off',REDOCLY_SUPPRESS_UPDATE_NOTICE='true'))
    if len(result.stdout)>8*1024*1024:raise RuntimeError('Probe output exceeded 8 MiB')
    return result
def probe(name,fn):
    try:fn();results.append({'tool':name,'status':'working'})
    except (FileNotFoundError,ModuleNotFoundError,PermissionError) as e:results.append({'tool':name,'status':'not-executed','detail':str(e)[:300]})
    except Exception as e:results.append({'tool':name,'status':'failing','detail':str(e)[:500]})
def executable(name):
    file=probes/'node_modules/.bin'/name
    if not file.exists():raise FileNotFoundError('Provision pinned '+name+' explicitly with tools/probes/provision.sh')
    return file
def assertions(text,*values):
    for value in values:
        if value not in text:raise AssertionError('Missing functional assertion: '+value)
with tempfile.TemporaryDirectory(prefix='busyapi-probes-') as temporary:
    out=pathlib.Path(temporary)
    for family,kind in [('31','rich'),('32','rich'),('31','minimal'),('32','minimal')]:
        source=fixtures/(f'oas{family}.json' if kind=='rich' else f'oas{family}-minimal.json')
        label=family if kind=='rich' else family+' minimal'
        def parser():
            if not cli.exists():raise FileNotFoundError('Build and supply the packaged BusyAPI CLI')
            r=run([cli,'check',source,'--json']);d=json.loads(r.stdout);assert r.returncode==0 and d['status']=='complete',r.stdout[:400]
            advanced=run([cli,'check',fixtures/'dialect.json','--json']);assert advanced.returncode==2;assert json.loads(advanced.stdout)['complete'] is False
        probe('BusyAPI parser/validator '+label,parser)
        def spectral():
            document=json.loads(source.read_text());document['paths']['/things']['get'].pop('summary');test=out/'lint.json';test.write_text(json.dumps(document));r=run([executable('spectral'),'lint',test,'--ruleset',probes/'spectral.yaml','--format','json']);assertions(r.stdout,'operation-summary')
        probe('Spectral '+label,spectral)
        bundle=out/f'bundle{family}.json'
        def bundler():
            r=run([executable('redocly'),'bundle',source,'--output',bundle,'--ext','json']);assert r.returncode==0,r.stderr[:300];text=bundle.read_text();d=json.loads(text);assert d['openapi']==json.loads(source.read_text())['openapi'];assertions(text,'listThings','Schema property sentinel');assert '$ref' in text
            if family=='32':assertions(text,'queryThings','copyThings','additionalOperations')
            if kind=='minimal':return
            assertions(text,'payload data','self')
            escaped=d['components']['schemas']['Escaped']
            seen=set()
            while '$ref' in escaped:
                reference=escaped['$ref'];assert reference.startswith('#/');assert reference not in seen;seen.add(reference);escaped=d
                for segment in reference[2:].split('/'):escaped=escaped[segment.replace('~1','/').replace('~0','~')]
            assert escaped.get('type')=='string','Escaped pointer schema semantics were lost'
            assert d['paths']['/things']['get']['responses']['200']['content']['application/json']['example']['$ref']=='payload data'
            recursive=[]
            def inspect(value,pointer=''):
                if isinstance(value,dict):
                    if pointer.endswith('/self') and isinstance(value.get('$ref'),str):recursive.append(value['$ref'])
                    for key,child in value.items():
                        if key not in ['example','examples']:inspect(child,pointer+'/'+key)
                elif isinstance(value,list):
                    for i,child in enumerate(value):inspect(child,pointer+'/'+str(i))
            inspect(d);assert recursive,'Recursive schema ownership was lost'
            for reference in recursive:
                assert reference.startswith('#/'),'Bundler retained an unresolved external recursive reference'
                target=d
                for segment in reference[2:].split('/'):target=target[segment.replace('~1','/').replace('~0','~')]
                assert isinstance(target,dict) and target.get('type')=='object'
            if family=='32':assertions(text,'queryThings','copyThings','additionalOperations')
        probe('Redocly '+label,bundler)
        for renderer in ['swagger','redoc']:
            def render(renderer=renderer):
                if not (probes/'node_modules/playwright').exists():raise FileNotFoundError('Pinned browser probe runtime is not provisioned')
                # Probe each renderer's own reference handling even when the
                # independently tested bundler fails; never rewrite the input.
                r=run(['node',probes/'render.mjs',source,renderer]);assert r.returncode==0,r.stderr[:400];assertions(r.stdout,'working')
            probe(renderer+' '+label,render)
        def prism():
            binary=executable('prism')
            with socket.socket() as reserve:reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
            process=subprocess.Popen([str(binary),'mock',str(fixtures/(f'oas{family}-before.json' if kind=='rich' else f'oas{family}-minimal.json')),'-h','127.0.0.1','-p',str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                response=None
                for _ in range(100):
                    if process.poll() is not None:raise AssertionError('Prism exited before readiness')
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/things',timeout=.25) as reply:response=json.loads(reply.read());assert reply.status==200;break
                    except (OSError,ValueError):time.sleep(.1)
                assert response is not None and response.get('name')=='fixture','Loopback response example was not returned'
            finally:
                if process.poll() is None:os.killpg(process.pid,15)
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(process.pid,9);process.wait()
        probe('Prism '+label,prism)
        def diff():
            binary=probes/'bin/oasdiff'
            if not binary.exists():raise FileNotFoundError('oasdiff 1.33.0 is not provisioned')
            r=run([binary,'breaking',fixtures/f'oas{family}-before.json',fixtures/f'oas{family}-after.json','--format','json']);assertions(r.stdout,'/things','api-path-removed')
        probe('oasdiff '+label,diff)
        def generator():
            jar=probes/'bin/openapi-generator-7.26.0.jar'
            if not jar.exists():raise FileNotFoundError('OpenAPI Generator 7.26.0 is not provisioned')
            dest=out/f'generated{family}';r=run(['java','-jar',jar,'generate','-i',source,'-g','typescript-fetch','-o',dest],timeout=60);assert r.returncode==0,r.stderr[:300];text='\n'.join(p.read_text() for p in dest.rglob('*.ts'));assertions(text,'listThings','name');models=list((dest/'models').glob('*.ts'));assert models,'No models generated';assertions('\n'.join(file.read_text() for file in models),'Composed','name','id')
            if family=='32':assertions(text,'queryThings','copyThings')
        probe('OpenAPI Generator '+label,generator)
print(json.dumps({'version':1,'results':results},indent=2));sys.exit(0 if all(r['status']=='working' for r in results) else 2)
