-- SPDX-License-Identifier: MIT
-- luccet.tex's symbols: lua/luccet/tex_symbols.lua is the engine's table,
-- luccet.tex.symbols (tools/tex_symbols.lua writes it), and each symbol reads
-- as the character the page shows.

-- The engine's table, or nil (and a note) without a checkout and Node.
local function engine(T)
  local root = T.luccet_root()
  if not root or vim.fn.executable('node') == 0 then
    print('    (skipped: needs Node and a Luccet checkout, $LUCCET_ROOT or ../luccet)')
    return nil
  end
  local r = vim.system({ 'node', '-e', 'process.stdout.write(JSON.stringify(require(process.argv[1]).tex.symbols))',
    root .. '/luccet.js' }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.json.decode(r.stdout)
end

return {
  { "lua/luccet/tex_symbols.lua is the engine's table", function(T)
    local want = engine(T)
    if want then
      T.eq(require('luccet.tex_symbols'), want, 'the same symbols; when the engine\'s changed, run '
        .. 'nvim --headless -u NONE -l tools/tex_symbols.lua')
    end
  end },

  { "every symbol of the engine reads as its character", function(T)
    local tex = require('luccet.tex')
    local wrong = {}
    for _, s in ipairs(require('luccet.tex_symbols')) do
      local u = tex.unicode('\\' .. s[1])
      if not u or vim.trim(u) ~= s[2] then
        wrong[#wrong + 1] = ('\\%s reads as %s, the page shows %s'):format(s[1], vim.inspect(u), s[2])
      end
    end
    T.eq(wrong, {}, 'each \\name alone')
    T.eq(tex.unicode('\\Alpha \\ne A, \\varnothing \\perp x, a \\ncong b'), 'Α ≠ A, ⌀ ⟂ x, a ≆ b',
      'in a formula, with their classes\' spacing')
  end },
}
