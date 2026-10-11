-- SPDX-License-Identifier: MIT
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true

local buf = vim.api.nvim_get_current_buf()
-- Hard-wrapping breaks one-line constructs (openers, leaves, table rows).
vim.opt_local.formatoptions:remove('t')
vim.opt_local.commentstring = '<!-- %s -->'
vim.b.undo_ftplugin = 'setlocal formatoptions< commentstring<'
-- What tern.render draws in place of the source hides the source.
if require('tern.config').options.render.conceal then
  vim.opt_local.conceallevel = 2
  vim.b.undo_ftplugin = vim.b.undo_ftplugin .. ' conceallevel<'
end

require('tern').attach(buf)
