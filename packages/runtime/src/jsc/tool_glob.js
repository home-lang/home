(function() {
  globalThis.__home_tool_glob_factory = function(native) {
    const patterns = new WeakMap();
    function patternFor(receiver) {
      if (!patterns.has(receiver)) throw new TypeError('Invalid Glob receiver');
      return patterns.get(receiver);
    }
    function request(...args) {
      const result = native(...args);
      if (!result || result.error) {
        const error = new Error('Glob: ' + (result && (result.detail || result.error) || 'native operation failed'));
        error.code = result && result.error || 'ERR_HOME_GLOB';
        throw error;
      }
      return result;
    }
    function optionsFor(options) {
      if (options === undefined || options === null) options = {};
      if (typeof options === 'string') options = { cwd: options };
      if (typeof options !== 'object') throw new TypeError('Glob options must be an object or cwd string');
      const result = { cwd: process.cwd(), dot: false, absolute: false, onlyFiles: true };
      for (const key of Object.keys(options)) {
        if (!['cwd', 'dot', 'absolute', 'onlyFiles', 'followSymlinks', 'throwErrorOnBrokenSymlink'].includes(key)) {
          const error = new Error(`Unsupported Glob option: ${key}`);
          error.code = 'ERR_HOME_UNSUPPORTED_GLOB';
          throw error;
        }
        const value = options[key];
        if (value === undefined) continue;
        if (key === 'cwd') {
          if (typeof value !== 'string' || value.includes('\0')) throw new TypeError('Glob cwd must be a string without NUL');
          result.cwd = value || process.cwd();
        }
        else {
          if (typeof value !== 'boolean') throw new TypeError(`Glob option ${key} must be boolean`);
          if (key === 'followSymlinks' && value) {
            const error = new Error('Glob symlink traversal is not implemented');
            error.code = 'ERR_HOME_UNSUPPORTED_GLOB';
            throw error;
          }
          // A broken symlink is inspected only during traversal. With
          // followSymlinks:false it stays a link, as in native Bun.
          if (key !== 'followSymlinks' && key !== 'throwErrorOnBrokenSymlink') result[key] = value;
        }
      }
      return result;
    }
    function files(pattern, options) {
      return JSON.parse(request('scan', pattern, options.cwd, options.dot, options.absolute, options.onlyFiles).json);
    }
    class Glob {
      constructor(pattern) {
        if (typeof pattern !== 'string' || pattern.includes('\0')) throw new TypeError('Glob pattern must be a string without NUL');
        patterns.set(this, pattern);
      }
      match(path) {
        if (typeof path !== 'string') throw new TypeError('Glob path must be a string');
        return request('match', patternFor(this), path).matches;
      }
      scanSync(options) {
        const pattern = patternFor(this);
        const normalized = optionsFor(options);
        return (function*() {
          yield* files(pattern, normalized);
        })();
      }
      scan(options) {
        const pattern = patternFor(this);
        const normalized = optionsFor(options);
        return (async function*() {
          for (const path of files(pattern, normalized)) yield path;
        })();
      }
    }
    return Glob;
  };
})();
