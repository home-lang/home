"""Verify actual console assertion stdout/stderr bytes against a Node oracle."""
from pathlib import Path
import json
import subprocess
import sys

binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
root=Path(script).parent
oracle=root/'console_assert_oracle.json'
base=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script]
if '--generate' in sys.argv[3:]:
    listing=subprocess.run(base+['--list'],capture_output=True,check=True,timeout=15)
    assert listing.stderr==b''
    data=json.loads(listing.stdout)
    cases=[]
    for name in data['cases']:
        child=subprocess.run(base+['--case',name],capture_output=True,timeout=15)
        assert child.returncode==0 and child.stdout.endswith(b'OK\n'),(name,child)
        cases.append({'name':name,'stdout_hex':child.stdout.hex(),'stderr_hex':child.stderr.hex()})
    oracle.write_text(json.dumps({'node':data['node'],'cases':cases},indent=2)+'\n')
    print('GENERATED NODE CONSOLE ASSERT ORACLE',data['node'],len(cases))
else:
    data=json.loads(oracle.read_text())
    failures=[]
    for case in data['cases']:
        child=subprocess.run(base+['--case',case['name']],capture_output=True,timeout=15)
        if child.returncode!=0 or child.stdout.hex()!=case['stdout_hex'] or child.stderr.hex()!=case['stderr_hex']:
            failures.append({'name':case['name'],'exit':child.returncode,'stdout_hex':child.stdout.hex(),'stderr_hex':child.stderr.hex(),'expected_stderr_hex':case['stderr_hex']})
    print('CONSOLE ASSERT PHYSICAL RESULTS '+json.dumps({'node':data['node'],'cases':len(data['cases']),'passed':len(data['cases'])-len(failures),'failures':failures}))
    assert not failures,failures
    if '--home-profile' in sys.argv[3:]:
        child=subprocess.run(base+['--home-profile'],capture_output=True,timeout=15)
        assert child.returncode==0 and child.stderr==b'',child
        assert child.stdout==b'HOME CONSOLE ASSERT PROFILE 6 INSPECTION REFUSALS; CIRCULAR JSON UNAVAILABLE\n',child
        print(child.stdout.decode(),end='')
    print('NATIVE CONSOLE ASSERT STDERR BYTES, RETURN VALUES AND WARN DISPATCH VERIFIED')
