// Home-owned module linkage and evaluation for either public-C engine backend.
(function() {
  const rawResolve = globalThis.__home_tool_resolve_module;
  function resolveNative(specifier, parent, lookupOnly) {
    const result = rawResolve(specifier, parent, lookupOnly);
    if (result && result.error) throw moduleError(result.code, `Cannot resolve ${specifier} from ${parent}: ${result.error}`);
    return result;
  }
  const builtins = globalThis.__home_tool_builtins || Object.create(null);
  delete globalThis.__home_tool_builtins;
  function isBuiltin(request) {
    return Object.prototype.hasOwnProperty.call(builtins, request);
  }
  const cache = Object.create(null);
  let mainModule = null;
  const records = Object.create(null);
  // Preserve emitted ESM identity while adapting genuine CommonJS values.
  globalThis.__importDefault = function(value) {
    return value && value.__esModule ? value : { default: value };
  };
  globalThis.__importStar = function(value) {
    if (value && value.__esModule) return value;
    const namespace = {};
    if (value !== null && value !== undefined) Object.keys(Object(value)).forEach(function(key) {
      if (key === 'default') return;
      let descriptor = Object.getOwnPropertyDescriptor(Object(value), key);
      if (!descriptor || 'get' in descriptor || descriptor.writable || descriptor.configurable) {
        descriptor = { enumerable: true, get: function() {
          return value[key];
        } };
      }
      Object.defineProperty(namespace, key, descriptor);
    });
    Object.defineProperty(namespace, 'default', { enumerable: true, value: value });
    return namespace;
  };
  function fileURL(path) {
    return `file://${path.split('/').map(encodeURIComponent).join('/')}`;
  }
  function makeRequire(parentPath) {
    function localRequire(request) {
      if (typeof request !== 'string') throw new TypeError('Module id must be a string');
      return load(request, parentPath, false);
    }
    localRequire.resolve = function(request) {
      if (typeof request !== 'string') throw new TypeError('Module id must be a string');
      if (isBuiltin(request)) return request;
      const resolved = resolveNative(request, parentPath, true);
      if (resolved === null) throw new Error(`cannot resolve module ${request} from ${parentPath}`);
      return resolved.path;
    };
    localRequire.cache = cache;
    Object.defineProperty(localRequire, 'main', { get: function() {
      return mainModule;
    } });
    return localRequire;
  }
  function moduleError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }
  function link(specifier, parentPath) {
    if (isBuiltin(specifier)) return { builtin: true, exports: builtins[specifier] };
    const resolved = resolveNative(specifier, parentPath || '', true);
    if (resolved === null) throw new Error(`cannot resolve module ${specifier} from ${parentPath}`);
    if (Object.prototype.hasOwnProperty.call(records, resolved.path)) return records[resolved.path];
    const payload = resolveNative(resolved.path, '');
    if (payload === null) throw new Error(`cannot emit module ${resolved.path}`);
    const record = { payload: payload, dependencies: [], asynchronous: !!(payload.esModule && payload.topLevelAwait), state: 'linked' };
    records[payload.path] = record;
    try {
      JSON.parse(payload.staticImports || '[]').forEach(function(request) {
        record.dependencies.push({ request: request, record: link(request, payload.path) });
      });
    }
    catch (error) {
      // Failed linkage must stay failed; a later import cannot evaluate an
      // incomplete graph and accidentally report success.
      record.state = 'failed';
      record.error = error;
      throw error;
    }
    return record;
  }
  function graph(specifier, parentPath) {
    const root = link(specifier, parentPath);
    let changed = true;
    // Async evaluation propagates through static ESM edges, including cycles.
    // This fixed point never executes module bodies.
    while (changed) {
      changed = false;
      Object.keys(records).forEach(function(path) {
        const record = records[path];
        if (!record.asynchronous && record.dependencies.some(function(edge) {
          return edge.record.asynchronous;
        })) {
          record.asynchronous = true;
          changed = true;
        }
      });
    }
    return root;
  }
  function prepare(record, asMain) {
    const payload = record.payload;
    const module = { id: payload.path, filename: payload.path, loaded: false, exports: {}, parent: null, children: [] };
    if (payload.esModule) Object.defineProperty(module.exports, '__esModule', { value: true });
    record.module = module;
    cache[payload.path] = module;
    if (asMain) mainModule = module;
    const slash = payload.path.lastIndexOf('/');
    const directory = slash < 0 ? '.' : payload.path.slice(0, slash);
    const localRequire = makeRequire(payload.path);
    module.require = localRequire;
    const metadata = Object.create(null);
    metadata.url = fileURL(payload.path);
    metadata.path = payload.path;
    metadata.dir = directory;
    metadata.file = payload.path.slice(slash + 1);
    metadata.dirname = directory;
    metadata.filename = payload.path;
    metadata.env = process.env;
    metadata.main = !!asMain;
    metadata.require = localRequire;
    function staticImport(request) {
      const edge = record.dependencies.find(function(candidate) {
        return candidate.request === request;
      });
      if (!edge) throw moduleError('ERR_HOME_MODULE_LINK', `Unlinked static import ${request}`);
      const dependency = edge.record;
      if (dependency.builtin) return dependency.exports;
      if (dependency.state === 'failed') throw dependency.error;
      if (dependency.asynchronous && dependency.state !== 'evaluated') throw moduleError('ERR_HOME_MODULE_LINK', `Async dependency not evaluated: ${request}`);
      return dependency.module.exports;
    }
    record.execute = function() {
      if (payload.format === 'json') {
        module.exports = JSON.parse(payload.source);
        return;
      }
      // The import accessor is separate from explicit source require(): only
      // linked static edges may read an already evaluated async dependency.
      const factorySource = `(function(${payload.metaBinding}, module, ${payload.importBinding || '__home_unused_import'}) { return ${record.asynchronous ? 'async ' : ''}function(exports, require, ${payload.moduleBinding || 'module'}, __filename, __dirname) {\n${payload.source}\n}; })`;
      const wrapper = (0, eval)(factorySource)(metadata, module, staticImport);
      return wrapper(module.exports, localRequire, module, payload.path, directory);
    };
  }
  function evaluateSync(record, asMain) {
    if (record.builtin) return record;
    if (record.asynchronous) throw moduleError('ERR_REQUIRE_ASYNC_MODULE', `require() cannot evaluate an async module graph: ${record.payload.path}`);
    if (record.state === 'failed') {
      if (record.payload.esModule || !record.module) throw record.error;
      record.state = 'linked';
    }
    if (Object.prototype.hasOwnProperty.call(cache, record.payload.path)) return record;
    record.state = 'evaluating';
    prepare(record, asMain);
    try {
      record.dependencies.forEach(function(edge) {
        evaluateSync(edge.record, false);
      });
      record.execute();
      record.module.loaded = true;
      record.state = 'evaluated';
      return record;
    }
    catch (error) {
      record.error = error;
      record.state = 'failed';
      if (!record.payload.esModule) delete cache[record.payload.path];
      throw error;
    }
  }
  function evaluateAsync(record, asMain, ancestors) {
    if (record.builtin || !record.asynchronous) return Promise.resolve(evaluateSync(record, asMain));
    if (record.state === 'failed') return Promise.reject(record.error);
    if (record.state === 'evaluated') return Promise.resolve(record);
    if (ancestors.indexOf(record) !== -1) return Promise.reject(moduleError('ERR_HOME_ASYNC_MODULE_CYCLE', `Async module cycles are not implemented: ${record.payload.path}`));
    if (record.promise) return record.promise;
    record.state = 'evaluating';
    prepare(record, asMain);
    const chain = ancestors.concat([record]);
    try {
      // ECMA-262 InnerModuleEvaluation starts later independent siblings even
      // while an earlier dependency is suspended. Serial awaiting can deadlock
      // a valid graph where a later sibling resolves the earlier one's await.
      const dependencies = record.dependencies.map(function(edge) {
        return evaluateAsync(edge.record, false, chain);
      });
      const hasAsyncDependency = record.dependencies.some(function(edge) {
        return edge.record.asynchronous;
      });
      // Without async dependencies, start the body immediately, up to its first
      // await. An extra checkpoint here would reorder sibling side effects.
      const execution = hasAsyncDependency
        ? Promise.all(dependencies).then(function() {
          return record.execute();
        })
        : record.execute();
      record.promise = Promise.resolve(execution).then(function() {
        record.module.loaded = true;
        record.state = 'evaluated';
        // Return the record, never raw exports: CJS may export a thenable.
        return record;
      }, function(error) {
        record.error = error;
        record.state = 'failed';
        throw error;
      });
    }
    catch (error) {
      record.error = error;
      record.state = 'failed';
      record.promise = Promise.reject(error);
    }
    return record.promise;
  }
  function load(specifier, parentPath, asMain) {
    const record = evaluateSync(graph(String(specifier), parentPath), asMain);
    return record.builtin ? record.exports : record.module.exports;
  }
  Home.startModule = function(specifier) {
    let state = 'pending';
    let failure;
    const root = graph(String(specifier), '');
    if (!root.asynchronous) {
      evaluateSync(root, true);
      state = 'fulfilled';
    }
    else {
      evaluateAsync(root, true, []).then(function() {
        state = 'fulfilled';
      }, function(error) {
        state = 'rejected';
        failure = error;
      });
    }
    // The native runner protects this closure across the engine's microtask
    // checkpoint, then invokes it. A pending or rejected entry cannot exit 0.
    return function() {
      if (state === 'rejected') throw failure;
      if (state !== 'fulfilled') throw moduleError('ERR_HOME_UNSETTLED_MODULE', `Module evaluation is still pending: ${specifier}`);
    };
  };
  Home.resolveModule = function(specifier, parentPath) {
    specifier = String(specifier);
    if (isBuiltin(specifier)) return specifier;
    const resolved = resolveNative(String(specifier), String(parentPath || ''), true);
    if (resolved === null) throw new Error(`cannot resolve module ${specifier}`);
    return resolved.path;
  };
  Home.createRequire = function(parentPath) {
    if (typeof parentPath !== 'string' || parentPath.charAt(0) !== '/' || parentPath.indexOf('\0') !== -1) throw new TypeError('Home require referrer must be an absolute POSIX filename');
    if (parentPath.charAt(parentPath.length - 1) === '/') parentPath += '__home_require__.js';
    return makeRequire(parentPath);
  };
  Home.require = makeRequire('');
  Home.runModule = function(specifier) {
    return load(specifier, '', true);
  };
  globalThis.require = Home.require;
  delete globalThis.__home_tool_resolve_module;
})();
