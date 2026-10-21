#!/usr/bin/env python3
"""Compare scoped ambient-module ownership and imported constructors with tsc.

Run under scripts/run-bounded.pl. --include-known-gaps retains the historical
cross-file global controls also covered by test-ts-global-owner-cli.py.
"""
from pathlib import Path
import runpy
import sys

CASES = {'ambient-local-negative': ({'types.d.ts': 'declare module "api"{type Path=string;export function '
                                           'take(path:Path):void;}',
                             'main.ts': 'import {take} from "api";take(1);'},
                            [2345]),
 'ambient-import-negative': ({'types.d.ts': 'declare module "owner"{export type '
                                            'Path=string;}declare module "api"{import type {Path} '
                                            'from "owner";export function take(path:Path):void;}',
                              'main.ts': 'import {take} from "api";take(1);'},
                             [2345]),
 'ambient-import-positive': ({'types.d.ts': 'declare module "owner"{export type '
                                            'Path=string;}declare module "api"{import type {Path} '
                                            'from "owner";export function take(path:Path):void;}',
                              'main.ts': 'import {take} from "api";take("ok");'},
                             []),
 'ambient-sibling-import-negative': ({'types.d.ts': 'declare module "left"{export type '
                                                    'Path=string;}declare module "right"{export '
                                                    'type Path=number;}declare module '
                                                    '"api-left"{import type {Path} from '
                                                    '"left";export function '
                                                    'take(path:Path):void;}declare module '
                                                    '"api-right"{import type {Path} from '
                                                    '"right";export function '
                                                    'take(path:Path):void;}',
                                      'main.ts': 'import {take as left} from "api-left";import '
                                                 '{take as right} from '
                                                 '"api-right";left(1);right("bad");'},
                                     [2345, 2345]),
 'ambient-sibling-import-positive': ({'types.d.ts': 'declare module "left"{export type '
                                                    'Path=string;}declare module "right"{export '
                                                    'type Path=number;}declare module '
                                                    '"api-left"{import type {Path} from '
                                                    '"left";export function '
                                                    'take(path:Path):void;}declare module '
                                                    '"api-right"{import type {Path} from '
                                                    '"right";export function '
                                                    'take(path:Path):void;}',
                                      'main.ts': 'import {take as left} from "api-left";import '
                                                 '{take as right} from '
                                                 '"api-right";left("ok");right(1);'},
                                     []),
 'ambient-import-dynamic-negative': ({'types.d.ts': 'declare module "owner"{export type '
                                                    'Path=string;}declare module "api"{import type '
                                                    '{Path} from "owner";export function '
                                                    'take(path:Path):void;}',
                                      'main.ts': 'export async function use():Promise<void>{const '
                                                 '{take}=await import("api");take(1);}'},
                                     [2345]),
 'ambient-global-negative': ({'types.d.ts': 'interface Path{value:string}declare module '
                                            '"api"{export function take(path:Path):void;}',
                              'main.ts': 'import {take} from "api";take(1);'},
                             [2345]),
 'ambient-global-positive': ({'types.d.ts': 'interface Path{value:string}declare module '
                                            '"api"{export function take(path:Path):void;}',
                              'main.ts': 'import {take} from "api";take({value:"ok"});'},
                             []),
 'ambient-import-type-negative': ({'types.d.ts': 'declare module "owner"{export type '
                                                 'Path={value:string};}declare module "api"{export '
                                                 'function take(path:import("owner").Path):void;}',
                                   'main.ts': 'import {take} from "api";take({value:1});'},
                                  [2322]),
 'ambient-namespace-import-negative': ({'types.d.ts': 'declare module "owner"{export interface '
                                                      'Path{value:string}}declare module '
                                                      '"api"{import type * as Owner from '
                                                      '"owner";export function '
                                                      'take(path:Owner.Path):void;}',
                                        'main.ts': 'import {take} from "api";take({value:1});'},
                                       [2322]),
 'ambient-export-list-hidden': ({'types.d.ts': 'declare module "owner"{type Hidden=string;type '
                                               'Visible=number;export {Visible};}',
                                 'main.ts': 'import type {Hidden} from "owner";export {};'},
                                [2459]),
 'ambient-export-list-visible': ({'types.d.ts': 'declare module "owner"{type Hidden=string;type '
                                                'Visible=number;export {Visible};}',
                                  'main.ts': 'import type {Visible} from "owner";const '
                                             'value:Visible=1;'},
                                 []),
 'ambient-implicit-with-exported-member': ({'types.d.ts': 'declare module "owner"{type '
                                                          'Hidden=string;export interface '
                                                          'Visible{value:number}}',
                                            'main.ts': 'import type {Hidden} from "owner";const '
                                                       'value:Hidden="ok";'},
                                           []),
 'ambient-reexport-negative': ({'types.d.ts': 'declare module "leaf"{export type '
                                              'Path=string;}declare module "owner"{export type '
                                              '{Path} from "leaf";}declare module "api"{import '
                                              'type {Path} from "owner";export function '
                                              'take(path:Path):void;}',
                                'main.ts': 'import {take} from "api";take(1);'},
                               [2345]),
 'ambient-missing-export': ({'types.d.ts': 'declare module "owner"{export type Visible=string;}',
                             'main.ts': 'import type {Missing} from "owner";export {};'},
                            [2305]),
 'ambient-empty-module': ({'types.d.ts': 'declare module "owner"{}',
                           'main.ts': 'import {missing} from "owner";export {};'},
                          [2305]),
 'ambient-local-renamed-import': ({'types.d.ts': 'declare module "owner"{type Hidden=string;export '
                                                 '{Hidden as Visible};}',
                                   'main.ts': 'import type {Hidden} from "owner";export {};'},
                                  [2460]),
 'ambient-default-local-import': ({'types.d.ts': 'declare module "owner"{export default function '
                                                 'take(path:string):void;}',
                                   'main.ts': 'import {take} from "owner";export {};'},
                                  [2614]),
 'ambient-private-function': ({'types.d.ts': 'declare module "owner"{function '
                                             'take(path:string):void;export {};}',
                               'main.ts': 'import {take} from "owner";export {};'},
                              [2459]),
 'ambient-overload-positive': ({'types.d.ts': 'declare module "owner"{export function '
                                              'take(path:string):string;export function '
                                              'take(path:number):number;}',
                                'main.ts': 'import {take} from "owner";const '
                                           'numberResult:number=take(1);const '
                                           'stringResult:string=take("ok");'},
                               []),
 'ambient-overload-negative': ({'types.d.ts': 'declare module "owner"{export function '
                                              'take(path:string):string;export function '
                                              'take(path:number):number;}',
                                'main.ts': 'import {take} from "owner";take(true);'},
                               [2769]),
 'ambient-erased-value-type-query': ({'types.d.ts': 'declare module "owner"{function '
                                                    'take(path:string):void;export type {take};}',
                                      'main.ts': 'export {};declare const take:typeof '
                                                 'import("owner").take;take(1);'},
                                     [2345]),
 'ambient-erased-value-dynamic': ({'types.d.ts': 'declare module "owner"{function '
                                                 'take(path:string):void;export type {take};}',
                                   'main.ts': 'export async function use():Promise<void>{const '
                                              'module=await import("owner");module.take("ok");}'},
                                  [2339]),
 'ambient-class-alias-negative': ({'types.d.ts': 'declare module "leaf"{export class '
                                                 'Item{constructor(path:string);value:string;}}declare '
                                                 'module "owner"{export {Item as Alias} from '
                                                 '"leaf";}',
                                   'main.ts': 'import {Alias} from "owner";const item=new '
                                              'Alias(1);'},
                                  [2345]),
 'ambient-class-alias-positive': ({'types.d.ts': 'declare module "leaf"{export class '
                                                 'Item{constructor(path:string);value:string;}}declare '
                                                 'module "owner"{export {Item as Alias} from '
                                                 '"leaf";}',
                                   'main.ts': 'import {Alias} from "owner";const item=new '
                                              'Alias("ok");const value:string=item.value;declare '
                                              'const other:Alias;const text:string=other.value;'},
                                  []),
 'ambient-export-equals-property': ({'types.d.ts': 'declare module "owner"{namespace Tool{function '
                                                   'take(path:string):void;}export=Tool;}',
                                     'main.ts': 'import {take} from "owner";take("ok");'},
                                    []),
 'ambient-class-alias-arity': ({'types.d.ts': 'declare module "leaf"{export class '
                                              'Item{constructor(path:string);value:string;}}declare '
                                              'module "owner"{export {Item as Alias} from "leaf";}',
                                'main.ts': 'import {Alias} from "owner";new Alias();'},
                               [2554]),
 'ambient-class-dynamic-negative': ({'types.d.ts': 'declare module "leaf"{export class '
                                                   'Item{constructor(path:string);value:string;}}declare '
                                                   'module "owner"{export {Item as Alias} from '
                                                   '"leaf";}',
                                     'main.ts': 'export async function use():Promise<void>{const '
                                                '{Alias}=await import("owner");new Alias(1);}'},
                                    [2345]),
 'ambient-class-query-negative': ({'types.d.ts': 'declare module "leaf"{export class '
                                                 'Item{constructor(path:string);value:string;}}declare '
                                                 'module "owner"{export {Item as Alias} from '
                                                 '"leaf";}',
                                   'main.ts': 'export {};declare const Alias:typeof '
                                              'import("owner").Alias;new Alias(1);'},
                                  [2345]),
 'ambient-class-optional-positive': ({'types.d.ts': 'declare module "owner"{export class '
                                                    'Item{constructor(path?:string);}}',
                                      'main.ts': 'import {Item} from "owner";new Item();new '
                                                 'Item("ok");'},
                                     []),
 'ambient-class-optional-negative': ({'types.d.ts': 'declare module "owner"{export class '
                                                    'Item{constructor(path?:string);}}',
                                      'main.ts': 'import {Item} from "owner";new Item(1);'},
                                     [2345]),
 'ambient-class-rest-positive': ({'types.d.ts': 'declare module "owner"{export class '
                                                'Item{constructor(...paths:string[]);}}',
                                  'main.ts': 'import {Item} from "owner";new Item();new '
                                             'Item("a","b");'},
                                 []),
 'ambient-class-rest-negative': ({'types.d.ts': 'declare module "owner"{export class '
                                                'Item{constructor(...paths:string[]);}}',
                                  'main.ts': 'import {Item} from "owner";new Item("a",1);'},
                                 [2345]),
 'ambient-class-overload-positive': ({'types.d.ts': 'declare module "owner"{export class '
                                                    'Item{constructor(path:string);constructor(path:number);}}',
                                      'main.ts': 'import {Item} from "owner";new Item("ok");new '
                                                 'Item(1);'},
                                     []),
 'ambient-class-overload-negative': ({'types.d.ts': 'declare module "owner"{export class '
                                                    'Item{constructor(path:string);constructor(path:number);}}',
                                      'main.ts': 'import {Item} from "owner";new Item(true);'},
                                     [2769]),
 'ambient-class-generic-positive': ({'types.d.ts': 'declare module "owner"{export class '
                                                   'Item<T>{constructor(value:T);value:T;}}',
                                     'main.ts': 'import {Item} from "owner";const item=new '
                                                'Item<string>("ok");const '
                                                'value:string=item.value;'},
                                    []),
 'ambient-class-generic-negative': ({'types.d.ts': 'declare module "owner"{export class '
                                                   'Item<T>{constructor(value:T);value:T;}}',
                                     'main.ts': 'import {Item} from "owner";new Item<string>(1);'},
                                    [2345]),
 'ambient-class-implicit-arity': ({'types.d.ts': 'declare module "owner"{export class '
                                                 'Item{value:string;}}',
                                   'main.ts': 'import {Item} from "owner";new Item(1);'},
                                  [2554]),
 'file-class-constructor-negative': ({'owner.ts': 'export class '
                                                  'Item{value:string;constructor(path:string){this.value=path;}}',
                                      'main.ts': 'import {Item} from "./owner";new Item(1);'},
                                     [2345]),
 'file-class-constructor-positive': ({'owner.ts': 'export class '
                                                  'Item{value:string;constructor(path:string){this.value=path;}}',
                                      'main.ts': 'import {Item} from "./owner";const '
                                                 'value:string=new Item("ok").value;'},
                                     [])}

