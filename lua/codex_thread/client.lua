local M = {}

local message_seq = 0

local function json_decode(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if ok then
    return decoded
  end
  return nil
end

local function default_socket_path()
  return vim.fn.expand("~/.codex/app-server-control/app-server-control.sock")
end

local function default_desktop_ipc_socket_path()
  local tmpdir = vim.env.TMPDIR or "/tmp/"
  local sep = tmpdir:sub(-1) == "/" and "" or "/"
  local uv = vim.uv or vim.loop
  local uid = uv.getuid and uv.getuid() or vim.fn.systemlist({ "id", "-u" })[1]
  return tmpdir .. sep .. "codex-ipc/ipc-" .. tostring(uid) .. ".sock"
end

local function socket_exists(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat and stat.type == "socket"
end

local function command_for_config(config)
  local transport = config.transport or "auto"
  local codex_bin = config.codex_bin or "codex"

  if transport == "desktop-ipc" then
    transport = config.resolve_transport or "stdio"
  end

  if transport == "auto" then
    local socket = config.proxy_socket or default_socket_path()
    transport = socket_exists(socket) and "proxy" or "stdio"
  end

  if transport == "proxy" then
    local cmd = { codex_bin, "app-server", "proxy" }
    if config.proxy_socket then
      vim.list_extend(cmd, { "--sock", config.proxy_socket })
    end
    return cmd, transport
  end

  return { codex_bin, "app-server", "--stdio" }, "stdio"
end

local function encode_request(id, method, params)
  return vim.json.encode({
    id = id,
    method = method,
    params = params,
  }) .. "\n"
end

local function encode_ipc_frame(message)
  local body = vim.json.encode(message)
  local len = #body
  local header = string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
  return header .. body
end

local function ipc_frame_length(buffer)
  if #buffer < 4 then
    return nil
  end
  local b1, b2, b3, b4 = buffer:byte(1, 4)
  return b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
end

local function ipc_payload_is_broadcast(payload)
  -- Broadcast frames can contain full thread snapshots. Avoid decoding them in
  -- Neovim; this client only needs request responses and discovery requests.
  return payload:find('"type":"broadcast"', 1, true) ~= nil
end

local ipc_method_versions = {
  ["initialize"] = 0,
  ["thread-follower-start-turn"] = 1,
  ["thread-follower-steer-turn"] = 1,
}

local function ipc_method_version(method)
  return ipc_method_versions[method] or 0
end

local function result_turn_id(result)
  if type(result) ~= "table" then
    return nil
  end
  if result.turnId then
    return result.turnId
  end
  if type(result.turn) == "table" then
    return result.turn.id or result.turn.turnId
  end
  return nil
end

local function status_type(value)
  if type(value) == "table" then
    return value.type
  end
  return nil
end

local function client_user_message_id()
  local uv = vim.uv or vim.loop
  message_seq = message_seq + 1
  return "codex-thread.nvim-" .. tostring(os.time()) .. "-" .. string.format("%.0f", uv.hrtime()) .. "-" .. tostring(message_seq)
end

local function default_log_file()
  return vim.fn.stdpath("state") .. "/codex-thread.nvim.log"
end

local function redact_fields(fields)
  local result = vim.deepcopy(fields or {})
  if result.prompt then
    result.prompt = "<redacted>"
  end
  if result.input then
    result.input = "<redacted>"
  end
  return result
end

function M.log(config, event, fields)
  if config.log_enabled == false then
    return
  end

  local log_file = config.log_file or default_log_file()
  local record = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event = event,
    fields = redact_fields(fields),
  }

  local function write()
    local line = vim.json.encode(record)
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(log_file, ":h"), "p")
    pcall(vim.fn.writefile, { line }, log_file, "a")
  end

  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(write)
  else
    write()
  end
end

function M.default_log_file()
  return default_log_file()
end

function M.default_desktop_ipc_socket_path()
  return default_desktop_ipc_socket_path()
end

