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
