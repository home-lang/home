export default {
  app: {
    framework: {
      serverComponents: {
        separateSSRGraph: false,
        serverRuntimeImportSource: './server.ts',
      },
      fileSystemRouterTypes: [
        {
          root: 'pages',
          prefix: '/',
          serverEntryPoint: './server.ts',
          clientEntryPoint: './client.ts',
          style: 'nextjs-pages',
          extensions: ['.ts'],
        },
      ],
    },
  },
};
