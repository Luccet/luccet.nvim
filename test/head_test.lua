-- SPDX-License-Identifier: MIT
-- tern.head: the head's lines, its summary and its fold text.
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
  { 'the head runs to the tern.js line', function(T)
    local head = require('tern.head')
    T.eq(head.lines(buffer({ '<!doctype html><script src="tern.js"></script>', '# x' })), 1, 'one line')
    T.eq(head.lines(buffer({ '<!doctype html>', '<script>', 'window.TERN = {}', '</script>', '<script src="../tern.js"></script>', 'x' })), 5, 'five')
    T.eq(head.lines(buffer({ '<p>no note</p>' })), nil, 'not a note')
    local buf = buffer({ '<!doctype html>', '<script src="tern.js"></script>', 'x' })
    T.eq(head.lines(buf), 2, 'before an edit')
    api.nvim_buf_set_lines(buf, 0, 0, false, { '<meta charset="utf-8">' })
    T.eq(head.lines(buf), 3, 'after one')
  end },

  { 'the summary names what the head holds', function(T)
    local head = require('tern.head')
    local function summary(lines)
      return text(head.summary(buffer(lines)))
    end
    T.eq(summary({ '<!doctype html><meta charset="utf-8"><script src="tern.js"></script>' }), '⟨head⟩', 'the canonical line')
    T.eq(summary({ '<!doctype html><html lang="en"><meta charset="utf-8"><title>Add-ons · Tern</title>'
      .. '<script src="../tern.js" data-use="docs.js  docs.css"></script>' }), '⟨head⟩ Add-ons · Tern · docs.js docs.css', 'title and add-ons')
    T.eq(summary({ '<!doctype html>', '<script>', '  window.TERN = { schema: {} };', '</script>', '<STYLE>', 'p {}', '</style>',
      "<script src='plot.js'></script>", '<script src=tern.js></script>' }), '⟨head⟩ schema · script · style', 'schema, a script, a style')
    local long = summary({ '<title>' .. ('word '):rep(30) .. '</title><script src="tern.js"></script>' })
    T.eq(vim.fn.strchars(long), vim.fn.strchars('⟨head⟩ ') + 72, 'shortened to 72 after the name: ' .. long)
    T.eq(vim.fn.strcharpart(long, vim.fn.strchars(long) - 1), '…', 'with an ellipsis')
    T.eq(head.summary(buffer({ 'x' }))[1], { '⟨head⟩', 'TernVirtVerbatim' }, 'highlights')
  end },

  { 'the fold text is the summary on the head, Neovim\'s elsewhere', function(T)
    local buf = buffer({ '<!doctype html>', '<script>window.TERN = {}</script>', '<script src="tern.js"></script>', '# A', 'x', 'y' })
    api.nvim_set_current_buf(buf)
    vim.wo.foldmethod = 'manual'
    vim.wo.foldtext = "v:lua.require'tern.head'.foldtext()"
    vim.wo.foldminlines = 0
    vim.cmd('1,3fold | 4,6fold')
    T.eq(vim.fn.foldtextresult(1), '⟨head⟩ schema', 'the head')
    T.eq(vim.fn.foldtextresult(4), vim.fn.foldtextresult(4):match('^%+%-+%s*3 lines: # A') and vim.fn.foldtextresult(4), 'Neovim\'s')
    vim.cmd('normal! zE')
    vim.wo.foldmethod = 'manual'
  end },
}
