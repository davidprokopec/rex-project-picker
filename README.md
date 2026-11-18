# rex-project-picker

A native session and project picker for [Rex](https://www.superlogical.com/rex).

Switch between open Rex sessions or open a folder from your sesh/zoxide history, in one searchable native palette. No floating terminal, fzf, or tmux required.

## Requirements

- Both the Rex app and running server must support `rex.ui.pick` (Preview 21 / macOS build 2042 or newer).
- Optional: [sesh](https://github.com/joshmedeski/sesh) and `jq` for configured projects and zoxide history; otherwise [zoxide](https://github.com/ajeetdsouza/zoxide) alone works.
- Without either history source, the working directory and home directory are still available. You can always type a directory path.

## Install

```sh
git clone https://github.com/davidprokopec/rex-project-picker.git \
  "${XDG_CONFIG_HOME:-$HOME/.config}/rex/rex-project-picker"
```

Add this to your Rex `init.lua`:

```lua
require("rex-project-picker").setup()
```

Reload:

```sh
rex config reload
```

Press **Ctrl+Space**, release, then **f**.

## Usage

- **Terminal icon:** switch to that existing session by its exact ID.
- **Folder icon:** open a session rooted in that directory, or reuse a session with the same folder basename.
- **Type a path:** submit an absolute path, `~/…`, or a path relative to `work_dir`.
- **Escape:** cancel without switching sessions.

Sessions appear first; folders keep the ranking from your history. An invalid path reopens the picker with your text preserved. Missing directories are filtered out.

The palette uses Rex's native keyboard navigation. This plugin does not remap navigation keys.

### Updated the app but prompts do not open?

The app, CLI, and running server can be different versions. Check the running server with `rex whoami --json`, not just `rex version`. An older server can keep running after an app update and reject prompts as `unsupported`.

In **Rex Settings → Server → Rex Server**, check the compatibility notice and update/restart the server when ready. Save your work first: restarting the server interrupts running terminals and programs.

## Configuration

All options are optional:

```lua
require("rex-project-picker").setup{
  key = "ctrl+space>f",        -- false to register the action without a binding
  action = "rex_project_picker",
  title = "Switch Project…",
  work_dir = os.getenv("HOME"),
}
```

Bind the registered action elsewhere if desired:

```lua
rex.bind("cmd+shift+k", "rex_project_picker")
```

## Notes

- This creates an independent native palette; it does not modify Rex's built-in session dropdown.
- The list contains up to 2,000 items, with existing sessions taking priority.
- There is no recursive disk scan or live filesystem completion. Type an existing path to reach a directory outside your history.
- Folder-session reuse is based on the directory basename. Two folders named `api` share the existing `api` session; use distinct session names when you need to distinguish them.
- Filesystem root `/` is not offered as a project.
- History paths containing newlines are not supported.
- History commands may refresh their own caches, just as when run directly.
- GUI-started servers often have a minimal `PATH`. For history discovery, the plugin also searches `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and `~/.cargo/bin`.

## Development

No build step or Lua package dependencies:

```sh
lua tests.lua
luac -p init.lua
```

The tests stub Rex's API and do not switch or create live sessions.

## License

MIT
