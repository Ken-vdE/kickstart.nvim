-- Translate Claude's zero-based IDE coordinates only for OpenCode clients.
--
-- OpenCode deliberately discovers Claude IDE WebSocket servers, but its TUI
-- models editor positions as one-based (like its Zed integration).  Until
-- OpenCode normalizes Claude/LSP positions itself, sending the same payload to
-- both clients makes line 2 appear as #1 in OpenCode.

local M = {}
local installed = false

local function increment_position(position)
  if type(position) ~= 'table' then return end
  if type(position.line) == 'number' then position.line = position.line + 1 end
  if type(position.character) == 'number' then position.character = position.character + 1 end
end

local function increment_selection(selection)
  if type(selection) ~= 'table' then return end
  increment_position(selection.start)
  increment_position(selection['end'])
end

---Return an OpenCode-specific copy of a Claude IDE notification payload.
---@param method string
---@param params table|nil
---@return table|nil
function M.translate(method, params)
  if type(params) ~= 'table' then return params end

  if method == 'selection_changed' then
    local translated = vim.deepcopy(params)
    increment_selection(translated.selection)
    if type(translated.ranges) == 'table' then
      for _, range in ipairs(translated.ranges) do
        increment_selection(range.selection)
      end
    end
    return translated
  end

  if method == 'at_mentioned' then
    local translated = vim.deepcopy(params)
    if type(translated.lineStart) == 'number' then translated.lineStart = translated.lineStart + 1 end
    if type(translated.lineEnd) == 'number' then translated.lineEnd = translated.lineEnd + 1 end
    return translated
  end

  return params
end

function M.setup()
  if installed then return end

  local server = require 'claudecode.server.init'
  local tcp_server = require 'claudecode.server.tcp'
  local live_claim = require 'custom.opencode_live_claim'
  local register_handlers = server.register_handlers

  local function disconnect_unclaimed_opencodes()
    local active_server = server.state.server
    if not active_server or live_claim.accepts(server.state.port) then return end

    for _, client in pairs(active_server.clients or {}) do
      if client._ide_client_name == 'opencode' then
        tcp_server.close_client(active_server, client.id, 1000, 'OpenCode context claimed by another Neovim')
      end
    end
  end

  live_claim.setup(disconnect_unclaimed_opencodes)

  -- OpenCode identifies itself during initialize. Store that identity on the
  -- connection so broadcasts can be encoded per client.
  server.register_handlers = function(...)
    register_handlers(...)
    local initialize = server.state.handlers.initialize
    server.state.handlers.initialize = function(client, params)
      local client_info = type(params) == 'table' and params.clientInfo or nil
      client._ide_client_name = type(client_info) == 'table' and client_info.name or nil
      return initialize(client, params)
    end

    -- claudecode.nvim only broadcasts when the cursor or selection changes.
    -- Replay the current editor state when OpenCode finishes connecting so a
    -- freshly started TUI has context without requiring an extra cursor move.
    local initialized = server.state.handlers['notifications/initialized']
    server.state.handlers['notifications/initialized'] = function(client, params)
      local result = initialized(client, params)
      if client._ide_client_name == 'opencode' then
        if live_claim.accepts(server.state.port) then
          local selection = require 'claudecode.selection'
          local current = selection.get_latest_selection() or selection.get_cursor_position()
          server.send(client, 'selection_changed', M.translate('selection_changed', current))
        else
          vim.schedule(disconnect_unclaimed_opencodes)
        end
      end
      return result
    end
  end

  -- claudecode.nvim normally encodes once and broadcasts the identical JSON to
  -- every client. Encode per connection so Claude keeps its native LSP values
  -- while OpenCode receives the one-based values its TUI expects.
  server.broadcast = function(method, params)
    local tcp_server = server.state.server
    if not tcp_server then return false end

    for _, client in pairs(tcp_server.clients or {}) do
      local payload = params
      if client._ide_client_name == 'opencode' then
        payload = M.translate(method, params)
      end
      server.send(client, method, payload)
    end
    return true
  end

  installed = true
end

return M
