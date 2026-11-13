'use strict';
const os = require('node:os');
const checks = [];
function check(name, condition) { checks.push({name, passed: condition === true}); }
if (typeof os.release !== 'function') console.log(JSON.stringify({available: false, executed: 0, checks: [], release: null}));
else {
  const release = os.release;
  const value = release();
  check('real nonempty string', typeof value === 'string' && value.length > 0);
  check('CJS alias identity', require('os') === os && require('os').release === release);
  check('name and arity', release.name === 'getOSRelease' && release.length === 0);
  check('unbound call', release.call(null) === value && Reflect.apply(release, {}, []) === value);
  check('arguments ignored', release(Symbol('ignored'), {toString() { throw new Error('must not convert'); }}) === value);
  const descriptor = Object.getOwnPropertyDescriptor(os, 'release');
  check('public descriptor', descriptor.writable && descriptor.enumerable && descriptor.configurable);
  let notConstructible = false;
  try { new release(); } catch (error) { notConstructible = error instanceof TypeError; }
  check('not constructible', notConstructible);
  const primitive = release[Symbol.toPrimitive];
  check('primitive hook', typeof primitive === 'function' && primitive !== release && primitive.length === 0 && primitive.name === '');
  const primitiveDescriptor = Object.getOwnPropertyDescriptor(release, Symbol.toPrimitive);
  check('primitive descriptor', primitiveDescriptor.writable && primitiveDescriptor.enumerable && primitiveDescriptor.configurable);
  check('primitive conversion', String(release) === value && `${release}` === value && release + '' === value);
  check('hint independent', ['string', 'number', 'default', undefined, null].every(hint => primitive.call({}, hint) === value));
  const platform = Object.getOwnPropertyDescriptor(process, 'platform');
  Object.defineProperty(process, 'platform', {...platform, value: 'ecosystem-fake-platform'});
  check('native platform independent', release() === value);
  Object.defineProperty(process, 'platform', platform);
  os.release = () => 'ecosystem-fake-release';
  check('captured hook independent', primitive() === value && release() === value);
  os.release = release;
  const convert = globalThis.String;
  globalThis.String = () => { throw new Error('must not call mutable String'); };
  check('conversion hook independent', release() === value && primitive() === value);
  globalThis.String = convert;
  check('repeated real reads', Array.from({length: 25}, () => release()).every(item => item === value));
  check('private callback absent', !Object.hasOwn(globalThis, '__home_tool_kernel_release'));
  console.log(JSON.stringify({available: true, executed: checks.length, checks, release: value}));
}
