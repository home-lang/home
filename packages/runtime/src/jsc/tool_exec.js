// Real bounded pipes are implemented by the native owner-context child host.
globalThis.__home_tool_exec_factory = function(native, Buffer, inherited) {
  'use strict';
  const encode = JSON.stringify;
  const apply = Reflect.apply;
  const from = Buffer.from;
  const toString = Buffer.prototype.toString;
  const join = Array.prototype.join;
  const Process = process;
  const maxBytes = 32 * 1024 * 1024;
  function invalid(message, code = 'ERR_INVALID_ARG_TYPE') {
    const error = new TypeError(message); error.code = code; throw error;
  }
  function unsupported(message) {
    const error = new Error(message); error.code = 'ERR_HOME_UNSUPPORTED'; throw error;
  }
  function string(value, label) {
    if (typeof value !== 'string') invalid(`${label} must be a string`);
    if (value.includes('\0')) invalid(`${label} cannot contain NUL`, 'ERR_INVALID_ARG_VALUE');
    return value;
  }
  function bytes(...args) { return apply(from, Buffer, args); }
  function capture(file, args, options, displayCommand) {
    if (args === undefined || args === null) args = [];
    else if (!Array.isArray(args)) { options = args; args = []; }
    if (options === undefined || options === null) options = {};
    if (typeof options !== 'object' || Array.isArray(options)) invalid('Options must be an object');
    file = string(file, 'Executable');
    if (Process.platform === 'win32' || !file.startsWith('/')) unsupported('Home execFileSync currently requires an absolute POSIX executable path');
    if (args.length > 4095) unsupported('Too many subprocess arguments');
    const checked = [];
    for (let index = 0; index < args.length; index++) checked.push(string(args[index], 'Argument'));
    args = checked;
    if (options.stdio === 'inherit') return inherited(file, args, options);
    if (options.stdio !== undefined && options.stdio !== null && options.stdio !== 'pipe') unsupported('Home captured execFileSync requires pipe stdio');
    for (const key of Object.keys(options)) {
      if (!['stdio', 'cwd', 'env', 'input', 'maxBuffer', 'encoding', 'windowsHide'].includes(key)) unsupported(`Unsupported Home captured execFileSync option: ${key}`);
    }
    if (options.windowsHide !== undefined && typeof options.windowsHide !== 'boolean') invalid('windowsHide must be a boolean');
    const cwd = options.cwd === undefined ? null : string(options.cwd, 'cwd');
    const encoding = options.encoding == null ? 'buffer' : options.encoding;
    if (typeof encoding !== 'string') invalid('encoding must be a string');
    const normalized = encoding.toLowerCase();
    if (!['buffer', 'utf8', 'utf-8'].includes(normalized)) unsupported('Home captured execFileSync supports Buffer or UTF-8 output');
    const maximum = options.maxBuffer === undefined ? 1024 * 1024 : options.maxBuffer;
    if (typeof maximum !== 'number' || !Number.isSafeInteger(maximum) || maximum < 0) invalid('maxBuffer must be a non-negative safe integer', 'ERR_OUT_OF_RANGE');
    if (maximum > maxBytes) unsupported('Home captured output is bounded to 32 MiB per stream');
    let input;
    if (options.input == null) input = bytes('');
    else if (typeof options.input === 'string') {
      if (options.encoding != null && normalized === 'buffer') invalid('Unknown string input encoding: buffer', 'ERR_UNKNOWN_ENCODING');
      input = bytes(options.input, 'utf8');
    }
    else if (ArrayBuffer.isView(options.input)) input = bytes(options.input.buffer, options.input.byteOffset, options.input.byteLength);
    else invalid('input must be a string or binary view');
    if (input.byteLength > maxBytes) unsupported('Home captured input is bounded to 32 MiB');
    const env = options.env == null ? Process.env : options.env;
    if (!env || typeof env !== 'object') invalid('env must be an object');
    const keys = [], values = [];
    for (const key of Object.keys(env)) {
      string(key, 'Environment key');
      if (!key || key.includes('=')) invalid('Invalid environment key', 'ERR_INVALID_ARG_VALUE');
      if (env[key] !== undefined) { keys.push(key); values.push(string(String(env[key]), 'Environment value')); }
    }
    const result = native(encode({ op: 'exec_file', argv: [file, ...args], cwd, keys, values, max_buffer: maximum, mirror_stderr: options.stdio == null }), input);
    if (!result) throw new Error('Native captured subprocess operation failed');
    const stdout = result.stdoutBytes && ArrayBuffer.isView(result.stdoutBytes) ? bytes(result.stdoutBytes) : null;
    const stderr = result.stderrBytes && ArrayBuffer.isView(result.stderrBytes) ? bytes(result.stderrBytes) : null;
    const decode = value => value === null || normalized === 'buffer' ? value : apply(toString, value, ['utf8']);
    if (result.error || result.status !== 0 || result.signal !== null) {
      let message;
      if (result.error) message = `Command failed: ${file}${result.detail ? ` (${result.detail})` : ''}`;
      else {
        // Like Node, error.message carries the original command and the
        // captured UTF-8 stderr even when callers only stringify the error.
        // Retain the original status, signal and raw output on the error.
        const command = displayCommand === undefined ? file + (args.length ? ' ' + apply(join, args, [' ']) : '') : displayCommand;
        message = `Command failed: ${command}`;
        if (stderr !== null && stderr.byteLength) message += '\n' + apply(toString, stderr, ['utf8']);
      }
      const error = new Error(message);
      if (result.error) error.code = result.error;
      if (result.errno !== undefined) error.errno = result.errno;
      if (result.pid !== undefined) error.pid = result.pid;
      error.status = result.status ?? null;
      error.signal = result.signal ?? null;
      error.stdout = decode(stdout); error.stderr = decode(stderr);
      error.output = [null, error.stdout, error.stderr];
      error.syscall = `spawnSync ${file}`; error.path = file; error.spawnargs = args.slice();
      throw error;
    }
    if (stdout === null || stderr === null) throw new Error('Native captured output was not returned');
    return decode(stdout);
  }
  function execFileSync(file, args, options) {
    return capture(file, args, options);
  }
  function execSync(command, options) {
    command = string(command, 'Command');
    if (options == null) options = {};
    if (typeof options !== 'object' || Array.isArray(options)) invalid('Options must be an object');
    const forwarded = {};
    for (const key of Object.keys(options)) {
      if (key !== 'shell') forwarded[key] = options[key];
    }
    const selected = options.shell;
    if (selected != null && typeof selected !== 'string' && typeof selected !== 'boolean') unsupported('Home execSync shell must be a POSIX executable path or boolean');
    // Node execSync always invokes a shell, including when shell is false.
    // Pass the command intact so quoting, redirections and expansion belong
    // to the real shell; execFileSync remains the literal argv API.
    const shell = typeof selected === 'string' ? selected : '/bin/sh';
    return capture(shell, ['-c', command], forwarded, command);
  }
  function spawnSync(file, args, options) {
    file = string(file, 'Executable');
    if (!file) invalid('Executable cannot be empty', 'ERR_INVALID_ARG_VALUE');
    if (args == null) args = [];
    else if (!Array.isArray(args)) {
      if (typeof args !== 'object') invalid('Arguments must be an array');
      options = args; args = [];
    }
    if (options == null) options = {};
    if (typeof options !== 'object' || Array.isArray(options)) invalid('Options must be an object');
    if (Process.platform === 'win32') unsupported('Home spawnSync currently requires POSIX');
    if (args.length > 4095) unsupported('Too many subprocess arguments');
    args = args.map(value => string(value, 'Argument'));
    for (const key of Object.keys(options)) {
      if (!['stdio', 'cwd', 'env', 'input', 'maxBuffer', 'encoding', 'windowsHide', 'timeout', 'shell'].includes(key)) unsupported(`Unsupported Home spawnSync option: ${key}`);
    }
    if (options.shell !== undefined && options.shell !== false) unsupported('Home spawnSync currently requires literal argv without a shell');
    if (options.timeout !== undefined && options.timeout !== 0) unsupported('Home spawnSync child timeouts are not implemented');
    if (options.windowsHide !== undefined && typeof options.windowsHide !== 'boolean') invalid('windowsHide must be a boolean');
    let stdio = options.stdio;
    if (stdio == null) stdio = ['pipe', 'pipe', 'pipe'];
    else if (typeof stdio === 'string') stdio = [stdio, stdio, stdio];
    else if (Array.isArray(stdio) && stdio.length <= 3) stdio = [stdio[0] ?? 'pipe', stdio[1] ?? 'pipe', stdio[2] ?? 'pipe'];
    else unsupported('Home spawnSync supports three pipe/ignore/inherit descriptors');
    if (stdio.some(mode => !['pipe', 'ignore', 'inherit'].includes(mode))) unsupported('Home spawnSync supports pipe/ignore/inherit descriptors only');
    const encoding = options.encoding == null ? 'buffer' : options.encoding;
    if (typeof encoding !== 'string') invalid('encoding must be a string');
    const normalized = encoding.toLowerCase();
    if (!['buffer', 'utf8', 'utf-8'].includes(normalized)) unsupported('Home spawnSync supports Buffer or UTF-8 output');
    const maximum = options.maxBuffer === undefined ? 1024 * 1024 : options.maxBuffer;
    if (typeof maximum !== 'number' || !Number.isSafeInteger(maximum) || maximum < 0) invalid('maxBuffer must be a non-negative safe integer', 'ERR_OUT_OF_RANGE');
    if (maximum > maxBytes) unsupported('Home captured output is bounded to 32 MiB per stream');
    let input;
    if (options.input == null) input = bytes('');
    else if (stdio[0] !== 'pipe') unsupported('Home spawnSync input requires a pipe');
    else if (typeof options.input === 'string') {
      if (options.encoding != null && normalized === 'buffer') invalid('Unknown string input encoding: buffer', 'ERR_UNKNOWN_ENCODING');
      input = bytes(options.input, 'utf8');
    }
    else if (ArrayBuffer.isView(options.input)) input = bytes(options.input.buffer, options.input.byteOffset, options.input.byteLength);
    else invalid('input must be a string or binary view');
    if (input.byteLength > maxBytes) unsupported('Home captured input is bounded to 32 MiB');
    const env = options.env == null ? Process.env : options.env;
    if (!env || typeof env !== 'object') invalid('env must be an object');
    const keys = [], values = [];
    for (const key of Object.keys(env)) {
      string(key, 'Environment key');
      if (!key || key.includes('=')) invalid('Invalid environment key', 'ERR_INVALID_ARG_VALUE');
      if (env[key] !== undefined) { keys.push(key); values.push(string(String(env[key]), 'Environment value')); }
    }
    const cwd = options.cwd == null ? null : string(options.cwd, 'cwd');
    const captured = native(encode({op: 'spawn_sync', argv: [file, ...args], cwd, keys, values, stdio, max_buffer: maximum}), input);
    if (!captured) throw new Error('Native synchronous subprocess operation failed');
    const decode = value => {
      if (!value || !ArrayBuffer.isView(value)) return null;
      const buffer = bytes(value);
      return normalized === 'buffer' ? buffer : apply(toString, buffer, ['utf8']);
    };
    const started = typeof captured.pid === 'number' && captured.pid > 0;
    const stdout = started ? decode(captured.stdoutBytes) : undefined;
    const stderr = started ? decode(captured.stderrBytes) : undefined;
    const result = {pid: started ? captured.pid : 0, output: started ? [null, stdout, stderr] : null,
      stdout, stderr, status: captured.status ?? null, signal: captured.signal ?? null};
    if (captured.error) {
      const error = new Error(`spawnSync ${file} ${captured.error}`);
      error.code = captured.error;
      if (captured.errno !== undefined) error.errno = captured.errno;
      error.syscall = `spawnSync ${file}`;
      error.path = file;
      error.spawnargs = args.slice();
      result.error = error;
    }
    return result;
  }
  return { execFileSync, execSync, spawnSync };
};
