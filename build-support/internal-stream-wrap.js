const { Duplex: HomeDuplex } = __HOME_NODE_STREAM__;
const HOME_UV_ECANCELED = -125;

class HomeShutdownWrap {}

function homeStreamWrapError() {
  const error = new Error('Stream has StringDecoder set or is in objectMode');
  error.code = 'ERR_STREAM_WRAP';
  return error;
}

class HomeJSStreamSocket extends HomeDuplex {
  #writePending = 0;
  #shutdownRequest = null;
  #closed = false;

  constructor(stream) {
    super({ readable: stream.readable !== false, writable: stream.writable !== false });
    this.stream = stream;
    this._handle = { _parentWrap: this, shutdown: request => this.#shutdown(request) };

    stream.pause();
    stream.on('error', error => this.emit('error', error));
    const ondata = chunk => {
      if (typeof chunk === 'string' || stream.readableObjectMode === true) {
        stream.pause();
        stream.removeListener('data', ondata);
        this.emit('error', homeStreamWrapError());
        return;
      }
      if (!this.destroyed) this.push(chunk);
    };
    stream.on('data', ondata);
    stream.once('end', () => this.push(null));
    stream.once('close', () => {
      this.#closed = true;
      if (!this.destroyed) this.destroy();
    });

    // Match Node's JSStreamSocket startup: request the first read after every
    // forwarding listener exists, so decoded strings and object-mode chunks
    // are rejected even when userland has not attached a data consumer.
    this.read(0);
  }

  static get StreamWrap() {
    return HomeJSStreamSocket;
  }

  _read() {
    this.stream.resume();
  }

  _write(chunk, encoding, callback) {
    this.#writePending++;
    try {
      this.stream.write(chunk, encoding, error => {
        this.#writePending--;
        callback(error);
        this.#finishPendingShutdown();
      });
    } catch (error) {
      this.#writePending--;
      callback(error);
      this.#finishPendingShutdown();
    }
  }

  _final(callback) {
    this.stream.end(callback);
  }

  _destroy(error, callback) {
    this.#closed = true;
    this.stream.destroy(error ?? undefined);
    this.#finishShutdown(HOME_UV_ECANCELED);
    callback(error);
  }

  #shutdown(request) {
    if (this.#shutdownRequest !== null) return 0;
    this.#shutdownRequest = request;
    if (this.destroyed || this.#closed) queueMicrotask(() => this.#finishShutdown(HOME_UV_ECANCELED));
    else this.#finishPendingShutdown();
    return 0;
  }

  #finishPendingShutdown() {
    if (this.#shutdownRequest === null || this.#writePending !== 0) return;
    this.stream.end(() => this.#finishShutdown(0));
  }

  #finishShutdown(status) {
    const request = this.#shutdownRequest;
    if (request === null) return;
    this.#shutdownRequest = null;
    request.oncomplete?.(status);
  }
}

const homeStreamWrapBinding = { ShutdownWrap: HomeShutdownWrap };
function homeInternalTestBinding(name) {
  if (name === 'stream_wrap') return homeStreamWrapBinding;
  return process.binding(name);
}
