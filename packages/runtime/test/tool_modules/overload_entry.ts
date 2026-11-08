import * as commands from './overload_exports.ts';
const factory = () => 42;
if (commands.defineCommand(factory) !== factory
  || commands.defineCommand({ value: 'actual' })() !== 'actual'
  || commands.defineCommand({ value: 7 })() !== 7
  || 'missing' in commands || 'ambient' in commands) {
  throw new Error('exported overload implementation or erasure changed');
}
console.log('OK actual exported overload bindings');
