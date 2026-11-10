import * as after from './after.mjs';
import * as before from './before.mjs';
import * as local from './local.mjs';
import * as alias from './alias.mjs';
import * as namespace from './namespace.mjs';
function check(value, message) { if (!value) throw new Error(message); operations++; }
let operations = 0;
check(after.value === 41, 'explicit source after star wins');
check(before.value === 41, 'explicit source before star wins');
check(after.other === 7 && before.other === 7, 'unshadowed star names survive');
after.bump();
check(after.value === 42, 'explicit source remains live');
check(before.value === 42, 'both explicit orders observe same live source');
before.bump();
check(after.value === 43 && before.value === 43, 'shared source stays live');
check(local.value === 3, 'local declaration after star wins');
local.bump();
check(local.value === 4, 'exported local declaration remains live');
check(local.other === 7, 'local declaration keeps unshadowed star names');
check(alias.value === 19, 'local alias after star wins');
check(namespace.value.value === 43, 'explicit namespace after star wins');
namespace.value.bumpOverride();
check(namespace.value.value === 44 && after.value === 44 && before.value === 44, 'namespace and forwarders share live binding');
check(!Reflect.set(after, 'value', 100), 'forwarded export rejects mutation');
let caught;
try { after.value = 100; } catch (error) { caught = error; }
check(caught instanceof TypeError && after.value === 44, 'strict export mutation throws');
if (operations !== 14) throw new Error('export precedence operation denominator ' + operations);
