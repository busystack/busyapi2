"""Installed headless commands and output ownership; no GUI/browser acceptance claim."""
import pathlib,subprocess,tempfile,json,os,shutil,sys,hashlib
from verify_flutter_sdk import verify_installed as verify_flutter_sdk
bundle=pathlib.Path(sys.argv[1]).resolve();cli=bundle/'busyapi'
verify_flutter_sdk(bundle)
environment=dict(os.environ,PATH='/nonexistent',NODE_OPTIONS='--require=/project-injection-must-not-load.cjs',NODE_PATH='/project-injection',DISPLAY='',WAYLAND_DISPLAY='')
def run(*args):return subprocess.run([str(cli),*map(str,args)],env=environment,cwd='/tmp',capture_output=True,text=True,timeout=30)

def output_files(directory):
    files={file.relative_to(directory).as_posix():file.read_bytes()
           for file in directory.rglob('*') if file.is_file()}
    assert files and not any(file.is_symlink() for file in directory.rglob('*'))
    receipt=json.loads(files.pop('busyapi-output.json'))
    assert receipt['version']==1 and receipt['owner']=='io.busystack.busyapi'
    assert receipt['files']=={name:hashlib.sha256(value).hexdigest() for name,value in files.items()}
    return files

def exports(project,source,temporary):
    before=source.read_bytes()
    lint=run('lint',project,'--fail-severity','error','--json')
    policy=json.loads(lint.stdout)
    assert lint.returncode==0 and policy['complete'],lint.stdout+'\n'+lint.stderr
    assert len(policy['checkedRoots'])==1 and policy['categories'][0]['results']['policy']['complete']
    for command,entry in [('bundle','openapi.json'),('build-docs','index.html')]:
        outputs=[];records=[]
        for index in [1,2]:
            destination=temporary/(command+' output '+str(index)+' 雪')
            result=run(command,project,'--output',destination,'--json')
            record=json.loads(result.stdout)
            assert result.returncode==0 and record['complete'],result.stdout+'\n'+result.stderr
            assert record['version']==1 and record['status']=='complete'
            assert record['input']=='saved-source' and record['unsaved'] is False
            assert len(record['checkedRoots'])==1 and record['snapshot'] and record['producerVersion']
            assert record['output']['entry']==entry and record['output']['receiptIdentity']
            records.append(record);outputs.append(output_files(destination))
            refused=run(command,project,'--output',destination,'--json')
            assert refused.returncode==3 and json.loads(refused.stdout)['complete'] is False,refused.stdout
            assert output_files(destination)==outputs[-1],'Collision refusal changed owned output'
        assert records[0]['output']['identity']==records[1]['output']['identity']
        assert outputs[0]==outputs[1],'Equivalent snapshots/configuration must produce equivalent content'
        relocated=temporary/(command+' relocated 空')
        pathlib.Path(records[0]['output']['directory']).rename(relocated)
        assert output_files(relocated)==outputs[0]
        assert (relocated/entry).is_file()
        if command=='bundle':
            contract=json.loads(outputs[0][entry]);assert contract['info']['title']=='Smoke'
            checked=run('check',relocated/entry,'--json')
            assert checked.returncode==0 and json.loads(checked.stdout)['complete'],checked.stdout
        else:
            assert b'Smoke' in outputs[0][entry] and b'NOTICE.txt' in outputs[0][entry]
            assert 'NOTICE.txt' in outputs[0] and 'README.txt' in outputs[0]
        assert source.read_bytes()==before,'An output command changed canonical source'
with tempfile.TemporaryDirectory(prefix='busyapi-artifact-smoke-') as tmp:
    root=pathlib.Path(tmp)
    for version in ['2.0','3.0.0','3.0.4','3.1.0','3.1.2','3.2.0','3.2.1']:
        for format in ['yaml','json']:
            project=root/(version+'-'+format);created=run('init',project,'--title','Smoke','--api-version','1.0.0','--openapi',version,'--format',format);assert created.returncode==0,created.stderr
            checked=run('check',project,'--json');d=json.loads(checked.stdout);assert checked.returncode==0 and d['status']=='complete',checked.stdout
            collision=run('init',project,'--title','Other','--api-version','2');assert collision.returncode==3
            file=project/f'openapi.{format}';before=file.read_bytes()
            export_parent=root/('exports '+version+' '+format);export_parent.mkdir()
            exports(project,file,export_parent)
            file.write_text('openapi: 3.3.0\ninfo: {title: A, version: "1"}\npaths: {}\n' if format=='yaml' else '{"openapi":"3.3.0","info":{"title":"A","version":"1"},"paths":{}}')
            unsupported=run('check',project,'--json');assert unsupported.returncode==2 and json.loads(unsupported.stdout)['status']=='incomplete'
            file.write_bytes(before);file.write_text(file.read_text().replace('Smoke',''))
            # Empty title is permitted by the spec, so use a strict syntax failure.
            file.write_text(file.read_text()+'\n[broken:')
            invalid=run('check',project,'--json');assert invalid.returncode==1,invalid.stdout
            file.write_bytes(before)
    for absent in ['node', 'engine.cjs', 'both']:
        missing=root/('missing '+absent);assets=missing/'libexec/busyapi';assets.mkdir(parents=True)
        shutil.copy2(cli,missing/'busyapi')
        for name in ['node','engine.cjs']:
            if absent not in [name,'both']:shutil.copy2(bundle/'libexec/busyapi'/name,assets/name)
        for command in ['check','lint','bundle','build-docs']:
            destination=root/('must not publish '+absent+' '+command)
            options=['--output',str(destination)] if command in ['bundle','build-docs'] else []
            r=subprocess.run([str(missing/'busyapi'),command,str(project),*options,'--json'],env=environment,cwd='/',capture_output=True,text=True,timeout=30)
            assert r.returncode==3,r.stdout
            failed=json.loads(r.stdout);assert failed['complete'] is False and 'engine.assets' in r.stdout
            assert not destination.exists()
            for name in ['node','engine.cjs']:
                if absent in [name,'both']:assert str(assets/name) in r.stdout,r.stdout
print('PASS installed headless init/check/lint/bundle/native-reference build-docs, both formats/families, deterministic relocated output bytes and receipts, collision refusal, unsupported/invalid source, missing runtime/helper/both, arbitrary cwd, empty PATH and injected Node options; display-independent; browser/native rendering and network isolation require separate qualification')
