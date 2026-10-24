-- SPDX-License-Identifier: MIT
-- Formatting with Neovim's own operators, kept to what cannot change a note.
-- = : a line that continues a paragraph lines up with the paragraph's text,
-- so a list item's continuation lines go under the text after its marker.
-- Only such lines move. A paragraph's first line, any line that starts a
-- block, and the lines of fences, math, raw HTML, verbatim bodies and the
-- head keep their indentation.
-- gq : Neovim's formatting, on paragraphs only. It never joins a paragraph
-- with a line that is not one (the head, a heading, an opener, a table row)
-- or across a hard break, and never touches verbatim lines. It does not
-- break where the next line would start a block (- 5, # 1, $$) or the line
-- would end in a new hard break, nor inline math more than once.
--   indent(lnum)   the 'indentexpr': the indent for line lnum (v:lnum)
--   formatexpr()   the 'formatexpr'
--   LIST           the 'formatlistpat': a list item's or a footnote's marker
--
-- Why moving them is safe: Luccet has no indented code, ignores indentation
-- past a container's content column, and continues a paragraph lazily with a
-- line that fails a container's prefix. A line that continues a paragraph
-- does so at any indentation. What it must not be is a line that would start
-- a block, so every such line, and some that would not, is left alone.
-- Which lines are verbatim comes from the syntax (syntax/luccet.vim); without
-- it, nothing moves.
local M = {}

-- Bullets, ordered markers and task boxes, and footnote labels; the text
-- after them is the item's (Vim regex, for 'formatlistpat').
M.LIST = [==[^\s*\%([-*+]\|\d\{1,9}[.)]\)\s\+\%(\[[ xX]\]\s\+\)\=\|^\s*\[\^[^\]]\+\]:\s\+]==]

-- How far up a paragraph's start is looked for.
local REACH = 1000

-- Syntax groups whose lines are not paragraphs.
local VERBATIM = { '^luccetHead$', '^luccetHtml', '^luccetFence', '^luccetMathBlock$', '^luccetRaw', '^luccetReserved$',
  '^luccetMacros', '^luccetMeta', '^luccetTableRow$' }

-- A table row's line, or the next one when it ends with a backslash (the
-- row goes on there, a line the syntax does not mark).
local function row(lnum)
  while lnum > 1 do
    local above = vim.fn.getline(lnum - 1):match('^[%s>]*(.-)%s*$')
    if above:sub(-1) ~= '\\' then
      return false
    elseif above:sub(1, 1) == '|' then
      return true
    end
    lnum = lnum - 1
  end
  return false
end

local function verbatim(lnum, line)
  if row(lnum) then
    return true
  end
  for _, id in ipairs(vim.fn.synstack(lnum, (line:find('%S')) or 1)) do
    local name = vim.fn.synIDattr(id, 'name')
    for _, pat in ipairs(VERBATIM) do
      if name:find(pat) then
        return true
      end
    end
  end
  return false
end

-- Whether text, without its indentation, may start a block (or is blank):
-- a closer, opener or leaf, a fence, raw HTML, a heading, a thematic break, a
-- table row, a quote, a list item, a cell separator, display math, a
-- footnote, an attribute line. Loose: a line it names may be text after all.
local function starts(text)
  local t = text:match('^%s*(.-)%s*$')
  return t == ''
    or t:find('^::') ~= nil
    or t:find('^```') ~= nil
    or t:find('^~~~') ~= nil
    or t:find('^<[%a/!?]') ~= nil
    or t:find('^#+%s') ~= nil
    or t:find('^#+$') ~= nil
    or (t:find('^[-*_%s]+$') ~= nil and select(2, t:gsub('[-*_]', '')) >= 3)
    or t:find('^|') ~= nil
    or (t:find('^[|:%-%s]+$') ~= nil and t:find('-', 1, true) ~= nil)
    or t:find('^>') ~= nil
    or t:find('^[-*+]%s') ~= nil
    or t:find('^[-*+]$') ~= nil
    or t:find('^%d+[.)]%s') ~= nil
    or t:find('^%d+[.)]$') ~= nil
    or t:find('^%+%+%+') ~= nil
    or t:find('^%$%$') ~= nil
    or t:find('^%[%^') ~= nil
    or t:find('^{') ~= nil
end

-- A list item's or a footnote's marker at the start of line, with the
-- spaces after it.
local function marker(line)
  return line:match('^%s*[-*+][ \t]+') or line:match('^%s*%d+[.)][ \t]+') or line:match('^%s*%[%^[^%]]+%]:[ \t]+')
