-- SPDX-License-Identifier: MIT
-- Options and their defaults. require('tern').setup(opts) merges opts over
-- them; every module reads require('tern.config').options at use time.
local M = {}

M.defaults = {
  -- The language server command, e.g. { 'node', '/path/to/tern-cli.js', 'lsp' }.
  -- nil: found per buffer (see tern.cli).
  cmd = nil,
  -- Start `tern lsp` for notes: diagnostics, completion, rename, hover …
  lsp = true,
  -- Fold from the language server (blocks, fences, sections); without
  -- node, headings only.
  fold = true,
  -- Virtual text drawn from the server's outline.
  render = {
    enabled = true,
    labels = true, -- "Theorem 1" beside a numbered block's opener
    refs = true, -- what an @reference will read as
    math = true, -- simple TeX shown as Unicode beside the formula
    conceal = true, -- math, block and inline element syntax drawn in place of the source, but under the cursor
  },
  -- :TernPreview, a local server that refreshes the browser as you type.
  preview = {
    host = '127.0.0.1',
    port = 0, -- 0: any free port
    open = true, -- open the page in a browser
    browser = nil, -- the command to open it with; nil: vim.ui.open
    update = 'change', -- 'change': the page follows the note's buffer, written or not; 'write': on each write
  },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
