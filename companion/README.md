# ClaudeLights Companion

Companion extension for the [ClaudeLights](https://github.com/tokyn-studio/claude-lights)
macOS menu bar app.

Without it, clicking a session that runs inside VS Code (or a fork like
Antigravity, Cursor, or Windsurf) can only bring the right *window* to the
front. With the companion installed, ClaudeLights deep-links into the editor
and focuses the **exact integrated-terminal tab** the session runs in — even
with several Claude Code sessions open in the same window.

## How it works

ClaudeLights records each session's `claude` process id via its hooks. On
click it opens `<scheme>://tokyn-studio.claudelights-companion/focus?pid=…`;
this extension resolves the pid's ancestor chain against the process ids of
the open terminals and calls `terminal.show()` on the match. No servers, no
polling, no configuration.

## Install

```sh
cd companion
./build.sh                       # produces claudelights-companion-<version>.vsix
# then, depending on your editor:
code        --install-extension claudelights-companion-*.vsix
antigravity --install-extension claudelights-companion-*.vsix
cursor      --install-extension claudelights-companion-*.vsix
```

ClaudeLights detects the installed companion automatically — no setting to
flip. Sessions started before ClaudeLights v0.2 (or before the hooks were
updated) lack the pid field until their next activity.
