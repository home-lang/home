(function() {
  const native = globalThis.__home_tool_yaml_parse;
  delete globalThis.__home_tool_yaml_parse;
  Home.parseYAML = function(source) {
    if (typeof source !== 'string') throw new TypeError('Home YAML parsing requires a string');
    for (const character of source) {
      const point = character.codePointAt(0);
      if (point >= 0xd800 && point <= 0xdfff) {
        const error = new Error('YAML source with lone UTF-16 surrogates is unsupported');
        error.code = 'ERR_HOME_UNSUPPORTED';
        throw error;
      }
    }
    const result = native(source);
    if (result === null) throw new Error('Native YAML parsing failed');
    const graph = JSON.parse(result);
    if (graph.kind) {
      const error = graph.kind === 'SyntaxError' ? new SyntaxError(graph.message)
        : graph.kind === 'RangeError' ? new RangeError(graph.message) : new Error(graph.message);
      if (graph.kind === 'ERR_HOME_UNSUPPORTED') error.code = graph.kind;
      throw error;
    }
    const values = graph.nodes.map(function(node) {
      if (node[0] === 'array') return [];
      if (node[0] === 'object') return {};
      if (node[0] === 'number') return Number(node[1]);
      if (node[0] === 'null') return null;
      return node[1];
    });
    graph.nodes.forEach(function(node, index) {
      if (node[0] === 'array') node[1].forEach(function(id) {
        values[index].push(values[id]);
      });
      if (node[0] === 'object') node[1].forEach(function(pair) {
        Object.defineProperty(values[index], String(values[pair[0]]), { value: values[pair[1]], enumerable: true, writable: true, configurable: true });
      });
    });
    if (graph.roots.length === 0) return null;
    if (graph.roots.length === 1) return values[graph.roots[0]];
    return graph.roots.map(function(id) {
      return values[id];
    });
  };
})();
