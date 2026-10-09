-- SPDX-License-Identifier: MIT
-- tern.nvim: Neovim support for Tern notes, a client of `tern lsp`.
--   require('tern').setup(opts)   options: see lua/tern/config.lua
--   require('tern').attach(buf)   called by ftplugin/tern.lua for each note
local M = {}

function M.setup(opts)
  require('tern.config').set(opts)
end

function M.attach(buf)
  local o = require('tern.config').options
  if o.lsp then
    require('tern.lsp').start(buf)
  else
    require('tern.lsp').lexical(buf)
  end
  if o.render.enabled then
    require('tern.render').attach(buf)
  end
end

return M
