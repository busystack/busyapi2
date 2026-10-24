"""Engine/CLI wall time only; does not measure Flutter paint or debounce completion."""
import pathlib,subprocess,time,json,sys,platform
cli=pathlib.Path(sys.argv[1]).resolve();directory=pathlib.Path(sys.argv[2]);results=[]
for file in [directory/name for name in ['1mb.json','5mb.json','1mb.yaml','5mb.yaml','1mb-minified.json','5mb-minified.json','graph/openapi.json']]:
    times=[]
    for _ in range(5):
        before=time.perf_counter();r=subprocess.run([str(cli),'check',str(file),'--json'],capture_output=True,text=True,timeout=60);times.append(time.perf_counter()-before)
        if r.returncode:raise RuntimeError(r.stdout[:500] or r.stderr[:500])
    results.append({'fixture':str(file),'bytes':file.stat().st_size,'seconds':times})
print(json.dumps({'version':1,'measurement':'CLI+IPC+collection+engine; no native input/paint measurements','machine':platform.platform(),'results':results},indent=2))
