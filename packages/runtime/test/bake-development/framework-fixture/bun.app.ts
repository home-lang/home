export default {
  app: {
    framework: {
      fileSystemRouterTypes: [
        {
          root: 'routes',
          style: 'nextjs-pages',
          serverEntryPoint: './minimal.server.ts',
        },
      ],
      serverComponents: {
        separateSSRGraph: false,
        serverRuntimeImportSource: './minimal.server.ts',
        serverRegisterClientReferenceExport: 'registerClientReference',
      },
    },
  },
};
