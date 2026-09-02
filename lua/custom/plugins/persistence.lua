-- Session persistence: reopen the same files when you return to a directory.
--
-- Sessions are keyed on cwd (plus git branch), stored under
-- `stdpath('state')/sessions`. Saving happens automatically on a clean exit
-- (`:qa`, `:wqa`); restoring happens automatically only when Neovim is started
-- with no file arguments, so `nvim some/file.lua` is never clobbered.

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

-- A neo-tree window in a saved session restores as an empty, broken buffer.
-- Close them before the session is written.
vim.api.nvim_create_autocmd('User', {
  pattern = 'PersistenceSavePre',
  group = vim.api.nvim_create_augroup('custom-persistence-save', { clear = true }),
  callback = function()
    if package.loaded['neo-tree'] then
      pcall(vim.cmd, 'Neotree close')
    end
  end,
})

-- Auto-restore, but only for a bare `nvim` in a directory that has a session.
-- `nested = true` is required, otherwise FileType/LSP/treesitter never fire on
-- the restored buffers.
vim.api.nvim_create_autocmd('VimEnter', {
  nested = true,
  group = vim.api.nvim_create_augroup('custom-persistence-restore', { clear = true }),
  callback = function()
    if vim.fn.argc() > 0 or vim.o.filetype == 'gitcommit' then
      return
    end
    require('persistence').load()
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
