-- SPDX-License-Identifier: MIT
-- Writes lua/luccet/tex_symbols.lua from the engine's luccet.tex.symbols, the
-- symbol commands its math reads, each with its character and its class:
--   nvim --headless -u NONE -l tools/tex_symbols.lua [LUCCET_ROOT]
-- LUCCET_ROOT is a Luccet checkout: the argument, else $LUCCET_ROOT, else
-- ../luccet beside this one. Needs Node. test/tex_test.lua fails while the
-- file and the engine's table differ: run this again after the engine's
-- table changes.
local here = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local root = vim.fs.normalize(vim.fn.fnamemodify(arg[1] or vim.env.LUCCET_ROOT or (here .. '/../luccet'), ':p'))
local js = root .. '/luccet.js'
local r = vim.system({ 'node', '-e', 'process.stdout.write(JSON.stringify(require(process.argv[1]).tex.symbols))', js },
  { text = true }):wait()
if r.code ~= 0 then
  io.stderr:write(('tools/tex_symbols.lua: cannot read luccet.tex.symbols from %s\n%s'):format(js, r.stderr or ''))
  os.exit(1)
end
local list = vim.json.decode(r.stdout)
local out = {
  '-- SPDX-License-Identifier: MIT',
  "-- The engine's symbol commands, luccet.tex.symbols: { name, character, class },",
  "-- the class being TeX's in the engine's spelling (mi: a letter-like symbol;",
  '-- opn: an operator with its limits beside). Written by tools/tex_symbols.lua;',
  '-- do not edit.',
  'return {',
}
for _, s in ipairs(list) do
  out[#out + 1] = ('  { %q, %q, %q },'):format(s[1], s[2], s[3])
end
out[#out + 1] = '}'
vim.fn.writefile(out, here .. '/lua/luccet/tex_symbols.lua')
print(('tools/tex_symbols.lua: wrote lua/luccet/tex_symbols.lua, %d symbols from %s'):format(#list, js))
