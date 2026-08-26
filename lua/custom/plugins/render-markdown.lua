-- Render markdown files nicely inside Neovim.
--
-- Uses the treesitter `markdown` and `markdown_inline` parsers (installed in
-- init.lua) and picks up mini.icons automatically. Rendering is active in
-- Normal mode and hides on the cursor line for editing (anti-conceal);
-- `:RenderMarkdown toggle` (or buftoggle) switches it off entirely.

vim.pack.add { { src = 'https://github.com/MeanderingProgrammer/render-markdown.nvim' } }

require('render-markdown').setup {
  -- No latex renderer installed (utftex / latex2text); silence the health check.
  latex = { enabled = false },
}
