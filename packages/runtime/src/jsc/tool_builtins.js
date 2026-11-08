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

  function utf8ReadOptions(options) {
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
  }

  const bufferFactory = globalThis.__home_tool_buffer_factory;
  delete globalThis.__home_tool_buffer_factory;
  const bufferApi = bufferFactory(decodeUtf8);
  globalThis.Buffer = bufferApi.Buffer;
  const nativeRandomBytes = globalThis.__home_tool_random_bytes;
  delete globalThis.__home_tool_random_bytes;
  const allocateBytes = bufferApi.Buffer.alloc;
  function nodeArgumentError(code, message, range) {
    const error = range ? new RangeError(message) : new TypeError(message);
    error.code = code;
    throw error;
  }
  const cryptoApi = {
    randomBytes: function(size, callback) {
      // https://nodejs.org/api/crypto.html#cryptorandombytessize-callback
      if (typeof size !== 'number') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'randomBytes size must be a number');
      if (!Number.isFinite(size) || size < 0 || size > 0x7fffffff) nodeArgumentError('ERR_OUT_OF_RANGE', 'randomBytes size must be between 0 and 2147483647', true);
      if (callback !== undefined) {
        if (typeof callback !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'randomBytes callback must be a function');
        unsupported('Home crypto.randomBytes callbacks require an asynchronous host');
      }
      const bytes = allocateBytes(Math.floor(size));
      if (!nativeRandomBytes(bytes)) throw new Error('Native crypto entropy source failed');
      return bytes;
    },
  };
  const fs = {
    readFileSync: function(path, options) {
      path = stringPath(path);
      utf8ReadOptions(options);
      // Hex transport preserves NULs and malformed UTF-8 that a sentinel-based
      // text callback cannot carry faithfully. File errors propagate as errors.
      return decodeUtf8(Home.readFileHex(path));
    },
    existsSync: function(path) {
      if (typeof path === 'string' && path.indexOf('\0') !== -1) return false;
      return Home.fileExists(stringPath(path));
    },
  };
  const nativeFs = globalThis.__home_tool_fs_operation;
  delete globalThis.__home_tool_fs_operation;
  const fsIsView = ArrayBuffer.isView.bind(ArrayBuffer);
  const fsBytes = Uint8Array;
  const fsDataView = DataView;
  const fsViewBuffer = Object.getOwnPropertyDescriptor(fsDataView.prototype, 'buffer').get;
  const fsViewOffset = Object.getOwnPropertyDescriptor(fsDataView.prototype, 'byteOffset').get;
  const fsViewLength = Object.getOwnPropertyDescriptor(fsDataView.prototype, 'byteLength').get;
  function fsOptions(options, allowed) {
    if (options === undefined) return {};
    if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Expected filesystem options object');
    for (const key of Object.keys(options)) {
      if (!allowed.includes(key)) unsupported(`Unsupported filesystem option: ${key}`);
    }
    return options;
  }
  function booleanFsOption(options, key) {
    if (options[key] !== undefined && typeof options[key] !== 'boolean') throw new TypeError(`Expected boolean ${key}`);
    return options[key] === true;
  }
  function fsOperation(operation, path, recursive, force, mode) {
    path = stringPath(path);
    const result = nativeFs(operation, path, recursive, force, mode);
    if (result === null) throw new Error('Native filesystem operation failed');
    if (result.error) {
      const error = new Error(`${result.error}: ${operation} '${path}'${result.detail ? ` (${result.detail})` : ''}`);
      error.code = result.error;
      error.syscall = operation;
      error.path = path;
      throw error;
    }
    return result;
  }
  class DirectoryEntry {
    constructor(name, kind, parentPath) {
      this.name = name;
      this.parentPath = parentPath;
      directoryKinds.set(this, kind);
    }
    isFile() {
      return directoryKinds.get(this) === 'file';
    }
    isDirectory() {
      return directoryKinds.get(this) === 'directory';
    }
    isSymbolicLink() {
      return directoryKinds.get(this) === 'sym_link';
    }
    isBlockDevice() {
      return directoryKinds.get(this) === 'block_device';
    }
    isCharacterDevice() {
      return directoryKinds.get(this) === 'character_device';
    }
    isFIFO() {
      return directoryKinds.get(this) === 'named_pipe';
    }
    isSocket() {
      return directoryKinds.get(this) === 'unix_domain_socket';
    }
  }
  const directoryKinds = new WeakMap();
  function readDirectory(path, options) {
    path = stringPath(path);
    options = typeof options === 'string' ? { encoding: options } : fsOptions(options === null ? undefined : options, ['encoding', 'withFileTypes', 'recursive']);
    const encoding = options.encoding;
    const withTypes = options.withFileTypes;
    const recursive = options.recursive;
    if (encoding != null && (typeof encoding !== 'string' || !['utf8', 'utf-8'].includes(encoding.toLowerCase()))) unsupported('Home readdir supports UTF-8 names only');
    if (withTypes !== undefined && typeof withTypes !== 'boolean') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'readdir withFileTypes must be a boolean');
    if (recursive !== undefined && typeof recursive !== 'boolean') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'readdir recursive must be a boolean');
    if (recursive === true) unsupported('Home readdir recursive enumeration is not implemented');
    const encoded = fsOperation('readdir', path, withTypes === true, false).entriesJSON;
    if (typeof encoded !== 'string') throw new Error('Native directory enumeration returned no entries');
    return JSON.parse(encoded).map(entry => withTypes ? new DirectoryEntry(entry.name, entry.kind, path) : entry.name);
  }
  fs.readdirSync = function(path, options) {
    return readDirectory(path, options);
  };
  const fsConstants = {};
  for (const [key, value] of [['F_OK', 0], ['R_OK', 4], ['W_OK', 2], ['X_OK', 1]]) {
    Object.defineProperty(fsConstants, key, { value, enumerable: true });
  }
  Object.defineProperty(fs, 'constants', { value: fsConstants, enumerable: true });
  function accessFile(path, mode) {
    if (mode == null) mode = 0;
    if (typeof mode !== 'number') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'access mode must be a number');
    // Node truncates numeric modes before validating the three access bits.
    mode = Math.trunc(mode);
    if (!Number.isFinite(mode) || mode < 0 || mode > 7) nodeArgumentError('ERR_OUT_OF_RANGE', 'access mode must be between 0 and 7', true);
    fsOperation('access', path, mode, false);
  }
  fs.accessSync = accessFile;
  function creationMode(mode, fallback) {
    if (mode == null) return fallback;
    if (typeof mode === 'string') {
      if (!/^[0-7]+$/.test(mode)) nodeArgumentError('ERR_INVALID_ARG_VALUE', 'creation mode must be an octal string');
      mode = parseInt(mode, 8);
    }
    if (typeof mode !== 'number') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'creation mode must be a number or octal string');
    if (!Number.isInteger(mode) || mode < 0 || mode > 0xffffffff) nodeArgumentError('ERR_OUT_OF_RANGE', 'creation mode must be a uint32', true);
    if (mode > 0o7777) unsupported('Home creation mode supports POSIX permission bits only');
    return mode;
  }
  const fsPromises = {
    constants: fsConstants,
    access: async function(path, mode) {
      accessFile(path, mode);
    },
    readdir: async function(path, options) {
      return readDirectory(path, options);
    },
    writeFile: async function(path, data, options) {
      path = stringPath(path);
      if (typeof data !== 'string' && !fsIsView(data)) {
        if (data != null && (typeof data[Symbol.iterator] === 'function' || typeof data[Symbol.asyncIterator] === 'function')) unsupported('Home writeFile does not support iterable input');
        nodeArgumentError('ERR_INVALID_ARG_TYPE', 'writeFile data must be a string or ArrayBuffer view');
      }
      options = typeof options === 'string' ? { encoding: options } : fsOptions(options, ['encoding', 'flag', 'mode']);
      if (options.encoding != null && (typeof options.encoding !== 'string' || !['utf8', 'utf-8'].includes(options.encoding.toLowerCase()))) unsupported('Home writeFile supports UTF-8 encoding only');
      if (options.flag !== undefined && options.flag !== 'w') unsupported('Home writeFile supports the w flag only');
      const mode = creationMode(options.mode, 0o666);
      if (data instanceof fsDataView) data = new fsBytes(fsViewBuffer.call(data), fsViewOffset.call(data), fsViewLength.call(data));
      fsOperation('writeFile', path, data, false, mode);
    },
    readFile: async function(path, options) {
      utf8ReadOptions(options);
      return decodeUtf8(fsOperation('readFile', path, false, false).hex);
    },
    mkdir: async function(path, options) {
      options = fsOptions(options, ['recursive', 'mode']);
      const result = fsOperation('mkdir', path, booleanFsOption(options, 'recursive'), false, creationMode(options.mode, 0o777));
      return result.created;
    },
    rm: async function(path, options) {
      options = fsOptions(options, ['recursive', 'force']);
      fsOperation('rm', path, booleanFsOption(options, 'recursive'), booleanFsOption(options, 'force'));
    },
    stat: async function(path, options) {
      fsOptions(options, []);
      const result = fsOperation('stat', path, false, false);
      const kind = result.kind;
      delete result.kind;
      result.isFile = function() {
        return kind === 'file';
      };
      result.isDirectory = function() {
        return kind === 'directory';
      };
      result.isSymbolicLink = function() {
        return kind === 'sym_link';
      };
      result.isBlockDevice = function() {
        return kind === 'block_device';
      };
      result.isCharacterDevice = function() {
        return kind === 'character_device';
      };
      result.isFIFO = function() {
        return kind === 'named_pipe';
      };
      result.isSocket = function() {
        return kind === 'unix_domain_socket';
      };
      result.mtime = new Date(result.mtimeMs);
      result.ctime = new Date(result.ctimeMs);
      if (result.atimeMs !== undefined) result.atime = new Date(result.atimeMs);
      return result;
    },
  };
  fs.promises = fsPromises;
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
    basename: function(path, suffix) {
      if (suffix !== undefined) pathString(suffix);
      pathString(path);
      let end = path.length;
      while (end > 0 && path[end - 1] === '/') end--;
      let start = end;
      while (start > 0 && path[start - 1] !== '/') start--;
      const component = path.slice(start, end);
      if (suffix !== undefined && suffix.length > 0 && suffix.length <= path.length) {
        if (suffix === path) return '';
        if (component.length > suffix.length && component.endsWith(suffix))
          return component.slice(0, -suffix.length);
        // Node retains trailing separators when a longer suffix only matches
        // the whole shorter component, including the empty root component.
        if (component.length < suffix.length && suffix.endsWith(component))
          return path.slice(start);
      }
      return component;
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
  const accountHomedir = globalThis.__home_tool_account_homedir;
  delete globalThis.__home_tool_account_homedir;
  const osProcess = process;
  const osApi = {
    platform: function() {
      return osProcess.platform;
    },
    homedir: function() {
      if (Object.prototype.hasOwnProperty.call(process.env, 'HOME')) {
        if (typeof process.env.HOME !== 'string') unsupported('Home os.homedir requires a string HOME environment value');
        return process.env.HOME;
      }
      const directory = accountHomedir();
      if (directory === null) throw new Error('Cannot query the native POSIX home directory');
      return directory;
    },
  };
  const eventsApi = globalThis.__home_tool_events;
  delete globalThis.__home_tool_events;
  const streamsFactory = globalThis.__home_tool_streams_factory;
  delete globalThis.__home_tool_streams_factory;
  const streamsApi = streamsFactory(eventsApi, bufferApi.Buffer);
  const zlibFactory = globalThis.__home_tool_zlib_factory;
  delete globalThis.__home_tool_zlib_factory;
  const nativeGzip = globalThis.__home_tool_gzip;
  delete globalThis.__home_tool_gzip;
  const zlibApi = zlibFactory(nativeGzip, bufferApi.Buffer, streamsApi.Transform);
  const nativeIsatty = globalThis.__home_tool_isatty;
  delete globalThis.__home_tool_isatty;
  const ttyApi = {
    isatty: function(descriptor) {
      // Node's isatty does not coerce strings, objects, BigInts or symbols.
      if (typeof descriptor !== 'number' || !Number.isInteger(descriptor) || descriptor < 0 || descriptor > 0x7fffffff) return false;
      const result = nativeIsatty(descriptor);
      if (result === null) unsupported('Home native isatty currently requires macOS or Linux');
      return result;
    },
  };
  function readlineCallback(callback) {
    if (callback !== undefined && typeof callback !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'readline callback must be a function');
  }
  function noCursorWrite(callback) {
    if (typeof callback === 'function') process.nextTick(callback, null);
    return true;
  }
  // Output helpers write actual ANSI sequences and preserve the destination's
  // backpressure/callback behavior. Input interfaces need a real stream host.
  // https://nodejs.org/api/readline.html#readlinecursortostream-x-y-callback
  const readlineApi = {
    cursorTo: function(stream, x, y, callback) {
      readlineCallback(callback);
      if (typeof y === 'function') {
        callback = y;
        y = undefined;
      }
      if (Number.isNaN(x) || Number.isNaN(y)) nodeArgumentError('ERR_INVALID_ARG_VALUE', 'Cursor coordinates cannot be NaN');
      if (stream == null || (typeof x !== 'number' && typeof y !== 'number')) return noCursorWrite(callback);
      if (typeof x !== 'number') nodeArgumentError('ERR_INVALID_CURSOR_POS', 'A row coordinate requires a numeric column');
      return stream.write(typeof y === 'number' ? `\x1b[${y + 1};${x + 1}H` : `\x1b[${x + 1}G`, callback);
    },
    moveCursor: function(stream, dx, dy, callback) {
      readlineCallback(callback);
      if (stream == null || !(dx || dy)) return noCursorWrite(callback);
      let sequence = '';
      if (dx < 0) sequence += `\x1b[${-dx}D`;
      else if (dx > 0) sequence += `\x1b[${dx}C`;
      if (dy < 0) sequence += `\x1b[${-dy}A`;
      else if (dy > 0) sequence += `\x1b[${dy}B`;
      return stream.write(sequence, callback);
    },
    clearLine: function(stream, direction, callback) {
      readlineCallback(callback);
      if (stream == null) return noCursorWrite(callback);
      return stream.write(`\x1b[${direction < 0 ? 1 : direction > 0 ? 0 : 2}K`, callback);
    },
    clearScreenDown: function(stream, callback) {
      readlineCallback(callback);
      if (stream == null) return noCursorWrite(callback);
      return stream.write('\x1b[0J', callback);
    },
  };
  const builtins = Object.create(null);
  const timerFactory = globalThis.__home_tool_timers_factory;
  const timerSchedule = globalThis.__home_tool_timer_schedule;
  const timerControl = globalThis.__home_tool_timer_control;
  delete globalThis.__home_tool_timers_factory;
  delete globalThis.__home_tool_timer_schedule;
  delete globalThis.__home_tool_timer_control;
  const asyncHooksFactory = globalThis.__home_tool_async_hooks_factory;
  delete globalThis.__home_tool_async_hooks_factory;
  const getAsyncContext = globalThis.__home_tool_get_async_context;
  const swapAsyncContext = globalThis.__home_tool_swap_async_context;
  delete globalThis.__home_tool_get_async_context;
  delete globalThis.__home_tool_swap_async_context;
  const timers = timerFactory(timerSchedule, timerControl, getAsyncContext, swapAsyncContext);
  globalThis.setTimeout = timers.setTimeout;
  globalThis.clearTimeout = timers.clearTimeout;
  globalThis.setInterval = timers.setInterval;
  globalThis.clearInterval = timers.clearInterval;
  // Engine-owned immediate queues cannot participate in this host's task
  // dispatch, context restoration or fatal-exception policy.
  for (const key of ['setImmediate', 'clearImmediate']) delete globalThis[key];
  builtins.timers = timers;
  builtins['node:timers'] = timers;
  builtins['timers/promises'] = timers.promises;
  builtins['node:timers/promises'] = timers.promises;
  if (typeof getAsyncContext === 'function' && typeof swapAsyncContext === 'function') {
    const asyncHooks = asyncHooksFactory(getAsyncContext, swapAsyncContext);
    builtins.async_hooks = asyncHooks;
    builtins['node:async_hooks'] = asyncHooks;
  }
  builtins.stream = streamsApi;
  builtins['node:stream'] = streamsApi;
  builtins['stream/promises'] = streamsApi.promises;
  builtins['node:stream/promises'] = streamsApi.promises;
  // The Node 26 recognizer covers CSI and terminated OSC sequences, including
  // colon-delimited SGR and Unicode/newline OSC payloads. Keep it private.
  const vtControls = /(?:\x1b\][\s\S]*?(?:\x07|\x1b\\|\x9c))|[\x1b\x9b][[\]()#;?]*(?:\d{1,4}(?:[;:]\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]/g;
  const stripControls = RegExp.prototype[Symbol.replace].bind(vtControls);
  const utilApi = {
    stripVTControlCharacters: function(text) {
      if (typeof text !== 'string') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'stripVTControlCharacters requires a string');
      return stripControls(text, '');
    },
  };
  builtins.util = utilApi;
  builtins.zlib = zlibApi;
  builtins['node:zlib'] = zlibApi;
  builtins['node:util'] = utilApi;
  builtins.readline = readlineApi;
  builtins['node:readline'] = readlineApi;
  builtins.buffer = bufferApi;
  builtins['node:buffer'] = bufferApi;
  builtins.crypto = cryptoApi;
  builtins['node:crypto'] = cryptoApi;
  builtins.tty = ttyApi;
  builtins['node:tty'] = ttyApi;
  builtins.events = eventsApi;
  builtins['node:events'] = eventsApi;
  builtins.os = osApi;
  builtins['node:os'] = osApi;
  builtins.process = globalThis.process;
  builtins['node:process'] = globalThis.process;
  const perfHooks = { performance: globalThis.performance, Performance: globalThis.Performance };
  builtins.perf_hooks = perfHooks;
  builtins['node:perf_hooks'] = perfHooks;
  builtins['fs/promises'] = fsPromises;
  builtins['node:fs/promises'] = fsPromises;
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
  const fileFactory = globalThis.__home_tool_file_factory;
  delete globalThis.__home_tool_file_factory;
  const globFactory = globalThis.__home_tool_glob_factory;
  const nativeGlob = globalThis.__home_tool_glob;
  delete globalThis.__home_tool_glob_factory;
  delete globalThis.__home_tool_glob;
  const markdownApi = globalThis.__home_tool_markdown_api;
  delete globalThis.__home_tool_markdown_api;
  const bunApi = { markdown: markdownApi, Glob: globFactory(nativeGlob), YAML: { parse: Home.parseYAML }, file: fileFactory(fsOperation, bufferApi.Buffer) };
  Object.defineProperty(bunApi, 'env', { value: process.env, enumerable: true });
  Object.defineProperty(bunApi, 'argv', { value: process.argv, writable: true, enumerable: true, configurable: false });
  globalThis.Bun = bunApi;
  builtins.bun = bunApi;
  globalThis.__home_tool_builtins = builtins;
})();
