// ClaudeLights Companion — focuses the integrated terminal that hosts a
// specific Claude Code session.
//
// The ClaudeLights menu bar app opens
//   <scheme>://tokyn-studio.claudelights-companion/focus?pid=<claude pid>
// when a session is clicked (scheme = vscode / antigravity / cursor / …).
// The claude process is a descendant of the terminal's shell, so walking the
// claude pid's ancestor chain and matching it against each terminal's
// processId identifies the right tab.
//
// The pid arrives via a world-writable file, so it is untrusted: before any
// focusing, the pid must belong to an actual claude CLI process — otherwise
// a crafted entry could steer keyboard focus to an arbitrary terminal.
// All process inspection is async; the extension host event loop is never
// blocked on ps.

const vscode = require('vscode');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

async function ps(args) {
  const { stdout } = await execFileAsync('/bin/ps', args);
  return stdout;
}

/** The pid's command must be the claude CLI (same rule as ClaudeLights:
 *  basename "claude", or a path under a claude install dir). */
async function isClaudeProcess(pid) {
  try {
    const out = await ps(['-p', String(pid), '-o', 'command=']);
    const executable = out.trim().split(/\s+/)[0] ?? '';
    const basename = executable.split('/').pop();
    return basename === 'claude' || executable.includes('/claude/');
  } catch {
    return false; // process gone (ps exits non-zero)
  }
}

/** Map of pid -> parent pid for all live processes. */
async function parentMap() {
  const out = await ps(['-axo', 'pid=,ppid=']);
  const map = new Map();
  for (const line of out.trim().split('\n')) {
    const [pid, ppid] = line.trim().split(/\s+/).map(Number);
    if (pid) map.set(pid, ppid);
  }
  return map;
}

async function focusSessionTerminal(claudePid) {
  const parents = await parentMap();
  const ancestors = new Set();
  let current = claudePid;
  for (let i = 0; i < 20 && current && current > 1; i++) {
    ancestors.add(current);
    current = parents.get(current);
  }

  for (const terminal of vscode.window.terminals) {
    const shellPid = await terminal.processId;
    if (shellPid && ancestors.has(shellPid)) {
      terminal.show(false); // false: give the terminal keyboard focus
      return true;
    }
  }
  return false;
}

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        try {
          const params = new URLSearchParams(uri.query);
          const pid = Number.parseInt(params.get('pid') ?? '', 10);
          if (!Number.isInteger(pid) || pid <= 1 || pid > 0x7fffffff) return;
          if (!(await isClaudeProcess(pid))) return;
          await focusSessionTerminal(pid);
        } catch (error) {
          console.error('claudelights-companion:', error);
        }
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
