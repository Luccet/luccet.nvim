-- SPDX-License-Identifier: MIT
return {
  { 'the plugin loads and defines its commands', function(T)
    T.ok(vim.g.loaded_tern, 'plugin/luccet.lua ran')
    for _, c in ipairs({ 'LuccetInit', 'LuccetCheck', 'LuccetBuild', 'LuccetPreview', 'LuccetPreviewStop', 'LuccetRender' }) do
      T.ok(vim.fn.exists(':' .. c) == 2, c .. ' is defined')
    end
  end },
  { 'setup merges options over the defaults', function(T)
    require('luccet').setup({ render = { math = false } })
    local o = require('luccet.config').options
    T.eq(o.render.math, false, 'render.math')
    T.eq(o.render.labels, true, 'render.labels kept')
    require('luccet').setup()
  end },
}
