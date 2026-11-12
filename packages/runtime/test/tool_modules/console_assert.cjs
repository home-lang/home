const output = console.log.bind(console);
function check(value) { if (!value) throw new Error('Console assertion witness failed'); }
function assertion(...args) { check(console.assert(...args) === undefined); }
const cases = {
  surface() { check(typeof console.assert === 'function'); check(console.assert.name === 'assert' && console.assert.length === 0); const d=Object.getOwnPropertyDescriptor(console,'assert'); check(d.writable && d.enumerable && d.configurable); },
  no_arguments() { assertion(); },
  false_value() { assertion(false); },
  zero() { assertion(0); },
  negative_zero() { assertion(-0); },
  nan() { assertion(NaN); },
  empty_condition() { assertion(''); },
  null_condition() { assertion(null); },
  undefined_condition() { assertion(undefined); },
  bigint_zero() { assertion(0n); },
  truthy_boolean() { assertion(true, 'SHOULD NOT PRINT'); },
  truthy_number() { assertion(-1, 'SHOULD NOT PRINT'); },
  truthy_string() { assertion('false', 'SHOULD NOT PRINT'); },
  truthy_bigint() { assertion(7n, 'SHOULD NOT PRINT'); },
  truthy_symbol() { assertion(Symbol('condition'), 'SHOULD NOT PRINT'); },
  truthy_object() { const value={valueOf(){throw new Error('Must not coerce');}}; assertion(value, {toString(){throw new Error('Must not format');}}); },
  truthy_boxed_false() { assertion(new Boolean(false)); },
  empty_message() { assertion(false,''); },
  literal() { assertion(false,'literal failure'); },
  unicode() { assertion(false,'€😀'); },
  nul() { assertion(false,'before\0after'); },
  native_log_unpaired() { console.log('before\ud800after'); },
  native_error_unpaired() { console.error('before\ud800after'); },
  unpaired_surrogate() { assertion(false,'before\ud800after'); },
  multiline() { assertion(false,'first\nsecond\r\nthird'); },
  undefined_message() { assertion(false,undefined); },
  null_message() { assertion(false,null); },
  boolean_message() { assertion(false,false); },
  number_message() { assertion(false,42); },
  negative_zero_message() { assertion(false,-0); },
  bigint_message() { assertion(false,7n); },
  symbol_message() { assertion(false,Symbol('message')); },
  extra_primitives() { assertion(false,'message',-0,7n,Symbol('x'),undefined,null,true); },
  string_substitution() { assertion(false,'value %s','text'); },
  primitive_substitution() { assertion(false,'%s|%s|%s|%s',7n,Symbol('x'),-0,null); },
  number_substitution() { assertion(false,'%d|%i|%f','2.5','2.5','2.5'); },
  nonfinite_substitution() { assertion(false,'%d|%i|%f',Infinity,'NaN',Infinity); },
  negative_zero_substitution() { assertion(false,'%s|%d|%i|%f',-0,-0,-0,-0); },
  bigint_substitution() { assertion(false,'%s|%d|%i|%f',7n,7n,7n,7n); },
  symbol_substitution() { assertion(false,'%s|%d|%i|%f',Symbol('x'),Symbol('x'),Symbol('x'),Symbol('x')); },
  json_object() { assertion(false,'%j',{a:1,b:'€'}); },
  json_undefined() { assertion(false,'%j',undefined); },
  json_hook() { let calls=0; assertion(false,'%j',{toJSON(){++calls;return {actual:1};}});check(calls===1); },
  json_throw_identity() { const reason={identity:true};try{assertion(false,'%j',{toJSON(){throw reason;}});throw new Error('Did not throw');}catch(error){check(error===reason);} },
  ignored_style() { assertion(false,'%cstyled',{toString(){throw new Error('Must not coerce style');}}); },
  percent_without_args() { assertion(false,'%%'); },
  percent_with_args() { assertion(false,'%%',7); },
  unknown_format() { assertion(false,'unknown %q then %s',7,'extra'); },
  missing_format_args() { assertion(false,'%s %d %%','x'); },
  detached() { const fn=console.assert;check(fn.call({warn(){throw new Error('Wrong receiver');}},false,'detached')===undefined); },
  nonconstructible() { let error;try{Reflect.construct(console.assert,[true]);}catch(e){error=e;}check(error instanceof TypeError); },
  warn_override() { const original=console.warn;const value={identity:true};let calls=0;console.warn=function(...args){++calls;check(this===console);check(args[0]==='Assertion failed: raw %s' && args[1]===value);return 123;};try{assertion(false,'raw %s',value);check(calls===1);}finally{console.warn=original;} },
  warn_getter_throw() { const d=Object.getOwnPropertyDescriptor(console,'warn');const reason={identity:true};Object.defineProperty(console,'warn',{get(){throw reason;},configurable:true});try{assertion(true,'silent');try{assertion(false,'x');throw new Error('Did not throw');}catch(error){check(error===reason);}}finally{Object.defineProperty(console,'warn',d);} },
  poisoned_conversions() { const saved=[globalThis.String,globalThis.Number,globalThis.parseInt,globalThis.parseFloat,Array.prototype.slice,Array.prototype.unshift];const poison=()=>{throw new Error('Mutable conversion called');};globalThis.String=globalThis.Number=globalThis.parseInt=globalThis.parseFloat=Array.prototype.slice=Array.prototype.unshift=poison;try{assertion(false,'%s|%d|%i|%f',7n,'2.5','2.5','2.5');}finally{[globalThis.String,globalThis.Number,globalThis.parseInt,globalThis.parseFloat,Array.prototype.slice,Array.prototype.unshift]=saved;} },
  replaced_global() { const original=console;const fn=original.assert;globalThis.console={warn(){throw new Error('Wrong console');}};try{check(fn(false,'original console')===undefined);}finally{globalThis.console=original;} },
};
if(process.argv.includes('--list')) { process.stdout.write(JSON.stringify({node:process.version,cases:Object.keys(cases)})); }
else if(process.argv.includes('--home-profile')) {
  check(typeof console.assert==='function');
  for(const args of [[false,{}],[false,()=>{}],[false,'%o',1],[false,'%O',{}],[false,'%s',{}],[false,'%d',{}]]) {
    let error;try{console.assert(...args);}catch(e){error=e;}check(error && error.code==='ERR_HOME_UNSUPPORTED');
  }
  const value={};value.self=value;let error;try{console.assert(false,'%j',value);}catch(e){error=e;}check(error instanceof TypeError);
  check(!Object.hasOwn(globalThis,'__home_console_assert_factory'));
  output('HOME CONSOLE ASSERT PROFILE 6 INSPECTION REFUSALS; CIRCULAR JSON UNAVAILABLE');
} else {
  const name=process.argv[process.argv.indexOf('--case')+1];
  if(!Object.hasOwn(cases,name))throw new Error('Unknown console assertion case');
  cases[name]();output('OK');
}
