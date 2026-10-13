// Hardcoded module "node:inspector" and "node:inspector/promises"
// Profiler APIs are implemented; other inspector APIs are stubs.
const { hideFromStack, throwNotImplemented } = require("internal/shared");
const EventEmitter = require("node:events");

const binding = $cpp("JS2Native.cpp", "Home::createInspectorBinding");
const { validateString, validateObject, validateFunction } = require("internal/validators");
function inspectorError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function open() {
  throwNotImplemented("node:inspector", 2445);
}

function close() {
  throwNotImplemented("node:inspector", 2445);
}

function url() {
  // Return undefined since that is allowed by the Node.js API
  // https://nodejs.org/api/inspector.html#inspectorurl
  return undefined;
}

function waitForDebugger() {
  throwNotImplemented("node:inspector", 2445);
}

class Session extends EventEmitter {
  #connection = null;
  #nextId = 1;
  #callbacks = new Map();
  connect() {
    if (this.#connection) throw inspectorError("ERR_INSPECTOR_ALREADY_CONNECTED", "The inspector session is already connected");
    this.#connection = binding.connect(message => this.#onMessage(message));
  }
  connectToMainThread() {
    const { isMainThread } = require("node:worker_threads");
    if (isMainThread) return this.connect();
    throw inspectorError("ERR_NOT_IMPLEMENTED", "Main-thread inspector attachment is not implemented");
  }
  #onMessage(message) {
    const parsed = JSON.parse(message);
    try {
      if (parsed.id) {
        const callback = this.#callbacks.get(parsed.id);
        this.#callbacks.delete(parsed.id);
        if (callback) {
          if (parsed.error) callback(inspectorError("ERR_INSPECTOR_COMMAND", `Inspector error ${parsed.error.code}: ${parsed.error.message}`));
          else callback(null, parsed.result);
        }
      } else {
        this.emit(parsed.method, parsed);
        this.emit("inspectorNotification", parsed);
      }
    } catch (error) {
      process.emitWarning(error);
    }
  }
  post(method, params, callback) {
    validateString(method, "method");
    if (!callback && typeof params === "function") { callback = params; params = null; }
    if (params) validateObject(params, "params");
    if (callback) validateFunction(callback, "callback");
    if (!this.#connection) {
      const error = inspectorError("ERR_INSPECTOR_NOT_CONNECTED", "Session is not connected");
      if (callback) { queueMicrotask(() => callback(error)); return; }
      throw error;
    }
    const id = this.#nextId++;
    const message = { id, method };
    if (params) message.params = params;
    // Preserve Bun's synchronous result extension when the native command
    // completes during dispatch; async commands keep the callback contract.
    let completed = false;
    let commandError;
    let commandResult;
    this.#callbacks.set(id, callback || ((error, result) => {
      completed = true;
      commandError = error;
      commandResult = result;
    }));
    binding.dispatch(this.#connection, JSON.stringify(message));
    if (!callback && completed) {
      if (commandError) throw commandError;
      return commandResult;
    }
  }
  disconnect() {
    if (!this.#connection) return;
    const connection = this.#connection;
    binding.disconnect(connection);
    this.#connection = null;
    for (const callback of this.#callbacks.values()) process.nextTick(callback, inspectorError("ERR_INSPECTOR_CLOSED", "Session was closed"));
    this.#callbacks.clear();
    this.#nextId = 1;
  }
}

const console = {
  ...globalThis.console,
  context: {
    console: globalThis.console,
  },
};

export default {
  console,
  open,
  close,
  url,
  waitForDebugger,
  Session,
};

hideFromStack(open, close, url, waitForDebugger, Session.prototype.constructor);
