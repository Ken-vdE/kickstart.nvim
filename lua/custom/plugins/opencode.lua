-- OpenCode's Neovim bridge: context-aware prompts and its own TUI/API server.
-- Requires the `opencode` CLI on $PATH (already installed locally).

vim.pack.add {
  {
    src = 'https://github.com/nickjvandyke/opencode.nvim',
    version = vim.version.range '*',
  },
}

---@type opencode.Opts
vim.g.opencode_opts = {}

-- Selecting/connecting an OpenCode HTTP server also makes this Neovim the
-- workspace's live editor. Other Neovims keep Claude clients but release their
-- OpenCode socket, which then rediscovers this instance.
vim.api.nvim_create_autocmd('User', {
  pattern = 'OpencodeEvent:server.connected',
  callback = function()
    local ok, err = require('custom.opencode_live_claim').claim()
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'OpenCode live context' })
    end
  end,
})

pcall(function()
  require('which-key').add { { '<leader>o', group = '[O]penCode', mode = { 'n', 'x' } } }
end)

local map = function(mode, keys, rhs, desc)
  vim.keymap.set(mode, keys, rhs, { desc = 'OpenCode: ' .. desc })
end

-- `@this` is the visual selection when present, otherwise the cursor context.
-- The trailing space tells opencode.nvim to append without submitting.
map({ 'n', 'x' }, '<leader>oa', function()
  require('opencode').prompt '@this '
end, 'add this to prompt')
-- Opens the composer with the current file attached, ready for your prompt.
-- This mirrors ClaudeCodeAdd: it does not submit a message by itself.
map('n', '<leader>ob', function()
  require('opencode').prompt '@buffer '
end, 'add current buffer')
map({ 'n', 'x' }, '<leader>op', function()
  require('opencode').select()
end, 'select prompt')
map('n', '<leader>oc', function()
  local ok, err = require('custom.opencode_live_claim').claim()
  if ok then
    vim.notify('This Neovim now owns live OpenCode context for the workspace', vim.log.levels.INFO)
  else
    vim.notify(err, vim.log.levels.WARN, { title = 'OpenCode live context' })
  end
end, 'claim live context')
map('n', '<leader>oh', '<cmd>checkhealth opencode<cr>', 'health check')
