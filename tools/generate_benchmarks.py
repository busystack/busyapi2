"""Construct trusted representative projects in a temporary output directory."""
import pathlib,json,sys
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
for mib in (1,5):
    operations={};i=0
    document={'openapi':'3.2.1','info':{'title':f'{mib} MiB typing fixture','version':'1'},'paths':operations}
    while True:
        for _ in range(100):
            operations[f'/items/{i}']={'get':{'summary':f'Get representative item {i}','description':'Representative text '*10,'responses':{'200':{'description':'OK','content':{'application/json':{'schema':{'type':'object','properties':{'name':{'type':'string'}}},'example':{'name':'fixture'}}}}}}};i+=1
        text=json.dumps(document,indent=2)+'\n'
        if len(text.encode())>=mib*1024*1024:break
    (out/f'{mib}mb.json').write_text(text)
    # Real block YAML with comments and quoted scalars, sharing the JSON semantics.
    yaml=['# Representative authored YAML','openapi: "3.2.1"',f'info: {{title: "{mib} MiB YAML", version: "1"}}','paths:']
    for path, item in operations.items():
        yaml += [f'  {json.dumps(path)}:', '    get:', '      summary: '+json.dumps(item['get']['summary']), '      description: '+json.dumps(item['get']['description']), '      responses:', '        "200":', '          description: "OK"', '          content:', '            application/json:', '              schema: {type: object, properties: {name: {type: string}}}', '              example: {name: "fixture"}']
    authored='\n'.join(yaml)+'\n'
    if len(authored.encode())<mib*1024*1024:authored+='# '+('x'*(mib*1024*1024-len(authored.encode())))+'\n'
    (out/f'{mib}mb.yaml').write_text(authored)
    longline={'openapi':'3.2.1','info':{'title':'Minified fixture','version':'1','description':'x'*(mib*1024*1024)},'paths':{}}
    (out/f'{mib}mb-minified.json').write_text(json.dumps(longline,separators=(',',':'))+'\n')
project=out/'graph';project.mkdir(exist_ok=True)
schemas={}
for i in range(500):
    name=f'Schema{i}';schemas[name]={'$ref':f'{name}.json'}
    (project/f'{name}.json').write_text(json.dumps({'type':'object','properties':{'name':{'type':'string'}}})+'\n')
(project/'openapi.json').write_text(json.dumps({'openapi':'3.2.1','info':{'title':'500 local files','version':'1'},'paths':{},'components':{'schemas':schemas}},indent=2)+'\n')
print(out)