local function send_turn_desktop_ipc(config, thread_id, prompt, on_done)
  local uv = vim.uv or vim.loop
  local socket_path = config.desktop_ipc_socket or default_desktop_ipc_socket_path()
  local timeout_ms = config.timeout_ms or 120000
  local finished = false
  local initialized = false
  local start_requested = false
  local start_request_written = false
  local wait_for_start_response = config.desktop_ipc_wait_for_start_response == true
  local client_id = "initializing-client"
  local request_seq = 0
  local start_request_id
  local message_id = client_user_message_id()
  local cwd = config.cwd or vim.fn.getcwd()
  local buffer = ""
  local skipped_broadcast_count = 0
  local skipped_broadcast_bytes = 0
  local pipe
  local timer

  M.log(config, "desktop_ipc.send_turn.start", {
    thread_id = thread_id,
    socket_path = socket_path,
    prompt_bytes = #prompt,
    client_user_message_id = message_id,
  })

  local function close_pipe()
    if pipe and not pipe:is_closing() then
      pcall(function()
        pipe:read_stop()
      end)
      pcall(function()
        pipe:close()
      end)
    end
  end

  local function finish(ok, message, result)
    if finished then
      return
    end
    finished = true
    M.log(config, "desktop_ipc.send_turn.finish", {
      ok = ok,
      message = message,
      thread_id = thread_id,
      client_id = client_id,
      start_requested = start_requested,
      start_request_written = start_request_written,
      wait_for_start_response = wait_for_start_response,
      skipped_broadcast_count = skipped_broadcast_count,
      skipped_broadcast_bytes = skipped_broadcast_bytes,
      client_user_message_id = message_id,
      result_type = result and result.resultType or nil,
      handled_by_client_id = result and result.handledByClientId or nil,
      error = result and result.error or nil,
    })
    if timer then
      timer:stop()
      timer:close()
    end
    close_pipe()
    if on_done then
      vim.schedule(function()
        on_done(ok, message, result)
      end)
    end
  end

  local function write_message(message, on_written)
    if not pipe or pipe:is_closing() then
      if on_written then
        on_written("IPC pipe is closed")
      end
      return
    end
    local ok, err = pcall(function()
      pipe:write(encode_ipc_frame(message), function(write_err)
        if on_written then
          on_written(write_err)
        end
      end)
    end)
    if not ok and on_written then
      on_written(err)
    end
  end

  local function send_request(method, params, on_written)
    request_seq = request_seq + 1
    local request_id = "codex-thread.nvim-" .. tostring(os.time()) .. "-" .. tostring(request_seq)
    M.log(config, "desktop_ipc.send", {
      request_id = request_id,
      method = method,
      thread_id = params and (params.conversationId or params.threadId) or nil,
      source_client_id = client_id,
      version = ipc_method_version(method),
    })
    write_message({
      type = "request",
      requestId = request_id,
      sourceClientId = client_id,
      version = ipc_method_version(method),
      method = method,
      params = params,
      timeoutMs = config.desktop_ipc_request_timeout_ms or 15000,
    }, on_written)
    return request_id
  end

  local function send_start_turn()
    if start_requested then
      return
    end
    start_requested = true
    if not wait_for_start_response and pipe and not pipe:is_closing() then
      pcall(function()
        pipe:read_stop()
      end)
    end

    start_request_id = send_request("thread-follower-start-turn", {
      conversationId = thread_id,
      turnStartParams = {
        threadId = thread_id,
        cwd = cwd,
        clientUserMessageId = message_id,
        input = {
          {
            type = "text",
            text = prompt,
            text_elements = {},
          },
        },
      },
    }, function(write_err)
      if finished then
        return
      end
      if write_err then
        finish(false, "Failed to write Codex desktop IPC start-turn request: " .. tostring(write_err), {
          resultType = "write-error",
          error = tostring(write_err),
        })
        return
      end

      start_request_written = true
      M.log(config, "desktop_ipc.start_turn.sent", {
        thread_id = thread_id,
        request_id = start_request_id,
        client_user_message_id = message_id,
        wait_for_start_response = wait_for_start_response,
      })

      if not wait_for_start_response then
        finish(true, "Sent Codex desktop thread request", {
          resultType = "sent",
          requestId = start_request_id,
        })
      end
    end)
  end

  local function handle_response(message)
    if message.method == "initialize" then
      if message.resultType ~= "success" then
        finish(false, "Codex desktop IPC initialize failed: " .. tostring(message.error or "unknown error"), message)
        return
      end
      initialized = true
      client_id = message.result and message.result.clientId or client_id
      M.log(config, "desktop_ipc.initialize.ok", {
        client_id = client_id,
      })
      send_start_turn()
      if not wait_for_start_response then
        return "stop-reading"
      end
      return nil
    end

    if message.requestId == start_request_id or message.method == "thread-follower-start-turn" then
      if message.resultType == "success" then
        local result = message.result or {}
        local turn_result = result.result or result
        local turn_id = result_turn_id(turn_result)
        M.log(config, "desktop_ipc.start_turn.ok", {
          thread_id = thread_id,
          turn_id = turn_id,
          handled_by_client_id = message.handledByClientId,
          client_user_message_id = message_id,
        })
        finish(true, "Codex desktop thread accepted the turn", message)
      else
        finish(false, "Codex desktop IPC start-turn failed: " .. tostring(message.error or "unknown error"), message)
      end
    end
    return nil
  end

  local function handle_ipc_message(message)
    M.log(config, "desktop_ipc.receive", {
      type = message.type,
      method = message.method,
      request_id = message.requestId,
      result_type = message.resultType,
      handled_by_client_id = message.handledByClientId,
      broadcast_thread_id = message.params and message.params.conversationId or nil,
    })

    if message.type == "response" then
      return handle_response(message)
    end

    if message.type == "client-discovery-request" then
      write_message({
        type = "client-discovery-response",
        requestId = message.requestId,
        response = {
          canHandle = false,
        },
      })
    end
    return nil
  end

  local function handle_chunk(chunk)
    if not chunk or chunk == "" then
      return
    end
    buffer = buffer .. chunk
    while true do
      local len = ipc_frame_length(buffer)
      if not len or #buffer < 4 + len then
        return
      end
      local payload = buffer:sub(5, 4 + len)
      buffer = buffer:sub(5 + len)
      if ipc_payload_is_broadcast(payload) then
        skipped_broadcast_count = skipped_broadcast_count + 1
        skipped_broadcast_bytes = skipped_broadcast_bytes + len
      else
        local ok, message = pcall(vim.json.decode, payload)
        if not ok then
          finish(false, "Codex desktop IPC sent invalid JSON", nil)
          return
        end
        local action = handle_ipc_message(message)
        if action == "stop-reading" then
          buffer = ""
          return
        end
      end
    end
  end

  pipe = uv.new_pipe(false)
  if not pipe then
    finish(false, "Failed to create Codex desktop IPC pipe", nil)
    return
  end

  timer = uv.new_timer()
  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    finish(false, "Timed out waiting for Codex desktop IPC after " .. timeout_ms .. "ms", nil)
  end))

  pipe:connect(socket_path, function(err)
    if err then
      finish(false, "Failed to connect to Codex desktop IPC socket " .. socket_path .. ": " .. tostring(err), nil)
      return
    end

    pipe:read_start(function(read_err, chunk)
      if read_err then
        finish(false, "Codex desktop IPC read failed: " .. tostring(read_err), nil)
        return
      end
      handle_chunk(chunk)
    end)

    send_request("initialize", {
      clientType = "codex-thread.nvim",
    })
  end)
