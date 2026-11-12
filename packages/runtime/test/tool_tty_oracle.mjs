// Refresh with the pinned Node reference; candidate runs use only saved facts.
import tty from 'node:tty';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
if(process.version!=='v26.10.0')throw new Error('Use pinned Node v26.10.0');
const environments=[{},...['xterm','XTERM','xterm-256color','xterm-kitty','vt100','vt220','dumb','mosh','direct','linux','foo'].map(TERM=>({TERM}))];
for(const FORCE_COLOR of ['','0','1','true','false','2','3','4','wat'])environments.push({FORCE_COLOR,TERM:'dumb'});
for(const NO_COLOR of ['','1'])for(const NODE_DISABLE_COLORS of ['','1'])environments.push({NO_COLOR,NODE_DISABLE_COLORS,TERM:'xterm-256color'});
for(const TEAMCITY_VERSION of ['9.0.0','9.1.0','9.0001.1','10.0','2026.1','8.1.0','wat'])environments.push({TEAMCITY_VERSION});
for(const name of ['APPVEYOR','BUILDKITE','CIRCLECI','DRONE','GITEA_ACTIONS','GITHUB_ACTIONS','GITLAB_CI','TRAVIS','UNKNOWN_CI'])for(const CI of ['','1','0'])environments.push({CI,[name]:'1',TERM:'xterm'});
for(const TERM_PROGRAM of ['iTerm.app','HyperTerm','MacTerm','Apple_Terminal','unknown'])for(const TERM_PROGRAM_VERSION of ['','2.0','3.0','10.0'])environments.push({TERM_PROGRAM,TERM_PROGRAM_VERSION});
for(const TERM of ['dumb','xterm','xterm-256color','foo','mosh'])for(const COLORTERM of ['','truecolor','24bit','yes'])for(const TMUX of ['','yes'])environments.push({TERM,COLORTERM,TMUX});
const counts=[2,16,256,65536,16777216,4294967296];
const cases=environments.map(env=>({env,depth:tty.WriteStream.prototype.getColorDepth(env),colors:counts.map(n=>tty.WriteStream.prototype.hasColors(n,env))}));
writeFileSync(fileURLToPath(new URL('./tool_modules/tty_color_oracle.json',import.meta.url)),JSON.stringify({node:process.version,counts,cases})+'\n');
console.log('PINNED TTY COLOR ORACLE '+cases.length);
