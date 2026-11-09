(function() {
  // Node's legacy alias refers to this realm's actual global object.
  globalThis.global = globalThis;
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

  function readFileOptions(options) {
    if (options !== undefined && options !== null && typeof options !== 'string' && (typeof options !== 'object' || Array.isArray(options))) throw new TypeError('Expected filesystem read options object or encoding');
    const encoding = typeof options === 'string' ? options : options && options.encoding;
    const utf8 = encoding !== undefined && encoding !== null;
    if (utf8 && (typeof encoding !== 'string' || !['utf8', 'utf-8'].includes(encoding.toLowerCase()))) {
      unsupported('Home node:fs string reads currently support utf8/utf-8 encoding only');
    }
    if (options && typeof options === 'object') {
      if (options.flag !== undefined && options.flag !== 'r') unsupported('Home node:fs currently supports the r flag only');
      const unknown = Object.keys(options).filter(function(key) {
        return key !== 'encoding' && key !== 'flag';
      });
      if (unknown.length) unsupported(`Unsupported Home node:fs read options: ${unknown.join(', ')}`);
    }
    return utf8;
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
      const utf8 = readFileOptions(options);
      // Hex transport preserves NULs and malformed UTF-8 that a sentinel-based
      // text callback cannot carry faithfully. File errors propagate as errors.
      const hex = fsOperation('readFile', path, false, false).hex;
      return utf8 ? decodeUtf8(hex) : bufferApi.Buffer.from(hex, 'hex');
    },
    existsSync: function(path) {
      if (typeof path === 'string' && path.indexOf('\0') !== -1) return false;
      return Home.fileExists(stringPath(path));
    },
  };
  const nativeFs = globalThis.__home_tool_fs_operation;
  delete globalThis.__home_tool_fs_operation;
  const nativeFd = globalThis.__home_tool_fd_operation;
  delete globalThis.__home_tool_fd_operation;
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
      error.syscall = result.syscall || operation;
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
  const legacyConstants = {};
  const nativeFsConstants = globalThis.__home_tool_fs_constants;
  delete globalThis.__home_tool_fs_constants;
  if (!nativeFsConstants) unsupported('Home filesystem constants require a native macOS or Linux host');
  for (const key of Object.keys(nativeFsConstants)) {
    Object.defineProperty(fsConstants, key, { value: nativeFsConstants[key], enumerable: true });
    Object.defineProperty(legacyConstants, key, { value: nativeFsConstants[key], enumerable: true });
  }
  Object.defineProperty(fs, 'constants', { value: fsConstants, enumerable: true });
  function accessMode(mode) {
    if (mode == null) mode = 0;
    if (typeof mode !== 'number') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'access mode must be a number');
    // Node truncates numeric modes before validating the three access bits.
    mode = Math.trunc(mode);
    if (!Number.isFinite(mode) || mode < 0 || mode > 7) nodeArgumentError('ERR_OUT_OF_RANGE', 'access mode must be between 0 and 7', true);
    return mode;
  }
  function accessFile(path, mode) {
    fsOperation('access', path, accessMode(mode), false);
  }
  fs.accessSync = accessFile;
  fs.access = function(path, mode, callback) {
    if (typeof mode === 'function') { callback = mode; mode = undefined; }
    if (typeof callback !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'access callback must be a function');
    mode = accessMode(mode);
    if (typeof path === 'string' && path.indexOf('\0') !== -1) nodeArgumentError('ERR_INVALID_ARG_VALUE', 'File paths cannot contain NUL bytes');
    path = stringPath(path);
    scheduleFilesystemTask(function() {
      let error;
      try { accessFile(path, mode); }
      catch (caught) { error = caught; }
      // Keep user callback failures outside native-operation error handling.
      callback(error || null);
    }, 0);
  };
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
  function fileDescriptor(fd) {
    if (typeof fd !== 'number') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'file descriptor must be a number');
    if (!Number.isInteger(fd) || fd < 0 || fd > 0x7fffffff) nodeArgumentError('ERR_OUT_OF_RANGE', 'file descriptor must be a nonnegative int32', true);
    return fd;
  }
  function fdOperation(operation, fd, data) {
    const result = nativeFd(operation, fileDescriptor(fd), data);
    if (result === null) throw new Error('Native descriptor operation failed');
    if (result.error) {
      const error = new Error(`${result.error}: ${operation} ${fd}`);
      error.code = result.error;
      error.syscall = result.syscall || operation;
      throw error;
    }
  }
  function fileFlag(flag, fallback) {
    if (flag === undefined) return fallback;
    if (!['r', 'r+', 'w', 'w+', 'wx', 'wx+', 'a', 'a+', 'ax', 'ax+'].includes(flag)) unsupported('Home filesystem supports r/r+/w/w+/wx/wx+/a/a+/ax/ax+ string flags only');
    return flag;
  }
  fs.openSync = function(path, flag, mode) {
    return fsOperation('open', path, fileFlag(flag, 'r'), false, creationMode(mode, 0o666)).fd;
  };
  fs.closeSync = function(fd) {
    fdOperation('close', fd);
  };
  fs.fsyncSync = function(fd) {
    fdOperation('fsync', fd);
  };
  function writeFile(path, data, options) {
    if (typeof path === 'number') fileDescriptor(path);
    else path = stringPath(path);
    if (typeof data !== 'string' && !fsIsView(data)) {
      if (data != null && (typeof data[Symbol.iterator] === 'function' || typeof data[Symbol.asyncIterator] === 'function')) unsupported('Home writeFile does not support iterable input');
      nodeArgumentError('ERR_INVALID_ARG_TYPE', 'writeFile data must be a string or ArrayBuffer view');
    }
    options = typeof options === 'string' ? { encoding: options } : fsOptions(options, ['encoding', 'flag', 'mode']);
    if (options.encoding != null && (typeof options.encoding !== 'string' || !['utf8', 'utf-8'].includes(options.encoding.toLowerCase()))) unsupported('Home writeFile supports UTF-8 encoding only');
    const flag = fileFlag(options.flag, 'w');
    const mode = creationMode(options.mode, 0o666);
    if (data instanceof fsDataView) data = new fsBytes(fsViewBuffer.call(data), fsViewOffset.call(data), fsViewLength.call(data));
    // An existing descriptor retains its kernel offset and O_APPEND state;
    // flag/mode options must never reopen or truncate that descriptor's file.
    if (typeof path === 'number') fdOperation('write', path, data);
    else fsOperation('writeFile', path, data, flag, mode);
  }
  function realPath(path, options, legacy) {
    path = stringPath(path);
    options = options == null ? {} : typeof options === 'string' ? { encoding: options } : fsOptions(options, ['encoding']);
    if (options.encoding != null && (typeof options.encoding !== 'string' || !['utf8', 'utf-8'].includes(options.encoding.toLowerCase()))) unsupported('Home realpath supports UTF-8 string results only');
    // Node's legacy sync facade resolves lexical dots before physical links.
    // Native and promised realpath pass the actual path to the OS instead.
    return fsOperation('realpath', legacy ? posixPath.resolve(path) : path).path;
  }
  fs.realpathSync = function(path, options) {
    return realPath(path, options, true);
  };
  fs.realpathSync.native = function(path, options) {
    return realPath(path, options, false);
  };
  function appendFile(path, data, options) {
    options = options == null ? {} : typeof options === 'string' ? { encoding: options } : fsOptions(options, ['encoding', 'flag', 'mode']);
    // Use kernel O_APPEND through the existing writer; never read/concatenate
    // the old file. Existing descriptors retain their offset and open flags.
    writeFile(path, data, { encoding: options.encoding, mode: options.mode, flag: fileFlag(options.flag, 'a') });
  }
  fs.appendFileSync = appendFile;
  fs.writeFileSync = writeFile;
  function statResult(result) {
    const kind = result.kind;
    delete result.kind;
    result.isFile = function() { return kind === 'file'; };
    result.isDirectory = function() { return kind === 'directory'; };
    result.isSymbolicLink = function() { return kind === 'sym_link'; };
    result.isBlockDevice = function() { return kind === 'block_device'; };
    result.isCharacterDevice = function() { return kind === 'character_device'; };
    result.isFIFO = function() { return kind === 'named_pipe'; };
    result.isSocket = function() { return kind === 'unix_domain_socket'; };
    result.mtime = new Date(result.mtimeMs);
    result.ctime = new Date(result.ctimeMs);
    if (result.atimeMs !== undefined) result.atime = new Date(result.atimeMs);
    return result;
  }
  function syncStat(operation, path, options) {
    options = fsOptions(options, ['bigint', 'throwIfNoEntry']);
    if (booleanFsOption(options, 'bigint')) unsupported('Home filesystem BigInt metadata is unsupported');
    booleanFsOption(options, 'throwIfNoEntry');
    try { return statResult(fsOperation(operation, path, false, false)); }
    catch (error) {
      // Node statSync suppresses ENOTDIR as well as ENOENT when requested;
      // lstatSync preserves ENOTDIR. Never hide permissions, loops or refusals.
      if (options.throwIfNoEntry === false && (error.code === 'ENOENT' || (operation === 'stat' && error.code === 'ENOTDIR'))) return undefined;
      throw error;
    }
  }
  fs.statSync = function(path, options) { return syncStat('stat', path, options); };
  fs.lstatSync = function(path, options) { return syncStat('lstat', path, options); };
  function callbackStat(operation, path, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    if (typeof callback !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'stat callback must be a function');
    path = stringPath(path);
    options = fsOptions(options === null ? undefined : options, ['bigint', 'throwIfNoEntry']);
    if (booleanFsOption(options, 'bigint')) unsupported('Home filesystem BigInt metadata is unsupported');
    booleanFsOption(options, 'throwIfNoEntry');
    const throwIfNoEntry = operation === 'lstat' || options.throwIfNoEntry !== false;
    // Defer the actual POSIX operation on the protected host task queue. This
    // is owner-thread I/O, not a worker pool. Callback throws must reach the
    // host uncaught-exception policy rather than become Promise rejections.
    scheduleFilesystemTask(function() {
      let result, error;
      try { result = syncStat(operation, path, { throwIfNoEntry }); }
      catch (caught) { error = caught; }
      if (error) callback(error);
      else callback(null, result);
    }, 0);
  }
  fs.stat = function(path, options, callback) { callbackStat('stat', path, options, callback); };
  fs.lstat = function(path, options, callback) { callbackStat('lstat', path, options, callback); };
  const fsPromises = {
    constants: fsConstants,
    realpath: async function(path, options) {
      return realPath(path, options, false);
    },
    access: async function(path, mode) {
      accessFile(path, mode);
    },
    readdir: async function(path, options) {
      return readDirectory(path, options);
    },
    appendFile: async function(path, data, options) {
      appendFile(stringPath(path), data, options);
    },
    writeFile: async function(path, data, options) {
      writeFile(stringPath(path), data, options);
    },
    readFile: async function(path, options) {
      const utf8 = readFileOptions(options);
      const hex = fsOperation('readFile', path, false, false).hex;
      return utf8 ? decodeUtf8(hex) : bufferApi.Buffer.from(hex, 'hex');
    },
    rename: async function(source, destination) {
      source = stringPath(source);
      destination = stringPath(destination);
      try { fsOperation('rename', source, destination, false); }
      catch (error) { error.dest = destination; throw error; }
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
      return statResult(fsOperation('stat', path, false, false));
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
    relative: function(from, to) {
      pathString(from);
      pathString(to);
      if (from === to) return '';
      const source = posixPath.resolve(from);
      const target = posixPath.resolve(to);
      if (source === target) return '';
      // Compare whole resolved segments: /foo must not match /foobar.
      const left = source === '/' ? [] : source.slice(1).split('/');
      const right = target === '/' ? [] : target.slice(1).split('/');
      let common = 0;
      while (common < left.length && common < right.length && left[common] === right[common]) common++;
      const result = [];
      for (let index = common; index < left.length; index++) result.push('..');
      for (let index = common; index < right.length; index++) result.push(right[index]);
      return result.join('/');
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
    parse: function(path) {
      pathString(path);
      // Parse lexically: retain directory separators and dot segments rather
      // than resolving them or looking at the host filesystem/cwd.
      const root = path.startsWith('/') ? '/' : '';
      let end = path.length;
      while (end > root.length && path[end - 1] === '/') end--;
      let start = end;
      while (start > root.length && path[start - 1] !== '/') start--;
      const base = path.slice(start, end);
      const dot = base.lastIndexOf('.');
      // Match Node's first absolute `/..` component, whose extension is a dot;
      // relative and nested `..` components instead have no extension.
      const leadingParent = root !== '' && start === root.length && base === '..';
      const ext = dot > 0 && (base !== '..' || leadingParent) ? base.slice(dot) : '';
      return {
        root,
        dir: start > root.length ? path.slice(0, start - 1) : root,
        base,
        ext,
        name: base.slice(0, base.length - ext.length),
      };
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
  const osNativePlatform = osProcess.platform;
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
    tmpdir: function() {
      if (osNativePlatform === 'win32') unsupported('Home os.tmpdir currently implements POSIX environment selection only');
      // Node's POSIX policy is lexical: read these variables each call and
      // remove one trailing separator, without resolving or creating a path.
      // https://nodejs.org/api/os.html#ostmpdir
      const directory = osProcess.env.TMPDIR || osProcess.env.TMP || osProcess.env.TEMP || '/tmp';
      if (typeof directory !== 'string' || directory.indexOf('\0') !== -1) unsupported('Home os.tmpdir requires environment strings without NUL bytes');
      return directory.length > 1 && directory.endsWith('/') ? directory.slice(0, -1) : directory;
    },
  };
  // EOL is platform metadata fixed when the OS module initializes; unlike
  // platform(), later writes to process.platform must not change its value.
  Object.defineProperty(osApi, 'EOL', { value: osProcess.platform === 'win32' ? '\r\n' : '\n', enumerable: true, configurable: true });
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
  const scheduleFilesystemTask = timers.setTimeout;
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
  const nativeIsPromise = globalThis.__home_tool_is_promise;
  const nativeIsProxy = globalThis.__home_tool_is_proxy;
  delete globalThis.__home_tool_is_promise;
  delete globalThis.__home_tool_is_proxy;
  const utilTypes = {
    isPromise: function(value) {
      if (typeof nativeIsPromise !== 'function') unsupported('Home util.types.isPromise requires native engine brand inspection');
      return nativeIsPromise(value);
    },
    isProxy: function(value) {
      if (typeof nativeIsProxy !== 'function') unsupported('Home util.types.isProxy requires native engine brand inspection');
      return nativeIsProxy(value);
    },
  };
  const utilPromise = Promise;
  const utilApply = Reflect.apply;
  const utilPush = Array.prototype.push;
  const utilDefine = Object.defineProperty;
  const utilDescriptors = Object.getOwnPropertyDescriptors;
  const utilDefineProperties = Object.defineProperties;
  const utilGetPrototype = Object.getPrototypeOf;
  const utilSetPrototype = Object.setPrototypeOf;
  const customPromisify = Symbol.for('nodejs.util.promisify.custom');
  function promisify(original) {
    if (typeof original !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'promisify original must be a function');
    if (original[customPromisify]) {
      const custom = original[customPromisify];
      if (typeof custom !== 'function') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'promisify custom must be a function');
      return utilDefine(custom, customPromisify, { __proto__: null, value: custom, writable: false, enumerable: false, configurable: true });
    }
    function wrapped(...args) {
      const receiver = this;
      return new utilPromise(function(resolve, reject) {
        utilApply(utilPush, args, [function(error, value) {
          if (error) reject(error);
          else resolve(value);
        }]);
        utilApply(original, receiver, args);
      });
    }
    utilSetPrototype(wrapped, utilGetPrototype(original));
    utilDefine(wrapped, customPromisify, { __proto__: null, value: wrapped, writable: false, enumerable: false, configurable: true });
    const descriptors = utilDescriptors(original);
    for (const key of Reflect.ownKeys(descriptors)) utilSetPrototype(descriptors[key], null);
    utilDefineProperties(wrapped, descriptors);
    return wrapped;
  }
  promisify.custom = customPromisify;
  const utilApi = {
    promisify,
    types: utilTypes,
    stripVTControlCharacters: function(text) {
      if (typeof text !== 'string') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'stripVTControlCharacters requires a string');
      return stripControls(text, '');
    },
  };
  const assertSameValue = Object.is;
  const assertBaseError = Error;
  class AssertionError extends assertBaseError {
    constructor(options) {
      if (options === null || typeof options !== 'object') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'AssertionError requires an options object');
      if (options.diff !== undefined) unsupported('Home AssertionError does not implement Node diff formatting');
      if (options.message !== undefined && typeof options.message !== 'string') unsupported('Home AssertionError requires a string message');
      const generated = !options.message;
      // Preserve failing values without inspecting user objects or running
      // their conversion hooks. Node source excerpts/diffs are not available.
      const message = options.message !== undefined ? options.message : `Assertion failed (${options.operator || 'assert'})`;
      super(message);
      this.name = 'AssertionError';
      this.code = 'ERR_ASSERTION';
      this.actual = options.actual;
      this.expected = options.expected;
      this.operator = options.operator;
      this.generatedMessage = generated;
    }
    toString() {
      return `${this.name} [${this.code}]: ${this.message}`;
    }
  }
  function assertionFailure(actual, expected, operator, message, extraMessages) {
    if (message instanceof assertBaseError) throw message;
    if (extraMessages || typeof message === 'function') unsupported('Home assertions do not implement lazy or formatted messages');
    if (message !== undefined && typeof message !== 'string') nodeArgumentError('ERR_INVALID_ARG_TYPE', 'Assertion message must be a string or Error');
    const error = new AssertionError({ actual: actual, expected: expected, operator: operator, message: message });
    if (operator === '==' && message !== undefined) error.generatedMessage = false;
    throw error;
  }
  function assertOk(value, message) {
    if (value) return;
    if (arguments.length === 0) {
      const error = new AssertionError({ actual: undefined, expected: true, operator: '==', message: 'No value argument passed to `assert.ok()`' });
      error.generatedMessage = true;
      throw error;
    }
    assertionFailure(value, true, '==', message, arguments.length > 2);
  }
  function assert(value, message) {
    if (arguments.length === 0) return assertOk();
    if (arguments.length > 2) return utilApply(assertOk, undefined, arguments);
    return assertOk(value, message);
  }
  assert.ok = assertOk;
  assert.AssertionError = AssertionError;
  // Node strict assertions use SameValue: NaN equals itself, +0 differs -0.
  // https://nodejs.org/api/assert.html#assertstrictequalactual-expected-message
  assert.strictEqual = function(actual, expected, message) {
    if (arguments.length < 2) nodeArgumentError('ERR_MISSING_ARGS', 'The actual and expected arguments must be specified');
    if (!assertSameValue(actual, expected)) assertionFailure(actual, expected, 'strictEqual', message, arguments.length > 3);
  };
  assert.notStrictEqual = function(actual, expected, message) {
    if (arguments.length < 2) nodeArgumentError('ERR_MISSING_ARGS', 'The actual and expected arguments must be specified');
    if (assertSameValue(actual, expected)) assertionFailure(actual, expected, 'notStrictEqual', message, arguments.length > 3);
  };
  builtins.assert = assert;
  builtins['node:assert'] = assert;
  builtins.constants = legacyConstants;
  builtins['node:constants'] = legacyConstants;
  builtins.util = utilApi;
  builtins.zlib = zlibApi;
  builtins['node:zlib'] = zlibApi;
  builtins['node:util'] = utilApi;
  builtins['util/types'] = utilTypes;
  builtins['node:util/types'] = utilTypes;
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
  const perfHooks = { performance: globalThis.performance, Performance: globalThis.Performance, PerformanceEntry: globalThis.PerformanceEntry, PerformanceMark: globalThis.PerformanceMark };
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
  const spawnFactory = globalThis.__home_tool_spawn_factory;
  const nativeChild = globalThis.__home_tool_child;
  delete globalThis.__home_tool_spawn_factory;
  delete globalThis.__home_tool_child;
  const writeParent = posixPath.dirname;
  async function write(path, data, options) {
    path = stringPath(path);
    if (typeof data !== 'string' && !fsIsView(data)) unsupported('Home Bun.write supports pathname destinations and string or ArrayBuffer view data only');
    options = fsOptions(options, ['createPath']);
    if (options.createPath !== undefined && typeof options.createPath !== 'boolean') throw new TypeError('Expected boolean createPath');
    if (data instanceof fsDataView) data = new fsBytes(fsViewBuffer.call(data), fsViewOffset.call(data), fsViewLength.call(data));
    if (options.createPath !== false) fsOperation('mkdir', writeParent(path), true, false, 0o777);
    // Acknowledgement follows actual POSIX write-all and close. The byte count
    // comes from that native operation, independent of public Buffer methods.
    const result = fsOperation('writeFile', path, data, 'w', 0o664);
    if (!Number.isSafeInteger(result.bytesWritten) || result.bytesWritten < 0) throw new Error('Native write returned no byte count');
    return result.bytesWritten;
  }
  const bunApi = { write, spawn: spawnFactory(nativeChild, timers), markdown: markdownApi, Glob: globFactory(nativeGlob), YAML: { parse: Home.parseYAML }, file: fileFactory(fsOperation, bufferApi.Buffer) };
  Object.defineProperty(bunApi, 'env', { value: process.env, enumerable: true });
  Object.defineProperty(bunApi, 'argv', { value: process.argv, writable: true, enumerable: true, configurable: false });
  globalThis.Bun = bunApi;
  builtins.bun = bunApi;
  globalThis.__home_tool_builtins = builtins;
})();
