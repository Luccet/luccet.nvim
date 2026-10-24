-- SPDX-License-Identifier: MIT
-- luccet.nvim: Neovim support for Luccet notes, a client of `luccet lsp`.
--   require('luccet').setup(opts)   options: see lua/luccet/config.lua
--   require('luccet').attach(buf)   called by ftplugin/luccet.lua for each note
local M = {}

function M.setup(opts)
  require('luccet.config').set(opts)
end

function M.attach(buf)
  local o = require('luccet.config').options
  if o.lsp then
    require('luccet.lsp').start(buf)
  else
    require('luccet.lsp').lexical(buf)
  end
  if o.render.enabled then
    require('luccet.render').attach(buf)
  end
end

return M