end

local function send_turn_app_server(config, thread_id, prompt, on_done)
  local cmd, transport = command_for_config(config)
  local timeout_ms = config.timeout_ms or 600000
  local stderr_lines = {}
  local finished = false
  local initialized = false
  local resumed = false
  local turn_started = false
  local user_message_seen = false
  local user_message_item_id
  local turn_id
  local message_id = client_user_message_id()
  local job_id
  local timer

  M.log(config, "send_turn.start", {
    thread_id = thread_id,
    transport = transport,
    cmd = cmd,
    prompt_bytes = #prompt,
    client_user_message_id = message_id,
  })

  local function finish(ok, message, result)
    if finished then
      return
    end
    finished = true
    M.log(config, "send_turn.finish", {
      ok = ok,
      message = message,
      thread_id = thread_id,
      turn_id = turn_id,
      user_message_seen = user_message_seen,
      user_message_item_id = user_message_item_id,
      client_user_message_id = message_id,
      result_id = result and result.id or nil,
      result_method = result and result.method or nil,
    })
    if timer then
      timer:stop()
      timer:close()
    end
    if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      pcall(vim.fn.chanclose, job_id, "stdin")
      if ok then
        vim.defer_fn(function()
          pcall(vim.fn.jobstop, job_id)
        end, 100)
      else
        pcall(vim.fn.jobstop, job_id)
      end
    end
    if on_done then
      vim.schedule(function()
        on_done(ok, message, result)
      end)
    end
  end

  local function send(line)
    if not job_id then
      return
    end
    vim.fn.chansend(job_id, line)
  end

  local function send_request(id, method, params)
    M.log(config, "jsonrpc.send", {
      id = id,
      method = method,
      thread_id = params and params.threadId or nil,
    })
    send(encode_request(id, method, params))
  end

  local function handle_rpc_message(message)
    local params = message.params or {}
    local result = message.result or {}
    local item = params.item or {}
    M.log(config, "jsonrpc.receive", {
      id = message.id,
      method = message.method,
      has_error = message.error ~= nil,
      thread_id = params.threadId,
      turn_id = params.turnId or result_turn_id(result),
      status_type = status_type(params.status),
      item_type = item.type,
      item_id = item.id,
    })

    if message.id == 1 then
      if message.error then
        finish(false, "Codex app-server initialize failed: " .. vim.inspect(message.error), message)
        return
      end

      initialized = true
      send_request(2, "thread/resume", {
        threadId = thread_id,
        excludeTurns = true,
      })
      return
    end

    if message.id == 2 then
      if message.error then
        finish(false, "Codex thread/resume failed: " .. vim.inspect(message.error), message)
        return
      end

      resumed = true
      local thread = result.thread or {}
      local resume_status_type = status_type(thread.status)
      M.log(config, "thread.resume.ok", {
        thread_id = thread.id or thread_id,
        status_type = resume_status_type,
        cwd = thread.cwd,
        updated_at = thread.updatedAt,
      })

      if config.fail_if_thread_not_idle ~= false and resume_status_type and resume_status_type ~= "idle" then
        finish(false, "Codex thread is " .. resume_status_type .. "; refusing to start a parallel turn", message)
        return
      end

      send_request(3, "turn/start", {
        threadId = thread_id,
        cwd = config.cwd or vim.fn.getcwd(),
        clientUserMessageId = message_id,
        input = {
          {
            type = "text",
            text = prompt,
          },
        },
      })
      return
    end

    if message.id == 3 then
      if message.error then
        finish(false, "Codex turn/start failed: " .. vim.inspect(message.error), message)
        return
      end

      turn_started = true
      turn_id = result_turn_id(result) or turn_id
      M.log(config, "turn.start.accepted", {
        thread_id = thread_id,
        turn_id = turn_id,
        client_user_message_id = message_id,
      })
      if config.notify_started ~= false then
        notify("Codex turn accepted for " .. thread_id .. " via " .. transport .. "; waiting for delivery")
      end
      return
    end

    if message.method == "item/started" or message.method == "item/completed" then
      if params.threadId == thread_id and item.type == "userMessage" then
        user_message_seen = true
        user_message_item_id = item.id or user_message_item_id
        turn_id = params.turnId or turn_id
        M.log(config, "send_turn.user_message_seen", {
          thread_id = thread_id,
          turn_id = turn_id,
          item_id = user_message_item_id,
          event = message.method,
          client_user_message_id = message_id,
        })
        if config.notify_delivered ~= false and message.method == "item/completed" then
          notify("Delivered user message to Codex thread " .. thread_id)
        end
      end
      return
    end

    if message.method == "turn/completed" then
      if not params.threadId or params.threadId == thread_id then
        if config.require_user_message ~= false and not user_message_seen then
          finish(false, "Codex turn completed without emitting a userMessage item", message)
        else
          finish(true, "Codex turn completed", message)
        end
      end
      return
    end

    if message.method == "thread/status/changed" then
      local status = params.status or {}
      if params.threadId == thread_id and status.type == "idle" and turn_started then
        if config.require_user_message ~= false and not user_message_seen then
          finish(false, "Codex thread went idle before emitting a userMessage item", message)
        else
          finish(true, "Codex thread is idle", message)
        end
      end
    end
  end

  local function handle_stdout(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        local message = json_decode(line)
        if message then
          handle_rpc_message(message)
        end
      end
    end
  end

  local function handle_stderr(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        table.insert(stderr_lines, line)
      end
    end
  end

  job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = handle_stdout,
    on_stderr = handle_stderr,
    on_exit = function(_, code)
      if finished then
        return
      end

      local stderr = table.concat(stderr_lines, "\n")
      if code ~= 0 then
        finish(false, "Codex app-server exited with code " .. code .. (stderr ~= "" and (": " .. stderr) or ""), nil)
      elseif not initialized then
        finish(false, "Codex app-server exited before initialize completed", nil)
      elseif not resumed then
        finish(false, "Codex app-server exited before thread/resume completed", nil)
      elseif not turn_started then
        finish(false, "Codex app-server exited before turn/start completed", nil)
      elseif config.require_user_message ~= false and not user_message_seen then
        finish(false, "Codex app-server exited after turn/start but before emitting a userMessage item", nil)
      else
        finish(true, "Codex app-server exited after starting the turn", nil)
      end
    end,
  })

  if job_id <= 0 then
    finish(false, "Failed to start Codex app-server command: " .. table.concat(cmd, " "), nil)
    return
  end

  M.log(config, "job.started", {
    job_id = job_id,
    thread_id = thread_id,
    transport = transport,
  })

  timer = (vim.uv or vim.loop).new_timer()
  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    finish(false, "Timed out waiting for Codex after " .. timeout_ms .. "ms", nil)
  end))

  send_request(1, "initialize", {
    clientInfo = {
      name = "codex-thread.nvim",
      version = "0.1.0",
    },
    capabilities = {
      experimentalApi = true,
    },
  })
