const scannerModuleName = __SCANNER_MODULE__;
const suppressError = __SUPPRESS_ERROR__;

type IPCMessage =
  | { type: 'result'; advisories: Bun.Security.Advisory[] }
  | { type: 'error'; code: 'MODULE_NOT_FOUND'; module: string }
  | { type: 'error'; code: 'INVALID_VERSION'; message: string }
  | { type: 'error'; code: 'SCAN_FAILED'; message: string };

// Two pipes for IPC:
// - fd 3: output - child writes response here
// - fd 4: input - child reads JSON package list here (reads until EOF)
const IPC_OUTPUT_FD = 3;
const IPC_INPUT_FD = 4;

async function sendAndExit(message: IPCMessage): Promise<never> {
  const data = new TextEncoder().encode(JSON.stringify(message));
  const written = await Bun.write(IPC_OUTPUT_FD, data);
  if (written !== data.byteLength) {
    console.error('Failed to write to IPC pipe');
    process.exit(1);
  }
  process.exit(message.type === 'error' ? 1 : 0);
}

// Read packages JSON from fd 4 (reads until EOF when parent closes the pipe)
let packages: Bun.Security.Package[];
let packagesJson: string = '';

try {
  packagesJson = await Bun.file(IPC_INPUT_FD).text();
} catch (error) {
  const message = `Failed to read packages from FD ${IPC_INPUT_FD}: ${error instanceof Error ? error.message : String(error)}`;
  await sendAndExit({
    type: 'error',
    code: 'SCAN_FAILED',
    message,
  });
}

try {
  packages = JSON.parse(packagesJson);
  if (!Array.isArray(packages)) {
    throw new Error('Expected packages to be an array');
  }
} catch (error) {
  const message = `Failed to parse packages JSON: ${error instanceof Error ? error.message : String(error)}`;
  await sendAndExit({
    type: 'error',
    code: 'SCAN_FAILED',
    message,
  });
}

let scanner: Bun.Security.Scanner;

try {
  scanner = (await import(scannerModuleName)).scanner;
} catch (error) {
  if (typeof error === 'object' && error !== null && 'code' in error && error.code === 'ERR_MODULE_NOT_FOUND') {
    if (!suppressError) {
      const msg = `\x1b[31merror: \x1b[0mFailed to import security scanner: \x1b[1m'${scannerModuleName}'`;
      console.error(msg);
    }

    await sendAndExit({
      type: 'error',
      code: 'MODULE_NOT_FOUND',
      module: scannerModuleName,
    });
  } else {
    await sendAndExit({
      type: 'error',
      code: 'SCAN_FAILED',
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

try {
  if (typeof scanner !== 'object' || scanner === null || typeof scanner.version !== 'string') {
    throw new Error('Security scanner must export a \'scanner\' object with a version property');
  }

  if (scanner.version !== '1') {
    await sendAndExit({
      type: 'error',
      code: 'INVALID_VERSION',
      message: `Security scanner must be version 1, got version ${scanner.version}`,
    });
  }

  if (typeof scanner.scan !== 'function') {
    throw new Error(`scanner.scan is not a function, got ${typeof scanner.scan}`);
  }

  const result = await scanner.scan({ packages });

  if (!Array.isArray(result)) {
    throw new Error('Security scanner must return an array of advisories');
  }

  await sendAndExit({ type: 'result', advisories: result });
} catch (error) {
  if (!suppressError) {
    console.error(error);
  }

  await sendAndExit({
    type: 'error',
    code: 'SCAN_FAILED',
    message: error instanceof Error ? error.message : 'Unknown error occurred',
  });
}
