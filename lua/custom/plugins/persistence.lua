-- Session persistence: reopen the same files when you return to a directory.
--
-- Sessions are keyed on cwd (plus git branch), stored under
-- `stdpath('state')/sessions`. Saving happens automatically on a clean exit
-- (`:qa`, `:wqa`). Restoring happens on a bare `nvim` -- so `cd project && nvim`
-- picks up where you left off, while `nvim some/file.lua` is never clobbered.
--
-- Neo-tree is opened on every start and after any session load, with the same
-- directories unfolded as when you left.

vim.pack.add { { src = 'https://github.com/folke/persistence.nvim' } }

-- The default `sessionoptions` includes `options` and `blank`, which restore
-- stale global options over a freshly configured Neovim and break plugins.
-- `localoptions` is kept: neo-tree and friends need their per-window options.
vim.o.sessionoptions = 'buffers,curdir,folds,globals,skiprtp,tabpages,winsize,winpos,terminal,localoptions'

require('persistence').setup {
  -- Separate sessions per git branch, so a feature branch doesn't reopen the
  -- buffers you had on main.
  branch = true,
}

local group = vim.api.nvim_create_augroup('custom-persistence', { clear = true })

local function neotree_state()
  local ok, manager = pcall(require, 'neo-tree.sources.manager')
  if not ok then
    return nil
  end
  local got, state = pcall(manager.get_state, 'filesystem')
  return got and state or nil
end

-- Which directories are unfolded in the tree. Stashed in an uppercase global so
-- that `sessionoptions+=globals` writes it into the session file alongside the
-- buffer list -- no second state file to keep in sync with the session.
local function save_expanded_dirs()
  local state = neotree_state()
  if not (state and state.tree) then
    return
  end
  local dirs = require('neo-tree.ui.renderer').get_expanded_nodes(state.tree)
  vim.g.NeotreeExpanded = table.concat(dirs, '\n')
end

local function show_neotree()
  pcall(vim.cmd, 'Neotree show')

  local saved = vim.g.NeotreeExpanded
  if type(saved) ~= 'string' or saved == '' then
    return
  end
  local state = neotree_state()
  if not state then
    return
  end
  -- `force_open_folders` is consumed by the next render, which is how neo-tree
  -- itself rebuilds a tree's fold state (see its `setup/init.lua`).
  state.force_open_folders = vim.split(saved, '\n', { plain = true })
  pcall(require('neo-tree.sources.filesystem').navigate, state)
end

-- A neo-tree window in a saved session restores as an empty, broken buffer, so
-- its fold state is recorded and the window closed before the session is written.
vim.api.nvim_create_autocmd('User', {
  pattern = 'PersistenceSavePre',
  group = group,
  callback = function()
    save_expanded_dirs()
    pcall(vim.cmd, 'Neotree close')
  end,
})

-- Loading a session sources it, rebuilding the window layout from scratch --
-- which drops the neo-tree window that the session deliberately doesn't hold.
vim.api.nvim_create_autocmd('User', {
  pattern = 'PersistenceLoadPost',
  group = group,
  callback = show_neotree,
})

-- `nested = true` is required, otherwise FileType/LSP/treesitter never fire on
-- the restored buffers.
vim.api.nvim_create_autocmd('VimEnter', {
  nested = true,
  group = group,
  callback = function()
    if vim.fn.argc() == 0 then
      -- No-op when this cwd has no session yet; neo-tree still opens below.
      require('persistence').load()
    end
    show_neotree()
  end,
})

-- `<leader>q` is already the diagnostic loclist, so persistence's own default
-- `<leader>q*` maps are avoided here in favour of `<leader>S`.
require('which-key').add { { '<leader>S', group = '[S]ession' } }

vim.keymap.set('n', '<leader>Sr', function()
  require('persistence').load()
end, { desc = '[S]ession [R]estore for cwd' })

vim.keymap.set('n', '<leader>Sl', function()
  require('persistence').load { last = true }
end, { desc = '[S]ession restore [L]ast' })

vim.keymap.set('n', '<leader>Ss', function()
  require('persistence').select()
end, { desc = '[S]ession [S]elect' })

vim.keymap.set('n', '<leader>Sd', function()
  require('persistence').stop()
end, { desc = '[S]ession [D]on\'t save on exit' })
