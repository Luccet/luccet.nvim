-- SPDX-License-Identifier: MIT
-- Virtual text drawn from the server's outline, so the source shows what the
-- page will: a numbered block's label at the end of its opener line, what
-- each @reference reads as, equation numbers, and simple math as Unicode.
-- The source is never hidden. Each kind has its options.render flag.
--   attach(buf)          draw now, and again on each User TernOutline
--   command(args)        :TernRender [on|off|toggle], per buffer
--   draw(buf, outline)   draw an outline table (what the events call)
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace('tern_render')
local state = {} -- buf -> { on = bool, drawn = bool }
local group

local function highlights()
  api.nvim_set_hl(0, 'TernVirtLabel', { link = 'Special', default = true })
  api.nvim_set_hl(0, 'TernVirtRef', { link = 'Comment', default = true })
  api.nvim_set_hl(0, 'TernVirtMath', { link = 'Comment', default = true })
end

-- tex.unicode by TeX source; a note repeats its formulas.
local cache, cached = {}, 0
local function unicode(tex)
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

-- Draws the outline over the buffer, replacing what was drawn. A mark whose
-- line no longer holds what the outline says (the outline lags while you
-- type) is left out.
function M.draw(buf, outline)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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

  if opts.labels then
    for _, b in ipairs(list(outline.blocks)) do
      local l = type(b.label) == 'string' and opener(lines, b)
      if l then
        local text = b.label
        if type(b.title) == 'string' and not visible(lines[l], b.title) then
          text = text .. ' — ' .. shorten(b.title, 60)
        end
        mark(l - 1, 0, { virt_text = { { text, 'TernVirtLabel' } }, virt_text_pos = 'eol' })
      end
    end
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
    for _, m in ipairs(list(outline.math)) do
      local u = type(m.tex) == 'string' and unicode(m.tex)
      if u and not worth(m.tex, u) then
        u = nil
      end
      local last = m.endLine or m.line
      if m.display then
        -- At the end of the closing line, where its id is written.
        local chunks = {}
        if u then
          chunks[#chunks + 1] = { u, 'TernVirtMath' }
        end
        if type(m.number) == 'string' then
          chunks[#chunks + 1] = { (u and '  ' or '') .. m.number, 'TernVirtLabel' }
        end
        if #chunks > 0 and lines[last] and lines[last]:find('$$', 1, true) then
          mark(last - 1, 0, { virt_text = chunks, virt_text_pos = 'eol' })
        end
      elseif u then
        local s, e = byte(m.line, m.col), byte(last, m['end'])
        if s and e and e > 0 and lines[m.line]:sub(s + 1, s + 1) == '$' and lines[last]:sub(e, e) == '$' then
          mark(last - 1, e, { virt_text = { { ' ' .. u, 'TernVirtMath' } }, virt_text_pos = 'inline' })
        end
      end
    end
  end
end

local function clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
end

local function setup()
  if group then
    return
  end
  highlights()
  group = api.nvim_create_augroup('tern_render', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
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
  state[buf] = { on = true }
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      state[buf] = nil
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
      refresh(buf)
    else
      M.attach(buf)
    end
  elseif st then
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
