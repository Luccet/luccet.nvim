-- SPDX-License-Identifier: MIT
-- Virtual text drawn from the server's outline, so the source shows what the
-- page will: a numbered block's label at the end of its opener line, what
-- each @reference reads as, equation numbers, and simple math as Unicode.
-- With options.render.conceal, math with a Unicode form is drawn in place of
-- its source, display math's $$ hidden too, and a block's opener in place of
-- its syntax, its attributes and closer hidden; the source shows again while
-- the cursor is on it. The head stays folded but while the cursor is in it
-- (tern.head). Each kind has its options.render flag.
--   attach(buf)          draw now, and again on each User TernOutline
--   command(args)        :TernRender [on|off|toggle], per buffer
--   draw(buf, outline)   draw an outline table (what the events call)
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace('tern_render')
local state = {} -- buf -> { on, drawn, folded = { [win] = true }, inside = { [win] = bool }, row = { [win] = row } }
-- buf -> { open = row, shown = { [id] = f } }: what is drawn in place of its
-- source (a formula, a block's line), by the id of a mark over all of it. f
-- holds parts, the pieces of source it hides, { id, chunks } each: a mark
-- within one line and the virtual text in its place; after, the virtual text
-- after it while its source shows; eol, { hidden, shown }, the virtual text
-- at the end of its last line; text, the ids of the marks that draw them.
-- open: see opened().
local inplace = {}
local group

local function highlights()
  api.nvim_set_hl(0, 'TernVirtLabel', { link = 'Special', default = true })
  api.nvim_set_hl(0, 'TernVirtRef', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'TernVirtMath', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'TernVirtName', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'TernVirtId', { link = 'Identifier', default = true })
  api.nvim_set_hl(0, 'TernVirtVerbatim', { link = 'PreProc', default = true })
  api.nvim_set_hl(0, 'TernVerbatim', { link = 'ColorColumn', default = true })
end

-- tex.unicode by TeX source, after the note's macros (tex.expand); a note
-- repeats its formulas.
local cache, cached = {}, 0
local function unicode(tex, macros)
  tex = require('tern.tex').expand(tex, macros)
  if not tex then
    return nil
  end
  local hit = cache[tex]
  if hit == nil then
    if cached > 4096 then
      cache, cached = {}, 0
    end
    hit = require('tern.tex').unicode(tex) or false
    cache[tex], cached = hit, cached + 1
  end
  return hit or nil
end

-- Whether the Unicode form shows more than the source already does.
local function norm(s)
  return (s:gsub('%s+', ''):gsub('−', '-'):gsub('∗', '*'):gsub('′', "'"))
end
local function worth(tex, u)
  return norm(u) ~= norm(tex)
end

-- A title is visible when the line holds it, ignoring markup and spacing.
local function visible(line, title)
  if line:find(title, 1, true) then
    return true
  end
  local bare = title:gsub('[%s%p]', '')
  return bare == '' or line:gsub('[%s%p]', ''):find(bare, 1, true) ~= nil
end

-- concealcursor's letter for each mode.
local modes = { v = 'v', V = 'v', ['\22'] = 'v', s = 'v', S = 'v', ['\19'] = 'v', i = 'i', R = 'i', c = 'c' }

-- Where buf's in-place text shows its source: true on every row (no window shows
-- buf, or its window has 'conceallevel' 0), else the cursor's row in the
-- current window, or -1 for none (another window, or 'concealcursor' has the
-- mode, as Neovim conceals).
local function opened(buf)
  local cur = api.nvim_get_current_win()
  local win = api.nvim_win_get_buf(cur) == buf and cur or vim.fn.win_findbuf(buf)[1]
  if not win or vim.wo[win].conceallevel == 0 then
    return true
  end
  local mode = modes[api.nvim_get_mode().mode:sub(1, 1)] or 'n'
  if win ~= cur or vim.wo[win].concealcursor:find(mode, 1, true) then
    return -1
  end
  return api.nvim_win_get_cursor(win)[1] - 1
