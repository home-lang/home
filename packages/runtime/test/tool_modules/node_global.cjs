function check(value,message){if(!value)throw new Error(message);}
check(typeof global==='object' && global===globalThis,'actual global alias');
const descriptor=Object.getOwnPropertyDescriptor(globalThis,'global');
check(descriptor.value===globalThis && descriptor.writable && descriptor.enumerable && descriptor.configurable,'Node global descriptor');
const probe='__home_owned_global_alias_probe';
try {
 global[probe]=17;check(globalThis[probe]===17,'write through legacy alias');
 globalThis[probe]=42;check(global[probe]===42,'write through globalThis');
 check(global.Math===Math && global.process===process && global.Buffer===Buffer,'shared actual builtins');
 check((function(global){return global===63 && globalThis[probe]===42;})(63),'ordinary local shadowing');
 globalThis.eval('globalThis.__home_owned_global_alias_probe = 81');
 check(global[probe]===81,'eval sees same global object');
 delete globalThis.global;check(typeof global==='undefined','delete actual property removes alias');
 Object.defineProperty(globalThis,'global',descriptor);check(global===globalThis,'restore alias');
} finally {delete globalThis[probe];Object.defineProperty(globalThis,'global',descriptor);}
console.log('OK actual Node global alias, descriptor, shared mutations, eval and deletion');