CASES.update({
    'ambient-class-private-constructor': ({'types.d.ts': 'declare module "owner"{export class Item{private constructor(path:string);}}', 'main.ts': 'import {Item} from "owner";new Item("ok");'}, [2673]),
    'ambient-class-protected-constructor': ({'types.d.ts': 'declare module "owner"{export class Item{protected constructor(path:string);}}', 'main.ts': 'import {Item} from "owner";new Item("ok");'}, [2674]),
    'ambient-class-abstract-constructor': ({'types.d.ts': 'declare module "owner"{export abstract class Item{constructor(path:string);}}', 'main.ts': 'import {Item} from "owner";new Item("ok");'}, [2511]),
    'ambient-class-constrained-constructor': ({'types.d.ts': 'declare module "owner"{export class Item<T extends string>{constructor(value:T);value:T;}}', 'main.ts': 'import {Item} from "owner";new Item<number>(1);'}, [2344]),
    'ambient-class-inferred-constructor': ({'types.d.ts': 'declare module "owner"{export class Item<T>{constructor(value:T);value:T;}}', 'main.ts': 'import {Item} from "owner";const value:string=new Item("ok").value;'}, []),
})

CASES.update({
    'ambient-class-private-dynamic': ({'types.d.ts': 'declare module "owner"{export class Item{private constructor(path:string);}}', 'main.ts': 'export async function use():Promise<void>{const {Item}=await import("owner");new Item("ok");}'}, [2673]),
    'ambient-class-private-query': ({'types.d.ts': 'declare module "owner"{export class Item{private constructor(path:string);}}', 'main.ts': 'export {};declare const Item:typeof import("owner").Item;new Item("ok");'}, [2673]),
    'ambient-class-protected-subclass': ({'types.d.ts': 'declare module "owner"{export class Item{protected constructor(path:string);}}', 'main.ts': 'import {Item} from "owner";class Child extends Item{static create():Item{return new Item("ok");}}'}, []),
})