end

-- Whether in-place text on rows row..last shows its source for open: the
-- cursor is on one of them.
local function shows(open, row, last)
  return open == true or (open >= row and open <= last)
end

-- Draws f, whose mark is id: hidden, each part's chunks in its place; or
-- shown, f.after after it. f.eol goes at the end of its last line.
local function place(buf, id, f, open)
  for _, t in ipairs(f.text) do
    api.nvim_buf_del_extmark(buf, ns, t)
  end
  f.text = {}
  local function text(r, c, chunks, pos)
    if chunks and r < api.nvim_buf_line_count(buf) then
      f.text[#f.text + 1] = api.nvim_buf_set_extmark(buf, ns, r, c, {
        virt_text = chunks,
        virt_text_pos = pos,
        hl_mode = 'combine', -- on the background of a verbatim block or the cursor line
        strict = false,
      })
    end
  end
  for _, p in ipairs(f.parts) do
    local row, col, d = unpack(api.nvim_buf_get_extmark_by_id(buf, ns, p.id, { details = true }))
    if row then
      api.nvim_buf_set_extmark(buf, ns, row, col, {
        id = p.id,
        end_row = d.end_row,
        end_col = d.end_col,
        conceal = not open and '' or nil,
        strict = false,
      })
      if not open then
        text(d.end_row, d.end_col, p.chunks, 'inline')
      end
    end
  end
  local row, _, d = unpack(api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true }))
  if row then
    if open then
      text(d.end_row, d.end_col, f.after, 'inline')
    end
    text(d.end_row, 0, f.eol and f.eol[open and 'shown' or 'hidden'], 'eol')
  end
end

-- Redraws what is drawn in place of its source after the cursor moves: on
-- the rows the cursor left and entered.
local function follow(buf)
  local d = inplace[buf]
  if not d or not api.nvim_buf_is_valid(buf) then
    return
  end
  local was, now = d.open, opened(buf)
  if was == now then
    return
  end
  d.open = now
  local done = {}
  local function redo(from, to)
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, from, to, { details = true, overlap = true })) do
      local f = d.shown[m[1]]
      if f and not done[m[1]] then
        done[m[1]] = true
        place(buf, m[1], f, shows(now, m[2], m[4].end_row))
      end
    end
  end
  if was == true or now == true then
    redo(0, -1)
  else
    for _, row in ipairs({ was, now }) do
      if row >= 0 then
        redo({ row, 0 }, { row, -1 })
      end
    end
  end
end

local function squash(s)
  return (s:gsub('%s+', ''))
end

local function math_text(text)
  return text ~= '' and { { text, 'TernVirtMath' } } or nil
end

-- The id written in an attribute group, if any.
local function idof(group)
  for item in group:sub(2, -2):gmatch('%S+') do
    local id = item:match('^#(.+)$')
    if id then
      return id
    end
  end
end

-- What shows in place of attribute groups: the id, if one has it.
local function ids(groups, lead)
  for g in (groups or ''):gmatch('%b{}') do
    local id = idof(g)
    if id then
      return { { lead .. '{#' .. id .. '}', 'TernVirtId' } }
    end
  end
end

-- What may follow display math's closing $$: nothing, or attributes.
local function attrs(rest)
  return rest:match('^%s*$') or rest:match('^%s*%b{}%s*$')
end

-- The Unicode form of display math TeX lines, line by line (tern.tex.lines).
local function rows(tex, macros)
  if #tex == 1 then
    local u = unicode(tex[1], macros)
    return u and { u }
  end
  local expanded = {}
  for i, l in ipairs(tex) do
    expanded[i] = require('tern.tex').expand(l, macros)
    if not expanded[i] then
      return nil
    end
  end
  return require('tern.tex').lines(expanded)
end

