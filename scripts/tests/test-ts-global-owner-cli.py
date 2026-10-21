#!/usr/bin/env python3
"""Compare global declaration ownership and merged overloads with native tsc."""
from pathlib import Path
import runpy,sys,json
r=Path(__file__).resolve().parents[2];h=runpy.run_path(str(r/'scripts/tests/test-ts-polymorphic-this-cli.py'));a=runpy.run_path(str(r/'scripts/tests/test-ts-ambient-owner-cli.py'));h['CASES'].clear();h['CASES'].update(a['KNOWN_GAPS'])
def case(name,files,main,codes):h['CASES'][name]=({**files,'main.ts':main},codes)
api='declare module "api"{export function take(value:Payload):void;}'
case('global-negative',{'global.d.ts':'interface Payload{value:string}','api.d.ts':api},'import {take} from "api";take(1);',[2345])
case('global-positive',{'global.d.ts':'interface Payload{value:string}','api.d.ts':api},'import {take} from "api";take({value:"ok"});',[])
case('global-consumer-shadow',{'global.d.ts':'interface Payload{value:string}','api.d.ts':api},'import {take} from "api";interface Payload{value:number}take({value:1});',[2322])
case('global-api-shadow',{'global.d.ts':'interface Payload{value:string}','api.d.ts':'declare module "api"{interface Payload{value:number}export function take(value:Payload):void;}'},'import {take} from "api";take({value:1});',[])
case('global-augmentation-negative',{'global.d.ts':'export {};declare global{interface Payload{value:string}}','api.d.ts':api},'import {take} from "api";take(1);',[2345])
case('global-nested-augmentation-negative',{'global.d.ts':'declare module "owner"{global{interface Payload{value:string}}}','api.d.ts':api},'import {take} from "api";take(1);',[2345])
case('global-transitive-alias-negative',{'global.d.ts':'type Payload=Value;','value.d.ts':'interface Value{value:string}','api.d.ts':api},'import {take} from "api";take(1);',[2345])
case('global-recursive-negative',{'first.d.ts':'interface Payload{value:string}','second.d.ts':'interface Payload{next?:Payload}','api.d.ts':api},'import {take} from "api";take({value:"ok",next:{value:1}});',[2322])
case('global-external-type-is-not-global',{'private.d.ts':'export interface Payload{value:string}','api.d.ts':api},'import {take} from "api";take(1);',[])
box={'first.d.ts':'type T=number;interface Box{first:T}','second.d.ts':'interface Box<T=string>{second:T}','api.d.ts':'declare module "api"{export function take(value:Box):void;}'}
case('global-added-parameter-positive',box,'import {take} from "api";take({first:1,second:"ok"});',[])
case('global-added-parameter-negative',box,'import {take} from "api";take({first:"bad",second:"ok"});',[2322])


case('global-overload-priority',{'first.d.ts':'interface Payload{pick(value:string|number):"first"}','second.d.ts':'interface Payload{pick(value:string):"second"}','api.d.ts':'declare module "api"{export function get():Payload;}'},'import {get} from "api";const exact:"second"=get().pick("ok");',[])
case('global-overload-priority-negative',{'first.d.ts':'interface Payload{pick(value:string|number):"first"}','second.d.ts':'interface Payload{pick(value:string):"second"}','api.d.ts':'declare module "api"{export function get():Payload;}'},'import {get} from "api";const wrong:"first"=get().pick("ok");',[2322])

for kind,member,expr in [('call','(value:{t}):{r}','get()("ok")'),('construct','new(value:{t}):{r}','new (get())("ok")'),('method','pick(value:{t}):{r}','get().pick("ok")')]:
 for good,annotation in [(True,'"second"'),(False,'"first"')]:
  files={'first.d.ts':'interface Payload{'+member.format(t='string|number',r='"first"')+'}', 'second.d.ts':'interface Payload{'+member.format(t='string',r='"second"')+'}', 'api.d.ts':'declare module "api"{export function get():Payload;}', 'main.ts':'import {get} from "api";const value:'+annotation+'='+expr+';'}
  h['CASES']['global-'+kind+'-priority-'+str(good)]=(files,[] if good else [2322])
# Multiple overloads in one fragment must all survive merging.
for value,result in [('"ok"','"text"'),('1','"number"')]:
 h['CASES']['global-within-fragment-'+result]=({'first.d.ts':'interface Payload{pick(value:string):"text";pick(value:number):"number"}', 'second.d.ts':'interface Payload{extra:boolean}', 'api.d.ts':'declare module "api"{export function get():Payload;}', 'main.ts':'import {get} from "api";const value:'+result+'=get().pick('+value+');'},[])

