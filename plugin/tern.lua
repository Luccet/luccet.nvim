-- SPDX-License-Identifier: MIT
-- Commands. Modules load on first use, so startup costs nothing.
if vim.g.loaded_tern then
  return
end
vim.g.loaded_tern = true

if vim.fn.has('nvim-0.11') == 0 then
  vim.notify('tern.nvim needs Neovim 0.11 or later', vim.log.levels.WARN)
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd('TernInit', function(a)
  require('tern.commands').init(a)
end, { nargs = '?', complete = 'file', desc = 'Write the tern.js line at the top of this buffer' })
cmd('TernCheck', function(a)
  require('tern.commands').check(a)
end, { nargs = '*', complete = 'file', desc = 'tern check into the quickfix list' })
cmd('TernBuild', function(a)
  require('tern.commands').build(a)
end, { nargs = '?', complete = 'file', desc = 'tern build this note' })
cmd('TernPreview', function(a)
  require('tern.preview').start(a)
end, { desc = 'Serve this note and reload the browser on save' })
cmd('TernPreviewStop', function()
  require('tern.preview').stop()
end, { desc = 'Stop the preview server' })
cmd('TernRender', function(a)
  require('tern.render').command(a)
end, { nargs = '?', complete = function()
  return { 'on', 'off', 'toggle' }
end, desc = 'Show or hide the virtual text drawn from the outline' })
