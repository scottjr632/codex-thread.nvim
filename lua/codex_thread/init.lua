local client = require("codex_thread.client")

local M = {}

local defaults = {
  codex_bin = "codex",
  transport = "desktop-ipc",
  proxy_socket = nil,
  desktop_ipc_socket = nil,
  desktop_ipc_wait_for_start_response = false,
  desktop_ipc_request_timeout_ms = 15000,
  timeout_ms = 120000,
  resolve_timeout_ms = 10000,
  resolve_thread_from_cwd = true,
  max_text_bytes = 40000,
  keymaps = true,
  notify_started = true,
  notify_delivered = true,
  require_user_message = true,
  fail_if_thread_not_idle = true,
  log_enabled = false,
  log_file = nil,
}

local config = vim.deepcopy(defaults)
local resolved_thread_ids_by_cwd = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "codex-thread.nvim" })
end

local function log(event, fields)
  client.log(config, event, fields)
end

local function log_file()
  return config.log_file or client.default_log_file()
end

local function merge_config(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function get_thread_id()
  return config.thread_id or vim.g.codex_thread_id or vim.env.CODEX_THREAD_ID
end

local function get_cwd()
  return vim.fn.getcwd()
end

local function resolve_thread_id(callback)
  local explicit_thread_id = get_thread_id()
  if explicit_thread_id and explicit_thread_id ~= "" then
    log("thread.resolve.explicit", {
      thread_id = explicit_thread_id,
    })
    callback(explicit_thread_id, "explicit")
    return
  end

  if config.resolve_thread_from_cwd == false then
    log("thread.resolve.disabled", {})
    callback(nil, "disabled")
    return
  end

  local cwd = get_cwd()
  local cached_thread_id = resolved_thread_ids_by_cwd[cwd]
  if cached_thread_id then
    log("thread.resolve.cached", {
      cwd = cwd,
      thread_id = cached_thread_id,
    })
    callback(cached_thread_id, "cached")
    return
  end

  client.resolve_thread(config, cwd, function(ok, message, thread)
    if not ok then
      notify(message or "Failed to resolve Codex thread id.", vim.log.levels.ERROR)
      log("thread.resolve.failed", {
        cwd = cwd,
        message = message,
      })
      callback(nil, "failed")
      return
    end

    resolved_thread_ids_by_cwd[cwd] = thread.id
    notify("Resolved Codex thread " .. thread.id .. " for " .. cwd)
    log("thread.resolve.cwd", {
      cwd = cwd,
      thread_id = thread.id,
    })
    callback(thread.id, "cwd", thread)
  end)
end

local function normalize_range(start_line, start_col, end_line, end_col)
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    return end_line, end_col, start_line, start_col
  end
  return start_line, start_col, end_line, end_col
end

local function buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function line_reference(path, start_line, end_line)
  if start_line == end_line then
    return path .. ":" .. start_line
  end
  return path .. ":" .. start_line .. "-" .. end_line
end

local function get_text_for_range(bufnr, start_line, start_col, end_line, end_col, mode)
  if mode == "line" then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), "\n")
  end

  local lines = vim.api.nvim_buf_get_text(bufnr, start_line - 1, start_col - 1, end_line - 1, end_col, {})
  return table.concat(lines, "\n")
end

local function visual_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local selection_mode = "char"
  local start_pos
  local end_pos

  if mode:match("[vV\22]") then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
    if mode == "V" then
      selection_mode = "line"
    elseif mode == "\22" then
      selection_mode = "block"
    end
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
    if vim.fn.visualmode() == "V" then
      selection_mode = "line"
    elseif vim.fn.visualmode() == "\22" then
      selection_mode = "block"
    end
  end

  local start_line, start_col, end_line, end_col =
    normalize_range(start_pos[2], start_pos[3], end_pos[2], end_pos[3])

  if selection_mode == "block" then
    selection_mode = "line"
  end

  return {
    bufnr = bufnr,
    path = buffer_path(bufnr),
    start_line = start_line,
    end_line = end_line,
    text = get_text_for_range(bufnr, start_line, start_col, end_line, end_col, selection_mode),
  }
end

local function command_context(command_opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = command_opts and command_opts.line1 or vim.fn.line(".")
  local end_line = command_opts and command_opts.line2 or start_line

  return {
    bufnr = bufnr,
    path = buffer_path(bufnr),
    start_line = start_line,
    end_line = end_line,
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), "\n"),
  }
end

