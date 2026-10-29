-- SPDX-License-Identifier: MIT
-- Commands. Modules load on first use, so startup costs nothing.
if vim.g.loaded_tern then
  return
end
vim.g.loaded_tern = true

if vim.fn.has('nvim-0.11') == 0 then
  vim.notify('luccet.nvim needs Neovim 0.11 or later', vim.log.levels.WARN)
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd('LuccetInit', function(a)
  require('luccet.commands').init(a)
end, { nargs = '?', complete = 'file', desc = 'Write the luccet.js line at the top of this buffer' })
cmd('LuccetCheck', function(a)
  require('luccet.commands').check(a)
end, { nargs = '*', complete = 'file', desc = 'luccet check into the quickfix list' })
cmd('LuccetSearch', function(a)
  require('luccet.commands').search(a)
end, { nargs = '+', complete = 'file', desc = 'luccet search into the quickfix list' })
cmd('LuccetBuild', function(a)
  require('luccet.commands').build(a)
end, { nargs = '?', complete = 'file', desc = 'luccet build this note' })
cmd('LuccetMove', function(a)
  require('luccet.commands').move(a)
end, { nargs = '+', complete = 'file', desc = 'Move this file, or FROM, to TO, fixing the links' })
cmd('LuccetPreview', function(a)
  require('luccet.preview').start(a)
end, { desc = 'Serve this note and reload the browser on save' })
cmd('LuccetPreviewStop', function()
  require('luccet.preview').stop()
end, { desc = 'Stop the preview server' })
cmd('LuccetRender', function(a)
  require('luccet.render').command(a)
end, { nargs = '?', complete = function()
  return { 'on', 'off', 'toggle' }
end, desc = 'Show or hide the virtual text drawn from the outline' })
