-- Claude Code IDE integration.
--
-- Runs a small WebSocket server and drops a lockfile in `~/.claude/ide/`, which
-- lets the Claude Code CLI read the current file, cursor position and visual
-- selection, pull LSP diagnostics, and render diffs back into Neovim.
--
-- Claude runs in its own terminal (tmux pane, separate window, ...) and attaches
-- with `/ide` or `claude --ide` from the same project directory. The `none`
-- terminal provider means this plugin never spawns or manages a Claude terminal
-- inside Neovim, so there is no risk of ending up with two sessions.
--
-- Snacks.nvim is intentionally not installed: claudecode.nvim only uses it for
-- a floating terminal window, which the `none` provider does not need anyway.

vim.pack.add { { src = 'https://github.com/coder/claudecode.nvim' } }

require('claudecode').setup {
  terminal = { provider = 'none' },
}

-- Document the key chain with which-key (loaded earlier in init.lua).
pcall(function()
  require('which-key').add {
    { '<leader>a', group = '[A]I / Claude', mode = { 'n', 'v' } },
  }
end)

local map = function(keys, cmd, desc, mode)
  vim.keymap.set(mode or 'n', keys, cmd, { desc = 'Claude: ' .. desc })
end

-- Context. Selections are tracked automatically; these are for explicit sends.
map('<leader>ab', '<cmd>ClaudeCodeAdd %<cr>', 'Add current buffer')
map('<leader>as', '<cmd>ClaudeCodeSend<cr>', 'Send selection', 'v')

-- Add the file under the cursor from neo-tree (enabled in init.lua).
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'neo-tree',
  callback = function(ev)
    vim.keymap.set('n', '<leader>as', '<cmd>ClaudeCodeTreeAdd<cr>', {
      buffer = ev.buf,
      desc = 'Claude: Add file from tree',
    })
  end,
})

-- Diffs Claude opens in this Neovim instance.
map('<leader>aa', '<cmd>ClaudeCodeDiffAccept<cr>', 'Accept diff')
map('<leader>ad', '<cmd>ClaudeCodeDiffDeny<cr>', 'Deny diff')
map('<leader>ax', '<cmd>ClaudeCodeCloseAllDiffs<cr>', 'Close all diffs')

-- Server control, for when the external session loses the connection.
map('<leader>aS', '<cmd>ClaudeCodeStatus<cr>', 'Server status')
map('<leader>aR', '<cmd>ClaudeCodeStop<cr><cmd>ClaudeCodeStart<cr>', 'Restart server')

-- Optional in-Neovim Claude, without changing the configured default.
--
-- The provider is resolved from the module-level table at call time, and
-- `build_config()` only whitelists appearance keys, so a per-call
-- `{ provider = 'native' }` override is silently dropped. Flipping
-- `terminal.defaults.provider` around the call is the only way in. It is
-- restored to 'none' as soon as no managed terminal buffer is left, so the
-- external `/ide` workflow keeps the no-op provider it expects.
local DEFAULT_PROVIDER = 'none'

local function with_native(fn)
  local term = require 'claudecode.terminal'
  term.defaults.provider = 'native'

  local ok, err = pcall(fn, term)

  -- Keep 'native' while a terminal exists, so toggling it back off still works.
  if not term.get_active_terminal_bufnr() then
    term.defaults.provider = DEFAULT_PROVIDER
  end

  if not ok then
    error(err)
  end
end

-- The spawned process exits (`/quit`, Ctrl-D) -> hand the provider back. The
-- buffer outlives the job, so match on the closing buffer rather than on
-- whether a managed terminal buffer still exists.
vim.api.nvim_create_autocmd('TermClose', {
  callback = function(ev)
    local ok, term = pcall(require, 'claudecode.terminal')
    if ok and ev.buf == term.get_active_terminal_bufnr() then
      term.defaults.provider = DEFAULT_PROVIDER
    end
  end,
})

map('<leader>ac', function()
  with_native(function(term)
    term.simple_toggle { split_side = 'right', split_width_percentage = 0.35 }
  end)
end, 'Toggle Claude in a split')

map('<leader>af', function()
  with_native(function(term)
    term.focus_toggle { split_side = 'right', split_width_percentage = 0.35 }
  end)
end, 'Focus Claude split')

map('<leader>am', function()
  with_native(function()
    vim.cmd 'ClaudeCodeSelectModel'
  end)
end, 'Open Claude with model')
