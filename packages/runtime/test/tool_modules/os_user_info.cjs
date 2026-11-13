"use strict";
const os = require('node:os');
const checks = [];
function check(name, passed) { checks.push({ name, passed: passed === true }); }
function probe(name, fn) { try { check(name, fn()); } catch { check(name, false); } }
if (typeof os.userInfo !== 'function') console.log(JSON.stringify({ available: false, executed: 0, checks }));
else {
  const expected = JSON.parse(process.env.HOME_TOOL_ACCOUNT_ORACLE);
  const userInfo = os.userInfo;
  const value = userInfo();
  function units(s) { return Array.from({length: s.length}, (_, i) => s.charCodeAt(i)); }
  function equal(user, encoding) {
    return user.uid === expected.uid && user.gid === expected.gid &&
      ['username', 'homedir', 'shell'].every(key => encoding === 'buffer'
        ? Buffer.isBuffer(user[key]) && user[key].toString('hex') === expected.rawHex[key]
        : JSON.stringify(units(user[key])) === JSON.stringify(expected[encoding][key]));
  }
  check('physical account strings and IDs', equal(value, 'utf8'));
  check('null prototype and key order', Object.getPrototypeOf(value) === null && Object.keys(value).join(',') === 'uid,gid,username,homedir,shell');
  check('field descriptors', Object.keys(value).every(key => { const d = Object.getOwnPropertyDescriptor(value, key); return d.writable && d.enumerable && d.configurable; }));
  check('CJS aliases', require('os') === os && require('os').userInfo === userInfo);
  check('name and arity', userInfo.name === 'userInfo' && userInfo.length === 1);
  check('unbound call', equal(Reflect.apply(userInfo, null, []), 'utf8'));
  check('constructible function', equal(new userInfo(), 'utf8'));
  check('public descriptor', (() => { const d = Object.getOwnPropertyDescriptor(os, 'userInfo'); return d.writable && d.enumerable && d.configurable; })());
  for (const encoding of Object.keys(expected.encodings)) probe('encoding ' + encoding, () => equal(userInfo({encoding}), expected.encodings[encoding]));
  for (const encoding of [undefined, null, '', 42, {}, Symbol('encoding')]) probe('default encoding ' + typeof encoding + ':' + checks.length, () => equal(userInfo({encoding}), 'utf8'));
  for (const options of [null, undefined, 42, 'buffer', true, Symbol('options')]) probe('primitive options ' + typeof options, () => equal(userInfo(options), 'utf8'));
  const fn = () => {}; fn.encoding = 'hex';
  check('function options ignored', equal(userInfo(fn), 'utf8'));
  check('inherited encoding', equal(userInfo(Object.create({encoding: 'hex'})), 'hex'));
  let reads = 0;
  check('encoding getter once', equal(userInfo({get encoding() { reads++; return 'buffer'; }}), 'buffer') && reads === 1);
  const sentinel = new Error('encoding getter'); let thrown;
  try { userInfo({get encoding() { throw sentinel; }}); } catch (error) { thrown = error; }
  check('getter exception identity', thrown === sentinel);
  probe('fresh owned objects and buffers', () => {
    const first = userInfo({encoding: 'buffer'}), second = userInfo({encoding: 'buffer'});
    first.uid = -2; first.username.fill(0); first.homedir.fill(0); first.shell.fill(0);
    return first !== second && equal(second, 'buffer') && equal(userInfo(), 'utf8');
  });
  const saved = ['HOME', 'USER', 'LOGNAME', 'SHELL'].map(key => [key, process.env[key]]);
  for (const [key] of saved) process.env[key] = '/ecosystem-not-the-native-account';
  check('environment independent', equal(userInfo(), 'utf8'));
  for (const [key, savedValue] of saved) { if (savedValue === undefined) delete process.env[key]; else process.env[key] = savedValue; }
  check('repeated native reads', Array.from({length: 20}, () => equal(userInfo(), 'utf8')).every(Boolean));
  check('private callback absent', !Object.hasOwn(globalThis, '__home_tool_user_info'));
  console.log(JSON.stringify({ available: true, executed: checks.length, checks }));
}