for kind,member,expr in [('call','(value:{t}):{r}','get()("ok")'),('construct','new(value:{t}):{r}','new (get())("ok")'),('method','pick(value:{t}):{r}','get().pick("ok")')]:
 for good,annotation in [(True,'"later"'),(False,'"earlier"')]:
  case('global-'+kind+'-broad-later-'+str(good), {'first.d.ts':'interface Payload{'+member.format(t='string',r='"earlier"')+'}', 'second.d.ts':'interface Payload{'+member.format(t='string|number',r='"later"')+'}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";const value:'+annotation+'='+expr+';', [] if good else [2322])

scoped = {'first.d.ts':'export {};type Value=string;declare global{interface Payload{left:Value}}', 'second.d.ts':'export {};type Value=number;declare global{interface Payload{right:Value}}', 'api.d.ts':'declare module "api"{export function take(value:Payload):void;}'}
case('global-fragment-scopes-positive',scoped,'import {take} from "api";type Value=boolean;take({left:"ok",right:1});',[])
case('global-fragment-scopes-negative',scoped,'import {take} from "api";take({left:1,right:"bad"});',[2322,2322])
case('global-named-namespace-is-not-augmentation',{'private.d.ts':'export {};declare namespace global{interface Payload{value:string}}','api.d.ts':api},'import {take} from "api";take(1);',[])

for kind,member,expr in [('call','(value:{t}):{r}','get()("ok")'),('method','pick(value:{t}):{r}','get().pick("ok")')]:
    for good,annotation in [(True,'"special"'),(False,'"ordinary"')]:
        case('global-'+kind+'-specialized-'+str(good), {'first.d.ts':'interface Payload{'+member.format(t='"ok"',r='"special"')+'}', 'second.d.ts':'interface Payload{'+member.format(t='string',r='"ordinary"')+'}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";const value:'+annotation+'='+expr+';', [] if good else [2322])
for good,annotation in [(True,'"later"'),(False,'"earlier"')]:
    case('global-generic-overload-priority-'+str(good), {'first.d.ts':'interface Payload<T>{pick(value:string):"earlier";value:T}', 'second.d.ts':'interface Payload<T>{pick(value:string|number):"later"}', 'api.d.ts':'declare module "api"{export function get():Payload<string>;}'}, 'import {get} from "api";const value:'+annotation+'=get().pick("ok");const field:string=get().value;', [] if good else [2322])

for good,annotation in [(True,'"later"'),(False,'"earlier"')]:
    case('global-inherited-generic-overload-priority-'+str(good), {'first.d.ts':'interface Base<T>{value:T}interface Payload<T> extends Base<T>{pick(value:string):"earlier"}', 'second.d.ts':'interface Payload<T>{pick(value:string|number):"later"}', 'api.d.ts':'declare module "api"{export function get():Payload<string>;}'}, 'import {get} from "api";const value:'+annotation+'=get().pick("ok");const field:string=get().value;', [] if good else [2322])
for kind,member,expr in [('call','(value:{t}):{r}','get()(1)'),('method','pick(value:{t}):{r}','get().pick(1)'),('construct','new(value:{t}):{r}','new (get())(1)')]:
 for good,annotation in [(True,'"special"'),(False,'"ordinary"')]:
  files={'first.d.ts':'interface Payload{'+member.format(t='1',r='"special"')+'}', 'second.d.ts':'interface Payload{'+member.format(t='number',r='"ordinary"')+'}', 'api.d.ts':'declare module "api"{export function get():Payload;}', 'main.ts':'import {get} from "api";const value:'+annotation+'='+expr+';'}
  h['CASES']['global-'+kind+'-numeric-literal-'+str(good)]=(files,[] if good else [2322])
for good,annotation in [(True,'"special"'),(False,'"ordinary"')]:
 h['CASES']['global-constructor-string-literal-'+str(good)]=({'first.d.ts':'interface Payload{new(value:"ok"):"special"}', 'second.d.ts':'interface Payload{new(value:string):"ordinary"}', 'api.d.ts':'declare module "api"{export function get():Payload;}', 'main.ts':'import {get} from "api";const value:'+annotation+'=new (get())("ok");'},[] if good else [2322])

for good,annotation in [(True,'"special"'),(False,'"ordinary"')]:
    case('global-const-inferred-literal-is-not-specialized-'+str(good), {'first.d.ts':'interface Payload{pick(value:"ok"):"special"}', 'second.d.ts':'interface Payload{pick<const T>(value:T):"ordinary"}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";const value:'+annotation+'=get().pick("ok");', [] if good else [2322])
for good,annotation in [(True,'"later"'),(False,'"earlier"')]:
    case('global-any-overload-order-'+str(good), {'first.d.ts':'interface Payload{pick(value:number):"earlier"}', 'second.d.ts':'interface Payload{pick(value:any):"later"}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";const value:'+annotation+'=get().pick(1);', [] if good else [2322])

for kind, declaration, expression in [
    ('method', 'pick(value:string):{result}', 'get().pick("value")'),
    ('call', '(value:string):{result}', 'get()("value")'),
    ('construct', 'new(value:string):{result}', 'new (get())("value")'),
]:
    for merged in (False, True):
        for good in (True, False):
            files = {
                'first.d.ts': 'interface Base{' + declaration.format(result='"base"|"own"') + '}interface Payload extends Base{' + declaration.format(result='"own"') + '}',
                'api.d.ts': 'declare module "api"{export function get():Payload;}',
                'main.ts': 'import {get} from "api";const value:' + ('"own"' if good else '"base"') + '=' + expression + ';',
            }
            if merged:
                files['second.d.ts'] = 'interface Payload{extra:boolean}'
            h['CASES'][f'global-own-before-inherited-{kind}-{merged}-{good}'] = (files, [] if good else [2322])
for first, second, valid, invalid in [('string', 'number', '"ok"', '1'), ('number', 'string', '1', '"bad"')]:
    for good in (True, False):
        files = {
            'first.d.ts': 'interface Payload{value:' + first + '}',
            'second.d.ts': 'interface Payload{value:' + second + '}',
            'api.d.ts': 'declare module "api"{export function take(value:Payload):void;}',
            'main.ts': 'import {take} from "api";take({value:' + (valid if good else invalid) + '});',
        }
        h['CASES'][f'global-duplicate-data-member-{first}-{good}'] = (files, [] if good else [2322])


# Generic heritage must preserve the own surface after actual substitution.
for kind, declaration, expression in [
    ('method', 'pick(value:T):{result}', 'get().pick("value")'),
    ('call', '(value:T):{result}', 'get()("value")'),
    ('construct', 'new(value:T):{result}', 'new (get())("value")'),
]:
    for merged in (False, True):
        for good in (True, False):
            files = {
                'first.d.ts': 'interface Base<T>{value:T;' + declaration.format(result='"base"|"own"') + '}interface Payload<T> extends Base<T>{' + declaration.format(result='"own"') + '}',
                'api.d.ts': 'declare module "api"{export function get():Payload<string>;}',
                'main.ts': 'import {get} from "api";const field:string=get().value;const value:' + ('"own"' if good else '"base"') + '=' + expression + ';',
            }
            if merged: files['second.d.ts'] = 'interface Payload<T>{extra:boolean}'
            h['CASES'][f'global-generic-own-before-inherited-{kind}-{merged}-{good}'] = (files, [] if good else [2322])

own_method_files = {'first.d.ts': 'interface Base{pick(value:string):"base"|"own"}interface Payload extends Base{pick(value:string):"own"}', 'api.d.ts': 'declare module "api"{export function get():Payload;}'}
for mode, prefix, expression in [
    ('detached', 'const pick=get().pick;', 'pick("value")'),
    ('element', '', 'get()["pick"]("value")'),
    ('indexed-type', 'declare const pick:Payload["pick"];', 'pick("value")'),
]:
    for good in (True, False):
        case('global-own-member-' + mode + '-' + str(good), own_method_files, 'import {get} from "api";' + prefix + 'const value:' + ('"own"' if good else '"base"') + '=' + expression + ';', [] if good else [2322])
case('global-own-mutable-overrides-readonly', {'first.d.ts':'interface Base{readonly value:string|number}interface Payload extends Base{value:string}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";get().value="ok";', [])
case('global-own-readonly-overrides-mutable', {'first.d.ts':'interface Base{value:string|number}interface Payload extends Base{readonly value:string}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";get().value="ok";', [2540])
case('global-own-required-delete-negative', {'first.d.ts':'interface Base{value?:string}interface Payload extends Base{value:string}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";delete get().value;', [2790])
case('global-own-optional-delete-positive', {'first.d.ts':'interface Base{value:string}interface Payload extends Base{value?:string}', 'api.d.ts':'declare module "api"{export function get():Payload;}'}, 'import {get} from "api";delete get().value;', [])

variants = [
    ('alias-string', 'type Param="ok";', 'Param', 'string', '"ok"'),
    ('alias-number', 'type Param=1;', 'Param', 'number', '1'),
    ('indexed-string', 'interface Holder{value:"ok"}', 'Holder["value"]', 'string', '"ok"'),
    ('parenthesized-string', '', '("ok")', 'string', '"ok"'),
    ('inline-null', '', 'null', 'null|string', 'null'),
    ('inline-boolean', '', 'true', 'boolean', 'true'),
]
for kind, member, expression in [
    ('method', 'pick(value:{type}):{result}', 'get().pick({argument})'),
    ('call', '(value:{type}):{result}', 'get()({argument})'),
    ('construct', 'new(value:{type}):{result}', 'new (get())({argument})'),
]:
    for label, prefix, parameter, broad, argument in variants:
        call = expression.format(argument=argument)
        files = {
            'first.d.ts': prefix + 'interface Payload{' + member.format(type=parameter, result='"special"') + '}',
            'second.d.ts': 'interface Payload{' + member.format(type=broad, result='"ordinary"') + '}',
            'api.d.ts': 'declare module "api"{export function get():Payload;}',
            'main.ts': 'import {get} from "api";\nconst special:"special"=' + call + ';\nconst ordinary:"ordinary"=' + call + ';',
        }
        # Exactly one assignment must fail. Its location reveals the choice.
        h['CASES'][f'global-literal-origin-{kind}-{label}'] = (files, [2322])


# Reading an overloaded method as a value must retain its declaration groups.
for mode, prefix, expression in [
    ('direct', '', 'get().pick("ok")'),
    ('bracket', '', 'get()["pick"]("ok")'),
    ('detached', 'const pick=get().pick;', 'pick("ok")'),
    ('detached-bracket', 'const pick=get()["pick"];', 'pick("ok")'),
    ('indexed-type', 'declare const pick:Payload["pick"];', 'pick("ok")'),
]:
    for specialized in (False, True):
        first_type = '"ok"' if specialized else 'string'
        second_type = 'string' if specialized else 'string|number'
        files = {
            'first.d.ts': 'interface Payload{pick(value:' + first_type + '):"first"}',
            'second.d.ts': 'interface Payload{pick(value:' + second_type + '):"second"}',
            'api.d.ts': 'declare module "api"{export function get():Payload;}',
            'main.ts': 'import {get} from "api";' + prefix + '\nconst first:"first"=' + expression + ';\nconst second:"second"=' + expression + ';',
        }
        h['CASES'][f'global-method-value-order-{mode}-{specialized}'] = (files, [2322])


# No-substitution templates are literal syntax; parentheses remove that priority.
for kind, member, expression in [
    ('method', 'pick(value:{type}):{result}', 'get().pick({argument})'),
    ('call', '(value:{type}):{result}', 'get()({argument})'),
    ('construct', 'new(value:{type}):{result}', 'new (get())({argument})'),
]:
    for label, parameter, value in [('plain', '`ok`', 'ok'), ('parenthesized', '(`ok`)', 'ok'), ('escaped', '`a\\nb`', 'a\nb'), ('hex', '`\\x6f\\x6b`', 'ok'), ('latin1', '`\\xE9`', 'é'), ('unicode', '`\\u{1F600}`', '😀'), ('quoted-escaped', '"a\\nb"', 'a\nb')]:
        for matching in (False, True):
            call = expression.format(argument=json.dumps(value if matching else 'different'))
            files = {
                'first.d.ts': 'interface Payload{' + member.format(type=parameter, result='"special"') + '}',
                'second.d.ts': 'interface Payload{' + member.format(type='string', result='"ordinary"') + '}',
                'api.d.ts': 'declare module "api"{export function get():Payload;}',
                'main.ts': 'import {get} from "api";\nconst special:"special"=' + call + ';\nconst ordinary:"ordinary"=' + call + ';',
            }
            h['CASES'][f'global-template-origin-{kind}-{label}-{matching}'] = (files, [2322])


# Bare global and local references use checked interface merges.
for placement in ('global', 'local'):
    for mode, setup, expression in [
        ('direct', '', 'value.pick("ok")'),
        ('bracket', '', 'value["pick"]("ok")'),
        ('detached', 'const pick=value.pick;', 'pick("ok")'),
        ('detached-bracket', 'const pick=value["pick"];', 'pick("ok")'),
        ('indexed-type', 'declare const pick:Payload["pick"];', 'pick("ok")'),
    ]:
        for specialized in (False, True):
            first = 'interface Payload{pick(value:' + ('"ok"' if specialized else 'string') + '):"first"}'
            second = 'interface Payload{pick(value:' + ('string' if specialized else 'string|number') + '):"second"}'
            if placement == 'global':
                files = {'first.d.ts': first, 'second.d.ts': second, 'api.d.ts': 'declare module "api"{export function get():Payload;}'}
                prefix = 'import {get} from "api";'
            else:
                files = {}
                prefix = 'export {};' + first + second
            files['main.ts'] = prefix + 'declare const value:Payload;' + setup + '\nconst first:"first"=' + expression + ';\nconst second:"second"=' + expression + ';'
            h['CASES'][f'bare-method-order-{placement}-{mode}-{specialized}'] = (files, [2322])


# Re-importing an already merged owner must not duplicate or promote groups.
for mode, setup, expression in [
    ('direct', '', 'value.pick("ok")'),
    ('bracket', '', 'value["pick"]("ok")'),
    ('detached', 'const pick=value.pick;', 'pick("ok")'),
    ('indexed-type', 'declare const pick:Payload["pick"];', 'pick("ok")'),
]:
    files = {
        'first.d.ts': 'interface Base{pick(value:string):"first"|"second"|"third";base:number}interface Payload extends Base{pick(value:string):"first";field:string}',
        'second.d.ts': 'interface Payload{pick(value:string|number):"second"}',
        'third.d.ts': 'interface Payload{pick(value:unknown):"third"}',
        'main.ts': 'export {};declare const value:Payload;' + setup + '\nconst first:"first"=' + expression + ';\nconst third:"third"=' + expression + ';const base:number=value.base;const field:string=value.field;',
    }
    h['CASES'][f'checked-global-transitive-groups-{mode}'] = (files, [2322])

# Native controls for the iterator contracts exposed by global library merging.
iterator_cases={
'entries-literal':({'main.ts':'const value=Object.fromEntries([["a",1]]);const good:number=value.a;'},[]),
'entries-mapped':({'main.ts':'const source=[{key:"a",value:1}];const value=Object.fromEntries(source.map(x=>[x.key,x.value]));const good:number=value.a;'},[]),
'entries-tuple-array':({'main.ts':'declare const source:[string,number][];const value=Object.fromEntries(source);const good:number=value.a;'},[]),
'entries-iterable':({'main.ts':'declare const source:Iterable<readonly [string,number]>;const value=Object.fromEntries(source);const good:number=value.a;'},[]),
'entries-array-lookalike':({'main.ts':'declare const source:{[index:number]:[string,number];length:number};const value=Object.fromEntries(source);'},[2769]),
 'entries-tuple-array-negative':({'main.ts':'declare const source:[string,number][];const value=Object.fromEntries(source);const wrong:string=value.a;'},[2322]),
'entries-explicit-positive':({'main.ts':'const value=Object.fromEntries<number>([["a",1]]);const good:number=value.a;'},[]),
'entries-explicit-negative':({'main.ts':'const value=Object.fromEntries<number>([["a","wrong"]]);'},[2345]),
'entries-optional-result':({'main.ts':'interface Result{facets?:Record<string,Record<string,number>>}function use():Result{const source=[{key:"a",counts:[{value:"b",count:1}]}];const facets=Object.fromEntries(source.map(f=>[f.key,Object.fromEntries(f.counts.map(c=>[c.value,c.count]))]));return{facets:Object.keys(facets).length?facets:undefined};}'},[]),
}
iterator_cases.update({
'entries-literal-negative':({'main.ts':'const value=Object.fromEntries([["a",1]]);const wrong:string=value.a;'},[2322]),
'entries-explicit-spread-positive':({'main.ts':'declare const source:readonly (readonly [string,number])[];const value=Object.fromEntries<number>([...source]);const good:number=value.a;'},[]),
'entries-explicit-hole-negative':({'main.ts':'Object.fromEntries<number>([,]);'},[2345]),
'entries-iterable-extra-required-negative':({'main.ts':'interface Labeled extends Iterable<readonly [string,number]>{label:string}declare function use(value:Labeled):void;use([["a",1]]);'},[2741]),
'entries-explicit-key-negative':({'main.ts':'Object.fromEntries<number>([[{},1]]);'},[2345]),
'entries-mapped-const-negative':({'main.ts':'const value=Object.fromEntries([{key:"a",value:1}].map(x=>[x.key,x.value] as const));const wrong:string=value.a;'},[2322]),
})
iterator_cases['array-hole-inference'] = ({'main.ts': 'const holes=[,];const good:undefined=holes[0];const bad:number=holes[0];const mixed=[1,,];const optional:number|undefined=mixed[0];const wrong:number=mixed[0];'}, [2322,2322])
iterator_cases['callback-optional-slots'] = ({'main.ts': 'declare function match<T>(cb:(value:T)=>boolean):T;declare function foo(pos:{x?:number;y?:number}):boolean;foo({y:match(y=>y>0)});declare function foo2(point:[number?]):boolean;foo2([match(y=>y>0)]);'}, [18048, 18048])
iterator_cases['callback-overloaded-optional-slot'] = ({'main.ts': 'declare function match<T>(cb:(value:T)=>boolean):T;interface Use{(point:[number?]):boolean;(point:string):boolean}declare const use:Use;use([match(y=>y>0)]);'}, [18048])
iterator_cases['callback-rejected-callback-context'] = ({'main.ts': 'declare function match<T>(cb:(value:T)=>boolean):T;interface Use{(point:[number?],tag:"numeric"):boolean;(point:[string?],tag:"text"):boolean}declare const use:Use;use([match(y=>y.length>0)],"text");'}, [2339, 2769, 18048])
iterator_cases['nullable-number-missing'] = ({'main.ts': 'declare const value:number|undefined;value.length;'}, [2339, 18048])
iterator_cases['nullable-object-missing'] = ({'main.ts': 'declare const value:{size:number}|undefined;value.missing;'}, [2339, 18048])
iterator_cases['nullable-known-and-empty'] = ({'main.ts': 'declare const valid:{size:number}|undefined;valid.size;declare const empty:undefined;empty.size;'}, [18048, 18048])
iterator_cases['async-result-factory-positive'] = ({'main.ts': 'declare const input:AsyncIterable<number>;async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-factory-negative'] = ({'main.ts': 'declare const input:AsyncIterable<number>;async function use(){for await(const value of input){const wrong:string=value;}}'}, [2322])
iterator_cases['async-result-completed-without-value'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|{done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-malformed-yield'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|{done:false}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-plain-positive'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():{value:number;done:boolean}}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-plain-missing'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():{done:boolean}}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-completion-only'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-completed-other-value'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|{value:string;done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-optional-done-true'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-primitive-alternative'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|number>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-complete-value-only'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:string;done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-completed-union-only'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{done:true}|{value:string;done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-completed-union-missing-only'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{done:true}|{done:true;extra:number}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-done-general-missing'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|{done:boolean}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-promise-never'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<never>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-optional-value-yield'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value?:number;done?:false}|{done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2322])
iterator_cases['async-result-empty-and-complete'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{}|{done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [2547])
iterator_cases['async-result-malformed-yield-with-return'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{done:false}|{value:string;done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-completed-union-values'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:string;done:true}|{value:number;done:true}>}};async function use(){for await(const value of input){const good:number=value;}}'}, [])
iterator_cases['async-result-missing-yield-member'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{done:false}|{value:string;done:true}>}};async function use(){for await(const value of input){value.toFixed();}}'}, [])
iterator_cases['async-result-mixed-yield-missing-with-return'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:number;done?:false}|{done:false}|{value:string;done:true}>}};async function use(){for await(const value of input){value.toFixed();}}'}, [])
iterator_cases['async-result-primitive-yield-with-return'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<number|{value:string;done:true}>}};async function use(){for await(const value of input){value.toFixed();}}'}, [])
iterator_cases['async-result-complete-value-member'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:string;done:true}>}};async function use(){for await(const value of input){value.toFixed();}}'}, [])
iterator_cases['async-result-factory-never-member'] = ({'main.ts': 'declare const input:AsyncIterable<never>;async function use(){for await(const value of input){value.toFixed();}}'}, [2339])
iterator_cases['async-result-yield-never-member'] = ({'main.ts': 'declare const input:{[Symbol.asyncIterator]():{next():Promise<{value:never;done?:false}>}};async function use(){for await(const value of input){value.toFixed();}}'}, [2339])
for name, value in iterator_cases.items():
    h['CASES']['global-iterator-' + name] = value

def main():
    h['main']()

if __name__ == '__main__':
    main()
