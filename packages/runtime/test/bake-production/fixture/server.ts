export function prerender(meta) {
  return {
    files: {
      '/index.html': JSON.stringify({
        page: meta.pageModule.default,
        params: meta.params,
      }),
    },
  };
}

export function getParams() {
  return [{ slug: 'alpha' }, { slug: 'beta' }];
}
