"""Compare the effective native account with independent Python pwd, without printing account data."""
from pathlib import Path
import json, os, pwd, subprocess, sys
binary, script = [str(Path(p).resolve()) for p in sys.argv[1:3]]
base = [binary] + ([] if '--node' in sys.argv[3:] else ['run'])
def snapshot():
    account = pwd.getpwuid(os.geteuid())
    raw = {key: os.fsencode(value) for key, value in [('username', account.pw_name), ('homedir', account.pw_dir), ('shell', account.pw_shell)]}
    def units(text):
        data = text.encode('utf-16-le', 'surrogatepass')
        return [int.from_bytes(data[i:i+2], 'little') for i in range(0, len(data), 2)]
    import base64
    encoders = {'utf8': lambda b: b.decode('utf8', 'replace'), 'hex': lambda b: b.hex(),
        'ascii': lambda b: ''.join(chr(x & 127) for x in b), 'latin1': lambda b: b.decode('latin1'),
        'utf16le': lambda b: b[:len(b)//2*2].decode('utf-16-le', 'surrogatepass'),
        'base64': lambda b: base64.b64encode(b).decode(), 'base64url': lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')}
    expected = {'uid': account.pw_uid, 'gid': account.pw_gid, 'rawHex': {key: value.hex() for key, value in raw.items()}}
    for encoding, encode in encoders.items(): expected[encoding] = {key: units(encode(value)) for key, value in raw.items()}
    expected['encodings'] = {key: value for key, value in [('utf8','utf8'), ('UTF8','utf8'), ('utf-8','utf8'), ('hex','hex'), ('base64','base64'), ('base64url','base64url'), ('ascii','ascii'), ('latin1','latin1'), ('binary','latin1'), ('ucs2','utf16le'), ('ucs-2','utf16le'), ('utf16le','utf16le'), ('utf-16le','utf16le'), ('buffer','buffer'), ('BUFFER','buffer'), ('invalid','utf8')]}
    return expected
expected = snapshot()
env = dict(os.environ, HOME_TOOL_ACCOUNT_ORACLE=json.dumps(expected, ensure_ascii=True))
child = subprocess.run(base+[script], env=env, capture_output=True, timeout=30)
assert child.returncode == 0 and not child.stderr, (child.returncode, child.stdout, child.stderr)
data = json.loads(child.stdout)
failures = [c['name'] for c in data['checks'] if not c['passed']]
print('OS USER INFO RESULTS '+json.dumps({'available': data['available'], 'executed': data['executed'], 'passed': data['executed']-len(failures), 'failures': failures}))
assert data['available'] and data['executed'] == 44 and not failures
child = subprocess.run(base+[str(Path(script).with_name('os_user_info_esm.mjs'))], env=env, capture_output=True, timeout=30)
assert child.returncode == 0 and not child.stderr, (child.returncode, child.stdout, child.stderr)
esm = json.loads(child.stdout)
assert esm['same'] and esm['physical'] and snapshot() == expected
print('NATIVE EFFECTIVE ACCOUNT AND CJS/ESM/RAW BUFFER IDENTITY VERIFIED')
