#!/usr/bin/env python3
"""Compare import types, module queries, and dynamic imports against TypeScript.

Run under scripts/run-bounded.pl. --include-known-gaps also exercises ambient
Node parameter transfer that is still unqualified; its mismatch is intentional
as discovery evidence, and is never reported as a passing replacement gate.
"""
from pathlib import Path
import runpy
import sys

CASES = {'direct-import-type': ({'owner.ts': 'export interface Token{value:string}',
                         'main.ts': 'export {};declare const token:import("./owner").Token;const '
                                    'good:string=token.value;'},
                        []),
 'promise-import-type': ({'owner.ts': 'export interface Token{value:string}',
                          'main.ts': 'export class Guard{async get():Promise<import("./owner").Token>{return '
                                     '{value:"ok"};}}'},
                         []),
 'barrel-promise-import-type': ({'token.ts': 'export interface Token{value:string}',
                                 'owner.ts': 'export type {Token} from "./token";',
                                 'main.ts': 'export class Guard{async '
                                            'get():Promise<import("./owner").Token>{return {value:"ok"};}}'},
                                []),
 'promise-import-type-negative': ({'owner.ts': 'export interface Token{value:string}',
                                   'main.ts': 'export class Guard{async '
                                              'get():Promise<import("./owner").Token>{return {value:1};}}'},
                                  [2322]),
 'missing-import-type-export': ({'owner.ts': 'export interface Token{value:string}',
                                 'main.ts': 'export {};declare const token:import("./owner").Missing;'},
                                [2694]),
 'missing-import-type-module': ({'main.ts': 'export {};declare const token:import("./missing").Token;'},
                                [2307]),
 'dynamic-local-import': ({'owner.ts': 'export async function remove(path:string):Promise<void>{}',
                           'main.ts': 'export async function use(path:string):Promise<void>{const '
                                      '{remove}=await import("./owner");await remove(path);}'},
                          []),
 'dynamic-local-import-negative': ({'owner.ts': 'export async function remove(path:string):Promise<void>{}',
                                    'main.ts': 'export async function use():Promise<void>{const '
                                               '{remove}=await import("./owner");await remove(1);}'},
                                   [2345]),
 'bun-namespace-dynamic-node-import': ({'main.ts': 'export async function '
                                                   'use(path:string):Promise<void>{const {unlink}=await '
                                                   'import("node:fs/promises");await unlink(path);}'},
                                       []),
 'bun-namespace-static-node-import': ({'main.ts': 'import {unlink} from "node:fs/promises";export async '
                                                  'function use(path:string):Promise<void>{await '
                                                  'unlink(path);}'},
                                      []),
 'bun-namespace-missing-node-import': ({'main.ts': 'export async function use():Promise<void>{await '
                                                   'import("node:missing-home-control");}'},
                                       [2307]),
 'local-shadow-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                        'Box<T=string>{value:T}export interface Bound<T extends '
                                        'string>{value:T}export const value=1;export function '
                                        'take(value:string):string{return value;}export namespace '
                                        'Inner{export interface Token{value:string}}',
                            'main.ts': 'export {};interface Token{value:number}const '
                                       'bad:import("./owner").Token={value:1};'},
                           [2322]),
 'parameter-shadow-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                            'Box<T=string>{value:T}export interface Bound<T extends '
                                            'string>{value:T}export const value=1;export function '
                                            'take(value:string):string{return value;}export namespace '
                                            'Inner{export interface Token{value:string}}',
                                'main.ts': 'export function use<Token>():void{const '
                                           'bad:import("./owner").Token={value:1};}'},
                               [2322]),
 'primitive-shadow-negative': ({'owner.ts': 'interface X{value:string}export {X as string};',
                                'main.ts': 'export {};const bad:import("./owner").string=1;'},
                               [2322]),
 'generic-argument-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                            'Box<T=string>{value:T}export interface Bound<T extends '
                                            'string>{value:T}export const value=1;export function '
                                            'take(value:string):string{return value;}export namespace '
                                            'Inner{export interface Token{value:string}}',
                                'main.ts': 'export {};const '
                                           'bad:import("./owner").Box<number>={value:"bad"};'},
                               [2322]),
 'generic-default-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                           'Box<T=string>{value:T}export interface Bound<T extends '
                                           'string>{value:T}export const value=1;export function '
                                           'take(value:string):string{return value;}export namespace '
                                           'Inner{export interface Token{value:string}}',
                               'main.ts': 'export {};const bad:import("./owner").Box={value:1};'},
                              [2322]),
 'generic-constraint-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                              'Box<T=string>{value:T}export interface Bound<T extends '
                                              'string>{value:T}export const value=1;export function '
                                              'take(value:string):string{return value;}export namespace '
                                              'Inner{export interface Token{value:string}}',
                                  'main.ts': 'export {};declare const bad:import("./owner").Bound<number>;'},
                                 [2344]),
 'generic-arity-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                         'Box<T=string>{value:T}export interface Bound<T extends '
                                         'string>{value:T}export const value=1;export function '
                                         'take(value:string):string{return value;}export namespace '
                                         'Inner{export interface Token{value:string}}',
                             'main.ts': 'export {};declare const bad:import("./owner").Token<number>;'},
                            [2315]),
 'namespace-import-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                            'Box<T=string>{value:T}export interface Bound<T extends '
                                            'string>{value:T}export const value=1;export function '
                                            'take(value:string):string{return value;}export namespace '
                                            'Inner{export interface Token{value:string}}',
                                'main.ts': 'export {};const bad:import("./owner").Inner.Token={value:1};'},
                               [2322]),
 'namespace-import-missing': ({'owner.ts': 'export interface Token{value:string}export interface '
                                           'Box<T=string>{value:T}export interface Bound<T extends '
                                           'string>{value:T}export const value=1;export function '
                                           'take(value:string):string{return value;}export namespace '
                                           'Inner{export interface Token{value:string}}',
                               'main.ts': 'export {};declare const bad:import("./owner").Inner.Missing;'},
                              [2694]),
 'type-value-export-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                             'Box<T=string>{value:T}export interface Bound<T extends '
                                             'string>{value:T}export const value=1;export function '
                                             'take(value:string):string{return value;}export namespace '
                                             'Inner{export interface Token{value:string}}',
                                 'main.ts': 'export {};declare const bad:import("./owner").value;'},
                                [2694]),
 'script-module-negative': ({'owner.ts': 'interface Token{value:string}',
                             'main.ts': 'export {};declare const bad:import("./owner").Token;'},
                            [2306]),
 'typeof-module-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                         'Box<T=string>{value:T}export interface Bound<T extends '
                                         'string>{value:T}export const value=1;export function '
                                         'take(value:string):string{return value;}export namespace '
                                         'Inner{export interface Token{value:string}}',
                             'main.ts': 'export {};declare const module:typeof '
                                        'import("./owner");module.take(1);'},
                            [2345]),
 'typeof-member-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                         'Box<T=string>{value:T}export interface Bound<T extends '
                                         'string>{value:T}export const value=1;export function '
                                         'take(value:string):string{return value;}export namespace '
                                         'Inner{export interface Token{value:string}}',
                             'main.ts': 'export {};declare const take:typeof '
                                        'import("./owner").take;take(1);'},
                            [2345]),
 'typeof-missing-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                          'Box<T=string>{value:T}export interface Bound<T extends '
                                          'string>{value:T}export const value=1;export function '
                                          'take(value:string):string{return value;}export namespace '
                                          'Inner{export interface Token{value:string}}',
                              'main.ts': 'export {};declare const bad:typeof import("./owner").missing;'},
                             [2694]),
 'typeof-class-negative': ({'owner.ts': 'export interface Token{value:string}export class '
                                        'Guard{take(value:string):void{}}',
                            'main.ts': 'export {};const bad:import("./owner").Token={value:1};declare const '
                                       'klass:typeof import("./owner").Guard;new klass().take(1);'},
                           [2322, 2345]),
 'exported-interface-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                              'Box<T=string>{value:T}export interface Bound<T extends '
                                              'string>{value:T}export const value=1;export function '
                                              'take(value:string):string{return value;}export namespace '
                                              'Inner{export interface Token{value:string}}',
                                  'main.ts': 'import type {API} from "./api";declare const api:API;const '
                                             'bad:number=api.token.value;',
                                  'api.ts': 'export interface API{token:import("./owner").Token}'},
                                 [2322]),
 'exported-function-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                             'Box<T=string>{value:T}export interface Bound<T extends '
                                             'string>{value:T}export const value=1;export function '
                                             'take(value:string):string{return value;}export namespace '
                                             'Inner{export interface Token{value:string}}',
                                 'main.ts': 'import {get} from "./api";const bad:number=get().value;',
                                 'api.ts': 'export function get():import("./owner").Token{return '
                                           '{value:"ok"};}'},
                                [2322]),
 'exported-generic-interface-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                                      'Box<T=string>{value:T}export interface Bound<T '
                                                      'extends string>{value:T}export const value=1;export '
                                                      'function take(value:string):string{return '
                                                      'value;}export namespace Inner{export interface '
                                                      'Token{value:string}}',
                                          'main.ts': 'import type {API} from "./api";declare const '
                                                     'api:API;const bad:number=api.token.value;',
                                          'api.ts': 'export interface '
                                                    'API{token:import("./owner").Box<string>}'},
                                         [2322]),
 'dynamic-namespace-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                             'Box<T=string>{value:T}export interface Bound<T extends '
                                             'string>{value:T}export const value=1;export function '
                                             'take(value:string):string{return value;}export namespace '
                                             'Inner{export interface Token{value:string}}',
                                 'main.ts': 'export async function use():Promise<void>{const module=await '
                                            'import("./owner");module.take(1);}'},
                                [2345]),
 'dynamic-template-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                            'Box<T=string>{value:T}export interface Bound<T extends '
                                            'string>{value:T}export const value=1;export function '
                                            'take(value:string):string{return value;}export namespace '
                                            'Inner{export interface Token{value:string}}',
                                'main.ts': 'export async function use():Promise<void>{const {take}=await '
                                           'import(`./owner`);take(1);}'},
                               [2345]),
 'dynamic-missing': ({'owner.ts': 'export interface Token{value:string}export interface '
                                  'Box<T=string>{value:T}export interface Bound<T extends '
                                  'string>{value:T}export const value=1;export function '
                                  'take(value:string):string{return value;}export namespace Inner{export '
                                  'interface Token{value:string}}',
                      'main.ts': 'export async function use():Promise<void>{await import("./missing");}'},
                     [2307]),
 'dynamic-attributes-negative': ({'owner.ts': 'export interface Token{value:string}export interface '
                                              'Box<T=string>{value:T}export interface Bound<T extends '
                                              'string>{value:T}export const value=1;export function '
                                              'take(value:string):string{return value;}export namespace '
                                              'Inner{export interface Token{value:string}}',
                                  'main.ts': 'export async function use():Promise<void>{const {take}=await '
                                             'import("./owner",{with:{type:"json"}});take(1);}'},
                                 [2345])}

KNOWN_GAPS = {'bun-namespace-dynamic-unlink-negative': ({'main.ts': 'export async function use():Promise<void>{const '
                                                       '{unlink}=await import("node:fs/promises");await '
                                                       'unlink(1);}'},
                                           [2345])}

if __name__ == '__main__':
    if '--include-known-gaps' in sys.argv and '--bun-node-modules' not in sys.argv:
        raise SystemExit('--include-known-gaps requires --bun-node-modules')
    if '--bun-node-modules' not in sys.argv:
        CASES = {name: case for name, case in CASES.items() if not name.startswith('bun-namespace')}
    if '--include-known-gaps' in sys.argv:
        sys.argv.remove('--include-known-gaps')
        CASES.update(KNOWN_GAPS)
    shared = runpy.run_path(str(Path(__file__).with_name('test-ts-polymorphic-this-cli.py')))
    shared['CASES'].clear()
    shared['CASES'].update(CASES)
    shared['main']()
