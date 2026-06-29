# codex-thread.nvim

Small Neovim bridge for sending the current buffer context to a Codex thread.

This targets the Codex desktop app's integrated-terminal workflow. The default
transport uses Codex desktop's internal IPC socket, so it can break if the app's
private protocol changes.

The plugin reads `CODEX_THREAD_ID` when it exists. If the integrated terminal
does not export that variable, it falls back to Codex app-server `thread/list`
and uses the most recently updated thread whose `cwd` matches Neovim's current
working directory. You can override the resolved thread for a Neovim session
with:

```vim
:CodexThreadSetId 019...
```

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

Requirements:

- Neovim 0.10 or newer.
- Codex CLI on `PATH` for cwd-based thread resolution.
- Codex desktop app running for the default `desktop-ipc` transport.

## Commands

- `:CodexThreadSend [message]` sends selected/current text and the file reference.
- `:CodexThreadSendText [message]` sends selected/current text only.
- `:CodexThreadSendRef [message]` sends the file reference and line numbers only.
- `:CodexThreadSendMessage [message]` sends only a message.
- `:CodexThreadStatus` shows the active thread id and transport.
- `:CodexThreadResolve` resolves and caches the thread id for the current cwd.
- `:CodexThreadLog` opens the JSONL log file.
- `:CodexThreadLogClear` clears the log file.

All send commands prompt for a message when no message argument is provided. Use
`!` to skip the prompt and send only the selected context:

```vim
:'<,'>CodexThreadSend!
```

## Keymaps

- Visual or normal `<leader>cs`: send text and reference.
- Visual or normal `<leader>ct`: send text only.
- Visual or normal `<leader>cr`: send reference only.
- Normal `<leader>cm`: send message only.

In visual mode, the selected range is used. In normal mode, the current line is
used for context commands.

## Setup

```lua
require("codex_thread").setup({
  transport = "desktop-ipc",
  codex_bin = "codex",
  resolve_thread_from_cwd = true,
  log_enabled = false,
  desktop_ipc_wait_for_start_response = false,
  -- log_file = vim.fn.stdpath("state") .. "/codex-thread.nvim.log",
})
```

`transport = "desktop-ipc"` connects to the Codex desktop IPC router at
`$TMPDIR/codex-ipc/ipc-<uid>.sock` and asks the open thread owner to start the
turn. This is the best fit for the integrated-terminal workflow because the
already-open desktop surface handles the message.

By default, the desktop IPC path waits only for the initial `initialize`
response, writes the start-turn request, then closes the socket. That keeps
Neovim from reading the desktop app's large thread-stream broadcasts. Set
`desktop_ipc_wait_for_start_response = true` only when debugging and you want
Neovim to wait for the desktop thread owner to acknowledge the start-turn
request.

`transport = "stdio"` starts `codex app-server --stdio` for each request. It can
append turns to the same persisted thread data, but the desktop UI may not
live-refresh because that process is not the app-server owned by the visible
Codex window.

The proxy transport exists, but a stale or disabled control socket can accept a
job without responding, so it is not the default.

Set `log_enabled = true` while debugging. The log file defaults to
`vim.fn.stdpath("state") .. "/codex-thread.nvim.log"`.

## Delivery checks

For `desktop-ipc`, the default success condition is intentionally lightweight:
the plugin initializes with the desktop IPC router, writes
`thread-follower-start-turn`, then closes the socket. This keeps Neovim from
reading large thread-stream broadcasts while Codex responds in the desktop app.

For `stdio` and `proxy`, the plugin waits until the app-server emits a
`userMessage` item for the target thread and then waits for the turn to complete
or become idle.

Useful log events:

- `desktop_ipc.initialize.ok`: connected to the Codex desktop IPC router.
- `desktop_ipc.start_turn.sent`: Neovim wrote the start-turn request to the
  desktop IPC socket and closed the connection.
- `desktop_ipc.start_turn.ok`: the open desktop thread owner accepted the turn.
  This only appears when `desktop_ipc_wait_for_start_response = true`.
- `desktop_ipc.send_turn.finish`: includes skipped broadcast counts/bytes for
  the slower debug acknowledgement path. The normal desktop IPC path closes
  before reading thread-stream broadcasts.
- `turn.start.accepted`: Codex accepted the request, but the message is not yet
  proven visible. This is used by the `stdio`/`proxy` transports.
- `send_turn.user_message_seen`: Codex emitted the user message item.
- `send.ok`: the turn completed or went idle after the user message was seen.
- `send.failed`: the app-server exited, idled, or completed without emitting a
  user message.

Open the log with:

```vim
:CodexThreadLog
```
