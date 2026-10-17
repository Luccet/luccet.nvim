-- SPDX-License-Identifier: MIT
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true

local buf = vim.api.nvim_get_current_buf()
-- Hard-wrapping breaks one-line constructs (openers, leaves, table rows).
vim.opt_local.formatoptions:remove('t')
vim.opt_local.commentstring = '<!-- %s -->'
-- Formatting (tern.format): = lines a paragraph's continuation lines up
-- with its text; gq formats paragraphs only, an item's lines under its text;
-- soft-wrapped lines line up with an item's text too. Quotes are the only
-- comment leader, so that gq does not take `* ` or `- ` for one. Typing
-- keeps 'autoindent' alone: no key re-indents.
local format = require('tern.format')
vim.opt_local.comments = 'n:>'
vim.opt_local.formatlistpat = format.LIST
vim.opt_local.formatoptions:append('n')
vim.opt_local.formatexpr = "v:lua.require'tern.format'.formatexpr()"
vim.opt_local.indentexpr = "v:lua.require'tern.format'.indent()"
vim.opt_local.indentkeys = ''
vim.opt_local.breakindent = true
vim.opt_local.breakindentopt:append('list:-1')
vim.b.undo_ftplugin = 'setlocal formatoptions< commentstring< comments< formatlistpat< formatexpr< indentexpr<'
  .. ' indentkeys< breakindent< breakindentopt<'
-- What tern.render draws in place of the source hides the source.
if require('tern.config').options.render.conceal then
  vim.opt_local.conceallevel = 2
  vim.b.undo_ftplugin = vim.b.undo_ftplugin .. ' conceallevel<'
end

require('tern').attach(buf)