end

function M.send_turn(config, thread_id, prompt, on_done)
  if config.transport == "desktop-ipc" then
    send_turn_desktop_ipc(config, thread_id, prompt, on_done)
    return
  end

  send_turn_app_server(config, thread_id, prompt, on_done)
end

function M.resolve_thread(config, cwd, on_done)
  local cmd, transport = command_for_config(config)
  local timeout_ms = config.resolve_timeout_ms or 10000
  local stderr_lines = {}
  local finished = false
  local initialized = false
  local requested = false
  local job_id
  local timer

  M.log(config, "resolve_thread.start", {
    cwd = cwd,
    transport = transport,
    cmd = cmd,
  })

  local function finish(ok, message, result)
    if finished then
      return
    end
    finished = true
    M.log(config, "resolve_thread.finish", {
      ok = ok,
      message = message,
      cwd = cwd,
      thread_id = ok and result and result.id or nil,
    })
    if timer then
      timer:stop()
      timer:close()
    end
    if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      pcall(vim.fn.chanclose, job_id, "stdin")
      vim.defer_fn(function()
        pcall(vim.fn.jobstop, job_id)
      end, 100)
    end
    if on_done then
      vim.schedule(function()
        on_done(ok, message, result)
      end)
    end
  end

  local function send(line)
    if job_id then
      vim.fn.chansend(job_id, line)
    end
  end

  local function send_request(id, method, params)
    M.log(config, "jsonrpc.send", {
      id = id,
      method = method,
      cwd = params and params.cwd or nil,
    })
    send(encode_request(id, method, params))
  end

  local function pick_thread(data)
    for _, thread in ipairs(data or {}) do
      if thread.cwd == cwd then
        return thread
      end
    end
    return (data or {})[1]
  end

  local function handle_rpc_message(message)
    M.log(config, "jsonrpc.receive", {
      id = message.id,
      method = message.method,
      has_error = message.error ~= nil,
    })

    if message.id == 1 then
      if message.error then
        finish(false, "Codex app-server initialize failed: " .. vim.inspect(message.error), message)
        return
      end

      initialized = true
      requested = true
      send_request(2, "thread/list", {
        cwd = cwd,
        limit = 5,
        sortKey = "updated_at",
        sortDirection = "desc",
        useStateDbOnly = true,
      })
      return
    end

    if message.id == 2 then
      if message.error then
        finish(false, "Codex thread/list failed: " .. vim.inspect(message.error), message)
        return
      end

      local result = message.result or {}
      local thread = pick_thread(result.data)
      if not thread or not thread.id then
        finish(false, "No Codex thread found for cwd " .. cwd, message)
        return
      end

      thread._transport = transport
      finish(true, "Resolved Codex thread " .. thread.id .. " for " .. cwd, thread)
    end
  end

  local function handle_stdout(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        local message = json_decode(line)
        if message then
          handle_rpc_message(message)
        end
      end
    end
  end

  local function handle_stderr(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        table.insert(stderr_lines, line)
      end
    end
  end

  job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = handle_stdout,
    on_stderr = handle_stderr,
    on_exit = function(_, code)
      if finished then
        return
      end

      local stderr = table.concat(stderr_lines, "\n")
      if code ~= 0 then
        finish(false, "Codex app-server exited with code " .. code .. (stderr ~= "" and (": " .. stderr) or ""), nil)
      elseif not initialized then
        finish(false, "Codex app-server exited before initialize completed", nil)
      elseif not requested then
        finish(false, "Codex app-server exited before thread/list was requested", nil)
      else
        finish(false, "Codex app-server exited before resolving a thread", nil)
      end
    end,
  })

  if job_id <= 0 then
    finish(false, "Failed to start Codex app-server command: " .. table.concat(cmd, " "), nil)
    return
  end

  M.log(config, "job.started", {
    job_id = job_id,
    cwd = cwd,
    transport = transport,
  })

  timer = (vim.uv or vim.loop).new_timer()
  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    finish(false, "Timed out resolving Codex thread after " .. timeout_ms .. "ms", nil)
  end))

  send_request(1, "initialize", {
    clientInfo = {
      name = "codex-thread.nvim",
      version = "0.1.0",
    },
    capabilities = {
      experimentalApi = true,
    },
  })
end

return M
