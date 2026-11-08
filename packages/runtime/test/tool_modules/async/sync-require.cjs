try { require('./value.mjs'); throw new Error('accepted async graph'); } catch (error) { if (error.code !== 'ERR_REQUIRE_ASYNC_MODULE') throw error; }
console.log('OK home-tool rejects synchronous async graph');
