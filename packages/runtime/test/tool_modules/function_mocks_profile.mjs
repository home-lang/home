import api from 'bun:test';
const {mock,spyOn}=api;
function check(v){if(!v)throw new Error('Home function mock profile mismatch');}
function refused(fn,code){try{fn();return false;}catch(e){return code?e.code===code:e instanceof TypeError;}}
check(Object.keys(api).sort().join(',')==='mock,spyOn');
for(const key of ['test','it','describe','expect','beforeEach','afterEach','jest','vi'])check(api[key]===undefined);
for(const key of ['module','restore','clearAllMocks'])check(mock[key]===undefined);
check(globalThis.__home_tool_function_mocks_factory===undefined);
check(refused(()=>new (mock(()=>1))(),'ERR_HOME_UNSUPPORTED'));
for(const value of [null,{},1,'x'])check(refused(()=>mock(value)));
const f=mock();for(const method of ['mockImplementation','mockImplementationOnce'])check(refused(()=>f[method](null)));
check(f.withImplementation===undefined&&f.mock.settledResults===undefined);
let touched=false;const obj={get f(){touched=true;return ()=>1;}};
check(refused(()=>spyOn(obj,'f'),'ERR_HOME_UNSUPPORTED')&&!touched);
check(refused(()=>spyOn(obj,'f','get'),'ERR_HOME_UNSUPPORTED')&&!touched);
check(refused(()=>spyOn({},'absent'))&&refused(()=>spyOn({f:1},'f')));
const frozen=Object.freeze({f(){return 3;}});check(refused(()=>spyOn(frozen,'f'))&&frozen.f()===3);
const proto={f(){return 5;}},child=Object.create(proto),spy=spyOn(child,'f');check(Object.hasOwn(child,'f'));spy.mockRestore();check(!Object.hasOwn(child,'f')&&child.f()===5);
const old=f.mock;f(1);f.mockClear();f(2);check(old.lastCall[0]===1&&f.mock.lastCall[0]===2);
// Bun1.4.4 leaves a cleared entry incomplete. Home retains the actual outcome
// in the detached history without repopulating the newly cleared trace.
const clearing=mock(()=>{clearing.mockClear();return 4;}),detached=clearing.mock;
check(clearing()===4&&detached.results[0].type==='return'&&detached.results[0].value===4&&clearing.mock.results.length===0);
console.log('HOME FUNCTION MOCK PROFILE REAL INVOCATION TRACES; TEST SCHEDULING AND MODULE MOCKING ABSENT');