CASES.update({
    'ambient-class-same-shape-access': ({'types.d.ts': 'declare module "owner"{export class Private{private constructor(path:string);}export class Public{constructor(path:string);}}', 'main.ts': 'import {Private,Public} from "owner";new Public("ok");new Private("bad");'}, [2673]),
    'ambient-class-owner-name-shadow': ({'types.d.ts': 'declare module "owner"{export class Item{private constructor();}}', 'main.ts': 'import {Item as Foreign} from "owner";class Item{constructor(){new Foreign();}}'}, [2673]),
})

CASES.update({
    'verbatim-ambient-class-reexport': ({'types.d.ts': 'declare module "owner"{export class Item{value:string;}}', 'main.ts': 'import {Item} from "owner";export {Item};'}, []),
    'verbatim-ambient-type-reexport': ({'types.d.ts': 'declare module "owner"{export interface Item{value:string;}}', 'main.ts': 'import type {Item} from "owner";export type {Item};'}, []),
    'verbatim-local-interface-reexport-negative': ({'main.ts': 'export {};interface Item{value:string;}export {Item};'}, [1205]),
    'ambient-global-value-export': ({'types.d.ts': 'declare module "owner"{global{var Item:string;}export {Item};}', 'main.ts': 'import {Item} from "owner";void Item;'}, []),
    'ambient-unresolved-local-alias': ({'types.d.ts': 'declare module "owner"{export {Unknown};}', 'main.ts': 'import {Unknown} from "owner";void Unknown;'}, []),
    'ambient-inherited-default-constructor': ({'types.d.ts': 'declare module "owner"{export class Base<T={value:string}>{constructor(config:T);protected config:T;}}', 'main.ts': 'import {Base} from "owner";class Derived extends Base{}new Derived({value:"ok"});'}, []),
    'ambient-inherited-default-constructor-negative': ({'types.d.ts': 'declare module "owner"{export class Base<T={value:string}>{constructor(config:T);protected config:T;}}', 'main.ts': 'import {Base} from "owner";class Derived extends Base{}new Derived(1);'}, [2345]),
})

