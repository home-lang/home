// Genuine same-global Script evaluation. This is not a contextification,
// V8-code-cache, interrupt, diagnostic-excerpt or dynamic-import implementation.
globalThis.__home_tool_vm_factory = function(nativeScript) {
  'use strict';
  const keys = Reflect.ownKeys;
  function unsupported(option) {
    const error = new Error('Home vm.runInThisContext does not support ' + option);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function invalid(name) {
    const error = new TypeError('Invalid vm.runInThisContext ' + name);
    error.code = 'ERR_INVALID_ARG_TYPE';
    throw error;
  }
  function runInThisContext(code, options) {
    const source = `${code}`;
    if (options === undefined) options = {};
    else if (typeof options === 'string') options = {filename: options};
    else if (options === null || typeof options !== 'object') invalid('options');
    for (const key of keys(options)) {
      if (key !== 'filename' && key !== 'lineOffset' && key !== 'columnOffset' && key !== 'displayErrors') unsupported(typeof key === 'symbol' ? 'symbol options' : key);
    }
    // Also refuse inherited execution/cache options, rather than silently
    // accepting a timeout or loader that the native evaluator cannot enforce.
    for (const key of ['timeout', 'breakOnSigint', 'cachedData', 'produceCachedData', 'importModuleDynamically', 'microtaskMode', 'contextCodeGeneration']) {
      if (options[key] !== undefined) unsupported(key);
    }
    const filenameOption = options.filename;
    const filename = filenameOption === undefined ? 'evalmachine.<anonymous>' : filenameOption;
    if (typeof filename !== 'string') invalid('filename');
    for (const key of ['lineOffset', 'columnOffset']) {
      const value = options[key];
      if (value !== undefined && typeof value !== 'number') invalid(key);
      if (value !== undefined && value !== 0) unsupported(key);
    }
    const displayErrors = options.displayErrors;
    if (displayErrors !== undefined && typeof displayErrors !== 'boolean') invalid('displayErrors');
    // The default uses the host's genuine engine diagnostics. V8's optional
    // source-excerpt formatting is unavailable; jiti requests false explicitly.
    if (displayErrors === true) unsupported('displayErrors=true source excerpts');
    if (typeof nativeScript !== 'function') unsupported('missing native Script evaluator');
    return nativeScript(source, filename);
  }
  return {runInThisContext};
};
