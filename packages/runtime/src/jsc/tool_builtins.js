(function() {
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }

  function stringPath(path) {
    if (typeof path !== 'string') unsupported('Home node:fs currently supports string paths only');
    if (path.indexOf('\0') !== -1) throw new TypeError('File paths cannot contain NUL bytes');
    return path;
  }

  // WHATWG UTF-8 decoder: retain BOMs for Node's file-content semantics,
  // replace malformed sequences, and reprocess a rejected continuation byte.
  // https://encoding.spec.whatwg.org/#utf-8-decoder
  function decodeUtf8(hex) {
    const output = [];
    let point = 0, needed = 0, seen = 0, lower = 0x80, upper = 0xbf;
    for (let index = 0; index < hex.length; index += 2) {
      const byte = parseInt(hex.slice(index, index + 2), 16);
      if (needed === 0) {
        if (byte <= 0x7f) output.push(String.fromCharCode(byte));
        else if (byte >= 0xc2 && byte <= 0xdf) {
          needed = 1;
          point = byte & 0x1f;
        }
        else if (byte >= 0xe0 && byte <= 0xef) {
          if (byte === 0xe0) lower = 0xa0;
          if (byte === 0xed) upper = 0x9f;
          needed = 2;
          point = byte & 0x0f;
        }
        else if (byte >= 0xf0 && byte <= 0xf4) {
          if (byte === 0xf0) lower = 0x90;
          if (byte === 0xf4) upper = 0x8f;
          needed = 3;
          point = byte & 0x07;
        }
        else output.push('\ufffd');
        continue;
      }
      if (byte < lower || byte > upper) {
        point = needed = seen = 0;
        lower = 0x80;
        upper = 0xbf;
        output.push('\ufffd');
        index -= 2;
        continue;
      }
      lower = 0x80;
      upper = 0xbf;
      point = (point << 6) | (byte & 0x3f);
      if (++seen !== needed) continue;
      if (point <= 0xffff) output.push(String.fromCharCode(point));
      else {
        point -= 0x10000;
        output.push(String.fromCharCode(0xd800 + (point >> 10), 0xdc00 + (point & 0x3ff)));
      }
      point = needed = seen = 0;
    }
    if (needed !== 0) output.push('\ufffd');
    return output.join('');
  }

  const fs = {
    readFileSync: function(path, options) {
      path = stringPath(path);
      const encoding = typeof options === 'string' ? options : options && options.encoding;
      if (typeof encoding !== 'string' || !['utf8', 'utf-8'].includes(encoding.toLowerCase())) {
        unsupported('Home node:fs readFileSync currently requires utf8 encoding; Buffer and other encodings are unsupported');
      }
      if (options && typeof options === 'object') {
        if (options.flag !== undefined && options.flag !== 'r') unsupported('Home node:fs currently supports the r flag only');
        const unknown = Object.keys(options).filter(function(key) {
          return key !== 'encoding' && key !== 'flag';
        });
        if (unknown.length) unsupported(`Unsupported Home node:fs read options: ${unknown.join(', ')}`);
      }
      // Hex transport preserves NULs and malformed UTF-8 that a sentinel-based
      // text callback cannot carry faithfully. File errors propagate as errors.
      return decodeUtf8(Home.readFileHex(path));
    },
    existsSync: function(path) {
      if (typeof path === 'string' && path.indexOf('\0') !== -1) return false;
      return Home.fileExists(stringPath(path));
    },
  };
  function invalidReferrer() {
    const error = new TypeError('createRequire needs an absolute filename or file URL string');
    error.code = 'ERR_INVALID_ARG_VALUE';
    throw error;
  }

  // POSIX file URL conversion for referrers. Normalize URL dot segments before
  // percent decoding, so %252e remains a literal filename rather than a dot.
  // https://nodejs.org/api/module.html#modulecreaterequirefilename
  function fileURLError(code) {
    const error = new TypeError('Invalid POSIX file URL');
    error.code = code;
    throw error;
  }

  function fileReferrer(filename) {
    let text = filename.replace(/^[\x00-\x20]+|[\x00-\x20]+$/g, '').replace(/[\t\r\n]/g, '').replace(/\\/g, '/');
    // URL input is a Unicode scalar-value string; lone UTF-16 surrogates are
    // replaced, whereas valid surrogate pairs retain their code point.
    text = Array.from(text, function(character) {
      const point = character.codePointAt(0);
      return point >= 0xd800 && point <= 0xdfff ? '\ufffd' : character;
    }).join('');
    if (!/^file:/i.test(text)) {
      fileURLError(/^[a-z][a-z0-9+.-]*:/i.test(text) ? 'ERR_INVALID_URL_SCHEME' : 'ERR_INVALID_URL');
    }
    text = text.slice(5);
    if (text.startsWith('//')) {
      text = text.slice(2);
      const end = text.search(/[/?#]/);
      const host = end === -1 ? text : text.slice(0, end);
      if (/[@:]/.test(host)) fileURLError('ERR_INVALID_URL');
      let decodedHost;
      try {
        decodedHost = decodeURIComponent(host).toLowerCase();
      }
      catch {
        fileURLError('ERR_INVALID_URL');
      }
      if (decodedHost !== '' && decodedHost !== 'localhost') fileURLError('ERR_INVALID_FILE_URL_HOST');
      text = end === -1 ? '/' : text.slice(end);
    }
    text = text.split(/[?#]/)[0];
    if (!text.startsWith('/')) text = `/${text}`;
    if (/%2f/i.test(text)) fileURLError('ERR_INVALID_FILE_URL_PATH');
    const segments = text.slice(1).split('/');
    const normalized = [];
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index];
      const dots = segment.replace(/%2e/ig, '.');
      if (dots === '..') {
        normalized.pop();
        if (index === segments.length - 1) normalized.push('');
      }
      else if (dots === '.') {
        if (index === segments.length - 1) normalized.push('');
      }
      else normalized.push(segment);
    }
    return decodeURIComponent(`/${normalized.join('/')}`);
  }

  const moduleApi = {
    createRequire: function(filename) {
      if (process.platform === 'win32') unsupported('Home createRequire currently supports POSIX referrers only');
      if (typeof filename !== 'string') {
        if (filename && typeof filename === 'object') unsupported('Home createRequire URL objects require a shared URL implementation');
        invalidReferrer();
      }
      if (!filename.startsWith('/')) {
        try {
          filename = fileReferrer(filename);
        }
        catch {
          invalidReferrer();
        }
      }
      if (filename.indexOf('\0') !== -1) invalidReferrer();
      return Home.createRequire(filename);
    },
  };

  function pathString(value) {
    if (typeof value !== 'string') {
      const error = new TypeError('Path must be a string');
      error.code = 'ERR_INVALID_ARG_TYPE';
      throw error;
    }
    return value;
  }

  function normalizedSegments(path, aboveRoot) {
    const result = [];
    for (const segment of path.split('/')) {
      if (segment === '' || segment === '.') continue;
      if (segment === '..') {
        if (result.length && result[result.length - 1] !== '..') result.pop();
        else if (aboveRoot) result.push('..');
      }
      else result.push(segment);
    }
    return result.join('/');
  }

  function normalize(path) {
    pathString(path);
    const absolute = path.startsWith('/');
    let result = normalizedSegments(path, !absolute);
    if (!absolute && result === '') result = '.';
    if (result !== '' && path.endsWith('/')) result += '/';
    return `${absolute ? '/' : ''}${result}`;
  }

  const posixPath = {
    sep: '/',
    delimiter: ':',
    normalize: normalize,
    isAbsolute: function(path) {
      return pathString(path).startsWith('/');
    },
    join: function(...paths) {
      const parts = [];
      for (const path of paths) {
        pathString(path);
        if (path !== '') parts.push(path);
      }
      return normalize(parts.join('/'));
    },
    resolve: function(...paths) {
      let result = '';
      let absolute = false;
      for (let index = paths.length - 1; index >= -1 && !absolute; index--) {
        if (index === -1 && process.platform === 'win32') unsupported('Home POSIX resolve cannot derive a POSIX cwd on Windows');
        const path = pathString(index >= 0 ? paths[index] : process.cwd());
        if (path === '') continue;
        result = `${path}/${result}`;
        absolute = path.startsWith('/');
      }
      result = normalizedSegments(result, !absolute);
      return `${absolute ? '/' : ''}${result}` || '.';
    },
    dirname: function(path) {
      pathString(path);
      if (path.length === 0) return '.';
      const root = path.startsWith('/');
      let end = -1;
      let trailing = true;
      for (let index = path.length - 1; index >= 1; index--) {
        if (path[index] === '/') {
          if (!trailing) {
            end = index;
            break;
          }
        }
        else trailing = false;
      }
      if (end === -1) return root ? '/' : '.';
      if (root && end === 1) return '//';
      return path.slice(0, end);
    },
  };
  posixPath.posix = posixPath;
  const urlApi = {
    fileURLToPath: function(url, options) {
      if (process.platform === 'win32' || options !== undefined) unsupported('Home fileURLToPath currently supports native POSIX conversion without options');
      if (typeof url !== 'string') unsupported('Home fileURLToPath currently supports URL strings only');
      return fileReferrer(url);
    },
  };
  const childProcess = {
    execFileSync: function(file, args, options) {
      if (!Array.isArray(args)) {
        options = args;
        args = [];
      }
      options = options || {};
      if (typeof file !== 'string' || file.indexOf('\0') !== -1) throw new TypeError('Executable must be a string without NUL bytes');
      if (process.platform === 'win32' || !file.startsWith('/')) unsupported('Home execFileSync currently requires an absolute POSIX executable path');
      if (args.some(function(arg) {
        return typeof arg !== 'string' || arg.indexOf('\0') !== -1;
      })) throw new TypeError('Arguments must be strings without NUL bytes');
      if (options.stdio !== 'inherit') unsupported('Home execFileSync currently requires inherited stdio; captured Buffer results are unsupported');
      for (const key of Object.keys(options)) {
        if (!['stdio', 'cwd', 'env'].includes(key)) unsupported(`Unsupported Home execFileSync option: ${key}`);
      }
      if (options.cwd !== undefined) stringPath(options.cwd);
      const env = {};
      const inheritEnv = options.env == null;
      if (!inheritEnv) {
        if (typeof options.env !== 'object') throw new TypeError('Environment must be an object');
        for (const key of Object.keys(options.env)) {
          if (key.includes('\0') || key.includes('=')) throw new TypeError('Invalid environment key');
          if (options.env[key] !== undefined) {
            const value = String(options.env[key]);
            if (value.includes('\0')) throw new TypeError('Environment values cannot contain NUL bytes');
            env[key] = value;
          }
        }
      }
      const result = Home.spawnSync([file, ...args], { stdio: 'inherit', cwd: options.cwd, env: env, inheritEnv: inheritEnv });
      if (result.exitCode !== 0) {
        const error = new Error(`Command failed: ${file}`);
        error.status = result.exitCode;
        error.signal = result.signal;
        error.stdout = result.stdout;
        error.stderr = result.stderr;
        throw error;
      }
      return null;
    },
  };
  const builtins = Object.create(null);
  builtins.process = globalThis.process;
  builtins['node:process'] = globalThis.process;
  builtins.fs = fs;
  builtins['node:fs'] = fs;
  builtins.module = moduleApi;
  builtins['node:module'] = moduleApi;
  if (process.platform !== 'win32') {
    builtins.path = posixPath;
    builtins['node:path'] = posixPath;
  }
  builtins['path/posix'] = posixPath;
  builtins['node:path/posix'] = posixPath;
  builtins.url = urlApi;
  builtins['node:url'] = urlApi;
  builtins.child_process = childProcess;
  builtins['node:child_process'] = childProcess;
  const bunApi = { YAML: { parse: Home.parseYAML } };
  globalThis.Bun = bunApi;
  builtins.bun = bunApi;
  globalThis.__home_tool_builtins = builtins;
})();
