// Native asynchronous children. The existing kernel timer queue performs
// bounded waitpid(WNOHANG) checks; no JS callback waits for a running child.
globalThis.__home_tool_spawn_factory = function(native, timers) {
  'use strict';
  const encode = JSON.stringify;
  const PromiseCtor = Promise;
  const setInterval = timers.setInterval;
  const clearInterval = timers.clearInterval;
  function invalid(message) {
    throw new TypeError(message);
  }
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function call(request) {
    const result = native(encode(request));
    if (!result || result.error) {
      const error = new Error(`Cannot ${request.op} child process: ${result?.detail || 'native failure'}`);
      error.code = result?.error || 'ERR_HOME_CHILD_PROCESS';
      throw error;
    }
    return result;
  }
  function string(value, name) {
    if (typeof value !== 'string' || value.includes('\0')) invalid(`${name} must be a string without NUL`);
    return value;
  }
  return function spawn(argv, options = {}) {
    if (!Array.isArray(argv) || argv.length === 0 || argv.length > 4096) invalid('spawn requires a nonempty argv array');
    argv = argv.map(arg => string(arg, 'argument'));
    if (!argv[0]) invalid('Executable cannot be empty');
    if (options === null || typeof options !== 'object') invalid('spawn options must be an object');
    for (const key of Object.keys(options)) {
      if (!['cwd', 'env', 'stdin', 'stdout', 'stderr', 'onExit'].includes(key)) unsupported(`Unsupported Home spawn option: ${key}`);
    }
    const cwd = options.cwd === undefined ? null : string(options.cwd, 'cwd');
    const onExit = options.onExit;
    if (onExit !== undefined && typeof onExit !== 'function') invalid('onExit must be a function');
    // Bun defaults stdout to a pipe. Refuse that default until real pipe
    // streams are implemented instead of silently discarding child output.
    const modes = [options.stdin ?? 'ignore', options.stdout ?? 'pipe', options.stderr ?? 'inherit'];
    for (const mode of modes) {
      if (mode !== 'inherit' && mode !== 'ignore') unsupported('Home spawn currently supports inherited or ignored stdio only');
    }
    const env = options.env === undefined ? process.env : options.env;
    if (!env || typeof env !== 'object') invalid('env must be an object');
    const keys = [], values = [];
    for (const key of Object.keys(env)) {
      string(key, 'environment key');
      if (!key || key.includes('=')) invalid('Invalid environment key');
      if (env[key] !== undefined) {
        keys.push(key);
        values.push(string(String(env[key]), 'environment value'));
      }
    }
    const request = { op: 'spawn', argv, cwd, keys, values, inherit: modes.map(mode => mode === 'inherit') };
    const started = call(request);
    let exitCode = null, signalCode = null, done = false, resolve, reject;
    const exited = new PromiseCtor((yes, no) => {
      resolve = yes;
      reject = no;
    });
    const child = {
      pid: started.pid, stdin: undefined, stdout: undefined, stderr: undefined, exited,
      get exitCode() {
        return exitCode;
      },
      get signalCode() {
        return signalCode;
      },
      kill(signal = 'SIGTERM') {
        if (done) return;
        if (typeof signal !== 'string' || !signal.startsWith('SIG')) unsupported('Home child.kill currently requires a signal name');
        call({ op: 'kill', id: started.id, signal: signal.slice(3) });
      },
      ref() {
        watcher.ref();
      },
      unref() {
        unsupported('Home child.unref lifetime semantics are not implemented');
      },
    };
    let watcher;
    try {
      watcher = setInterval(() => {
        let result;
        try {
          result = call({ op: 'poll', id: started.id });
        }
        catch (error) {
          done = true;
          clearInterval(watcher);
          call({ op: 'close', id: started.id });
          reject(error);
          if (onExit) onExit(child, null, null, error);
          return;
        }
        if (!result.done) return;
        done = true;
        clearInterval(watcher);
        exitCode = result.exitCode ?? null;
        signalCode = result.signalCode ?? null;
        resolve(exitCode ?? 128 + result.signalNumber);
        if (onExit) onExit(child, exitCode, signalCode, undefined);
      }, 5);
    }
    catch (error) {
      call({ op: 'close', id: started.id });
      throw error;
    }
    return child;
  };
};