CASES.update({
    'ambient-unresolved-alias-missing-export': ({'types.d.ts': 'declare module "owner"{export {Unknown};}', 'main.ts': 'import {Missing} from "owner";void Missing;'}, [2305]),
    'verbatim-erased-class-import': ({'types.d.ts': 'declare module "leaf"{export class Item{}}declare module "owner"{export type {Item} from "leaf";}', 'main.ts': 'import {Item} from "owner";export type {Item};'}, [1485]),
    'verbatim-erased-function-import': ({'types.d.ts': 'declare module "owner"{function take(path:string):void;export type {take};}', 'main.ts': 'import {take} from "owner";export type {take};'}, [1485]),
    'verbatim-erased-interface-import': ({'types.d.ts': 'declare module "leaf"{export interface Item{}}declare module "owner"{export type {Item} from "leaf";}', 'main.ts': 'import {Item} from "owner";export type {Item};'}, [1484]),
})

KNOWN_GAPS = {'ambient-global-other-owner-negative': ({'global.d.ts': 'interface Path{value:string}',
                                          'types.d.ts': 'declare module "api"{export function '
                                                        'take(path:Path):void;}',
                                          'main.ts': 'import {take} from "api";take(1);'},
                                         [2345]),
 'ambient-global-other-owner-positive': ({'global.d.ts': 'interface Path{value:string}',
                                          'types.d.ts': 'declare module "api"{export function '
                                                        'take(path:Path):void;}',
                                          'main.ts': 'import {take} from '
                                                     '"api";take({value:"ok"});'},
                                         []),
 'ambient-global-merged-negative': ({'first.d.ts': 'interface Path{left:string}',
                                     'second.d.ts': 'interface Path{right:number}',
                                     'types.d.ts': 'declare module "api"{export function '
                                                   'take(path:Path):void;}',
                                     'main.ts': 'import {take} from "api";take({left:"ok"});'},
                                    [2741])}

def main():
    cases = dict(CASES)
    if '--include-known-gaps' in sys.argv:
        sys.argv.remove('--include-known-gaps')
        cases.update(KNOWN_GAPS)
    harness = runpy.run_path(str(Path(__file__).with_name('test-ts-polymorphic-this-cli.py')))
    harness['CASES'].clear()
    harness['CASES'].update(cases)
    harness['main']()

if __name__ == '__main__':
    main()
