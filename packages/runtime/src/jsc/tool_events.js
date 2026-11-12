// Synchronous EventEmitter semantics for Home's repository-tool realm.
(function() {
  'use strict';
  const own = Object.prototype.hasOwnProperty;
  const errorMonitor = Symbol('events.errorMonitor');
  let defaultMaxListeners = 10;
  function argumentError(message) {
    const error = new TypeError(message);
    error.code = 'ERR_INVALID_ARG_TYPE';
    throw error;
  }
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function checkListener(listener) {
    if (typeof listener !== 'function') argumentError('The listener must be a function');
  }
  function checkMaximum(value) {
    if (typeof value !== 'number') argumentError('The maximum must be a number');
    if (Number.isNaN(value) || value < 0) {
      const error = new RangeError('The maximum must be non-negative');
      error.code = 'ERR_OUT_OF_RANGE';
      throw error;
    }
  }
  function keyFor(type) {
    return typeof type === 'symbol' ? type : String(type);
  }
  function eventsFor(emitter) {
    if (!own.call(emitter, '_events') || !emitter._events) {
      emitter._events = Object.create(null);
      emitter._eventsCount = 0;
    }
    return emitter._events;
  }
  function maximumFor(emitter) {
    return emitter._maxListeners === undefined ? defaultMaxListeners : emitter._maxListeners;
  }
  function EventEmitter(options) {
    if (options && options.captureRejections !== undefined) {
      if (typeof options.captureRejections !== 'boolean') argumentError('captureRejections must be boolean');
      if (options.captureRejections) unsupported('Home EventEmitter captureRejections is not implemented');
    }
    eventsFor(this);
  }
  function add(emitter, type, listener, prepend) {
    checkListener(listener);
    let events = eventsFor(emitter);
    const key = keyFor(type);
    if (events.newListener && events.newListener.length) {
      emitter.emit('newListener', type, listener.listener || listener);
      // A newListener callback can replace the event table.
      events = eventsFor(emitter);
    }
    let listeners = events[key];
    if (!listeners) {
      listeners = events[key] = [];
      emitter._eventsCount++;
    }
    if (prepend) listeners.unshift(listener);
    else listeners.push(listener);
    const maximum = maximumFor(emitter);
    if (maximum > 0 && listeners.length > 1 && listeners.length > maximum && !listeners.warned) {
      listeners.warned = true;
      const warning = new Error(`Possible EventEmitter memory leak detected: ${listeners.length} ${String(type)} listeners`);
      warning.name = 'MaxListenersExceededWarning';
      warning.emitter = emitter;
      warning.type = type;
      warning.count = listeners.length;
      process.emitWarning(warning);
    }
    return emitter;
  }
  function addOnce(emitter, type, listener, prepend) {
    checkListener(listener);
    let fired = false;
    function onceWrapper(...args) {
      // Remove before invocation, and guard snapshots/manual wrapper calls
      // against firing this registration twice under reentrant emit().
      if (fired) return;
      fired = true;
      emitter.removeListener(type, onceWrapper);
      return listener.apply(emitter, args);
    }
    onceWrapper.listener = listener;
    if (prepend) emitter.prependListener(type, onceWrapper);
    else emitter.on(type, onceWrapper);
    return emitter;
  }
  EventEmitter.prototype.addListener = function(type, listener) {
    return add(this, type, listener, false);
  };
  EventEmitter.prototype.on = EventEmitter.prototype.addListener;
  EventEmitter.prototype.prependListener = function(type, listener) {
    return add(this, type, listener, true);
  };
  EventEmitter.prototype.once = function(type, listener) {
    return addOnce(this, type, listener, false);
  };
  EventEmitter.prototype.prependOnceListener = function(type, listener) {
    return addOnce(this, type, listener, true);
  };
  EventEmitter.prototype.emit = function(type, ...args) {
    const events = eventsFor(this);
    const key = keyFor(type);
    if (key === 'error' && events[errorMonitor]) this.emit(errorMonitor, ...args);
    const listeners = eventsFor(this)[key];
    if (!listeners || !listeners.length) {
      if (key === 'error') {
        if (args[0] instanceof Error) throw args[0];
        const error = new Error('Unhandled error event');
        error.code = 'ERR_UNHANDLED_ERROR';
        error.context = args[0];
        throw error;
      }
      return false;
    }
    // Event dispatch sees the registration snapshot even when callbacks add
    // or remove listeners. Exceptions and arbitrary thrown values propagate.
    for (const listener of listeners.slice()) listener.apply(this, args);
    return true;
  };
  EventEmitter.prototype.removeListener = function(type, listener) {
    checkListener(listener);
    const events = eventsFor(this);
    const key = keyFor(type);
    const listeners = events[key];
    if (!listeners) return this;
    for (let index = listeners.length - 1; index >= 0; index--) {
      const removed = listeners[index];
      if (removed !== listener && removed.listener !== listener) continue;
      listeners.splice(index, 1);
      if (!listeners.length) {
        delete events[key];
        this._eventsCount--;
      }
      if (events.removeListener && events.removeListener.length) this.emit('removeListener', type, removed.listener || removed);
      break;
    }
    return this;
  };
  EventEmitter.prototype.off = EventEmitter.prototype.removeListener;
  EventEmitter.prototype.removeAllListeners = function(type) {
    const events = eventsFor(this);
    if (arguments.length === 0) {
      for (const key of Reflect.ownKeys(events)) {
        if (key !== 'removeListener') this.removeAllListeners(key);
      }
      this.removeAllListeners('removeListener');
      this._events = Object.create(null);
      this._eventsCount = 0;
    }
    else {
      const listeners = events[keyFor(type)];
      if (listeners) {
        for (const listener of listeners.slice().reverse()) this.removeListener(type, listener);
      }
    }
    return this;
  };
  EventEmitter.prototype.rawListeners = function(type) {
    const listeners = eventsFor(this)[keyFor(type)];
    return listeners ? listeners.slice() : [];
  };
  EventEmitter.prototype.listeners = function(type) {
    const listeners = eventsFor(this)[keyFor(type)] || [];
    return listeners.map(function(listener) {
      return listener.listener || listener;
    });
  };
  EventEmitter.prototype.listenerCount = function(type, listener) {
    const listeners = eventsFor(this)[keyFor(type)] || [];
    if (listener === undefined || listener === null) return listeners.length;
    return listeners.filter(function(candidate) {
      return candidate === listener || candidate.listener === listener;
    }).length;
  };
  EventEmitter.prototype.eventNames = function() {
    return Reflect.ownKeys(eventsFor(this));
  };
  EventEmitter.prototype.setMaxListeners = function(value) {
    checkMaximum(value);
    this._maxListeners = value;
    return this;
  };
  EventEmitter.prototype.getMaxListeners = function() {
    return maximumFor(this);
  };
  Object.defineProperty(EventEmitter, 'defaultMaxListeners', {
    enumerable: true,
    get: function() {
      return defaultMaxListeners;
    },
    set: function(value) {
      checkMaximum(value);
      defaultMaxListeners = value;
    },
  });
  Object.defineProperty(EventEmitter, 'captureRejections', {
    enumerable: true,
    get: function() {
      return false;
    },
    set: function(value) {
      if (typeof value !== 'boolean') argumentError('captureRejections must be boolean');
      if (value) unsupported('Home EventEmitter captureRejections is not implemented');
    },
  });
  EventEmitter.EventEmitter = EventEmitter;
  EventEmitter.errorMonitor = errorMonitor;
  // The native bootstrap already owns the default warning reporter. Preserve
  // those listeners when replacing its minimal emitter, before any user code.
  const target = globalThis.process;
  const warningListeners = target.listeners('warning');
  EventEmitter.call(target);
  Object.setPrototypeOf(target, EventEmitter.prototype);
  for (const method of ['on', 'addListener', 'prependListener', 'once', 'prependOnceListener', 'off', 'removeListener', 'removeAllListeners', 'emit', 'listeners', 'rawListeners', 'listenerCount', 'eventNames', 'setMaxListeners', 'getMaxListeners']) {
    target[method] = EventEmitter.prototype[method];
  }
  for (const listener of warningListeners) target.on('warning', listener);
  globalThis.__home_tool_events = EventEmitter;
})();
