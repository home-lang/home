"""Execute real system resolution, independently compare physical host answers."""
from pathlib import Path
import hashlib
import ipaddress
import json
import socket
import subprocess
import sys
import tempfile

binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
reference = '--reference' in sys.argv[3:]
prefix = [binary] + ([] if reference else ['run'])
hosts = Path('/etc/hosts').read_bytes()
names = ['localhost', socket.gethostname()]
for line in hosts.decode(errors='replace').splitlines():
    fields = line.split('#', 1)[0].split()
    if len(fields) < 2:
        continue
    try:
        ipaddress.ip_address(fields[0])
    except ValueError:
        continue
    for name in fields[1:]:
        if name not in names and name.isascii():
            names.append(name)
        if len(names) >= 6:
            break
    if len(names) >= 6:
        break
queries = []
requests = [(name, family, 0) for name in names for family in [0, 4, 6]]
requests += [('localhost', 0, socket.AI_ADDRCONFIG), ('localhost', 6, socket.AI_V4MAPPED | socket.AI_ALL), ('localhost', 4, socket.AI_ADDRCONFIG), ('localhost', 6, socket.AI_V4MAPPED)]
for name, family, hints in requests:
    records = []
    failure = None
    try:
        raw = socket.getaddrinfo(name, None, {0:socket.AF_UNSPEC,4:socket.AF_INET,6:socket.AF_INET6}[family], socket.SOCK_STREAM, 0, hints)
        for version, _, _, _, address in raw:
            item = {'address': address[0], 'family': 4 if version == socket.AF_INET else 6}
            if item not in records:
                records.append(item)
    except socket.gaierror as error:
        failure = error.errno
    queries.append({'hostname': name, 'family': family, 'hints': hints, 'records': records, 'failure': failure})
assert queries[0]['records'], 'Physical localhost oracle produced no addresses'
with tempfile.TemporaryDirectory(prefix='home-dns-lookup-') as temporary:
    data = Path(temporary) / 'oracle.json'
    data.write_text(json.dumps(queries))
    child = subprocess.run(prefix + [str(Path(scripts) / 'node_dns_lookup.mjs'), str(data)], capture_output=True, timeout=90)
    assert child.returncode == 0 and child.stderr == b'', (child.returncode, child.stdout.decode(), child.stderr.decode())
    lines = child.stdout.decode().splitlines()
    ledger = json.loads(lines[0].removeprefix('DNS LOOKUP RESULTS '))
    assert ledger == {'groups': 28, 'passed': 28, 'failures': []}, ledger
    actual = json.loads(lines[1].removeprefix('DNS PHYSICAL HOST ANSWERS '))
    assert len(actual) == len(queries) and len(queries) >= 6
    for query, result in zip(queries, actual):
        if query['failure'] is None:
            assert result == {'records': query['records']}, (query, result)
        else:
            assert result['failure'] in ['ENOTFOUND', 'EAI_ADDRFAMILY', 'EAI_AGAIN', 'EAI_FAIL'], (query, result)
    print(lines[0])
    print('NATIVE DNS PHYSICAL HOST ORACLE VERIFIED ' + json.dumps({'queries':len(queries),'answers':sum(len(q['records']) for q in queries),'resolver_failures':sum(q['failure'] is not None for q in queries),'hosts_file_sha256':hashlib.sha256(hosts).hexdigest()}))
    marker = Path(temporary) / 'live.json'
    child = subprocess.run(prefix + [str(Path(scripts) / 'dns_lookup_exit.cjs'), 'live', str(marker)], capture_output=True, timeout=30)
    assert child.returncode == 0 and child.stderr == b'', (child.returncode, child.stderr)
    assert json.loads(marker.read_text()) == queries[0]['records'], 'Pending native lookup did not retain process liveness or the actual host answers'
    child = subprocess.run(prefix + [str(Path(scripts) / 'dns_lookup_exit.cjs'), 'unhandled', str(marker)], capture_output=True, timeout=30)
    assert child.returncode != 0 and b'ENOTFOUND' in child.stderr, (child.returncode, child.stderr)
    print('NATIVE DNS REF LIVENESS AND REAL UNHANDLED RESOLVER FAILURE VERIFIED')
    if not reference:
        child = subprocess.run(prefix + [str(Path(scripts) / 'dns_lookup_profile.mjs')], capture_output=True, timeout=30)
        assert child.returncode == 0 and child.stderr == b'', (child.stdout, child.stderr)
        assert child.stdout == b'HOME DNS PROFILE ASCII BOUND, PRIVATE BRIDGE, ONCE SNAPSHOT; RECORD RESOLVERS ABSENT\n', child.stdout
        print(child.stdout.decode(), end='')
