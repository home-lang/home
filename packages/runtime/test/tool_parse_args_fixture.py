"""Compare actual util.parseArgs results/errors/tokens with a generated Node oracle."""
from pathlib import Path
import json,subprocess,sys
binary,script=[str(Path(p).resolve()) for p in sys.argv[1:3]]
argv=[binary]+([] if '--node' in sys.argv[3:] else ['run'])+[script]
child=subprocess.run(argv,capture_output=True,timeout=45)
assert child.returncode==0,(child.returncode,child.stdout,child.stderr)
assert not child.stderr,child.stderr
actual=json.loads(child.stdout)
oracle=Path(script).with_name('util_parse_args_oracle.json')
esm=Path(script).with_name('util_parse_args_esm.mjs')
esm_child=subprocess.run([*argv[:-1],str(esm)],capture_output=True,timeout=45) if actual['available'] else None
if '--generate' in sys.argv[3:]:
    assert actual['available'] and actual['executed']==actual['expectedCases']
    assert esm_child.returncode==0 and not esm_child.stderr
    version=subprocess.check_output([binary,'--version'],text=True).strip()
    oracle.write_text(json.dumps({'node':version,'observation':actual,'esm_stdout_hex':esm_child.stdout.hex()},indent=2)+'\n')
    print('GENERATED NODE PARSE ARGS ORACLE',version,actual['executed'])
else:
    saved=json.loads(oracle.read_text());expected=saved['observation']
    failures=[]
    for a,e in zip(actual['records'],expected['records']):
        if a!=e:failures.append({'name':e['name'],'actual':a,'expected':e})
    if actual.get('controls')!=expected['controls']:failures.append({'name':'controls','actual':actual.get('controls'),'expected':expected['controls']})
    if esm_child is not None and (esm_child.returncode!=0 or esm_child.stderr or esm_child.stdout.hex()!=saved['esm_stdout_hex']):failures.append({'name':'esm','exit':esm_child.returncode,'stdout_hex':esm_child.stdout.hex(),'stderr_hex':esm_child.stderr.hex()})
    complete=actual['available'] and actual['executed']==expected['executed'] and actual['expectedCases']==expected['expectedCases']
    print('UTIL PARSE ARGS RESULTS '+json.dumps({'node':saved['node'],'cases':expected['executed'],'executed':actual['executed'],'passed':actual['executed']-len([f for f in failures if f['name'] not in ['controls','esm']]),'available':actual['available'],'failures':failures}))
    assert complete and not failures
    print('UTIL PARSE ARGS VALUES/TOKENS/ERROR CODES, NULL PROTOTYPES AND ARGV DEFAULTS VERIFIED')
