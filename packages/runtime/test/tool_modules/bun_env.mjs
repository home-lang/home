import bun, { env } from 'bun';
import process from 'node:process';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
function check(value, message) { if (!value) throw new Error(message); }
check(env === process.env && Bun.env === env && bun.env === env, 'actual environment alias identity');
check(createRequire(process.argv[1])('bun').env === env && (await import('bun')).env === env, 'CJS and dynamic aliases');
check(env.ECOSYSTEM_ENV_WITNESS === 'native-witness', 'actual inherited OS value');
const descriptor = Object.getOwnPropertyDescriptor(Bun, 'env');
check(descriptor.value === env && descriptor.enumerable === true && descriptor.configurable === false && descriptor.writable === false, 'Bun environment property descriptor');
let reason;
try { (function() { 'use strict'; Bun.env = {}; })(); } catch (error) { reason = error; }
check(reason instanceof TypeError && Bun.env === env, 'environment namespace is read-only');
const original = env.ECOSYSTEM_ENV_WITNESS;
try {
  env.ECOSYSTEM_ENV_WITNESS = 'changed-🟢';
  check(process.env.ECOSYSTEM_ENV_WITNESS === 'changed-🟢' && bun.env.ECOSYSTEM_ENV_WITNESS === 'changed-🟢', 'shared mutable values');
  execFileSync('/bin/sh', ['-c', 'test "$ECOSYSTEM_ENV_WITNESS" = "$1"', 'env-witness', 'changed-🟢'], { stdio: 'inherit', env });
  delete process.env.ECOSYSTEM_ENV_WITNESS;
  check(!Object.hasOwn(Bun.env, 'ECOSYSTEM_ENV_WITNESS'), 'deletion shares identity');
  execFileSync('/bin/sh', ['-c', 'test -z "${ECOSYSTEM_ENV_WITNESS+x}"'], { stdio: 'inherit', env });
}
finally { env.ECOSYSTEM_ENV_WITNESS = original; }
console.log('OK actual OS environment aliases, descriptor, mutation and native child forwarding');
