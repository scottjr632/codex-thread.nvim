# codex-thread.nvim

Send the current Neovim buffer context to an already-open Codex desktop thread.

## Status

This is very, very, very experimental.

The default transport talks to Codex desktop through an internal IPC socket. That
socket and protocol are not a public API. They can change without warning, and
this plugin may break after a Codex desktop update.

Use this as a personal workflow bridge, not as a stable integration contract.

## What It Is For

`codex-thread.nvim` is useful when you are editing code in Neovim inside the
Codex desktop integrated terminal and want to send context back to the visible
Codex thread without copying and pasting.

Common workflows:

- Highlight a function and ask Codex what it does.
- Send a file and line reference without sending the full code.
- Send both the selected code and its file reference.
- Send a short message to the current Codex thread from inside Neovim.

Example message sent from a visual selection:

````text
what does this function do?
Neovim context:
- Reference: /path/to/project/lua/example.lua:17-42

Selected text from /path/to/project/lua/example.lua:17-42:
```lua
local function example()
  return true
end
```
````

## Requirements

- Neovim 0.10 or newer.
- Codex desktop running for the default `desktop-ipc` transport.
- Codex CLI on `PATH` only if you opt into cwd-based thread resolution.
- macOS is the only environment this has been exercised on so far.

## Installation

With lazy.nvim:

```lua
{
  "scottjr632/codex-thread.nvim",
  config = function()
    require("codex_thread").setup()
  end,
}
```

With a local checkout:

```lua
{
  dir = "~/path/to/codex-thread.nvim",
  config = function()
    require("codex_thread").setup()
  end,
}
```

## Setup

Minimal setup:

```lua
require("codex_thread").setup()
```

Full defaults:

```lua
require("codex_thread").setup({
  codex_bin = "codex",
  transport = "desktop-ipc",
  proxy_socket = nil,
  desktop_ipc_socket = nil,
  desktop_ipc_wait_for_start_response = false,
  desktop_ipc_request_timeout_ms = 15000,
  timeout_ms = 120000,
  resolve_timeout_ms = 10000,
  resolve_thread_from_cwd = false,
  max_text_bytes = 40000,
  keymaps = true,
  notify_started = true,
  notify_delivered = true,
  require_user_message = true,
  fail_if_thread_not_idle = true,
  log_enabled = false,
  log_file = nil,
})
```

## Thread Resolution

The plugin chooses a target thread in this order:

1. `config.thread_id`
2. `vim.g.codex_thread_id`
3. `$CODEX_THREAD_ID`
4. If `resolve_thread_from_cwd = true`, the most recently updated Codex thread
   whose `cwd` matches Neovim's current working directory, resolved through
   `codex app-server`.

By default, cwd-based discovery is disabled because it can pick the wrong thread
when several Codex threads are active in the same repository.

Set the thread explicitly:

```vim
:CodexThreadSetId 019...
```

Or configure a fixed thread id:

```lua
require("codex_thread").setup({
  thread_id = "019...",
})
```

Opt into cwd-based discovery only if that matches your workflow:

```lua
require("codex_thread").setup({
  resolve_thread_from_cwd = true,
})
```

You can inspect the active target with:

```vim
:CodexThreadStatus
```

## Commands

- `:CodexThreadSend [message]` sends selected/current text and the file reference.
- `:CodexThreadSendText [message]` sends selected/current text only.
- `:CodexThreadSendRef [message]` sends the file reference and line numbers only.
- `:CodexThreadSendMessage [message]` sends only a message.
- `:CodexThreadStatus` shows the active thread id and transport.
- `:CodexThreadResolve` resolves and caches the thread id for the current cwd
  when `resolve_thread_from_cwd = true`.
- `:CodexThreadLog` opens the JSONL log file.
- `:CodexThreadLogClear` clears the log file.

All send commands prompt for a message when no message argument is provided. Use
`!` to skip the prompt and send only the selected context:

```vim
:'<,'>CodexThreadSend!
```

## Keymaps

When `keymaps = true`, these mappings are installed:

- Visual or normal `<leader>cs`: send text and reference.
- Visual or normal `<leader>ct`: send text only.
- Visual or normal `<leader>cr`: send reference only.
- Normal `<leader>cm`: send message only.

In visual mode, the selected range is used. In normal mode, context commands use
the current line.

## Transports

### `desktop-ipc`

This is the default and the only path that is expected to update the already-open
Codex desktop thread.

It connects to:

```text
$TMPDIR/codex-ipc/ipc-<uid>.sock
```

The plugin initializes with the desktop IPC router, writes a
`thread-follower-start-turn` request, then closes the socket. Closing quickly is
intentional: Codex desktop can broadcast large thread state snapshots over the
same socket, and Neovim does not need to consume those responses for the common
"send this prompt" workflow.

Set this only while debugging:

```lua
desktop_ipc_wait_for_start_response = true
```

That slower mode waits for the desktop thread owner to acknowledge the
start-turn request.

### `stdio`

`transport = "stdio"` starts `codex app-server --stdio` for each request. It can
append turns to the same persisted thread data, but the visible Codex desktop UI
may not live-refresh because this is a separate app-server process.

### `proxy`

The proxy transport exists for older experimentation with
`codex app-server proxy`. It is not the default because stale or disabled control
sockets can accept a job without producing useful delivery feedback.

## Logging

Logging is off by default:

```lua
log_enabled = false
```

Enable it while debugging:

```lua
require("codex_thread").setup({
  log_enabled = true,
})
```

The default log file is:

```lua
vim.fn.stdpath("state") .. "/codex-thread.nvim.log"
```

Open it with:

```vim
:CodexThreadLog
```

Useful desktop IPC events:

- `desktop_ipc.initialize.ok`: connected to the Codex desktop IPC router.
- `desktop_ipc.start_turn.sent`: wrote the start-turn request and closed.
- `desktop_ipc.start_turn.ok`: desktop owner acknowledged the turn. This only
  appears when `desktop_ipc_wait_for_start_response = true`.
- `desktop_ipc.send_turn.finish`: final result for the desktop IPC send path.

Useful `stdio`/`proxy` events:

- `turn.start.accepted`: Codex accepted the `turn/start` request.
- `send_turn.user_message_seen`: app-server emitted the user message item.
- `send.ok`: the turn completed or went idle after the user message was seen.
- `send.failed`: the app-server exited, idled, or completed without emitting a
  user message.

## Troubleshooting

If nothing appears in Codex desktop:

1. Confirm the target thread:

   ```vim
   :CodexThreadStatus
   ```

2. Set it manually if needed:

   ```vim
   :CodexThreadSetId 019...
   ```

3. Enable logs and send again:

   ```lua
   require("codex_thread").setup({
     log_enabled = true,
   })
   ```

4. Open the log:

   ```vim
   :CodexThreadLog
   ```

If Neovim feels slow after sending, make sure
`desktop_ipc_wait_for_start_response` is `false`. The default fast path closes
the socket before Neovim starts reading large Codex desktop stream broadcasts.

## Caveats

- The default IPC protocol is private to Codex desktop.
- The socket path can change if Codex desktop changes its IPC implementation.
- This has mainly been tested on one macOS workflow.
- There is no guarantee that a successful socket write means Codex will complete
  the turn. It means the request was handed to Codex desktop IPC.
- Public use should assume breakage and require occasional maintenance.