local function current_line_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")

  return {
    bufnr = bufnr,
    path = buffer_path(bufnr),
    start_line = line,
    end_line = line,
    text = vim.api.nvim_get_current_line(),
  }
end

local function get_context(opts)
  opts = opts or {}
  if opts.visual then
    return visual_context()
  end
  if opts.command_opts and opts.command_opts.range and opts.command_opts.range > 0 then
    return command_context(opts.command_opts)
  end
  return current_line_context()
end

local function trim_text(text)
  local max_text_bytes = config.max_text_bytes
  if not max_text_bytes or #text <= max_text_bytes then
    return text, nil
  end

  return text:sub(1, max_text_bytes), "Selected text was truncated to " .. max_text_bytes .. " bytes."
end

local function filetype_fence(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    return ""
  end
  return ft
end

local function build_prompt(context, message, include_text, include_reference)
  local parts = {}
  local trimmed_text, truncation_note = trim_text(context.text or "")

  if message and message ~= "" then
    table.insert(parts, message)
  end

  table.insert(parts, "Neovim context:")

  if include_reference then
    table.insert(parts, "- Reference: " .. line_reference(context.path, context.start_line, context.end_line))
  end

  if include_text then
    if truncation_note then
      table.insert(parts, "- Note: " .. truncation_note)
    end
    table.insert(parts, "")
    table.insert(parts, "Selected text from " .. line_reference(context.path, context.start_line, context.end_line) .. ":")
    table.insert(parts, "```" .. filetype_fence(context.bufnr))
    table.insert(parts, trimmed_text)
    table.insert(parts, "```")
  end

  return table.concat(parts, "\n")
end

local function prompt_for_message(callback)
  vim.ui.input({ prompt = "Codex message: " }, function(input)
    if input == nil then
      return
    end
    callback(input)
  end)
end

local function send_with_message(opts, message)
  opts = opts or {}
  local include_text = opts.include_text == true
  local include_reference = opts.include_reference ~= false
  local context = get_context(opts)
  local prompt = opts.message_only and (message or "") or build_prompt(context, message, include_text, include_reference)

  log("send.requested", {
    include_text = include_text,
    include_reference = include_reference,
    message_only = opts.message_only == true,
    prompt_bytes = #prompt,
    path = context.path,
    start_line = context.start_line,
    end_line = context.end_line,
  })

  if prompt == "" then
    notify("Nothing to send to Codex.", vim.log.levels.WARN)
    log("send.empty", {})
    return
  end

  resolve_thread_id(function(thread_id)
    if not thread_id or thread_id == "" then
      notify("No Codex thread id found. Set one with :CodexThreadSetId or open Neovim in a directory with a recent Codex thread.", vim.log.levels.ERROR)
      log("send.no_thread_id", {})
      return
    end

    client.send_turn(config, thread_id, prompt, function(ok, result_message)
      if ok then
        notify(result_message or "Sent to Codex.")
        log("send.ok", {
          thread_id = thread_id,
          message = result_message,
        })
      else
        notify(result_message or "Failed to send to Codex.", vim.log.levels.ERROR)
        log("send.failed", {
          thread_id = thread_id,
          message = result_message,
        })
      end
    end)
  end)
end

function M.send(opts)
  opts = opts or {}
  local args = opts.args or ""

  if args ~= "" or opts.no_prompt then
    send_with_message(opts, args)
    return
  end

  prompt_for_message(function(message)
    send_with_message(opts, message)
  end)
end

function M.send_both(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    include_text = true,
    include_reference = true,
  })
  M.send(opts)
end

function M.send_text(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    include_text = true,
    include_reference = false,
  })
  M.send(opts)
end

function M.send_reference(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    include_text = false,
    include_reference = true,
  })
  M.send(opts)
end

function M.send_message(opts)
  opts = vim.tbl_extend("force", opts or {}, {
    message_only = true,
  })
  M.send(opts)
end

