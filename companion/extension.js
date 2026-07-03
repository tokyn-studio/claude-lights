// ClaudeLights Companion — focuses the integrated terminal that hosts a
// specific Claude Code session.
//
// The ClaudeLights menu bar app opens
//   <scheme>://tokyn-studio.claudelights-companion/focus?pid=<claude pid>
// when a session is clicked (scheme = vscode / antigravity / cursor / …).
// The claude process is a descendant of the terminal's shell, so walking the
// claude pid's ancestor chain and matching it against each terminal's
// processId identifies the right tab.

const vscode = require('vscode');
const { execFileSync } = require('child_process');

/** Map of pid -> parent pid for all live processes. */
function parentMap() {
  const out = execFileSync('/bin/ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' });
  const map = new Map();
  for (const line of out.trim().split('\n')) {
    const [pid, ppid] = line.trim().split(/\s+/).map(Number);
    if (pid) map.set(pid, ppid);
  }
  return map;
}

async function focusSessionTerminal(claudePid) {
  const parents = parentMap();
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
          if (!Number.isInteger(pid) || pid <= 1) return;
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
