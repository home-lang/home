// MIT License

// Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (sindresorhus.com)

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

'use strict';

// Adapted from Node v26.10.0 internal/tty.js for the POSIX tool host.
globalThis.__home_tool_tty_colors_factory = function() {
const ArrayPrototypeSome = Function.call.bind(Array.prototype.some);
const ObjectEntries = Object.entries;
const hasOwn = Function.call.bind(Object.prototype.hasOwnProperty);
const RegExpPrototypeExec = Function.call.bind(RegExp.prototype.exec);
const StringPrototypeToLowerCase = Function.call.bind(String.prototype.toLowerCase);
const SafeMap = Map;
function validateInteger(value, name, minimum) {
const code = typeof value !== 'number' ? 'ERR_INVALID_ARG_TYPE' : (!Number.isInteger(value) || value < minimum || !Number.isSafeInteger(value)) ? 'ERR_OUT_OF_RANGE' : null;
 if (code) { const error = new (code === 'ERR_INVALID_ARG_TYPE' ? TypeError : RangeError)(`${name} must be an integer >= ${minimum}`); error.code = code; throw error; }
}


const COLORS_2 = 1;
const COLORS_16 = 4;
const COLORS_256 = 8;
const COLORS_16m = 24;

// Some entries were taken from `dircolors`
// (https://linux.die.net/man/1/dircolors). The corresponding terminals might
// support more than 16 colors, but this was not tested for.
//
// Copyright (C) 1996-2016 Free Software Foundation, Inc. Copying and
// distribution of this file, with or without modification, are permitted
// provided the copyright notice and this notice are preserved.
const TERM_ENVS = {
  'eterm': COLORS_16,
  'cons25': COLORS_16,
  'console': COLORS_16,
  'cygwin': COLORS_16,
  'dtterm': COLORS_16,
  'gnome': COLORS_16,
  'hurd': COLORS_16,
  'jfbterm': COLORS_16,
  'konsole': COLORS_16,
  'kterm': COLORS_16,
  'mlterm': COLORS_16,
  'mosh': COLORS_16m,
  'putty': COLORS_16,
  'st': COLORS_16,
  // http://lists.schmorp.de/pipermail/rxvt-unicode/2016q2/002261.html
  'rxvt-unicode-24bit': COLORS_16m,
  // https://bugs.launchpad.net/terminator/+bug/1030562
  'terminator': COLORS_16m,
  'xterm-kitty': COLORS_16m,
};

const CI_ENVS_MAP = new SafeMap(ObjectEntries({
  APPVEYOR: COLORS_256,
  BUILDKITE: COLORS_256,
  CIRCLECI: COLORS_16m,
  DRONE: COLORS_256,
  GITEA_ACTIONS: COLORS_16m,
  GITHUB_ACTIONS: COLORS_16m,
  GITLAB_CI: COLORS_256,
  TRAVIS: COLORS_256,
}));

const TERM_ENVS_REG_EXP = [
  /ansi/,
  /color/,
  /linux/,
  /direct/,
  /^con[0-9]*x[0-9]/,
  /^rxvt/,
  /^screen/,
  /^xterm/,
  /^vt100/,
  /^vt220/,
];

let warned = false;
function warnOnDeactivatedColors(env) {
  if (warned)
    return;
  let name = '';
  if (env.NODE_DISABLE_COLORS !== undefined && env.NODE_DISABLE_COLORS !== '')
    name = 'NODE_DISABLE_COLORS';
  if (env.NO_COLOR !== undefined && env.NO_COLOR !== '') {
    if (name !== '') {
      name += "' and '";
    }
    name += 'NO_COLOR';
  }

  if (name !== '') {
    process.emitWarning(
      `The '${name}' env is ignored due to the 'FORCE_COLOR' env being set.`,
      'Warning',
    );
    warned = true;
  }
}

// The `getColorDepth` API got inspired by multiple sources such as
// https://github.com/chalk/supports-color,
// https://github.com/isaacs/color-support.
function getColorDepth(env = process.env) {
  // Use level 0-3 to support the same levels as `chalk` does. This is done for
  // consistency throughout the ecosystem.
  if (env.FORCE_COLOR !== undefined) {
    switch (env.FORCE_COLOR) {
      case '':
      case '1':
      case 'true':
        warnOnDeactivatedColors(env);
        return COLORS_16;
      case '2':
        warnOnDeactivatedColors(env);
        return COLORS_256;
      case '3':
        warnOnDeactivatedColors(env);
        return COLORS_16m;
      default:
        return COLORS_2;
    }
  }

  if ((env.NODE_DISABLE_COLORS !== undefined && env.NODE_DISABLE_COLORS !== '') ||
      // See https://no-color.org/
      (env.NO_COLOR !== undefined && env.NO_COLOR !== '') ||
      // The "dumb" special terminal, as defined by terminfo, doesn't support
      // ANSI color control codes.
      // See https://invisible-island.net/ncurses/terminfo.ti.html#toc-_Specials
      env.TERM === 'dumb') {
    return COLORS_2;
  }

  if (process.platform === 'win32') { const error = new Error('Home terminal colors require POSIX'); error.code = 'ERR_HOME_UNSUPPORTED'; throw error; }

  if (env.TMUX) {
    return COLORS_16m;
  }

  // Azure DevOps
  if (hasOwn(env, 'TF_BUILD') && hasOwn(env, 'AGENT_NAME')) {
    return COLORS_16;
  }

  if (hasOwn(env, 'CI')) {
    for (const { 0: envName, 1: colors } of CI_ENVS_MAP) {
      if (hasOwn(env, envName)) {
        return colors;
      }
    }
    if (env.CI_NAME === 'codeship') {
      return COLORS_256;
    }
    return COLORS_2;
  }

  if ('TEAMCITY_VERSION' in env) {
    return RegExpPrototypeExec(/^(9\.(0*[1-9]\d*)\.|\d{2,}\.)/, env.TEAMCITY_VERSION) !== null ?
      COLORS_16 : COLORS_2;
  }

  switch (env.TERM_PROGRAM) {
    case 'iTerm.app':
      if (!env.TERM_PROGRAM_VERSION ||
        RegExpPrototypeExec(/^[0-2]\./, env.TERM_PROGRAM_VERSION) !== null
      ) {
        return COLORS_256;
      }
      return COLORS_16m;
    case 'HyperTerm':
    case 'MacTerm':
      return COLORS_16m;
    case 'Apple_Terminal':
      return COLORS_256;
  }

  if (env.COLORTERM === 'truecolor' || env.COLORTERM === '24bit') {
    return COLORS_16m;
  }

  if (env.TERM) {
    if (RegExpPrototypeExec(/truecolor/, env.TERM) !== null) {
      return COLORS_16m;
    }

    if (RegExpPrototypeExec(/^xterm-256/, env.TERM) !== null) {
      return COLORS_256;
    }

    const termEnv = StringPrototypeToLowerCase(env.TERM);

    if (TERM_ENVS[termEnv]) {
      return TERM_ENVS[termEnv];
    }
    if (ArrayPrototypeSome(TERM_ENVS_REG_EXP,
                          (term) => RegExpPrototypeExec(term, termEnv) !== null)) {
      return COLORS_16;
    }
  }
  // Move 16 color COLORTERM below 16m and 256
  if (env.COLORTERM) {
    return COLORS_16;
  }
  return COLORS_2;
}

function hasColors(count, env) {
  if (env === undefined &&
      (count === undefined || (typeof count === 'object' && count !== null))) {
    env = count;
    count = 16;
  } else {
    validateInteger(count, 'count', 2);
  }

  return count <= 2 ** getColorDepth(env);
}

return {
  getColorDepth,
  hasColors,
};

};

