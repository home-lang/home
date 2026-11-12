// Real process warning delivery: preserve Error payloads, queue the event, and
// keep a removable default stderr listener alongside user warning listeners.
(function(p) {
  'use strict';
  const NativeError = Error;
  const NativeTypeError = TypeError;
  const isArray = Array.isArray;
  const capture = NativeError.captureStackTrace;
  function invalid(name) {
    const error = new NativeTypeError('Invalid process.emitWarning ' + name);
    error.code = 'ERR_INVALID_ARG_TYPE';
    throw error;
  }
  p.on('warning', function(warning) {
    const name = String(warning.name || 'Warning');
    const prefix = '(home:' + p.pid + ') ' + (warning.code === undefined ? '' : '[' + String(warning.code) + '] ');
    const trace = p.traceProcessWarnings || (name === 'DeprecationWarning' && p.traceDeprecation);
    const message = String(warning.message);
    const header = name + ': ' + message;
    let text = header;
    if (trace && warning.stack) {
      const stack = String(warning.stack);
      const newline = stack.indexOf('\n');
      const first = newline < 0 ? stack : stack.slice(0, newline);
      // Providers may cache "Error" before the warning name is assigned, or
      // omit a header entirely. Format the real warning fields and retain the
      // actual native frames, without manufacturing constructor-frame pruning.
      const frames = first === header || first === 'Error: ' + message ? (newline < 0 ? '' : stack.slice(newline + 1)) : stack;
      if (frames) text += '\n' + frames;
    }
    p.stderr.write(prefix + text + '\n');
    if (warning.detail !== undefined) p.stderr.write(String(warning.detail) + '\n');
  });
  p.emitWarning = function(warning, type, code, ctor) {
    if (p.noDeprecation && type === 'DeprecationWarning') return;
    let detail;
    if (type !== null && typeof type === 'object' && !isArray(type)) {
      const options = type;
      ctor = options.ctor;
      code = options.code;
      if (typeof options.detail === 'string') detail = options.detail;
      type = options.type || 'Warning';
    }
    else if (typeof type === 'function') {
      ctor = type;
      code = undefined;
      type = 'Warning';
    }
    if (type !== undefined && typeof type !== 'string') invalid('type');
    if (typeof code === 'function') {
      ctor = code;
      code = undefined;
    }
    else if (code !== undefined && typeof code !== 'string') invalid('code');
    if (typeof warning === 'string') {
      warning = new NativeError(warning);
      warning.name = type || 'Warning';
      if (code !== undefined) warning.code = code;
      if (detail !== undefined) warning.detail = detail;
      // Use the provider's real stack facility. Basic JSC retains its native
      // frames; it does not fabricate V8 constructor-frame pruning.
      if (typeof capture === 'function') capture(warning, ctor || p.emitWarning);
    }
    else if (!(warning instanceof NativeError)) invalid('warning');
    if (warning.name === 'DeprecationWarning') {
      if (p.noDeprecation) return;
      if (p.throwDeprecation) {
        p.nextTick(function() { throw warning; });
        return;
      }
    }
    p.nextTick(function() { p.emit('warning', warning); });
  };
})(globalThis.process);
