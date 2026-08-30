export default {
  name: 'home-bake-development-plugin',
  setup(build) {
    build.onResolve({ filter: /^virtual-client$/ }, () => ({
      path: `${import.meta.dir}/client.ts`,
      namespace: 'file',
    }));
  },
};
