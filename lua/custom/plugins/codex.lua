-- Dependency-free Codex `/ide` bridge. An external `codex` session can run
-- `/ide` to read this Neovim instance's active file, selection, and open tabs.

local uv = vim.uv
local codex_home = vim.env.CODEX_HOME or vim.fn.expand '~/.codex'
local ipc_dir, socket_path = codex_home .. '/ipc', codex_home .. '/ipc/ipc.sock'
local client_id = 'nvim-' .. tostring(uv.os_getpid())
local listener, clients, terminal_buffer, socket_inode = nil, {}, nil, nil
local role, provider_pipe, providers, pending = 'stopped', nil, {}, {}
local MAX_SELECTION_BYTES = 64 * 1024

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Codex IDE' })
end

local function project_root(path)
  local start = path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd()
  return vim.fs.root(start, { '.git', '.jj', 'package.json', 'pyproject.toml', 'go.mod', 'Cargo.toml' }) or vim.fn.getcwd()
end

local function active_buffer()
  local current = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(current) ~= '' then return current end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) ~= '' then return buf end
  end
  return current
end

local function selection(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local cursor = { line = row - 1, character = col }
  local mode = vim.fn.mode(true):sub(1, 1)
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then return cursor, cursor, '' end

  -- '< and '> are only updated after Visual mode ends. `/ide` is commonly
  -- invoked from another terminal while Neovim remains in Visual mode, so use
  -- the live Visual anchor ('v') and cursor instead.
  local anchor = vim.fn.getpos('v')
  local anchor_pos = { line = math.max(anchor[2] - 1, 0), character = math.max(anchor[3] - 1, 0) }
  local start, finish
  if mode == 'V' then
    local first_line, last_line = math.min(anchor_pos.line, cursor.line), math.max(anchor_pos.line, cursor.line)
    start = { line = first_line, character = 0 }
    finish = { line = last_line, character = #(vim.api.nvim_buf_get_lines(buf, last_line, last_line + 1, false)[1] or '') }
  elseif anchor_pos.line < cursor.line or (anchor_pos.line == cursor.line and anchor_pos.character <= cursor.character) then
    start, finish = anchor_pos, { line = cursor.line, character = cursor.character + 1 }
  else
    start, finish = cursor, { line = anchor_pos.line, character = anchor_pos.character + 1 }
  end
  local text = table.concat(vim.api.nvim_buf_get_text(buf, start.line, start.character, finish.line, finish.character, {}), '\n')
  if #text > MAX_SELECTION_BYTES then
    text = text:sub(1, MAX_SELECTION_BYTES) .. '\n[Selection truncated by Neovim Codex bridge]'
  end
  return start, finish, text
end

local function ide_context()
  local buf = active_buffer()
  local path = vim.api.nvim_buf_get_name(buf)
  local root = project_root(path)
  local start, finish, text = selection(buf)
  local tabs, seen = {}, {}
  for _, open_buf in ipairs(vim.api.nvim_list_bufs()) do
    local open_path = vim.api.nvim_buf_get_name(open_buf)
    local normalized = open_path ~= '' and vim.fs.normalize(open_path) or ''
    if normalized ~= '' and vim.bo[open_buf].buflisted and not seen[normalized] then
      seen[normalized] = true
      table.insert(tabs, {
        label = vim.fn.fnamemodify(normalized, ':t'),
        path = vim.fs.relpath(root, normalized) or normalized,
        fsPath = normalized,
      })
    end
  end
  table.sort(tabs, function(a, b) return a.path < b.path end)
  return root, {
    activeFile = path ~= '' and {
      label = vim.fn.fnamemodify(path, ':t'), path = vim.fn.fnamemodify(path, ':.'), fsPath = path,
      selection = { start = start, ['end'] = finish }, activeSelectionContent = text, selections = {},
    } or nil,
    openTabs = tabs,
  }
end

local function workspace_roots()
  local roots, seen = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buf)
    if path ~= '' then
      local root = vim.fs.normalize(project_root(path))
      if not seen[root] then seen[root] = true; table.insert(roots, root) end
    end
  end
  if #roots == 0 then table.insert(roots, vim.fs.normalize(vim.fn.getcwd())) end
  return roots
end

local function frame(value)
  local payload = vim.json.encode(value)
  local size = #payload
  return string.char(size % 256, math.floor(size / 256) % 256, math.floor(size / 65536) % 256, math.floor(size / 16777216) % 256) .. payload
end

local function send(pipe, value)
  if not pipe:is_closing() then pipe:write(frame(value)) end
end

local function respond_error(pipe, request_id, message)
  if request_id then send(pipe, { type = 'response', requestId = request_id, resultType = 'error', error = message }) end
end

local function handle(pipe, message)
  if message.type == 'nvim-register' or message.type == 'nvim-update' then
    if role == 'router' and message.clientId then providers[message.clientId] = { pipe = pipe, roots = message.roots or {} } end
    return
  end
  if message.type == 'nvim-context-request' and role == 'client' then
    local root, context = ide_context()
    send(pipe, { type = 'nvim-context-response', requestId = message.requestId, root = root, context = context })
    return
  end
  if message.type == 'nvim-context-response' and role == 'router' then
    local request = pending[message.requestId]
    if request then
      pending[message.requestId] = nil
      send(request.pipe, { type = 'response', requestId = message.requestId, resultType = 'success', method = 'ide-context', handledByClientId = client_id, result = { type = 'broadcast', ideContext = message.context } })
    end
    return
  end
  local root, context = ide_context()
  local requested_root = message.params and message.params.workspaceRoot
  local matches = not requested_root or vim.fs.normalize(requested_root) == vim.fs.normalize(root)
  if message.type == 'client-discovery-request' then
    send(pipe, { type = 'client-discovery-response', requestId = message.requestId, response = { canHandle = matches, clientId = client_id } })
  elseif message.type == 'request' and message.method == 'ide-context' and matches then
    send(pipe, {
      type = 'response', requestId = message.requestId, resultType = 'success', method = 'ide-context', handledByClientId = client_id,
      result = { type = 'broadcast', ideContext = context },
    })
  elseif message.type == 'request' and message.method == 'ide-context' then
    local wanted = requested_root and vim.fs.normalize(requested_root)
    local provider
    for _, candidate in pairs(providers) do
      for _, candidate_root in ipairs(candidate.roots) do if candidate_root == wanted then provider = candidate; break end end
      if provider then break end
    end
    if provider and provider.pipe and not provider.pipe:is_closing() then
      pending[message.requestId] = { pipe = pipe }
      send(provider.pipe, { type = 'nvim-context-request', requestId = message.requestId, workspaceRoot = wanted })
      vim.defer_fn(function()
        if pending[message.requestId] then pending[message.requestId] = nil; respond_error(pipe, message.requestId, 'request-timeout') end
      end, 4500)
    else
      respond_error(pipe, message.requestId, 'no-client-found')
    end
  else
    respond_error(pipe, message.requestId, 'no-handler-for-request')
  end
end

local function read_client(pipe)
  local buffered = ''
  pipe:read_start(function(err, chunk)
    if err then notify('IPC read error: ' .. err, vim.log.levels.ERROR) end
    if not chunk then
      clients[pipe] = nil
      if not pipe:is_closing() then pipe:close() end
      return
    end
    buffered = buffered .. chunk
    while #buffered >= 4 do
      local b1, b2, b3, b4 = buffered:byte(1, 4)
      local length = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
      if length > 16 * 1024 * 1024 then pipe:close(); return end
      if #buffered < length + 4 then return end
      local payload = buffered:sub(5, length + 4)
      buffered = buffered:sub(length + 5)
      local ok, message = pcall(vim.json.decode, payload)
      if ok and type(message) == 'table' then
        -- libuv read callbacks are fast events. Collecting buffer/cursor state
        -- must run on Neovim's main loop, not inside this callback.
        vim.schedule(function()
          if not pipe:is_closing() then handle(pipe, message) end
        end)
      else
        vim.schedule(function() notify('Rejected invalid IPC JSON', vim.log.levels.WARN) end)
      end
    end
  end)
end

local function stop_ipc()
  for pipe in pairs(clients) do if not pipe:is_closing() then pipe:close() end end
  clients = {}
  if listener and not listener:is_closing() then listener:close() end
  listener = nil
  local stat = uv.fs_lstat(socket_path)
  if stat and stat.type == 'socket' and stat.ino == socket_inode then uv.fs_unlink(socket_path) end
  socket_inode = nil
end

local function start_ipc()
  if listener and not listener:is_closing() then return end
  vim.fn.mkdir(ipc_dir, 'p', '0700')
  uv.fs_chmod(ipc_dir, 448) -- 0700
  local stat = uv.fs_lstat(socket_path)
  if stat then
    if stat.type == 'socket' then
      local pipe = uv.new_pipe(false)
      pipe:connect(socket_path, function(err)
        vim.schedule(function()
          if err then notify('Could not join Codex IPC router: ' .. err, vim.log.levels.ERROR); return end
          role, provider_pipe = 'client', pipe
          clients[pipe] = true
          read_client(pipe)
          send(pipe, { type = 'nvim-register', clientId = client_id, roots = workspace_roots() })
        end)
      end)
    else
      notify('Refusing to replace non-socket: ' .. socket_path, vim.log.levels.ERROR)
    end
    return
  end
  listener = uv.new_pipe(false)
  local bound, bind_err = listener:bind(socket_path)
  if not bound then listener:close(); listener = nil; notify('Could not bind IPC socket: ' .. tostring(bind_err), vim.log.levels.ERROR); return end
  uv.fs_chmod(socket_path, 384) -- 0600
  socket_inode = (uv.fs_lstat(socket_path) or {}).ino
  role = 'router'
  local listening, listen_err = listener:listen(32, function(err)
    if err then notify('IPC listener error: ' .. err, vim.log.levels.ERROR); return end
    local pipe = uv.new_pipe(false)
    listener:accept(pipe)
    clients[pipe] = true
    read_client(pipe)
  end)
  if not listening then
    listener:close()
    listener = nil
    notify('Could not listen on IPC socket: ' .. tostring(listen_err), vim.log.levels.ERROR)
  end
end

local function toggle_terminal()
  if terminal_buffer and vim.api.nvim_buf_is_valid(terminal_buffer) then
    local windows = vim.fn.win_findbuf(terminal_buffer)
    if #windows > 0 then vim.api.nvim_set_current_win(windows[1]); vim.cmd 'startinsert'; return end
  end
  vim.cmd 'botright vsplit | enew'
  terminal_buffer = vim.api.nvim_get_current_buf()
  vim.bo[terminal_buffer].bufhidden, vim.bo[terminal_buffer].buflisted = 'hide', false
  vim.fn.termopen({ 'codex', '--cd', project_root(vim.api.nvim_buf_get_name(0)), '--no-alt-screen' }, { on_exit = function() terminal_buffer = nil end })
  vim.cmd 'startinsert'
end

-- `/ide` is Codex's pull-based live-context protocol. These mappings cover
-- the complementary workflow: copy a native Codex @-mention for pasting into
-- any external Codex terminal.
local function copy_mention(with_selection)
  local buf = active_buffer()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' then
    notify('Current buffer is not backed by a file', vim.log.levels.WARN)
    return
  end
  local relative = vim.fs.relpath(project_root(path), path) or path
  local mention = '@' .. relative
  if with_selection then
    local mode = vim.fn.mode(true):sub(1, 1)
    local first, last
    if mode == 'v' or mode == 'V' or mode == '\22' then
      local anchor = vim.fn.getpos('v')
      local cursor = vim.api.nvim_win_get_cursor(0)
      first, last = { anchor[2], anchor[3] }, { cursor[1], cursor[2] }
    else
      first, last = vim.api.nvim_buf_get_mark(buf, '<'), vim.api.nvim_buf_get_mark(buf, '>')
    end
    if first[1] == 0 or last[1] == 0 then
      notify('No visual selection to copy', vim.log.levels.WARN)
      return
    end
    mention = string.format('%s:%d-%d', mention, math.min(first[1], last[1]), math.max(first[1], last[1]))
  end
  vim.fn.setreg('+', mention)
  vim.fn.setreg('"', mention)
  vim.api.nvim_echo({ { mention .. ' copied to clipboard', 'ModeMsg' } }, false, {})
  notify('Copied ' .. mention .. ' — paste it into Codex')
end

start_ipc()
vim.api.nvim_create_user_command('Codex', toggle_terminal, { desc = 'Open Codex terminal' })
vim.api.nvim_create_user_command('CodexIpcStatus', function()
  local state = role == 'router' and ('Router listening at ' .. socket_path) or role == 'client' and 'Connected to Codex IPC router' or 'IPC bridge is stopped'
  notify(state)
end, { desc = 'Show Codex IDE bridge status' })
vim.api.nvim_create_user_command('CodexIpcRestart', function() stop_ipc(); start_ipc() end, { desc = 'Restart Codex IDE bridge' })
vim.api.nvim_create_autocmd('VimLeavePre', { callback = stop_ipc })
vim.api.nvim_create_autocmd({ 'BufEnter', 'DirChanged', 'VimResized' }, {
  callback = function()
    if role == 'client' and provider_pipe and not provider_pipe:is_closing() then
      send(provider_pipe, { type = 'nvim-update', clientId = client_id, roots = workspace_roots() })
    end
  end,
})

-- Kickstart uses mini.statusline. Keep the indicator deliberately small:
-- `CX` means the external Codex `/ide` socket is ready, `CX!` means it is not.
pcall(function()
  local statusline = require 'mini.statusline'
  local original = statusline.section_location
  statusline.section_location = function(...)
    local state = role ~= 'stopped' and ' CX ' or ' CX! '
    return state .. original(...)
  end
end)

pcall(function() require('which-key').add { { '<leader>c', group = '[C]odex', mode = { 'n', 'x' } } } end)
vim.keymap.set('n', '<leader>ct', '<cmd>Codex<cr>', { desc = 'Codex: toggle terminal' })
vim.keymap.set('n', '<leader>ci', '<cmd>CodexIpcStatus<cr>', { desc = 'Codex: IDE bridge status' })
vim.keymap.set('n', '<leader>cb', function() copy_mention(false) end, { desc = 'Codex: copy buffer mention' })
vim.keymap.set('x', '<leader>cs', function() copy_mention(true) end, { desc = 'Codex: copy selection mention' })
vim.api.nvim_create_user_command('CodexCopyBuffer', function() copy_mention(false) end, { desc = 'Copy current Codex buffer mention' })
vim.api.nvim_create_user_command('CodexCopySelection', function() copy_mention(true) end, { range = true, desc = 'Copy current Codex selection mention' })