function M.status()
  local explicit_thread_id = get_thread_id()
  local transport = config.transport or "auto"
  if explicit_thread_id and explicit_thread_id ~= "" then
    notify("thread_id=" .. explicit_thread_id .. " source=explicit transport=" .. transport)
    log("status", {
      thread_id = explicit_thread_id,
      source = "explicit",
      transport = transport,
      log_file = log_file(),
    })
    return
  end

  local cwd = get_cwd()
  local cached_thread_id = resolved_thread_ids_by_cwd[cwd]
  if cached_thread_id then
    notify("thread_id=" .. cached_thread_id .. " source=cwd-cache cwd=" .. cwd .. " transport=" .. transport)
    log("status", {
      thread_id = cached_thread_id,
      source = "cwd-cache",
      cwd = cwd,
      transport = transport,
      log_file = log_file(),
    })
    return
  end

  if config.resolve_thread_from_cwd == false then
    notify("thread_id=nil source=none transport=" .. transport)
    log("status", {
      source = "none",
      transport = transport,
      log_file = log_file(),
    })
    return
  end

  notify("Resolving Codex thread for cwd " .. cwd .. "...")
  resolve_thread_id(function(thread_id, source)
    notify("thread_id=" .. tostring(thread_id) .. " source=" .. tostring(source) .. " cwd=" .. cwd .. " transport=" .. transport)
    log("status", {
      thread_id = thread_id,
      source = source,
      cwd = cwd,
      transport = transport,
      log_file = log_file(),
    })
  end)
end

function M.resolve()
  local cwd = get_cwd()
  resolved_thread_ids_by_cwd[cwd] = nil
  resolve_thread_id(function(thread_id, source)
    notify("thread_id=" .. tostring(thread_id) .. " source=" .. tostring(source) .. " cwd=" .. cwd)
  end)
end

local function create_user_command(name, callback, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, callback, opts)
end

local function create_commands()
  create_user_command("CodexThreadSend", function(command_opts)
    M.send_both({
      args = command_opts.args,
      command_opts = command_opts,
      no_prompt = command_opts.bang,
    })
  end, { nargs = "*", range = true, bang = true, desc = "Send selection/current line and reference to Codex" })

  create_user_command("CodexThreadSendText", function(command_opts)
    M.send_text({
      args = command_opts.args,
      command_opts = command_opts,
      no_prompt = command_opts.bang,
    })
  end, { nargs = "*", range = true, bang = true, desc = "Send selection/current line text to Codex" })

  create_user_command("CodexThreadSendRef", function(command_opts)
    M.send_reference({
      args = command_opts.args,
      command_opts = command_opts,
      no_prompt = command_opts.bang,
    })
  end, { nargs = "*", range = true, bang = true, desc = "Send file and line reference to Codex" })

  create_user_command("CodexThreadSendMessage", function(command_opts)
    M.send_message({
      args = command_opts.args,
      command_opts = command_opts,
      no_prompt = command_opts.bang,
    })
  end, { nargs = "*", bang = true, desc = "Send a message to the current Codex thread" })

  create_user_command("CodexThreadStatus", function()
    M.status()
  end, { desc = "Show Codex thread bridge status" })

  create_user_command("CodexThreadResolve", function()
    M.resolve()
  end, { desc = "Resolve and cache the Codex thread id for the current cwd" })

  create_user_command("CodexThreadLog", function()
    vim.cmd.edit(vim.fn.fnameescape(log_file()))
  end, { desc = "Open the codex-thread.nvim log file" })

  create_user_command("CodexThreadLogClear", function()
    vim.fn.writefile({}, log_file())
    notify("Cleared " .. log_file())
  end, { desc = "Clear the codex-thread.nvim log file" })

  create_user_command("CodexThreadSetId", function(command_opts)
    vim.g.codex_thread_id = command_opts.args
    log("thread.set_id", {
      thread_id = command_opts.args,
    })
    notify("Codex thread id set to " .. command_opts.args)
  end, { nargs = 1, desc = "Set the Codex thread id for this Neovim session" })
end

local function map(lhs, rhs, desc, mode)
  vim.keymap.set(mode or { "n", "x" }, lhs, rhs, { desc = desc, silent = true })
end

local function create_keymaps()
  map("<leader>cs", function()
    M.send_both({ visual = vim.fn.mode():match("[vV\22]") ~= nil })
  end, "Codex: send text and ref")

  map("<leader>ct", function()
    M.send_text({ visual = vim.fn.mode():match("[vV\22]") ~= nil })
  end, "Codex: send text")

  map("<leader>cr", function()
    M.send_reference({ visual = vim.fn.mode():match("[vV\22]") ~= nil })
  end, "Codex: send ref")

  map("<leader>cm", function()
    M.send_message()
  end, "Codex: send message", "n")
end

function M.setup(opts)
  merge_config(opts)
  create_commands()

  if config.keymaps then
    create_keymaps()
  end
end

M._build_prompt = build_prompt
M._get_context = get_context
M._resolve_thread_id = resolve_thread_id
M._log_file = log_file

return M
