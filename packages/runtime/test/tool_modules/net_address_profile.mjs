import net from 'node:net';
if (Object.keys(net).sort().join(',') !== 'BlockList,isIP,isIPv4,isIPv6') throw new Error('Unexpected host API advertised');
for (const name of ['Socket', 'Server', 'SocketAddress', 'connect', 'createConnection', 'createServer', 'lookup']) if (name in net) throw new Error('Unimplemented host API advertised: ' + name);
for (const invoke of [b => b.addAddress('127.0.0.1\0evil'), b => b.addRange('1.2.3.4', '1.2.3.5\0evil'), b => b.addSubnet('::1\0evil', 128, 'ipv6'), b => b.check('::1\0evil', 'ipv6')]) {
  const b = new net.BlockList(); let refused = false;
  try { invoke(b); } catch (e) { refused = e.code === 'ERR_HOME_UNSUPPORTED'; }
  if (!refused || b.rules.length) throw new Error('Ambiguous NUL spelling was not refused');
}
const list = new net.BlockList();
list.addAddress('::1', 'ipv6');
list.addSubnet('10.1.2.3', 8);
if (!list.check('::1', 'other') || list.rules.join('|') !== 'Subnet: IPv4 10.1.2.3/8|Address: IPv6 ::1') throw new Error('Home rule order or Node check family behavior changed');
console.log('HOME NET PROFILE 4 REAL EXPORTS; SOCKET AND DNS APIS ABSENT; NUL REFUSED');
