import page from './index.html';

export default {
  port: __HOME_BAKE_TEST_PORT__,
  development: {
    console: true,
  },
  static: {
    '/*': page,
  },
  fetch() {
    return new Response('Not Found', { status: 404 });
  },
};