// Real terminal output through the managed Writable implementation and an
// independently owned /dev/fd descriptor. Read streams/raw mode, pipe/file
// constructors and automatic SIGWINCH watching are outside this profile.
globalThis.__home_tool_tty_factory = function(tty, sizeOf, fs, writeDescriptor, Writable, readline, colors) {
  'use strict';
  const owned = new WeakMap();
  function failure(code, message, Type) {
    const error = new (Type || Error)(message);
    error.code = code;
    throw error;
  }
  class WriteStream extends Writable {
    constructor(fd, options) {
      if (typeof fd !== 'number' || !Number.isInteger(fd) || fd < 0 || fd > 0x7fffffff) failure('ERR_INVALID_FD', 'fd must be a positive integer', RangeError);
      if (options !== undefined && options !== null) failure('ERR_HOME_UNSUPPORTED', 'Home tty.WriteStream supports default stream options only');
      if (!tty.isatty(fd)) failure('ERR_TTY_INIT_FAILED', 'Home tty.WriteStream requires an actual terminal descriptor');
      const size = sizeOf(fd);
      if (!size) failure('ERR_TTY_INIT_FAILED', 'Cannot query native terminal size');
      super();
      // The private descriptor is closed exactly once by the existing FS host.
      // Destroying this writer never closes a caller-owned process descriptor.
      const duplicate = fs.openSync(`/dev/fd/${fd}`, 'w');
      owned.set(this, duplicate);
      this.isTTY = true;
      this.columns = size.columns;
      this.rows = size.rows;
    }
    _write(chunk, encoding, callback) {
      try { writeDescriptor('write', owned.get(this), chunk); }
      catch (error) { callback(error); return; }
      callback();
    }
    _destroy(error, callback) {
      const fd = owned.get(this);
      owned.delete(this);
      if (fd !== undefined) {
        try { fs.closeSync(fd); }
        catch (closeError) { error = error || closeError; }
      }
      callback(error);
    }
    getWindowSize() { return [this.columns, this.rows]; }
    _refreshSize() {
      const fd = owned.get(this);
      if (fd === undefined) return;
      const size = sizeOf(fd);
      if (!size) failure('ERR_TTY_INIT_FAILED', 'Cannot query native terminal size');
      if (size.columns === this.columns && size.rows === this.rows) return;
      this.columns = size.columns;
      this.rows = size.rows;
      this.emit('resize');
    }
    clearLine(direction, callback) { return readline.clearLine(this, direction, callback); }
    clearScreenDown(callback) { return readline.clearScreenDown(this, callback); }
    cursorTo(x, y, callback) { return readline.cursorTo(this, x, y, callback); }
    moveCursor(dx, dy, callback) { return readline.moveCursor(this, dx, dy, callback); }
  }
  WriteStream.prototype.getColorDepth = colors.getColorDepth;
  WriteStream.prototype.hasColors = colors.hasColors;
  tty.WriteStream = WriteStream;
  return tty;
};