-- How display math m can be drawn in place: `$$ TeX $$` on one line; or a
-- $$ line, TeX lines shown line by line, and a closing $$ line, whose $$
-- hide too. Attributes after the closing $$ show as their id. Returns the
-- parts to hide, { row, start, end, chunks } (0-based), where the formula
-- ends (row, col), and its Unicode form when the TeX is one line; nil for any
-- other shape, or lines that no longer hold the TeX.
local function display(lines, byte, m, last, macros)
  if type(m.tex) ~= 'string' or type(m.line) ~= 'number' or type(last) ~= 'number' then
    return nil
  elseif last == m.line then
    local u, tex = unicode(m.tex, macros), vim.trim(m.tex)
    local line, s = lines[m.line], byte(m.line, m.col)
    if u and s and line:sub(s + 1, s + 2) == '$$' then
      local _, e = line:find('^%s*' .. vim.pesc(tex) .. '%s*%$%$', s + 3)
      if e and attrs(line:sub(e + 1)) then
        local parts = { { m.line - 1, s, e, math_text(u) } }
        if e < #line then
          parts[2] = { m.line - 1, e, #line, ids(line:sub(e + 1), ' ') }
        end
        return parts, m.line - 1, #line, u
      end
    end
    return nil
  end
  local open, close = lines[m.line], lines[last]
  local n = open and open:match('^[%s>]*()%$%$%s*$')
  local cs, rest = (close or ''):match('^[%s>]*()%$%$(.*)$')
  if not n or not cs or not attrs(rest) then
    return nil
  end
  -- The TeX lines start after the opener's indentation or quote marks.
  n = n - 1
  local tex = {}
  for l = m.line + 1, last - 1 do
    if lines[l]:sub(1, n):find('[^%s>]') then
      return nil
    end
    tex[#tex + 1] = lines[l]:sub(n + 1)
  end
  local shown = #tex > 0 and squash(table.concat(tex)) == squash(m.tex) and rows(tex, macros)
  if not shown then
    return nil
  end
  local parts = { { m.line - 1, n, #open } }
  for i, text in ipairs(shown) do
    parts[#parts + 1] = { m.line + i - 1, n, #lines[m.line + i], math_text(text) }
  end
  parts[#parts + 1] = { last - 1, cs - 1, #close, ids(rest, '') }
  return parts, last - 1, #close, #shown == 1 and shown[1] or nil
end

local function list(x)
  return type(x) == 'table' and x or {}
end

local function shorten(text, max)
  if #text <= max or vim.fn.strchars(text) <= max then
    return text
  end
  return vim.fn.strcharpart(text, 0, max - 1) .. '…'
end

-- The lines and a converter from the outline's 1-based UTF-16 columns to
-- 0-based byte columns; nil past the end of the line or a missing line.
local function reader(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local units = {} -- line -> its length in UTF-16 units, for non-ASCII lines
  local function byte(l, col)
    local line = lines[l]
    if not line or type(col) ~= 'number' or col < 1 then
      return nil
    end
    local i = col - 1
    if not line:find('[\128-\255]') then
      return i <= #line and i or nil
    end
    units[l] = units[l] or vim.str_utfindex(line, 'utf-16')
    if i > units[l] then
      return nil
    end
    return vim.str_byteindex(line, 'utf-16', i, false)
  end
  return lines, byte
end

-- The opener of a block: its first line, or a line after its attribute lines.
local function opener(lines, b)
  if type(b.line) ~= 'number' or type(b.name) ~= 'string' then
    return nil
  end
  local written = (':'):rep(tonumber(b.colons) or 2) .. b.name
  for l = b.line, math.min(tonumber(b.endLine) or b.line, b.line + 3) do
    if lines[l] and lines[l]:find(written, 1, true) then
      return l
    end
  end
end

-- The label at the end of a block's opener line, and the title after it when
-- the line does not show the title.
local function label(b, line)
  local text = b.label
  if type(b.title) == 'string' and not visible(line, b.title) then
    text = text .. ' — ' .. shorten(b.title, 60)
  end
  return { { text, 'TernVirtLabel' } }
end

-- Raw HTML elements whose body is code: drawn like a verbatim block, the
-- lines of their tags hidden, the name in place of the start tag. Returns
-- the units, as block() does, and the rows to tint.
local CODE = { script = true, style = true }
local function rawcode(lines, r)
  local first, last = lines[r.line], lines[r.endLine]
  if r.kind ~= 'rawtext' or not first or not last then
    return {}
  end
  local pre, name = first:match('^([%s>]*)<(%a[%w-]*)')
  name = name and name:lower()
  if not CODE[name] then
    return {}
  end
  local units = {}
  if r.endLine > r.line then
    if first:match('^[%s>]*<%a[%w-]*[^<>]*>%s*$') then
      units[1] = { { { r.line - 1, #pre, #first, { { name, 'TernVirtVerbatim' } } } }, r.line - 1, #first }
    end
    local cpre = last:lower():match('^([%s>]*)</' .. name .. '%s*>%s*$')
    if cpre then
      units[#units + 1] = { { { r.endLine - 1, #cpre, #last } }, r.endLine - 1, #last }
    end
  end
  return units, { r.line - 1, r.endLine - 1 }
end

-- Containers whose body is verbatim text, besides those marked {raw}.
local VERBATIM = { meta = true, macros = true, script = true, style = true, html = true }

-- A block's lines drawn in place: its opener as its label, or else its name
-- (a leaf's in ⟨⟩), before its title, and its attributes as their id; the
-- attribute lines above it as their ids; its closer as nothing. Its body is
-- left to the rest. Returns a list of { parts, row, end, eol }, one a line,
-- parts as display() returns them; and for a container with a verbatim
-- body, its first and last rows, to tint.
local function block(lines, b, labels)
  local l = opener(lines, b)
  if not l then
    return {}
  end
  local line = lines[l]
  local s, e = line:find((':'):rep(tonumber(b.colons) or 2) .. b.name, 1, true)
  local tail = line:match('()%b{}%s*$', e + 1) or #line + 1
  local groups = line:sub(tail)
  if not line:sub(1, s - 1):match('^[%s>]*$') or line:sub(e + 1, e + 1):match('[%w_%-\128-\255]') then
    return {}
  end
  local verbatim = b.kind == 'container' and (VERBATIM[b.name] or (' ' .. groups:sub(2, -2) .. ' '):find('%sraw[%s=]') ~= nil)
  local head = { b.name, 'TernVirtName' }
  if labels and type(b.label) == 'string' then
    head = { b.label, 'TernVirtLabel' }
  elseif verbatim then
    head[2] = 'TernVirtVerbatim'
  elseif b.kind == 'leaf' then
    head[1] = '⟨' .. b.name .. '⟩'
  end
  local between = line:sub(e + 1, tail - 1)
  local open = between:match('^%s*()%[')
  local parts
  if open then
    -- The title stays, between the hidden `:::name[` and `]{attrs}`.
    open = e + open
    local close = line:sub(1, tail - 1):match('.*()%]')
    if not close or close <= open or not line:sub(close + 1, tail - 1):match('^%s*$') then
      return {}
    end
    if vim.trim(line:sub(open + 1, close - 1)) ~= '' then
      parts = {
        { l - 1, s - 1, open, { { head[1] .. ' ', head[2] } } },
        { l - 1, close - 1, #line, ids(groups, ' ') },
      }
    end
  elseif not between:match('^%s*$') then
    return {}
  end
  if not parts then
    parts = { { l - 1, s - 1, #line, vim.list_extend({ head }, ids(groups, ' ') or {}) } }
  end
  local units = { { parts, l - 1, #line, { shown = labels and type(b.label) == 'string' and label(b, line) or nil } } }
  for a = b.line, l - 1 do
    local pre, body = lines[a]:match('^([%s>]*)(.-)%s*$')
    if body:sub(1, 1) == '{' and body:gsub('%b{}', ''):match('^%s*$') then
      units[#units + 1] = { { { a - 1, #pre, #lines[a], ids(body, '') } }, a - 1, #lines[a] }
    end
  end
  local c = tonumber(b.endLine)
  local closer = c and c > l and lines[c]
  local cs = closer and (closer:match('^[%s>]*():::+%s*$') or closer:match('^[%s>]*():::+/' .. vim.pesc(b.name) .. '%s*$'))
  if cs then
    units[#units + 1] = { { { c - 1, cs - 1, #closer } }, c - 1, #closer }
  end
  -- Unclosed, a verbatim body runs to its end line, or to the note's.
  local last = cs and c or math.min(math.max(c or l, l), #lines)
  return units, verbatim and { l - 1, last - 1 } or nil
end

-- Draws the outline over the buffer, replacing what was drawn. A mark whose
-- line no longer holds what the outline says (the outline lags while you
-- type) is left out.
function M.draw(buf, outline)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  inplace[buf] = nil
  if state[buf] then
    state[buf].drawn = true
  end
  if type(outline) ~= 'table' then
    return
  end
  local opts = require('tern.config').options.render
  opts = type(opts) == 'table' and opts or {}
  local lines, byte = reader(buf)
  local function mark(row, col, o)
    o.strict = false
    api.nvim_buf_set_extmark(buf, ns, row, col, o)
  end
  local d = { open = opened(buf), shown = {} }
  inplace[buf] = d
  -- Draws f in place of its parts, { row, start, end, chunks }, unless the
  -- source shows; follow() redraws it when the cursor moves. The first part
  -- starts f's source, which ends at (erow, ecol).
  local function hide(f, parts, erow, ecol)
    local first = parts[1]
    local id = api.nvim_buf_set_extmark(buf, ns, first[1], first[2], { end_row = erow, end_col = ecol, strict = false })
    f.parts, f.text = {}, {}
    for i, p in ipairs(parts) do
      local pid = #parts == 1 and id or api.nvim_buf_set_extmark(buf, ns, p[1], p[2], { end_col = p[3], strict = false })
      f.parts[i] = { id = pid, chunks = p[4] }
    end
    d.shown[id] = f
    place(buf, id, f, shows(d.open, first[1], erow))
  end

  for _, b in ipairs(list(outline.blocks)) do
    local units, tint = {}, nil
    if opts.conceal then
      units, tint = block(lines, b, opts.labels)
    end
    for _, u in ipairs(units) do
      hide({ eol = u[4] }, u[1], u[2], u[3])
    end
    if tint then
      mark(tint[1], 0, { end_row = tint[2], line_hl_group = 'TernVerbatim' })
    end
    local l = #units == 0 and opts.labels and type(b.label) == 'string' and opener(lines, b)
    if l then
      mark(l - 1, 0, { virt_text = label(b, lines[l]), virt_text_pos = 'eol' })
    end
  end

  for _, r in ipairs(opts.conceal and list(outline.raw) or {}) do
    if type(r.line) == 'number' and type(r.endLine) == 'number' then
      local units, tint = rawcode(lines, r)
      for _, u in ipairs(units) do
        hide({}, u[1], u[2], u[3])
      end
      if tint then
        mark(tint[1], 0, { end_row = tint[2], line_hl_group = 'TernVerbatim' })
      end
    end
  end

  -- Without the plugin's folds, a one-line head is drawn in place.
  if opts.conceal and not require('tern.config').options.fold and require('tern.head').lines(buf) == 1 then
    hide({}, { { 0, 0, #lines[1], require('tern.head').summary(buf) } }, 0, #lines[1])
  end

  if opts.refs then
    for _, r in ipairs(list(outline.refs)) do
      if r.resolved and type(r.text) == 'string' and r.text ~= '' and type(r.id) == 'string' then
        local s, e = byte(r.line, r.col), byte(r.line, r['end'])
        if s and e and lines[r.line]:sub(s + 1, s + 1 + #r.id) == '@' .. r.id then
          mark(r.line - 1, e, { virt_text = { { ' ' .. shorten(r.text, 40), 'TernVirtRef' } }, virt_text_pos = 'inline' })
        end
      end
    end
  end

  if opts.math then
    -- The macros every formula shares: window.TERN's, then each :::macros
    -- block's, in the note's order, wherever the formula is.
    local macros = require('tern.head').macros(buf)
    for _, b in ipairs(list(outline.blocks)) do
      local l = b.kind == 'container' and b.name == 'macros' and opener(lines, b)
      local last = l and math.min(tonumber(b.endLine) or l, #lines)
      if last and last > l then
        -- After the opener's indentation or quote marks, up to the closer.
        local n = #lines[l]:match('^[%s>]*')
        local body = {}
        for k = l + 1, last do
          if k < last or not lines[k]:match('^[%s>]*:::') then
            body[#body + 1] = lines[k]:sub(n + 1)
          end
        end
        require('tern.tex').macros(table.concat(body, '\n'), macros)
      end
    end
    macros = next(macros) and macros or nil
    for _, m in ipairs(list(outline.math)) do
      local u = type(m.tex) == 'string' and unicode(m.tex, macros) or nil
      local w = u ~= nil and worth(m.tex, u)
      local last = m.endLine or m.line
      local number = type(m.number) == 'string' and m.number or nil
      local parts, erow, ecol, single
      if m.display and opts.conceal then
        parts, erow, ecol, single = display(lines, byte, m, last, macros)
      end
      if parts then
        -- The number at the end of the closing line; the Unicode form of
        -- one line of TeX before it while the source shows.
        local shown = {}
        if single and worth(m.tex, single) then
          shown[1] = { single, 'TernVirtMath' }
        end
        if number then
          shown[#shown + 1] = { (#shown > 0 and '  ' or '') .. number, 'TernVirtLabel' }
        end
        hide({ eol = { hidden = number and { { number, 'TernVirtLabel' } }, shown = #shown > 0 and shown or nil } }, parts, erow, ecol)
      elseif m.display then
        -- At the end of the closing line, where its id is written.
        u = w and u or nil
        local chunks = {}
        if u then
          chunks[#chunks + 1] = { u, 'TernVirtMath' }
        end
        if number then
          chunks[#chunks + 1] = { (u and '  ' or '') .. number, 'TernVirtLabel' }
        end
        if #chunks > 0 and lines[last] and lines[last]:find('$$', 1, true) then
          mark(last - 1, 0, { virt_text = chunks, virt_text_pos = 'eol' })
        end
      elseif u then
        local s, e = byte(m.line, m.col), byte(last, m['end'])
        if s and e and e > 0 and lines[m.line]:sub(s + 1, s + 1) == '$' and lines[last]:sub(e, e) == '$' then
          if opts.conceal and m.line == last then
            hide({ after = w and { { ' ' .. u, 'TernVirtMath' } } or nil }, { { last - 1, s, e, math_text(u) } }, last - 1, e)
          elseif w then
            mark(last - 1, e, { virt_text = { { ' ' .. u, 'TernVirtMath' } }, virt_text_pos = 'inline' })
          end
        end
      end
    end
  end
end

local function clear(buf)
  inplace[buf] = nil
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

-- The head's fold in each window showing buf: closed when the note is first
-- drawn there, and when the cursor leaves the head; opened when the cursor
-- moves into it, or Insert mode starts there. Only in windows that fold
-- notes the plugin's way, with options.render.conceal.
local function fold(win, how)
  api.nvim_win_call(win, function()
    -- Closing a closed fold would close the one around it: only the inner.
    if how == 'open' then
      pcall(vim.cmd, 'silent 1foldopen!')
    elseif vim.fn.foldclosed(1) == -1 then
      pcall(vim.cmd, 'silent 1foldclose')
    end
  end)
end

local function heads(buf, how)
  local st = state[buf]
  local n = st and st.on and require('tern.config').options.render.conceal and require('tern.head').lines(buf)
  if not n then
    return
  end
  local cur = api.nvim_get_current_win()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if require('tern.lsp').folding(win) then
      local row = api.nvim_win_get_cursor(win)[1]
      local was, before = st.inside[win], st.row[win]
      st.inside[win], st.row[win] = row <= n, row
      if how == 'start' then
        if not st.folded[win] then
          st.folded[win] = true
          fold(win, 'close')
        end
      elseif how == 'open' then
        fold(win, 'open')
      elseif win == cur then
        if row <= n and (was == false or api.nvim_get_mode().mode:find('^[iR]')) then
          fold(win, 'open')
          -- Up from the line below: onto the head's last line, not its first.
          if before == n + 1 then
            api.nvim_win_set_cursor(win, { n, 0 })
            st.row[win] = n
          end
        elseif row > n and was then
          fold(win, 'close')
        end
      end
    end
  end
end

local function latest(buf)
  local ok, lsp = pcall(require, 'tern.lsp')
  return ok and lsp.outline and lsp.outline(buf) or nil
end

-- An outline older than the buffer is skipped once something is drawn: the
-- marks drawn before moved with the edits, and the server sends a fresh
-- outline after its debounce.
local function stale(buf, o)
  if type(o) ~= 'table' or type(o.version) ~= 'number' then
    return false
  end
  local current = rawget(vim.lsp.util.buf_versions, buf)
  return type(current) == 'number' and o.version < current
end

local function refresh(buf)
  local st = state[buf]
  if not st or not st.on then
    return
  end
  local o = latest(buf)
  if st.drawn and stale(buf, o) then
    return
  end
  M.draw(buf, o)
  heads(buf, 'start')
end

local function setup()
  if group then
    return
  end
  highlights()
  group = api.nvim_create_augroup('tern_render', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  api.nvim_create_autocmd('OptionSet', {
    group = group,
    pattern = { 'conceallevel', 'concealcursor' },
    callback = function()
      follow(api.nvim_get_current_buf())
    end,
  })
  api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'TernOutline',
    callback = function(ev)
      local buf = type(ev.data) == 'table' and ev.data.buf
      if buf and state[buf] then
        refresh(buf)
      end
    end,
  })
end

function M.attach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  setup()
  if state[buf] then
    return
  end
  state[buf] = { on = true, folded = {}, inside = {}, row = {} }
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      state[buf] = nil
      inplace[buf] = nil
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'BufWinEnter', 'WinEnter' }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      follow(buf)
      if ev.event == 'BufWinEnter' and state[buf] then
        -- Shown in a window again: the head starts folded there.
        state[buf].folded[api.nvim_get_current_win()] = nil
        heads(buf, 'start')
      else
        heads(buf, 'follow')
      end
    end,
  })
  -- The window left no longer shows the cursor line's source.
  api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        follow(buf)
      end)
    end,
  })
  refresh(buf)
end

function M.command(args)
  local what = type(args) == 'table' and args.args or args or ''
  what = vim.trim(what)
  what = what == '' and 'toggle' or what
  if what ~= 'on' and what ~= 'off' and what ~= 'toggle' then
    vim.notify('tern: :TernRender takes on, off or toggle', vim.log.levels.ERROR)
    return
  end
  local buf = api.nvim_get_current_buf()
  local st = state[buf]
  if what == 'toggle' then
    what = st and st.on and 'off' or 'on'
  end
  if what == 'on' then
    if st then
      st.on = true
      st.folded = {}
      refresh(buf)
    else
      M.attach(buf)
    end
  elseif st then
    heads(buf, 'open')
    st.on = false
    st.drawn = false
    clear(buf)
  end
end

-- Whether the buffer shows the virtual text (for tests and statuslines).
function M.enabled(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  return state[buf] ~= nil and state[buf].on
end

M.ns = ns

return M
