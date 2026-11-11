"""Independent stdlib numeric-address oracle; same fixture runs on Node and Bun."""
import ipaddress
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile

binary, scripts = [str(Path(p).resolve()) for p in sys.argv[1:3]]
prefix = [binary] + ([] if '--reference' in sys.argv[3:] else ['run'])
rng = random.Random(0x4E4554)
validators = []
for version, Address in [(4, ipaddress.IPv4Address), (6, ipaddress.IPv6Address)]:
    for _ in range(128):
        address = Address(rng.getrandbits(Address(0).max_prefixlen))
        for spelling in {str(address), address.exploded.upper()}:
            validators.append([spelling, version])
        validators.append([str(address) + '/0', 0])
        validators.append([' ' + str(address), 0])
# Exercise every prefix width, including non-byte-aligned masks, with queries
# immediately inside and outside the actual stdlib network's bounds.
blocks = []
mapped = int(ipaddress.IPv6Address('::ffff:0:0'))
for version, Address, Network in [(4, ipaddress.IPv4Address, ipaddress.IPv4Network), (6, ipaddress.IPv6Address, ipaddress.IPv6Network)]:
    # Before Python 3.14 this is a property on the class, not an integer.
    width = Address(0).max_prefixlen
    for bits in range(width + 1):
        host = Address(rng.getrandbits(width))
        network = Network((host, bits), strict=False)
        low, high = int(network.network_address), int(network.broadcast_address)
        queries = []
        for number in {low, high, int(host), max(0, low - 1), min((1 << width) - 1, high + 1)}:
            queries.append([str(Address(number)), 'ipv' + str(version), Address(number) in network])
            if version == 4:
                queries.append([str(ipaddress.IPv6Address(mapped | number)), 'ipv6', Address(number) in network])
        if version == 6:
            for v4 in ['0.0.0.0', '127.0.0.1', '192.0.2.1', '255.255.255.255']:
                queries.append([v4, 'ipv4', ipaddress.IPv6Address(mapped | int(ipaddress.IPv4Address(v4))) in network])
        blocks.append({'address': str(host), 'family': 'ipv' + str(version), 'prefix': bits, 'queries': queries})
with tempfile.TemporaryDirectory(prefix='home-net-address-') as temporary:
    data = Path(temporary) / 'oracle.json'
    data.write_text(json.dumps({'validators': validators, 'blocks': blocks}))
    child = subprocess.run(prefix + [str(Path(scripts) / 'node_net_addresses.mjs'), str(data)], capture_output=True, timeout=90)
    assert child.returncode == 0 and child.stderr == b'', (child.returncode, child.stdout.decode(), child.stderr.decode())
    lines = child.stdout.decode().splitlines()
    ledger = json.loads(lines[0].removeprefix('NET ADDRESS RESULTS '))
    assert ledger == {'groups': 31, 'passed': 31, 'failures': []}, ledger
    actual = json.loads(lines[1].removeprefix('NET INDEPENDENT ORACLE '))
    expected = {'validators': len(validators), 'subnets': len(blocks), 'queries': sum(len(b['queries']) for b in blocks)}
    assert actual == expected, (actual, expected)
    print(child.stdout.decode(), end='')
    print('PYTHON IPADDRESS ORACLE VERIFIED')
    if '--reference' not in sys.argv[3:]:
        child = subprocess.run(prefix + [str(Path(scripts) / 'net_address_profile.mjs')], capture_output=True, timeout=30)
        assert child.returncode == 0 and child.stderr == b'', (child.stdout, child.stderr)
        assert child.stdout == b'HOME NET PROFILE 4 REAL EXPORTS; SOCKET AND DNS APIS ABSENT; NUL REFUSED\n', child.stdout
        print(child.stdout.decode(), end='')
