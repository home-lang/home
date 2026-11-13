"""Verify synchronous POSIX children against independent bytes/PID/filesystem observations."""
from pathlib import Path
import errno, hashlib, json, os, shlex, stat, subprocess, sys, tempfile
binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
base = [binary] + ([] if '--node' in sys.argv[3:] else ['run'])
helper = str(Path(script).parents[1] / 'tool_spawn_sync_child.py')
with tempfile.TemporaryDirectory(prefix='home-spawn-sync-') as folder:
    root = Path(folder).resolve(); work = root/'work'; work.mkdir(); (work/'tools').mkdir(); denied=root/'denied'; denied.mkdir()
    local = '#!/bin/sh\nprintf "%s" "$$" > "$1"\nprintf relative-out\n'
    for path in [work/'local-tool',work/'tools/local-tool']:
        path.write_text(local); path.chmod(0o755)
    (denied/'sh').write_text('not executable'); (denied/'sh').chmod(0o644)
    cases=[]; expected={}
    def add(name, *, options=None, input_data=None, input_kind=None, mode='normal', command=None, args=None, stdout=None, stderr=None, status=0, signal=None, error=None, shell_pid=False, overload=False, extra_args=()):
        witness=str(root/(name+'.witness')); output=str(root/name); opts=dict(options or {})
        entry={'name':name,'command':command or sys.executable,'args':args if args is not None else [helper,witness,mode,*extra_args], 'options':opts,'output':output,'overload':overload}
        if shell_pid: entry['args']=[part.replace('<PID>',witness) for part in entry['args']]
        if input_data is not None: entry.update(input=input_data.hex(),inputKind=input_kind)
        expected[name]={'witness':witness,'stdout':b'out\0\xff\xe2\x82\xac' if stdout is None else stdout,'stderr':b'err\0\xfe' if stderr is None else stderr,'status':None if error else status,'signal':signal,'error':error,'shell_pid':shell_pid,'input':b'' if input_data is None else input_data[1:-1] if input_kind in ('view','dataview') else input_data,'mode':mode}
        cases.append(entry)
    add('buffer')
    add('utf8',options={'encoding':'utf8'})
    add('utf8-alias',options={'encoding':'UTF-8'})
    add('pipe',options={'stdio':'pipe'})
    add('null-stdio',options={'stdio':None})
    add('ignore-input',options={'stdio':['ignore','pipe','pipe']})
    add('ignore-output',options={'stdio':['pipe','ignore','pipe']})
    add('ignore-error',options={'stdio':['pipe','pipe','ignore']})
    add('ignore-all',options={'stdio':'ignore'})
    add('short-stdio',options={'stdio':['ignore']})
    add('cwd',options={'cwd':str(work)})
    add('environment',options={'env':{'WITNESS':'real-env','PATH':'/bin'}})
    add('literal-args',extra_args=('space arg','$(touch NEVER_RUN)',';exit 91','\u20ac\U0001f600'))
    add('input-buffer',input_data=b'\0\xffinput',mode='input',stdout=b'\0\xffinput',stderr=b'')
    add('input-string',input_data='\u20ac\U0001f600'.encode(),input_kind='string',mode='input',stdout='\u20ac\U0001f600'.encode(),stderr=b'',options={'encoding':'utf8'})
    add('input-view',input_data=b'x\0\xffviewz',input_kind='view',mode='input',stdout=b'\0\xffview',stderr=b'')
    add('input-dataview',input_data=b'x\0\xffviewz',input_kind='dataview',mode='input',stdout=b'\0\xffview',stderr=b'')
    add('duplex',input_data=bytes([165])*(512*1024),mode='duplex',stdout=bytes(256*1024)+bytes([165])*(512*1024),stderr=bytes([7])*(256*1024))
    write_pid='printf "%s" "$$" > "$1"; '
    add('exit-seven',command='/bin/sh',args=['-c',write_pid+'printf nonzero-out; printf nonzero-err >&2; exit 7','probe','<PID>'],stdout=b'nonzero-out',stderr=b'nonzero-err',status=7,shell_pid=True)
    add('signal',command='/bin/sh',args=['-c',write_pid+'printf signal-out; kill -TERM $$','probe','<PID>'],stdout=b'signal-out',stderr=b'',status=None,signal='SIGTERM',shell_pid=True)
    for name,env in [('path',{'PATH':'/bin'}),('default-path',{}),('denied-then-path',{'PATH':str(denied)+':/bin'})]:
        add(name,command='sh',args=['-c',write_pid+'printf path-out','probe','<PID>'],options={'env':env},stdout=b'path-out',stderr=b'',shell_pid=True)
    for name,command,path in [('relative','./local-tool',None),('empty-path','local-tool',''),('relative-path','local-tool','tools')]:
        opts={'cwd':str(work)}
        if path is not None: opts['env']={'PATH':path}
        add(name,command=command,args=['<PID>'],options=opts,stdout=b'relative-out',stderr=b'',shell_pid=True)
    overloaded=work/'overload-tool';overloaded.write_text('#!/bin/sh\nprintf "%s" "$$" > '+shlex.quote(str(root/'overload.witness'))+'\nprintf overload-out\n');overloaded.chmod(0o755)
    add('overload',command=str(overloaded),args=[],options={'encoding':'utf8'},stdout=b'overload-out',stderr=b'',shell_pid=True,overload=True)
    add('missing',command='ecosystem-no-such-executable',args=[],options={'env':{'PATH':'/no-such-directory'}},error='ENOENT')
    add('denied',command=str(denied/'sh'),args=[],error='EACCES')
    add('missing-cwd',options={'cwd':str(root/'missing')},error='ENOENT')
    assert len(cases)==30
    config=root/'config.json'; config.write_text(json.dumps({'cases':cases}))
    child=subprocess.run(base+[script,str(config)],capture_output=True,timeout=60)
    assert child.returncode==0 and not child.stderr,(child.returncode,child.stdout[-4000:],child.stderr[-4000:])
    data=json.loads(child.stdout); failures=[]
    if not data['available']:
        print('NODE SPAWN SYNC RESULTS '+json.dumps({'available':False,'cases':30,'executed':0,'passed':0,'failures':['API absent']}))
        raise AssertionError('spawnSync absent; no child cases executed')
    assert data['executed']==30 and len(data['records'])==30
    assert data['controls']=={'alias':True,'name':'spawnSync','arity':3,'descriptor':True},data['controls']
    physical=0
    for case,record in zip(cases,data['records']):
        want=expected[case['name']]
        try:
            assert record['name']==case['name'] and 'thrown' not in record,record
            assert record['status']==want['status'] and record['signal']==want['signal'],record
            if want['error']:
                assert record['pid']==0 and record['aliases'] is None and record['stdoutType']==record['stderrType']=='undefined',record
                assert record['error']=={'code':want['error'],'errno':-getattr(errno,want['error']),'syscall':'spawnSync '+case['command'],'path':case['command'],'spawnargs':case['args']},record
                assert not Path(want['witness']).exists()
                continue
            assert record['error'] is None and record['pid']>0 and record['aliases'],record
            modes=case['options'].get('stdio') or ['pipe']*3
            if isinstance(modes,str): modes=[modes]*3
            modes=modes+['pipe']*(3-len(modes))
            encoding=case['options'].get('encoding','buffer').lower()
            for stream,index in [('stdout',1),('stderr',2)]:
                path=Path(case['output']+'.'+stream)
                assert record[stream+'Type']==('null' if modes[index]!='pipe' else 'buffer' if encoding=='buffer' else 'string'),record
                if modes[index]=='pipe':
                    raw=want[stream] if encoding=='buffer' else want[stream].decode('utf8','replace').encode()
                    assert path.read_bytes()==raw,(case['name'],stream,len(path.read_bytes()),len(raw))
                else: assert not path.exists()
            witness=json.loads(Path(want['witness']).read_text())
            if want['shell_pid']: assert witness==record['pid']
            else:
                assert witness['pid']==record['pid'] and witness['cwd']==case['options'].get('cwd',os.getcwd()),witness
                assert witness['stdin_character']==(modes[0]=='ignore'),witness
                assert witness['args']==case['args'][3:],witness
                assert witness['input_bytes']==len(want['input']) and witness['input_sha256']==hashlib.sha256(want['input']).hexdigest(),witness
                if 'env' in case['options']:
                    assert witness['WITNESS']==case['options']['env'].get('WITNESS') and 'HOME_TOOL_ACCOUNT_ORACLE' not in witness['env_keys'],witness
            try: os.kill(record['pid'],0)
            except ProcessLookupError: pass
            else: raise AssertionError('child not reaped')
            physical+=1
        except (AssertionError,OSError,KeyError,TypeError,ValueError) as error: failures.append({'case':case['name'],'detail':str(error)[:2000]})
    print('NODE SPAWN SYNC RESULTS '+json.dumps({'available':True,'cases':30,'executed':30,'passed':30-len(failures),'failures':failures}))
    assert not failures,failures
    assert physical==27
    child=subprocess.run(base+[str(Path(script).with_name('node_spawn_sync_esm.mjs'))],capture_output=True,timeout=15)
    assert child.returncode==0 and not child.stderr
    assert json.loads(child.stdout)=={'same':True,'status':0,'stdout':'esm-native','pidPositive':True,'error':False}
    inherited={'python':sys.executable,'helper':helper,'witness':str(root/'inherit.witness'),'result':str(root/'inherit.result')}
    inherit_config=root/'inherit.json';inherit_config.write_text(json.dumps(inherited));payload=b'physical-inherited-stdin\0\xff'
    child=subprocess.run(base+[str(Path(script).with_name('node_spawn_sync_inherit.cjs')),str(inherit_config)],input=payload,capture_output=True,timeout=15)
    assert child.returncode==0 and child.stdout==b'inherited-out:'+payload and child.stderr==b'inherited-err',(child.returncode,child.stdout,child.stderr)
    result=json.loads(Path(inherited['result']).read_text());witness=json.loads(Path(inherited['witness']).read_text())
    assert result['pid']==witness['pid'] and result['status']==0 and result['signal'] is None and result['stdout'] is result['stderr'] is None and result['aliases'] and not result['error']
    assert witness['input_bytes']==len(payload) and witness['input_sha256']==hashlib.sha256(payload).hexdigest()
    limit_config=root/'limit.json';limit_witness=root/'limit.witness'
    limit_config.write_text(json.dumps({'python':sys.executable,'helper':helper,'witness':str(limit_witness)}))
    child=subprocess.run(base+[str(Path(script).with_name('node_spawn_sync_limit.cjs')),str(limit_config)],capture_output=True,timeout=15)
    assert child.returncode==0 and not child.stderr,(child.returncode,child.stdout,child.stderr)
    limited=json.loads(child.stdout);witness=json.loads(limit_witness.read_text())
    assert limited['pid']==witness['pid'] and limited['status'] is None and limited['signal'] in ('SIGTERM','SIGKILL') and limited['error']=='ENOBUFS' and limited['errno']==-errno.ENOBUFS and limited['bytes']>128 and limited['aliases'],limited
    if '--home-profile' in sys.argv[3:]: assert limited['signal']=='SIGKILL' and limited['bytes']<=128+8192,limited
    try: os.kill(limited['pid'],0)
    except ProcessLookupError: pass
    else: raise AssertionError('capture-limit child not reaped')
    print('NATIVE SPAWN SYNC CAPTURE LIMIT KILLED/REAPED WITH REAL PARTIAL OUTPUT '+json.dumps({'error':limited['error'],'signal':limited['signal'],'bytes':limited['bytes']}))
    print('NATIVE SPAWN SYNC RAW BYTES, DUPLEX INPUT, PID/REAP, CWD/ENV/PATH AND INHERITED DESCRIPTORS VERIFIED')
    if '--home-profile' in sys.argv[3:]:
        child=subprocess.run(base+[str(Path(script).with_name('node_spawn_sync_profile.cjs')),str(root/'refused-start')],capture_output=True,timeout=15)
        assert child.returncode==0 and not child.stderr
        assert json.loads(child.stdout)=={'cases':11,'codes':['ERR_HOME_UNSUPPORTED']*11,'notStarted':True},child.stdout
        print('HOME SPAWN SYNC 11 PRE-SPAWN REFUSALS; TIMEOUT/SHELL/IPC/IDENTITY/DESCRIPTOR-TRANSFER UNAVAILABLE')
