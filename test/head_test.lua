-- SPDX-License-Identifier: MIT
-- luccet.head: the head's lines, its summary and its fold text.
local api = vim.api

local function buffer(lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function text(chunks)
  local out = {}
  for _, c in ipairs(chunks) do
    out[#out + 1] = c[1]
  end
  return table.concat(out)
end

return {
  { 'the head runs to the luccet.js line', function(T)
    local head = require('luccet.head')
    T.eq(head.lines(buffer({ '<!doctype html><script src="luccet.js"></script>', '# x' })), 1, 'one line')
    T.eq(head.lines(buffer({ '<!doctype html>', '<script>', 'window.LUCCET = {}', '</script>', '<script src="../luccet.js"></script>', 'x' })), 5, 'five')
    T.eq(head.lines(buffer({ '<p>no note</p>' })), nil, 'not a note')
    local buf = buffer({ '<!doctype html>', '<script src="luccet.js"></script>', 'x' })
    T.eq(head.lines(buf), 2, 'before an edit')
    api.nvim_buf_set_lines(buf, 0, 0, false, { '<meta charset="utf-8">' })
    T.eq(head.lines(buf), 3, 'after one')
  end },

  { 'the summary names what the head holds', function(T)
    local head = require('luccet.head')
    local function summary(lines)
      return text(head.summary(buffer(lines)))
    end
    T.eq(summary({ '<!doctype html><meta charset="utf-8"><script src="luccet.js"></script>' }), '⟨head⟩', 'the canonical line')
    T.eq(summary({ '<!doctype html><html lang="en"><meta charset="utf-8"><title>Add-ons · Luccet</title>'
      .. '<script src="../luccet.js" data-use="docs.js  docs.css"></script>' }), '⟨head⟩ Add-ons · Luccet · docs.js docs.css', 'title and add-ons')
    T.eq(summary({ '<script src="https://cdn.luccet.dev/v2/luccet.js" data-use="https://cdn.luccet.dev/themes/v1/classic.css '
      .. 'https://cdn.luccet.dev/code/v1/code.js?base=vendor/highlight lib/chart.js#x"></script>' }),
      '⟨head⟩ classic.css code.js chart.js', 'each add-on by its file name')
    T.eq(summary({ '<!doctype html>', '<script>', '  window.LUCCET = { schema: {} };', '</script>', '<STYLE>', 'p {}', '</style>',
      "<script src='plot.js'></script>", '<script src=luccet.js></script>' }), '⟨head⟩ schema · script · style', 'schema, a script, a style')
    local long = summary({ '<title>' .. ('word '):rep(30) .. '</title><script src="luccet.js"></script>' })
    T.eq(vim.fn.strchars(long), vim.fn.strchars('⟨head⟩ ') + 72, 'shortened to 72 after the name: ' .. long)
    T.eq(vim.fn.strcharpart(long, vim.fn.strchars(long) - 1), '…', 'with an ellipsis')
    T.eq(head.summary(buffer({ 'x' }))[1], { '⟨head⟩', 'LuccetVirtVerbatim' }, 'highlights')
  end },

  { 'the macros of window.LUCCET.macros, read as the engine reads them', function(T)
    local head = require('luccet.head')
    local buf = buffer({
      '<!doctype html>',
      '<script>window.LUCCET = { schema: { block: { x: { label: "}," } } }, // a }, in a comment',
      [[  macros: { '\\RR': '\\mathbb{R}', "\\abs": "\\left|#1\\right|", pair: `(#1, #2)`, /* , } */]],
      [[  'not-a-macro': 'x', '\\one': 1, '\\o': { a: 2, b: [3, 4] }, '\\N': '\\mathbb{N}', '\\|': '\\Vert' },]],
      [[  use: { katex: { macros: { '\\K': 'k' } } } };</script>]],
      '<script src="luccet.js"></script>',
    })
    T.eq(head.macros(buf), {
      ['\\RR'] = { n = 0, body = '\\mathbb{R}' },
      ['\\abs'] = { n = 1, body = '\\left|#1\\right|' },
      ['\\pair'] = { n = 2, body = '(#1, #2)' },
      ['\\N'] = { n = 0, body = '\\mathbb{N}' },
      ['\\|'] = { n = 0, body = '\\Vert' },
    }, 'each string value on its own, past a number and an object; a name with or without its backslash, of letters or one other character')
    T.eq(head.macros(buffer({ '<script>window.LUCCET = {};', [[window.LUCCET.macros = { '\\Z': '\\mathbb{Z}' };</script>]],
      '<script src="luccet.js"></script>' })), { ['\\Z'] = { n = 0, body = '\\mathbb{Z}' } }, 'assigned on their own')
    T.eq(head.macros(buffer({ [[<script>window.LUCCET = { katex: { macros: { '\\RR': '\\mathbb{R}' } } };</script>]],
      '<script src="luccet.js"></script>' })), {}, 'not where Luccet 1 had them, which the engine no longer reads')
    T.eq(head.macros(buffer({ '<script src="luccet.js"></script>' })), {}, 'none')
    T.eq(head.macros(buffer({ 'no note' })), {}, 'not a note')
  end },

  { 'the fold text is the summary on the head, Neovim\'s elsewhere', function(T)
    local buf = buffer({ '<!doctype html>', '<script>window.LUCCET = {}</script>', '<script src="luccet.js"></script>', '# A', 'x', 'y' })
    api.nvim_set_current_buf(buf)
    vim.wo.foldmethod = 'manual'
    vim.wo.foldtext = "v:lua.require'luccet.head'.foldtext()"
    vim.wo.foldminlines = 0
    vim.cmd('1,3fold | 4,6fold')
    T.eq(vim.fn.foldtextresult(1), '⟨head⟩ schema', 'the head')
    T.eq(vim.fn.foldtextresult(4), vim.fn.foldtextresult(4):match('^%+%-+%s*3 lines: # A') and vim.fn.foldtextresult(4), 'Neovim\'s')
    vim.cmd('normal! zE')
    vim.wo.foldmethod = 'manual'
  end },
}
