-- Coordinate OpenCode's live editor socket across Neovim instances that share
-- a workspace. OpenCode discovers Claude IDE lockfiles independently from
-- opencode.nvim's HTTP server selection, so without coordination it can remain
-- attached to an older Neovim in another terminal tab.

local M = {}
local uv = vim.uv or vim.loop
local claim_dir = vim.fs.joinpath(vim.fn.stdpath 'state', 'opencode-editor-claims')
local watcher
local on_change
local owned_paths = {}

local function workspace()
  local cwd = vim.fn.getcwd()
  return uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
end

local function claim_path(root)
  return vim.fs.joinpath(claim_dir, vim.fn.sha256(root) .. '.json')
end

local function lock_path(port)
  return vim.fs.joinpath(vim.fn.expand '~/.claude/ide', tostring(port) .. '.lock')
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then return nil end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, '\n'))
  return decoded and type(value) == 'table' and value or nil
end

local function process_alive(pid)
  if type(pid) ~= 'number' then return false end
  local ok, result = pcall(uv.kill, pid, 0)
  return ok and result == 0
end

local function valid(claim, root)
  if type(claim) ~= 'table' then return false end
  if claim.workspace ~= root or type(claim.port) ~= 'number' then return false end
  if not process_alive(claim.pid) then return false end

  local lock = read_json(lock_path(claim.port))
  return lock ~= nil and lock.pid == claim.pid
end

local function touch_owner(claim)
  local path = lock_path(claim.port)
  if not uv.fs_stat(path) then return end
  local now = os.time()
  uv.fs_utime(path, now, now)
end

---Return the valid live-editor claim for this workspace, if any.
---@return table|nil
function M.current()
  local root = workspace()
  local path = claim_path(root)
  local claim = read_json(path)
  if valid(claim, root) then return claim end

  -- Best-effort stale lease cleanup. A new claim always wins via atomic rename.
  if claim then pcall(uv.fs_unlink, path) end
  return nil
end

---Whether this Neovim's Claude IDE server may accept an OpenCode client.
---@param port number|nil
---@return boolean
function M.accepts(port)
  local claim = M.current()
  if not claim then return true end
  if claim.pid == vim.fn.getpid() and claim.port == port then return true end
  touch_owner(claim)
  return false
end

---Claim live OpenCode context for this Neovim and workspace.
---@return boolean success
---@return string|nil error
function M.claim()
  local server = require 'claudecode.server.init'
  local port = server.state.port
  if not port or not server.state.server then
    return false, 'Claude IDE server is not running'
  end

  vim.fn.mkdir(claim_dir, 'p')
  local root = workspace()
  local claim = {
    workspace = root,
    pid = vim.fn.getpid(),
    port = port,
    claimed_at = os.time(),
  }

  -- OpenCode chooses the newest equally-specific lockfile when reconnecting.
  touch_owner(claim)

  local path = claim_path(root)
  local temporary = path .. '.' .. tostring(claim.pid) .. '.tmp'
  local wrote, write_result = pcall(vim.fn.writefile, { vim.json.encode(claim) }, temporary)
  if not wrote or write_result ~= 0 then
    return false, 'Could not write OpenCode editor claim'
  end

  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    pcall(uv.fs_unlink, temporary)
    return false, 'Could not activate OpenCode editor claim: ' .. tostring(rename_error)
  end

  owned_paths[path] = true
  if on_change then on_change(claim) end
  return true
end

function M.release()
  -- A Neovim can change its cwd and claim more than one workspace over its
  -- lifetime. Release every lease it still owns without deleting replacements.
  for path in pairs(owned_paths) do
    local claim = read_json(path)
    if claim and claim.pid == vim.fn.getpid() then
      pcall(uv.fs_unlink, path)
    end
    owned_paths[path] = nil
  end
end

---Watch claims made by other Neovim processes.
---@param callback fun(claim: table|nil)
function M.setup(callback)
  on_change = callback
  if watcher then return end

  vim.fn.mkdir(claim_dir, 'p')
  watcher = uv.new_fs_event()
  if watcher then
    watcher:start(claim_dir, {}, function()
      vim.schedule(function()
        if on_change then on_change(M.current()) end
      end)
    end)
  end

  local group = vim.api.nvim_create_augroup('OpenCodeLiveClaim', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      M.release()
      if watcher and not watcher:is_closing() then
        watcher:stop()
        watcher:close()
      end
      watcher = nil
    end,
  })
end

return M
