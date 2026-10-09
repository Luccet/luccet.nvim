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

require('tern').attach(buf)
