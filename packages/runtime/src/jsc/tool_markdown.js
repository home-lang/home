// The HTML implementation is Home's native CommonMark/GFM parser.
(function() {
  const render = globalThis.__home_tool_render_markdown;
  delete globalThis.__home_tool_render_markdown;
  const encode = JSON.stringify.bind(JSON);
  const create = Object.create.bind(Object);
  const Bytes = Uint8Array;
  const isView = ArrayBuffer.isView.bind(ArrayBuffer);
  const BufferType = ArrayBuffer;
  const byteLength = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Bytes.prototype), 'byteLength').get;
  const bufferLength = Object.getOwnPropertyDescriptor(BufferType.prototype, 'byteLength').get;
  const stringValue = String.prototype.valueOf;
  const View = DataView;
  const viewBuffer = Object.getOwnPropertyDescriptor(View.prototype, 'buffer').get;
  const viewOffset = Object.getOwnPropertyDescriptor(View.prototype, 'byteOffset').get;
  const viewLength = Object.getOwnPropertyDescriptor(View.prototype, 'byteLength').get;
  const fields = ['tables', 'strikethrough', 'tasklists', 'hard_soft_breaks', 'wiki_links', 'underline', 'latex_math', 'collapse_whitespace', 'permissive_atx_headers', 'no_indented_code_blocks', 'no_html_blocks', 'no_html_spans', 'tag_filter'];
  const aliases = ['tables', 'strikethrough', 'tasklists', 'hardSoftBreaks', 'wikiLinks', 'underline', 'latexMath', 'collapseWhitespace', 'permissiveAtxHeaders', 'noIndentedCodeBlocks', 'noHtmlBlocks', 'noHtmlSpans', 'tagFilter'];
  function html(input, options = undefined) {
    if (new.target) throw new TypeError('Bun.markdown.html is not a constructor');
    if (typeof input !== 'string') {
      try {
        input = stringValue.call(input);
      }
      catch {}
    }
    if (typeof input !== 'string') {
      if (!isView(input) && !(input instanceof BufferType)) throw new TypeError('Expected a string or buffer to render');
      if (input instanceof BufferType) {
        bufferLength.call(input);
        input = new Bytes(input);
      }
      if (input instanceof View) input = new Bytes(viewBuffer.call(input), viewOffset.call(input), viewLength.call(input));
    }
    const inputLength = typeof input === 'string' ? null : byteLength.call(input);
    const flags = create(null);
    if (options !== null && (typeof options === 'object' || typeof options === 'function')) {
      const autolinks = options.autolinks;
      if (autolinks === true) flags.permissive_autolinks = true;
      else if (autolinks !== null && (typeof autolinks === 'object' || typeof autolinks === 'function')) {
        flags.permissive_url_autolinks = !!autolinks.url;
        flags.permissive_www_autolinks = !!autolinks.www;
        flags.permissive_email_autolinks = !!autolinks.email;
      }
      const headings = options.headings;
      if (headings === true) flags.heading_ids = flags.autolink_headings = true;
      else if (headings !== null && (typeof headings === 'object' || typeof headings === 'function')) {
        flags.heading_ids = !!headings.ids;
        flags.autolink_headings = !!headings.autolink;
      }
      for (let i = 0; i < fields.length; i++) {
        let value = options[aliases[i]];
        if (value === undefined && aliases[i] !== fields[i]) value = options[fields[i]];
        if (value !== undefined) flags[fields[i]] = !!value;
      }
    }
    const encoded = encode(flags);
    if (inputLength !== null && byteLength.call(input) !== inputLength) {
      const error = new RangeError('Markdown binary view changed while reading options');
      error.code = 'ERR_HOME_MARKDOWN_BUFFER_CHANGED';
      throw error;
    }
    const result = render(input, encoded);
    if (result.error) {
      const ErrorType = result.error === 'StackOverflow' || result.error === 'InputTooLarge' || result.error === 'OutOfMemory' ? RangeError : Error;
      const error = new ErrorType(`Home Markdown renderer: ${result.error}`);
      error.code = 'ERR_HOME_MARKDOWN';
      throw error;
    }
    if (typeof result.html !== 'string') throw new Error('Home Markdown renderer returned no HTML');
    return result.html;
  }
  globalThis.__home_tool_markdown_api = { html };
})();
