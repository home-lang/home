"""Compare real nonzero process errors and captured bytes with Node observations."""
from pathlib import Path
import json
import subprocess
import sys

binary,script=[str(Path(p).resolve()) for p in sys.argv[1:3]]
base=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script]
oracle=Path(script).with_name('exec_diagnostics_oracle.json')
if '--generate' in sys.argv[3:]:
    child=subprocess.run(base+['--list'],capture_output=True,check=True,timeout=15)
    assert child.stderr==b''
    listing=json.loads(child.stdout)
    records=[]
    for name in listing['cases']:
        child=subprocess.run(base+['--case',name],capture_output=True,check=True,timeout=15)
        data=json.loads(child.stdout)
        assert data['status']!=0 and data['outputAliases'],data
        records.append({'name':name,'record':data,'stderr_hex':child.stderr.hex()})
    oracle.write_text(json.dumps({'node':listing['node'],'cases':records},indent=2)+'\n')
    print('GENERATED NODE EXEC DIAGNOSTIC ORACLE',listing['node'],len(records))
else:
    data=json.loads(oracle.read_text());failures=[]
    for case in data['cases']:
        child=subprocess.run(base+['--case',case['name']],capture_output=True,timeout=15)
        try:actual=json.loads(child.stdout)
        except ValueError:actual={'unparsed_stdout_hex':child.stdout.hex()}
        if child.returncode!=0 or actual!=case['record'] or child.stderr.hex()!=case['stderr_hex']:
            failures.append({'name':case['name'],'exit':child.returncode,'actual':actual,'expected':case['record'],'stderr_hex':child.stderr.hex(),'expected_stderr_hex':case['stderr_hex']})
    print('EXEC DIAGNOSTIC RESULTS '+json.dumps({'node':data['node'],'cases':len(data['cases']),'passed':len(data['cases'])-len(failures),'failures':failures}))
    assert not failures,failures
    print('NATIVE NONZERO COMMANDS, UTF8/BINARY STDERR AND ERROR STATUS VERIFIED')
