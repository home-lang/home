"""Verify real kernel release queries against independent Python uname."""
from pathlib import Path
import json,os,subprocess,sys
binary,script=[str(Path(p).resolve()) for p in sys.argv[1:3]]
base=[binary]+([] if '--node' in sys.argv[3:] else ['run'])
before=os.uname().release
child=subprocess.run(base+[script],capture_output=True,timeout=30)
assert child.returncode==0 and not child.stderr,(child.returncode,child.stdout,child.stderr)
data=json.loads(child.stdout)
failures=[c['name'] for c in data['checks'] if not c['passed']]
print('OS RELEASE RESULTS '+json.dumps({'groups':16,'executed':data['executed'],'passed':data['executed']-len(failures),'available':data['available'],'failures':failures,'release':data['release']}))
assert data['available'] and data['executed']==16 and not failures
child=subprocess.run(base+[str(Path(script).with_name('os_release_esm.mjs'))],capture_output=True,timeout=30)
assert child.returncode==0 and not child.stderr,(child.returncode,child.stdout,child.stderr)
esm=json.loads(child.stdout)
after=os.uname().release
assert data['release']==esm['release']==esm['primitive']==before==after and esm['same'],(data,esm,before,after)
print('NATIVE KERNEL RELEASE AND CJS/ESM/PRIMITIVE IDENTITY VERIFIED '+json.dumps({'release':before,'uname_sysname':os.uname().sysname}))
