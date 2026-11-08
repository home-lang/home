// Managed Node stream data flow for repository tools. Native file/terminal
// adapters are separate capabilities, not emulated by successful empty writes.
globalThis.__home_tool_streams_factory = function(EventEmitter, Buffer) {
  'use strict';
  const readers = new WeakMap();
  const writers = new WeakMap();
  const lives = new WeakMap();
  const transforms = new WeakMap();
  const tick = process.nextTick.bind(process);
  function deferCallback(callback, ...args) {
    tick(() => callback(...args));
  }
  function error(code, message) {
    const Type = ['ERR_INVALID_ARG_TYPE', 'ERR_INVALID_ARG_VALUE', 'ERR_STREAM_NULL_VALUES', 'ERR_MISSING_ARGS'].includes(code) ? TypeError : Error;
    const failure = new Type(message);
    failure.code = code;
    return failure;
  }
  function unsupported(message) {
    throw error('ERR_HOME_UNSUPPORTED', message);
  }
  function optionsFor(options) {
    if (options === undefined || options === null)
      return {
    };
    if (typeof options !== 'object' || Array.isArray(options))
      throw new TypeError('Expected stream options');
    const supported = ['read', 'write', 'final', 'destroy', 'transform', 'flush', 'objectMode', 'readableObjectMode', 'writableObjectMode', 'highWaterMark', 'readableHighWaterMark', 'writableHighWaterMark', 'allowHalfOpen'];
    for (const key of Object.keys(options)) {
      if (!supported.includes(key))
        unsupported(`Unsupported Home stream option: ${key}`);
    }
    for (const key of ['read', 'write', 'final', 'destroy', 'transform', 'flush']) {
      if (options[key] !== undefined && typeof options[key] !== 'function')
        throw new TypeError(`Expected function ${key}`);
    }
    for (const key of ['objectMode', 'readableObjectMode', 'writableObjectMode', 'allowHalfOpen']) {
      if (options[key] !== undefined && typeof options[key] !== 'boolean')
        throw new TypeError(`Expected boolean ${key}`);
    }
    return options;
  }
  function watermark(options, side, objectMode) {
    const size = options[`${side}HighWaterMark`] === undefined ? options.highWaterMark : options[`${side}HighWaterMark`];
    if (size === undefined)
      return objectMode ? 16 : 65536;
    if (!Number.isInteger(size) || size < 0)
      throw error('ERR_INVALID_ARG_VALUE', 'highWaterMark must be a non-negative integer');
    return size;
  }
  function life(stream) {
    const state = lives.get(stream);
    if (!state)
      throw new TypeError('Expected an owned Home stream');
    return state;
  }
  function Stream() {
    EventEmitter.call(this);
    lives.set(this, {
      destroyed: false, closed: false, error: null, closeWaiters: []
    });
  }
  Object.setPrototypeOf(Stream.prototype, EventEmitter.prototype);
  Object.setPrototypeOf(Stream, EventEmitter);
  function property(prototype, name, get) {
    Object.defineProperty(prototype, name, {
      configurable: true, get
    });
  }
  property(Stream.prototype, 'destroyed', function() {
    return life(this).destroyed;
  });
  property(Stream.prototype, 'closed', function() {
    return life(this).closed;
  });
  property(Stream.prototype, 'errored', function() {
    return life(this).error;
  });
  Stream.prototype._destroy = function(failure, callback) {
    callback(failure);
  };
  Stream.prototype.destroy = function(failure) {
    const state = life(this);
    if (state.destroyed)
      return this;
    state.destroyed = true;
    if (failure && state.error === null)
      state.error = failure;
    const writer = writers.get(this);
    if (writer) {
      const pending = writer.queue.splice(0);
      for (const item of pending) {
        writer.length -= item.length;
        if (item.callback)
          deferCallback(item.callback, failure || error('ERR_STREAM_DESTROYED', 'Stream was destroyed'));
      }
      for (const callback of writer.endCallbacks.splice(0))
        deferCallback(callback, failure || error('ERR_STREAM_DESTROYED', 'Stream was destroyed'));
    }
    let called = false;
    const stream = this;
    function done(cleanupError) {
      if (called)
        return;
      called = true;
      if (cleanupError && state.error === null)
        state.error = cleanupError;
      tick(function() {
        try {
          if (state.error !== null)
            stream.emit('error', state.error);
        }
        finally {
          state.closed = true;
          stream.emit('close');
          for (const notify of state.closeWaiters.splice(0))
            notify();
        }
      });
    }
    try {
      this._destroy(failure || null, done);
    }
    catch (thrown) {
      done(thrown || error('ERR_HOME_STREAM_ABRUPT', '_destroy threw a falsy value'));
    }
    return this;
  };
  function autoDestroy(stream) {
    const reader = readers.get(stream), writer = writers.get(stream);
    if ((!reader || reader.endEmitted) && (!writer || writer.finished))
      stream.destroy();
  }
  function bytes(chunk, encoding) {
    if (typeof chunk === 'string')
      return Buffer.from(chunk, encoding === undefined ? 'utf8' : encoding);
    if (ArrayBuffer.isView(chunk) && chunk instanceof Uint8Array)
      return Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    if (ArrayBuffer.isView(chunk))
      unsupported('Home binary stream chunks currently require Uint8Array/Buffer views');
    throw error('ERR_INVALID_ARG_TYPE', 'Expected a string, Buffer or Uint8Array chunk');
  }
  function scheduleRead(stream) {
    const state = readers.get(stream);
    if (!state || state.scheduled || life(stream).destroyed)
      return;
    state.scheduled = true;
    tick(function() {
      state.scheduled = false;
      pumpRead(stream);
    });
  }
  function requestRead(stream) {
    const state = readers.get(stream);
    if (state.reading || state.eof || life(stream).destroyed)
      return;
    state.reading = true;
    try {
      stream._read(state.highWaterMark);
    }
    catch (thrown) {
      stream.destroy(thrown || error('ERR_HOME_STREAM_ABRUPT', '_read threw a falsy value'));
    }
  }
  function endReadable(stream) {
    const state = readers.get(stream);
    if (!state.eof || state.queue.length || !state.demand || state.endEmitted || life(stream).destroyed)
      return;
    state.endEmitted = true;
    stream.emit('end');
    const writer = writers.get(stream);
    if (writer && !state.allowHalfOpen && !writer.ending)
      stream.end();
    autoDestroy(stream);
  }
  function pumpRead(stream) {
    const state = readers.get(stream);
    if (life(stream).destroyed)
      return;
    while (state.flowing && state.queue.length && !life(stream).destroyed) {
      const chunk = state.queue.shift();
      state.length -= state.objectMode ? 1 : chunk.byteLength;
      stream.emit('data', chunk);
    }
    if (state.eof)
      endReadable(stream);
    else if (state.flowing && !state.queue.length)
      requestRead(stream);
  }
  function Readable(options) {
    if (!this || !(this instanceof Stream))
      return new Readable(options);
    options = optionsFor(options);
    Stream.call(this);
    const objectMode = options.objectMode === true || options.readableObjectMode === true;
    readers.set(this, {
      queue: [], length: 0, objectMode, highWaterMark: watermark(options, 'readable', objectMode), flowing: null, eof: false, endEmitted: false, reading: false, scheduled: false, notified: false, demand: false, allowHalfOpen: options.allowHalfOpen !== false
    });
    if (options.read)
      this._read = options.read;
    if (options.destroy)
      this._destroy = options.destroy;
  }
  Object.setPrototypeOf(Readable.prototype, Stream.prototype);
  Object.setPrototypeOf(Readable, Stream);
  Readable.prototype._read = function() {
    throw error('ERR_METHOD_NOT_IMPLEMENTED', '_read() is not implemented');
  };
  Readable.prototype.push = function(chunk, encoding) {
    const state = readers.get(this);
    if (life(this).destroyed)
      return false;
    if (chunk === null) {
      state.reading = false;
      state.eof = true;
      notifyReadable(this);
      scheduleRead(this);
      return false;
    }
    if (state.eof) {
      this.destroy(error('ERR_STREAM_PUSH_AFTER_EOF', 'push() after EOF'));
      return false;
    }
    if (chunk === undefined && !state.objectMode) {
      state.reading = false;
      return state.length < state.highWaterMark;
    }
    const value = state.objectMode ? chunk : bytes(chunk, encoding);
    state.reading = false;
    if (!state.objectMode && value.byteLength === 0)
      return state.length < state.highWaterMark;
    state.queue.push(value);
    state.length += state.objectMode ? 1 : value.byteLength;
    notifyReadable(this);
    if (state.flowing)
      scheduleRead(this);
    return state.length < state.highWaterMark;
  };
  Readable.prototype.read = function(size) {
    const state = readers.get(this);
    state.demand = true;
    if (life(this).destroyed)
      return null;
    if (size !== undefined && (!Number.isInteger(size) || size < 0))
      throw error('ERR_INVALID_ARG_VALUE', 'read size must be a non-negative integer');
    if (!state.queue.length)
      requestRead(this);
    if (!state.objectMode && size !== undefined && size > state.length && !state.eof) {
      requestRead(this);
      if (size > state.length && !state.eof)
        return null;
    }
    if (!state.queue.length || size === 0) {
      if (state.eof)
        scheduleRead(this);
      return null;
    }
    let value;
    if (state.objectMode) {
      value = state.queue.shift();
      state.length--;
    }
    else {
      const wanted = size === undefined ? state.length : Math.min(size, state.length);
      const chunks = [];
      let remaining = wanted;
      while (remaining > 0) {
        const next = state.queue.shift();
        const count = Math.min(remaining, next.byteLength);
        chunks.push(Buffer.from(next.buffer, next.byteOffset, count));
        if (count < next.byteLength)
          state.queue.unshift(next.subarray(count));
        remaining -= count;
      }
      state.length -= wanted;
      value = Buffer.concat(chunks, wanted);
    }
    if (state.eof && !state.queue.length)
      scheduleRead(this);
    else if (state.length < state.highWaterMark)
      tick(() => requestRead(this));
    this.emit('data', value);
    return value;
  };
  Readable.prototype.pause = function() {
    readers.get(this).flowing = false;
    this.emit('pause');
    return this;
  };
  Readable.prototype.resume = function() {
    const state = readers.get(this);
    state.demand = true;
    if (state.flowing !== true) {
      state.flowing = true;
      tick(() => this.emit('resume'));
    }
    scheduleRead(this);
    return this;
  };
  Readable.prototype.isPaused = function() {
    return readers.get(this).flowing === false;
  };
  Readable.prototype.on = function(name, listener) {
    EventEmitter.prototype.on.call(this, name, listener);
    if (name === 'data' && readers.get(this).flowing !== false)
      this.resume();
    if (name === 'readable')
      requestRead(this);
    return this;
  };
  Readable.prototype.addListener = Readable.prototype.on;
  function notifyReadable(stream) {
    const state = readers.get(stream);
    if (state.notified)
      return;
    state.notified = true;
    tick(function() {
      state.notified = false;
      if (!life(stream).destroyed)
        stream.emit('readable');
    });
  }
  property(Readable.prototype, 'readable', function() {
    return !life(this).destroyed && !readers.get(this).endEmitted;
  });
  property(Readable.prototype, 'readableEnded', function() {
    return readers.get(this).endEmitted;
  });
  property(Readable.prototype, 'readableLength', function() {
    return readers.get(this).length;
  });
  property(Readable.prototype, 'readableHighWaterMark', function() {
    return readers.get(this).highWaterMark;
  });
  property(Readable.prototype, 'readableObjectMode', function() {
    return readers.get(this).objectMode;
  });
  property(Readable.prototype, 'readableFlowing', function() {
    return readers.get(this).flowing;
  });
  function initWritable(stream, options) {
    const objectMode = options.objectMode === true || options.writableObjectMode === true;
    writers.set(stream, {
      queue: [], length: 0, objectMode, highWaterMark: watermark(options, 'writable', objectMode), writing: false, needDrain: false, ending: false, finalizing: false, finished: false, pendingCallbacks: 0, endCallbacks: []
    });
    if (options.write)
      stream._write = options.write;
    if (options.final)
      stream._final = options.final;
    if (options.destroy)
      stream._destroy = options.destroy;
  }
  function Writable(options) {
    if (!this || !(this instanceof Stream))
      return new Writable(options);
    options = optionsFor(options);
    Stream.call(this);
    initWritable(this, options);
  }
  Object.setPrototypeOf(Writable.prototype, Stream.prototype);
  Object.setPrototypeOf(Writable, Stream);
  // eslint-disable-next-line pickier/no-unused-vars
  Writable.prototype._write = function(chunk, encoding, callback) {
    callback(error('ERR_METHOD_NOT_IMPLEMENTED', '_write() is not implemented'));
  };
  function finishWritable(stream) {
    const state = writers.get(stream);
    if (!state.ending || state.writing || state.queue.length || state.pendingCallbacks || state.finalizing || state.finished || life(stream).destroyed)
      return;
    state.finalizing = true;
    let called = false;
    function done(failure) {
      if (called) {
        stream.destroy(error('ERR_MULTIPLE_CALLBACK', 'Stream callback called twice'));
        return;
      }
      called = true;
      if (failure) {
        stream.destroy(failure);
        return;
      }
      tick(function() {
        if (life(stream).destroyed)
          return;
        state.finished = true;
        stream.emit('prefinish');
        stream.emit('finish');
        for (const callback of state.endCallbacks.splice(0))
          callback();
        autoDestroy(stream);
      });
    }
    if (typeof stream._final === 'function')
      stream._final(done);
    else done();
  }
  function pumpWrite(stream) {
    const state = writers.get(stream);
    if (state.writing || life(stream).destroyed || life(stream).error !== null)
      return;
    const item = state.queue.shift();
    if (!item) {
      finishWritable(stream);
      return;
    }
    state.writing = true;
    let called = false;
    stream._write(item.chunk, item.encoding, function(failure) {
      if (called) {
        stream.destroy(error('ERR_MULTIPLE_CALLBACK', 'Stream callback called twice'));
        return;
      }
      called = true;
      state.writing = false;
      state.length -= item.length;
      if (failure)
        life(stream).error = failure;
      state.pendingCallbacks++;
      tick(function() {
        state.pendingCallbacks--;
        const callback = item.callback;
        if (callback)
          callback(failure || undefined);
        if (failure) {
          stream.destroy(failure);
          return;
        }
        if (life(stream).destroyed)
          return;
        if (state.needDrain && state.length === 0 && !state.ending) {
          state.needDrain = false;
          stream.emit('drain');
        }
        pumpWrite(stream);
        finishWritable(stream);
      });
    });
  }
  Writable.prototype.write = function(chunk, encoding, callback) {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (callback !== undefined && typeof callback !== 'function')
      throw new TypeError('Expected write callback');
    const state = writers.get(this);
    if (chunk === null)
      throw error('ERR_STREAM_NULL_VALUES', 'May not write null values to a stream');
    const value = state.objectMode ? chunk : bytes(chunk, encoding);
    if (state.ending || life(this).destroyed || life(this).error !== null) {
      const failure = life(this).error || error(state.ending ? 'ERR_STREAM_WRITE_AFTER_END' : 'ERR_STREAM_DESTROYED', 'Cannot write to a completed stream');
      if (callback)
        deferCallback(callback, failure);
      if (!life(this).destroyed)
        this.destroy(failure);
      return false;
    }
    const length = state.objectMode ? 1 : value.byteLength;
    state.queue.push({
      chunk: value, encoding: ArrayBuffer.isView(value) ? 'buffer' : encoding || 'utf8', callback, length
    });
    state.length += length;
    pumpWrite(this);
    const accepted = life(this).error === null && (state.length < state.highWaterMark || state.length === 0);
    if (!accepted)
      state.needDrain = true;
    return accepted;
  };
  Writable.prototype.end = function(chunk, encoding, callback) {
    if (typeof chunk === 'function') {
      callback = chunk;
      chunk = undefined;
      encoding = undefined;
    }
    else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (callback !== undefined && typeof callback !== 'function')
      throw new TypeError('Expected end callback');
    const state = writers.get(this);
    if (chunk !== undefined && chunk !== null)
      this.write(chunk, encoding);
    if (callback) {
      if (state.finished)
        deferCallback(callback);
      else state.endCallbacks.push(callback);
    }
    state.ending = true;
    finishWritable(this);
    return this;
  };
  property(Writable.prototype, 'writable', function() {
    return !life(this).destroyed && life(this).error === null && !writers.get(this).ending;
  });
  property(Writable.prototype, 'writableEnded', function() {
    return writers.get(this).ending;
  });
  property(Writable.prototype, 'writableFinished', function() {
    return writers.get(this).finished;
  });
  property(Writable.prototype, 'writableLength', function() {
    return writers.get(this).length;
  });
  property(Writable.prototype, 'writableNeedDrain', function() {
    return !life(this).destroyed && !writers.get(this).ending && writers.get(this).needDrain;
  });
  property(Writable.prototype, 'writableHighWaterMark', function() {
    return writers.get(this).highWaterMark;
  });
  property(Writable.prototype, 'writableObjectMode', function() {
    return writers.get(this).objectMode;
  });
  function Duplex(options) {
    if (!this || !(this instanceof Stream))
      return new Duplex(options);
    options = optionsFor(options);
    Readable.call(this, options);
    initWritable(this, options);
  }
  Object.setPrototypeOf(Duplex.prototype, Readable.prototype);
  Object.setPrototypeOf(Duplex, Readable);
  for (const key of Reflect.ownKeys(Writable.prototype)) {
    if (key !== 'constructor')
      Object.defineProperty(Duplex.prototype, key, Object.getOwnPropertyDescriptor(Writable.prototype, key));
  }
  Object.defineProperty(Writable, Symbol.hasInstance, {
    value: function(value) {
      if (this === Writable)
        return writers.has(value);
      return Function.prototype[Symbol.hasInstance].call(this, value);
    }
  });
  function Transform(options) {
    if (!this || !(this instanceof Stream))
      return new Transform(options);
    options = optionsFor(options);
    Duplex.call(this, options);
    transforms.set(this, {
      pending: null
    });
    if (options.transform)
      this._transform = options.transform;
    if (options.flush)
      this._flush = options.flush;
    if (options.final)
      unsupported('Home Transform final hooks require composition with flush');
  }
  Object.setPrototypeOf(Transform.prototype, Duplex.prototype);
  Object.setPrototypeOf(Transform, Duplex);
  Transform.prototype._read = function() {
    readers.get(this).reading = false;
    const state = transforms.get(this);
    if (state.pending) {
      const callback = state.pending;
      state.pending = null;
      callback();
    }
  };
  // eslint-disable-next-line pickier/no-unused-vars
  Transform.prototype._transform = function(chunk, encoding, callback) {
    callback(error('ERR_METHOD_NOT_IMPLEMENTED', '_transform() is not implemented'));
  };
  Transform.prototype._write = function(chunk, encoding, callback) {
    let called = false;
    this._transform(chunk, encoding, (failure, output) => {
      if (called) {
        transforms.get(this).pending = null;
        callback(error('ERR_MULTIPLE_CALLBACK', 'Transform callback called twice'));
        return;
      }
      called = true;
      if (failure) {
        callback(failure);
        return;
      }
      if (output !== undefined && output !== null)
        this.push(output);
      const reader = readers.get(this);
      if (reader.length >= reader.highWaterMark && reader.length > 0)
        transforms.get(this).pending = callback;
      else callback();
    });
  };
  Transform.prototype._final = function(callback) {
    let called = false;
    const done = (failure, output) => {
      if (called) {
        callback(error('ERR_MULTIPLE_CALLBACK', 'Flush callback called twice'));
        return;
      }
      called = true;
      if (failure) {
        callback(failure);
        return;
      }
      if (output !== undefined && output !== null)
        this.push(output);
      this.push(null);
      callback();
    };
    if (typeof this._flush === 'function')
      this._flush(done);
    else done();
  };
  function PassThrough(options) {
    if (!this || !(this instanceof Stream))
      return new PassThrough(options);
    Transform.call(this, options);
  }
  Object.setPrototypeOf(PassThrough.prototype, Transform.prototype);
  Object.setPrototypeOf(PassThrough, Transform);
  // eslint-disable-next-line pickier/no-unused-vars
  PassThrough.prototype._transform = function(chunk, encoding, callback) {
    callback(null, chunk);
  };
  const pipes = new WeakMap();
  Readable.prototype.pipe = function(destination, options) {
    if (!writers.has(destination))
      unsupported('Home pipe requires an owned Writable; native stdio/file adapters are not installed');
    if ((pipes.get(this) || []).length)
      unsupported('Home multi-destination pipe backpressure is not implemented');
    if (options !== undefined && (options === null || typeof options !== 'object' || Object.keys(options).some(key => key !== 'end')))
      unsupported('Unsupported pipe options');
    const source = this;
    function ondata(chunk) {
      if (!destination.write(chunk))
        source.pause();
    }
    function ondrain() {
      source.resume();
    }
    function onend() {
      if (!options || options.end !== false)
        destination.end();
    }
    function cleanup() {
      source.removeListener('data', ondata);
      source.removeListener('end', onend);
      destination.removeListener('drain', ondrain);
      destination.removeListener('close', cleanup);
      destination.removeListener('finish', cleanup);
      const links = pipes.get(source);
      if (links) {
        const index = links.indexOf(link);
        if (index !== -1)
          links.splice(index, 1);
      }
    }
    const link = {
      destination, cleanup
    };
    if (!pipes.has(source))
      pipes.set(source, []);
    pipes.get(source).push(link);
    destination.on('drain', ondrain);
    destination.once('close', cleanup);
    destination.once('finish', cleanup);
    source.once('end', onend);
    source.on('data', ondata);
    destination.emit('pipe', source);
    source.resume();
    return destination;
  };
  Readable.prototype.unpipe = function(destination) {
    for (const link of (pipes.get(this) || []).slice()) {
      if (destination === undefined || link.destination === destination) {
        link.cleanup();
        link.destination.emit('unpipe', this, {
          hasUnpiped: true
        });
      }
    }
    return this;
  };
  Readable.from = function(iterable, options) {
    options = optionsFor(options);
    if (options.read || options.destroy)
      unsupported('Readable.from owns its read/destroy hooks');
    if (typeof iterable === 'string' || Buffer.isBuffer(iterable))
      iterable = [iterable];
    const iterator = iterable && (typeof iterable[Symbol.asyncIterator] === 'function' ? iterable[Symbol.asyncIterator]() : typeof iterable[Symbol.iterator] === 'function' ? iterable[Symbol.iterator]() : null);
    if (!iterator || typeof iterator.next !== 'function')
      throw error('ERR_INVALID_ARG_TYPE', 'Expected an iterable');
    const stream = new Readable(Object.assign({
      objectMode: true, highWaterMark: 1
    }, options));
    let busy = false, done = false;
    stream._read = function() {
      if (busy || done)
        return;
      busy = true;
      Promise.resolve().then(() => iterator.next()).then(record => {
        if (!record || typeof record !== 'object')
          throw new TypeError('Iterator result must be an object');
        if (record.done) {
          done = true;
          return {
            done: true
          };
        }
        return Promise.resolve(record.value).then(value => ({
          value, done: false
        }));
      }).then(record => {
        busy = false;
        readers.get(stream).reading = false;
        if (stream.destroyed)
          return;
        if (record.done)
          stream.push(null);
        else if (record.value === null)
          stream.destroy(error('ERR_STREAM_NULL_VALUES', 'Iterable may not yield null'));
        else stream.push(record.value);
        if (readers.get(stream).flowing)
          scheduleRead(stream);
      }, failure => {
        busy = false;
        stream.destroy(failure || error('ERR_HOME_STREAM_ABRUPT', 'Iterator rejected a falsy value'));
      });
    };
    stream._destroy = function(failure, callback) {
      if (!done && typeof iterator.return === 'function') {
        done = true;
        Promise.resolve().then(() => iterator.return()).then(() => callback(failure), cleanupError => callback(failure || cleanupError));
      }
      else callback(failure);
    };
    return stream;
  };
  function terminal(stream, readable, writable) {
    return (!readable || readers.get(stream).endEmitted) && (!writable || writers.get(stream).finished);
  }
  async function finishedPromise(stream, options) {
    const state = life(stream);
    const reader = readers.get(stream), writer = writers.get(stream);
    options = options === undefined ? {
    } : options;
    if (!options || typeof options !== 'object' || Object.keys(options).some(key => !['readable', 'writable', 'cleanup'].includes(key)))
      unsupported('Unsupported finished options');
    const readable = !!reader && options.readable !== false, writable = !!writer && options.writable !== false;
    if (!reader && !writer)
      throw error('ERR_INVALID_ARG_TYPE', 'Expected a Readable or Writable');
    if (!readable && !writable)
      unsupported('Home finished requires at least one observed stream side');
    return new Promise((resolve, reject) => {
      let settled = false;
      function cleanup() {
        stream.removeListener('end', check);
        stream.removeListener('finish', check);
        stream.removeListener('close', check);
        stream.removeListener('error', onerror);
      }
      function settle(failure) {
        if (settled)
          return;
        settled = true;
        if (options.cleanup)
          cleanup();
        if (failure)
          reject(failure);
        else resolve();
      }
      function onerror(failure) {
        settle(failure || error('ERR_STREAM_DESTROYED', 'Stream failed'));
      }
      function check() {
        if (state.error !== null) {
          settle(state.error);
          return;
        }
        const complete = terminal(stream, readable, writable);
        if (state.closed && !complete)
          settle(error('ERR_STREAM_PREMATURE_CLOSE', 'Premature stream close'));
        else if (complete && (state.closed || (readable && !writable && writer) || (writable && !readable && reader)))
          settle();
      }
      stream.on('error', onerror);
      stream.on('end', check);
      stream.on('finish', check);
      stream.on('close', check);
      tick(check);
    });
  }
  async function pipelinePromise(...streams) {
    if (Array.isArray(streams[0])) {
      if (streams.length !== 1)
        unsupported('Home pipeline options/iterable stages are not implemented');
      streams = streams[0];
    }
    if (streams.length < 2)
      throw error('ERR_MISSING_ARGS', 'pipeline needs at least two streams');
    for (let index = 0; index < streams.length; index++) {
      if (!lives.has(streams[index]) || (index < streams.length - 1 && !readers.has(streams[index])) || (index > 0 && !writers.has(streams[index])))
        unsupported('Home pipeline requires owned Readable/Writable stages');
    }
    let failed = false, failure;
    function abort(reason) {
      if (failed)
        return;
      failed = true;
      failure = reason || error('ERR_STREAM_DESTROYED', 'Pipeline failed');
      for (const stream of streams)
        stream.destroy(failure);
    }
    const observers = streams.map((stream, index) => {
      stream.on('error', abort);
      return finishedPromise(stream, {
        readable: index !== streams.length - 1, writable: index !== 0, cleanup: true
      }).catch(abort);
    });
    for (let index = 0; index < streams.length - 1; index++)
      streams[index].pipe(streams[index + 1]);
    await Promise.all(observers);
    // A failed observer can reject before custom destroy hooks acknowledge
    // cleanup. Do not resolve/reject the pipeline until their real callbacks.
    if (failed)
      await Promise.all(streams.map(stream => new Promise(resolve => {
      const state = life(stream);
      if (state.closed)
        resolve();
      else state.closeWaiters.push(resolve);
    })));
    for (const stream of streams)
      stream.removeListener('error', abort);
    if (failed)
      throw failure;
  }
  function pipeline(...streams) {
    const callback = streams.pop();
    if (typeof callback !== 'function')
      throw error('ERR_INVALID_ARG_TYPE', 'pipeline requires a callback');
    const sequence = Array.isArray(streams[0]) ? streams[0] : streams;
    pipelinePromise(...streams).then(() => callback(), callback);
    return sequence[sequence.length - 1];
  }
  const promises = {
    pipeline: pipelinePromise, finished: finishedPromise
  };
  Object.assign(Stream, {
    Stream, Readable, Writable, Duplex, Transform, PassThrough, pipeline, promises
  });
  return Stream;
};
