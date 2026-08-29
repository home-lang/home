import appConfig from './bun.app.ts';

export default {
  ...appConfig,
  port: __HOME_BAKE_TEST_PORT__,
};