end

-- Whether line is a marker alone, a task's box included: an empty item.
local function bare(line)
  local m = marker(line .. ' ')
  local rest = m and (line .. ' '):sub(#m + 1)
  return rest ~= nil and (rest:match('^%s*$') or rest:match('^%[[ xX]%]%s*$')) ~= nil
end

-- The display column of the text of a list item or footnote that line
-- opens, when that text is a paragraph's; else nil.
local function item(line)
  local prefix = marker(line)
  if not prefix then
    return nil
  end
  local digits = prefix:match('%d+')
  if digits and #digits > 9 then
    return nil
  end
  prefix = prefix .. (line:sub(#prefix + 1):match('^%[[ xX]%][ \t]+') or '')
  local rest = line:sub(#prefix + 1)
  if rest == '' or starts(rest) then
    return nil
  end
  return vim.fn.strdisplaywidth(prefix)
end

-- Whether the syntax that tells verbatim lines is on, and up to date. Its
-- state follows an edit at the next screen update, so after edits made with
-- none between (a macro, :g, a gq before this one), synstack() would read
-- the old text: a screen update first, once per change.
local seen = {} -- buf -> the changedtick the syntax was brought up to date at
local function syntax()
  if vim.g.syntax_on == nil or vim.bo.syntax ~= 'luccet' then
    return false
  end
  local buf, tick = vim.api.nvim_get_current_buf(), vim.b.changedtick
  if seen[buf] ~= tick then
    pcall(vim.api.nvim__redraw, { flush = true })
    seen[buf] = tick
  end
  return true
end

-- = rewrites the indentation of every line it is given, even one whose
-- indent stays, in tabs or spaces as 'expandtab' says: a fence's code
-- would change. With 'preserveindent' a line keeps its own when its indent
-- stays. The expression runs for each line just before = sets its indent,
-- so it turns 'preserveindent' on for a line that stays, off for one that
-- moves (clean indentation), and the user's value comes back after.
local saved = {} -- buf -> 'preserveindent' before
local function preserve(on)
  local buf = vim.api.nvim_get_current_buf()
  if saved[buf] == nil then
    saved[buf] = vim.bo[buf].preserveindent
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].preserveindent = saved[buf]
      end
      saved[buf] = nil
    end)
  end
  vim.bo[buf].preserveindent = on
end

-- The indent for lnum, without the 'preserveindent' choice.
local function indent(lnum)
  local keep = vim.fn.indent(lnum)
  if not syntax() then
    return keep
  end
  local line = vim.fn.getline(lnum)
  if starts(line) or verbatim(lnum, line) then
    return keep
  end
  -- Up to the paragraph's first line: an item's, or the line below one
  -- that is not a paragraph's.
  for l = lnum - 1, math.max(lnum - REACH, 1), -1 do
    local text = vim.fn.getline(l)
    if verbatim(l, text) then
      return l + 1 < lnum and vim.fn.indent(l + 1) or keep
    end
    local col = item(text)
    if col then
      return col
    end
    if starts(text) then
      return l + 1 < lnum and vim.fn.indent(l + 1) or keep
    end
  end
  return keep
end

function M.indent(lnum)
  lnum = lnum or vim.v.lnum
  local want = indent(lnum)
  preserve(want == vim.fn.indent(lnum))
  return want
end

-- A line's quote markers, up to most: how many, and the text after them.
local function unquote(line, most)
  local depth = 0
  while not most or depth < most do
    local rest = line:match('^%s*>[ \t]?(.*)$')
    if not rest then
      break
    end
    depth, line = depth + 1, rest
  end
  return depth, line
end

-- Where the wrap must not break, its spaces are no-break spaces, put back
-- after: before what would start a block at the start of a line (- 5, # 1,
-- > x, $$), after a backslash (a new hard break), inside inline math,
-- which may cross one line break only, and in a code span's runs of
-- spaces, which a line break would make one space. Dollars are paired in
-- order, past escapes, $$ and code spans: a pair that is not math (prices)
-- only has fewer places to break. Not done when the lines hold a no-break
-- space.
local NBSP = '\194\160'
local function protect(s, e)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, s - 1, e, false), '\n')
  if text:find(NBSP, 1, true) then
    return false
  end
  local keep = {} -- byte index -> true for a space to keep
  -- The spaces between words, before a block's start or after a backslash.
  for a, z in text:gmatch('[^%s]() +()') do
    if text:sub(a - 1, a - 1) == '\\' or starts(text:match('^[^\n]*', z)) then
      for k = a, z - 1 do
        keep[k] = true
      end
    end
  end
  -- The spaces in inline math, and runs of them in code spans.
  local i, open = 1, false
  while i <= #text do
    local c = text:sub(i, i)
    local ticks = c == '`' and not open and text:match('^`+', i)
    local close = ticks and text:find('%f[`]' .. ticks .. '%f[^`]', i + #ticks)
    if c == '\\' then
      i = i + 2
    elseif close then
      local from = i + #ticks - 1
      for a, z in text:sub(from + 1, close - 1):gmatch('[^%s]()  +()') do
        for k = from + a, from + z - 1 do
          keep[k] = true
        end
      end
      i = close + #ticks
    elseif text:sub(i, i + 1) == '$$' then
      i = i + 2
    else
      if c == '$' then
        open = not open
      elseif open and c == ' ' then
        keep[i] = true
      end
      i = i + 1
    end
  end
  if next(keep) == nil then
    return false
  end
  local out = {}
  for k = 1, #text do
    out[k] = keep[k] and NBSP or text:sub(k, k)
  end
  vim.api.nvim_buf_set_lines(0, s - 1, e, false, vim.split(table.concat(out), '\n', { plain = true }))
  return true
end

local function restore(s, e)
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  for k, l in ipairs(lines) do
    lines[k] = l:gsub(NBSP, ' ')
  end
  vim.api.nvim_buf_set_lines(0, s - 1, e, false, lines)
end

-- Formats lines s..e, inside depth quotes, with Neovim's formatter, from
-- the indentation = gives them (a run after a hard break continues a
-- paragraph), then joins back each line that begins with a block's marker
-- (a quote's included), or follows a new hard break or a marker the wrap
-- left alone (a first word wider than 'textwidth'). In that last case the
-- wrap has also lost the item's indentation, so the lines after are wrapped
-- again, from it. Returns where the lines end.
local function wrap(s, e, depth)
  local before = vim.api.nvim_buf_line_count(0)
  vim.cmd(('keepjumps silent normal! %dG=%dG'):format(s, e))
  local protected = protect(s, e)
  vim.cmd(('keepjumps silent normal! %dGgw%dG'):format(s, e))
  e = e + vim.api.nvim_buf_line_count(0) - before
  if protected then
    restore(s, e)
  end
  local l, alone = s + 1, false
  while l <= e do
    local prev = vim.fn.getline(l - 1)
    local _, rest = unquote(vim.fn.getline(l), depth)
    local marker_alone = bare(select(2, unquote(prev, depth)))
    if starts(rest) or prev:find('\\%s*$') or marker_alone then
      vim.api.nvim_buf_set_lines(0, l - 2, l, false, { (prev:gsub('%s+$', '')) .. ' ' .. rest:match('^%s*(.-)$') })
      e, alone = e - 1, alone or marker_alone
    else
      l = l + 1
    end
  end
  if alone and e > s then
    return wrap(s + 1, e, depth)
  end
  return e
end

local warned = false

function M.formatexpr()
  -- Wrapping while typing ('textwidth' with 'formatoptions' c): Neovim's.
  if vim.v.char ~= '' then
    return 1
  end
  local first, last = vim.v.lnum, vim.v.lnum + vim.v.count - 1
  if not syntax() then
    if not warned then
      warned = true
      vim.notify('luccet: gq formats a note with its syntax on only, to tell its paragraphs from its code', vim.log.levels.WARN)
    end
    return 0
  end
  -- The runs of paragraph lines: each starts at an item or at a paragraph
  -- line after something else, and ends at a hard break.
  local runs, run = {}, nil
  for l = first, last do
    local line = vim.fn.getline(l)
    local depth, rest = unquote(line)
    local opens = item(rest) ~= nil
    local text = opens or not starts(rest)
    if not text or verbatim(l, line) then
      run = nil
    else
      if not run or opens or run.depth ~= depth or run.hard then
        run = { s = l, depth = depth }
        runs[#runs + 1] = run
      end
      run.e, run.hard = l, rest:find('\\%s*$') ~= nil
    end
  end
  local count = vim.api.nvim_buf_line_count(0)
  for i = #runs, 1, -1 do
    wrap(runs[i].s, runs[i].e, runs[i].depth)
  end
  local at = math.max(math.min(last + vim.api.nvim_buf_line_count(0) - count, vim.api.nvim_buf_line_count(0)), first)
  vim.api.nvim_win_set_cursor(0, { at, 0 })
  return 0
end

return M
