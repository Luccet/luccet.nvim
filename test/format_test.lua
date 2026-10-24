-- SPDX-License-Identifier: MIT
-- luccet.format and the ftplugin's formatting options: = aligns the lines that
-- continue a paragraph and nothing else, gq formats paragraphs only, and
-- soft-wrapped list items line up.
local api = vim.api

local HEAD = '<!doctype html><meta charset="utf-8"><script src="luccet.js"></script>'

-- A note in the current window, with the ftplugin but no language server.
local function note(lines)
  if vim.g.syntax_on == nil then
    vim.cmd('syntax enable')
  end
  require('luccet').setup({ lsp = false, render = { enabled = false } })
  local buf = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ HEAD }, lines))
  vim.bo[buf].filetype = 'luccet'
  -- Its text is not an undoable change: a script never waits for input, the
  -- moment that closes an undo block.
  vim.bo[buf].undolevels = vim.bo[buf].undolevels
  return buf
end

local function body(buf)
  return vim.list_slice(api.nvim_buf_get_lines(buf, 0, -1, false), 2)
end

local function run(T, fn)
  local ok, err = pcall(fn)
  require('luccet').setup()
  if not ok then
    error(err, 0)
  end
end

return {
  { 'the ftplugin sets the formatting options, and undoes them', function(T)
    run(T, function()
      local buf = note({ 'x' })
      T.eq(vim.bo.comments, 'n:>', 'quotes are the only comment leader')
      T.eq(vim.bo.formatlistpat, require('luccet.format').LIST, 'formatlistpat')
      T.ok(vim.bo.formatoptions:find('n', 1, true) and not vim.bo.formatoptions:find('t', 1, true), 'formatoptions: ' .. vim.bo.formatoptions)
      T.eq(vim.bo.formatexpr, "v:lua.require'luccet.format'.formatexpr()", 'formatexpr')
      T.eq({ vim.bo.indentexpr, vim.bo.indentkeys }, { "v:lua.require'luccet.format'.indent()", '' }, 'indentexpr, and no key re-indents')
      T.ok(vim.wo.breakindent and vim.wo.breakindentopt:find('list:-1', 1, true), 'breakindent')
      vim.bo[buf].filetype = 'text'
      T.eq({ vim.bo.indentexpr, vim.bo.formatexpr }, { '', '' }, 'undone with another filetype')
    end)
  end },

  { '= aligns the lines that continue a paragraph, and nothing else', function(T)
    run(T, function()
      local lines = {
        '- This is some very long paragraph', -- 2
        'that spanned to this line', -- 3: under the text
        '    and over-indented', -- 4
        '- [ ] a task', -- 5
        'continued', -- 6: under the task's text
        '10. ordered', -- 7
        'continued', -- 8
        '  - nested', -- 9
        'lazy of nested', -- 10
        '', -- 11
        '```', -- 12
        '- not an item', -- 13
        'code stays', -- 14
        '```', -- 15
        '- # heading item', -- 16
        'not lazy: stays', -- 17: not the item's, it would move into it
        ':::note', -- 18
        '  Indented body', -- 19
        'continues', -- 20: under the body's first line
        '# Heading', -- 21
        'first line', -- 22
        '      second', -- 23
        '- item', -- 24
        '# not lazy heading', -- 25
        '[^1]: A footnote', -- 26
        'continued', -- 27
        ':::macros', -- 28
        '- \\gdef\\x{1}', -- 29
        '  body', -- 30
        ':::', -- 31
        '> - quoted', -- 32
        'lazy quote', -- 33: a quote's: no indentation reaches it
        '- item', -- 34
        '$$', -- 35
        '  x', -- 36
        '$$', -- 37
        '- 3 - 5', -- 38
        '- 6', -- 39: an item, not a continuation
      }
      local buf = note(lines)
      vim.cmd('silent normal! gg=G')
      local want = vim.deepcopy(lines)
      want[2] = '  that spanned to this line'
      want[3] = '  and over-indented'
      want[5] = '      continued'
      want[7] = '    continued'
      want[9] = '    lazy of nested'
      want[19] = '  continues'
      want[22] = 'second'
      want[26] = '      continued'
      T.eq(body(buf), want, 'aligned')
      T.eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], HEAD, 'the head stays')
      local once = body(buf)
      vim.cmd('silent normal! gg=G')
      T.eq(body(buf), once, 'a second = changes nothing')
    end)
  end },

  { '= keeps the whitespace of the lines it does not move, tabs and spaces alike', function(T)
    run(T, function()
      local lines = {
        '```make',
        'all:',
        '\tcc -o x x.c', -- a tab, which 'expandtab' would make spaces
        '        eight spaces', -- which 'noexpandtab' would make a tab
        '```',
        '[^1]: A footnote',
        '  continued', -- moves: clean indentation
      }
      local buf = note(lines)
      vim.bo.preserveindent = false
      for _, et in ipairs({ false, true }) do
        api.nvim_buf_set_lines(buf, 1, -1, false, lines)
        vim.bo.expandtab, vim.bo.tabstop = et, 8
        vim.cmd('silent normal! gg=G')
        local want = vim.deepcopy(lines)
        want[7] = et and '      continued' or '      continued'
        T.eq(body(buf), want, 'expandtab ' .. tostring(et))
      end
      vim.wait(0)
      T.eq(vim.bo.preserveindent, false, 'preserveindent back to its value')
    end)
  end },

  { '= moves nothing without the syntax', function(T)
    run(T, function()
      local buf = note({ '- item', 'continued' })
      vim.cmd('syntax off')
      local ok, err = pcall(vim.cmd, 'silent normal! gg=G')
      vim.cmd('syntax enable')
      T.ok(ok, err)
      T.eq(body(buf), { '- item', 'continued' }, 'unchanged')
    end)
  end },

  { 'gq formats paragraphs only, their lines under an item\'s text', function(T)
    run(T, function()
      local lines = {
        '# A heading right under the head, longer than forty columns',
        'A paragraph under the heading that is long enough to wrap twice at forty.',
        '- [ ] A task item whose text is long enough to wrap at forty columns',
        'lazy continuation line',
        'Roses are red, and this line is long enough to be wrapped,\\',
        'violets are blue.',
        ':::note[A title that is long enough to wrap if it were a paragraph]',
        'Body text right under the opener, long enough to wrap at forty columns.',
        ':::',
        '```',
        'code that is long enough to wrap at forty columns but must not move',
        '```',
        '> A quoted paragraph long enough to wrap at forty columns here.',
        '| a | table row that is long enough to wrap at forty columns |',
        '* star bullet with a long line of text that should wrap around',
      }
      local buf = note(lines)
      vim.bo.textwidth = 40
      vim.cmd('silent normal! gggqG')
      T.eq(body(buf), {
        '# A heading right under the head, longer than forty columns',
        'A paragraph under the heading that is',
        'long enough to wrap twice at forty.',
        '- [ ] A task item whose text is long',
        '      enough to wrap at forty columns',
        '      lazy continuation line Roses are',
        '      red, and this line is long enough',
        '      to be wrapped,\\',
        '      violets are blue.', -- after the hard break, still the item's
        ':::note[A title that is long enough to wrap if it were a paragraph]',
        'Body text right under the opener, long',
        'enough to wrap at forty columns.',
        ':::',
        '```',
        'code that is long enough to wrap at forty columns but must not move',
        '```',
        '> A quoted paragraph long enough to wrap',
        '> at forty columns here.',
        '| a | table row that is long enough to wrap at forty columns |',
        '* star bullet with a long line of text',
        '  that should wrap around', -- not a second bullet
      }, 'formatted')
      T.eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], HEAD, 'the head stays')
      local once = body(buf)
      vim.cmd('silent normal! gggqG')
      T.eq(body(buf), once, 'a second gq changes nothing')
      vim.cmd('silent normal! u')
      T.eq(body(buf), lines, 'one undo')
    end)
  end },

  { 'gq and = read the syntax of the text as it is, edits since the last screen update included', function(T)
    run(T, function()
      local buf = note({ 'para', '```', '- not an item', 'code that is long enough to wrap at forty columns', '```' })
      api.nvim__redraw({ flush = true })
      -- Lines above the fence, with no screen update after: code moves down.
      api.nvim_buf_set_lines(buf, 1, 1, false, { 'one', 'two' })
      vim.bo.textwidth = 40
      vim.cmd('silent normal! gggqG')
      vim.cmd('silent normal! gg=G')
      T.eq(body(buf), { 'one two para', '```', '- not an item', 'code that is long enough to wrap at forty columns', '```' }, 'the code untouched')
    end)
  end },

  { 'gq, at any width, never begins a line with a block, breaks math twice or touches a table', function(T)
    run(T, function()
      local lines = {
        '- [`a-long-link-wider-than-the-width`](u) then `a < b && c > d`, a price - 5 # 6 1. x',
        'and math $a + b + c + d + e + f + g$ with $$ x $$ and done\\',
        'after the break.',
        '| a | b \\',
        '  row continued | c |',
      }
      local function words(list)
        return (table.concat(list, ' '):gsub('%s+', ' '))
      end
      for tw = 6, 40 do
        local buf = note(lines)
        vim.bo.textwidth = tw
        vim.cmd('silent normal! gggqG')
        local out = body(buf)
        local what = 'textwidth ' .. tw .. ': ' .. table.concat(out, ' | ')
        T.eq(vim.list_slice(out, #out - 1), vim.list_slice(lines, 4), 'the table row untouched, ' .. what)
        local para = vim.list_slice(out, 1, #out - 2)
        local first, last
        for i, l in ipairs(para) do
          local t = l:match('^%s*(.-)$')
          T.ok(i == 1 or not (t:find('^[-*+]%s') or t:find('^%d+[.)]%s') or t:find('^[#>]') or t:find('^%$%$')), 'line ' .. i .. ' starts no block, ' .. what)
          T.ok(not t:find('^[-*+]%s*$'), 'no bare marker, ' .. what)
          T.ok(not t:find('\\$') or t:find('done\\$') or i == #para, 'no new hard break, ' .. what)
          first = first or (l:find('$a', 1, true) and i)
          last = last or (l:find('g$', 1, true) and i)
        end
        T.ok(last - first <= 1, 'inline math over one line break at most, ' .. what)
        local hard
        for i, l in ipairs(para) do
          hard = hard or (l:find('done\\$') and i)
        end
        T.ok(hard and para[hard + 1]:find('^%s*after'), 'the hard break kept, ' .. what)
        for i = 2, #para do
          T.eq(para[i]:match('^%s*'), '  ', 'line ' .. i .. ' under the item\'s text, ' .. what)
        end
        T.eq(words(out), words(lines), 'the same words, ' .. what)
        vim.cmd('silent normal! gggqG')
        T.eq(body(buf), out, 'a second gq changes nothing, ' .. what)
        vim.cmd('silent! bwipeout!')
      end
    end)
  end },

  { 'a soft-wrapped list item lines up with its text', function(T)
    run(T, function()
      local line = '- [ ] A soft-wrapped tasks item that is long enough to wrap on the screen'
      note({ line })
      vim.cmd('vsplit')
      api.nvim_win_set_width(0, 30)
      vim.wo.wrap = true
      vim.wo.number = false
      vim.cmd('normal! gg')
      api.nvim__redraw({ flush = true })
      local pos = vim.fn.screenpos(0, 2, 30)
      local row = {}
      for c = pos.col - 29, pos.col do
        row[#row + 1] = vim.fn.screenstring(pos.row + 1, c)
      end
      T.eq(table.concat(row):sub(1, 7), '      ' .. line:sub(31, 31), 'the second screen line starts under the text: ' .. table.concat(row))
      vim.cmd('close')
    end)
  end },
}
