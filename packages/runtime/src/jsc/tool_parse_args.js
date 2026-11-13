// Node util.parseArgs: tokenize argv, validate declared types, then apply defaults.
// https://nodejs.org/api/util.html#utilparseargsconfig
// This parses arguments only; it never registers, runs or passes consumer tests.
globalThis.__home_tool_parse_args_factory = function(Process) {
  'use strict';
  const create = Object.create;
  const keys = Object.keys;
  const own = Function.call.bind(Object.prototype.hasOwnProperty);
  const isArray = Array.isArray;
  function fail(code, message) {
    const error = new TypeError(message);
    error.code = code;
    throw error;
  }
  function object(value, name) {
    if (value === null || typeof value !== 'object' || isArray(value)) fail('ERR_INVALID_ARG_TYPE', `${name} must be an object`);
  }
  function boolean(value, name) {
    if (typeof value !== 'boolean') fail('ERR_INVALID_ARG_TYPE', `${name} must be a boolean`);
  }
  function parseArgs(config = {}) {
    const args = config.args ?? Process.argv.slice(2);
    const options = config.options ?? {};
    const strict = config.strict ?? true, allowPositionals = config.allowPositionals ?? !strict;
    const allowNegative = config.allowNegative ?? false, wantTokens = config.tokens ?? false;
    if (!isArray(args)) fail('ERR_INVALID_ARG_TYPE', 'args must be an array');
    boolean(strict, 'strict');
    boolean(allowPositionals, 'allowPositionals');
    boolean(allowNegative, 'allowNegative');
    boolean(wantTokens, 'tokens');
    object(options, 'options');
    const definitions = create(null), aliases = create(null);
    const names = keys(options);
    for (const name of names) {
      const option = options[name];
      object(option, `options.${name}`);
      const {type, short, multiple = false, default: fallback} = option;
      if (type !== 'boolean' && type !== 'string') fail('ERR_INVALID_ARG_TYPE', `options.${name}.type must be boolean or string`);
      boolean(multiple, `options.${name}.multiple`);
      if (short !== undefined) {
        if (typeof short !== 'string') fail('ERR_INVALID_ARG_TYPE', `options.${name}.short must be a string`);
        if (short.length !== 1) fail('ERR_INVALID_ARG_VALUE', `options.${name}.short must be a single character`);
        if (!own(aliases, short)) aliases[short] = name;
      }
      if (fallback !== undefined) {
        if (multiple) {
          if (!isArray(fallback)) fail('ERR_INVALID_ARG_TYPE', `options.${name}.default must be an array`);
          for (let i = 0; i < fallback.length; i++) if (typeof fallback[i] !== type) fail('ERR_INVALID_ARG_TYPE', `options.${name}.default has an invalid value`);
        } else if (typeof fallback !== type) fail('ERR_INVALID_ARG_TYPE', `options.${name}.default has an invalid type`);
      }
      definitions[name] = {type, multiple, fallback};
    }
    const values = create(null), positionals = [], tokens = [];
    function positional(value, index) {
      if (!allowPositionals) fail('ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL', `Unexpected argument '${value}'`);
      positionals.push(value);
      tokens.push({kind: 'positional', index, value});
    }
    function option(name, rawName, index, value, inlineValue) {
      const base = allowNegative && name.startsWith('no-') ? name.slice(3) : undefined;
      const checkName = base !== undefined && own(definitions, base) && definitions[base].type === 'boolean' ? base : name;
      let definition = own(definitions, checkName) ? definitions[checkName] : undefined;
      if (strict) {
        if (!definition) fail('ERR_PARSE_ARGS_UNKNOWN_OPTION', `Unknown option '${rawName}'`);
        if (definition.type === 'string' && value === undefined) fail('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', `Option '${rawName}' requires an argument`);
        if (definition.type === 'boolean' && value !== undefined) fail('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', `Option '${rawName}' does not take an argument`);
        if (definition.type === 'string' && !inlineValue && value.length > 1 && value[0] === '-') fail('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', `Option '${rawName}' argument is ambiguous`);
      }
      const negative = base !== undefined && value === undefined;
      if (negative) name = base;
      definition = own(definitions, name) ? definitions[name] : undefined;
      const parsed = value === undefined ? !negative : value;
      // Node excludes __proto__ from values, while retaining its token.
      if (name === '__proto__') { /* deliberately not a value property */ }
      else if (definition && definition.multiple) {
        if (!own(values, name)) values[name] = [];
        values[name].push(parsed);
      } else values[name] = parsed;
      tokens.push({kind: 'option', name, rawName, index, value, inlineValue});
    }
    let ended = false;
    for (let index = 0; index < args.length; index++) {
      const arg = args[index];
      if (ended) { positional(arg, index); continue; }
      if (arg === '--') { tokens.push({kind: 'option-terminator', index}); ended = true; continue; }
      if (arg.length < 2 || arg[0] !== '-') { positional(arg, index); continue; }
      if (arg.startsWith('--')) {
        const equal = arg.indexOf('=', 3);
        const name = equal === -1 ? arg.slice(2) : arg.slice(2, equal);
        const rawName = equal === -1 ? arg : arg.slice(0, equal);
        let value, inlineValue;
        if (equal !== -1) { value = arg.slice(equal + 1); inlineValue = true; }
        else if (own(definitions, name) && definitions[name].type === 'string' && index + 1 < args.length) { value = args[index + 1]; inlineValue = false; }
        const tokenIndex = index;
        if (inlineValue === false) index++;
        option(name, rawName, tokenIndex, value, inlineValue);
      } else {
        const tokenIndex = index;
        for (let offset = 1; offset < arg.length; offset++) {
          const short = arg[offset], name = own(aliases, short) ? aliases[short] : short;
          let value, inlineValue;
          if (own(definitions, name) && definitions[name].type === 'string') {
            if (offset + 1 < arg.length) { value = arg.slice(offset + 1); inlineValue = true; }
            else if (index + 1 < args.length) { value = args[++index]; inlineValue = false; }
            option(name, '-' + short, tokenIndex, value, inlineValue);
            break;
          }
          option(name, '-' + short, tokenIndex, value, inlineValue);
        }
      }
    }
    // Defaults apply after parsing and only for options absent from argv. This
    // preserves explicit false/empty values and never mutates default arrays.
    for (const name of names) if (name !== '__proto__' && !own(values, name) && definitions[name].fallback !== undefined) values[name] = definitions[name].fallback;
    return wantTokens ? {values, positionals, tokens} : {values, positionals};
  }
  return parseArgs;
};
