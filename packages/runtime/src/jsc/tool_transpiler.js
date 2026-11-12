// Home's real TypeScript parser/emitter, without module loading or evaluation.
// https://bun.sh/docs/runtime/transpiler#transformsync
(function() {
  'use strict';
  const transform = globalThis.__home_tool_transform_ts;
  delete globalThis.__home_tool_transform_ts;
  const instances = new WeakSet();
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    return error;
  }
  function loader(value) {
    if (value !== 'ts') throw unsupported('Home Transpiler currently supports only the explicit ts loader');
  }
  class Transpiler {
    constructor(options) {
      if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Transpiler requires an options object');
      for (const key of Reflect.ownKeys(options)) {
        if (key !== 'loader') throw unsupported(`Home Transpiler option ${String(key)} is not implemented`);
      }
      loader(options.loader);
      instances.add(this);
    }

    transformSync(source, override) {
      if (!instances.has(this)) throw new TypeError('Invalid Transpiler receiver');
      if (arguments.length > 2) throw unsupported('Home Transpiler macro/context arguments are not implemented');
      if (override !== undefined) loader(override);
      if (typeof source !== 'string') throw new TypeError('Home Transpiler source must be a string');
      const result = transform(source);
      if (result && typeof result.syntax === 'string') throw new SyntaxError(result.syntax);
      if (!result || typeof result.source !== 'string') {
        const error = new Error(`Home TypeScript transform failed: ${result && result.error || 'native result unavailable'}`);
        error.code = 'ERR_HOME_TRANSPILE';
        throw error;
      }
      return result.source;
    }
  }
  globalThis.Bun.Transpiler = Transpiler;
})();
