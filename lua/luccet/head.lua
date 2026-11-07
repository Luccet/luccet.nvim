-- SPDX-License-Identifier: MIT
-- A note's head: its lines up to the luccet.js line, which the page does not
-- show (the doctype, <meta>, <title>, a window.LUCCET script, styles). The
-- folds give it a fold of its own, and luccet.render keeps that fold closed
-- but while the cursor is in it.
--   lines(buf)     -> the number of lines in the head, or nil (not a note)
--   summary(buf)   -> virtual text chunks: ⟨head⟩, then what the head holds
--   macros(buf)    -> the page's macros, window.LUCCET.macros, as
--                     luccet.tex.macros returns them
--   foldtext()     -> 'foldtext' for notes: the summary on the head's fold,
--                     Neovim's own on the others
local M = {}

local api = vim.api
local cache = {} -- buf -> { tick, lines }

function M.lines(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    local d = require('luccet.detect').buffer(buf)
    c = { tick = tick, lines = d and d.lnum or false, tag = d and d.tag }
    cache[buf] = c
  end
  return c.lines or nil
end

-- The value of an attribute in a tag, quoted or not.
local function attribute(tag, name)
  local pat = '%s' .. name .. '%s*=%s*'
  return tag:match(pat .. '"([^"]*)"') or tag:match(pat .. "'([^']*)'") or tag:match(pat .. '([^%s>]+)')
end

function M.summary(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local n = M.lines(buf)
  local chunks = { { '⟨head⟩', 'LuccetVirtVerbatim' } }
  if not n then
    return chunks
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, n, false), '\n')
  local low = text:lower()
  local items = {}
  local _, open = low:find('<title[^>]*>')
  if open then
    local title = vim.trim(text:sub(open + 1, (low:find('</title', open, true) or #text + 1) - 1))
    items[#items + 1] = title ~= '' and title or nil
  end
  local schema = text:find('window%.LUCCET') ~= nil
  items[#items + 1] = schema and 'schema' or nil
  -- Scripts besides luccet.js and the schema's.
  local _, scripts = low:gsub('<script[%s>/]', '')
  local others = scripts - 1 - (schema and 1 or 0)
  items[#items + 1] = others == 1 and 'script' or others > 1 and others .. ' scripts' or nil
  items[#items + 1] = low:find('<style[%s>]') and 'style' or nil
  -- Each add-on by its file name: https://cdn.luccet.dev/code/v1/code.js and
  -- code.js?base=vendor/highlight are both code.js.
  local names = {}
  for entry in (attribute(cache[buf].tag or '', 'data%-use') or ''):gmatch('%S+') do
    names[#names + 1] = entry:gsub('[?#].*$', ''):match('([^/]+)/*$') or entry
  end
  items[#items + 1] = #names > 0 and table.concat(names, ' ') or nil
  if #items > 0 then
    local rest = table.concat(items, ' · ')
    if vim.fn.strchars(rest) > 72 then
      rest = vim.fn.strcharpart(rest, 0, 71) .. '…'
    end
    chunks[2] = { ' ' .. rest, 'LuccetVirtName' }
  end
  return chunks
end

-- A JavaScript string literal at s[i], or a template without ${…}: its
-- value and the index after it.
local function literal(s, i)
  local q = s:sub(i, i)
  if q ~= "'" and q ~= '"' and q ~= '`' then
    return nil
  end
  local out, k = {}, i + 1
  while k <= #s do
    local c = s:sub(k, k)
    if c == q then
      return table.concat(out), k + 1
    elseif c == '\\' then
      local d = s:sub(k + 1, k + 1)
      out[#out + 1] = ({ n = '\n', t = '\t' })[d] or d
      k = k + 2
    elseif (c == '\n' and q ~= '`') or (q == '`' and s:sub(k, k + 1) == '${') then
      return nil
    else
      out[#out + 1] = c
      k = k + 1
    end
  end
end

-- The index after the comment at s[i], or nil when none starts there.
local function comment(s, i)
  local two = s:sub(i, i + 1)
  if two == '//' then
    return (s:find('\n', i, true) or #s) + 1
  elseif two == '/*' then
    local e = s:find('*/', i + 2, true)
    return e and e + 2 or #s + 1
  end
end

-- The index after the spaces, commas and comments at s[i].
local function gap(s, i)
  while true do
    i = s:match('^[%s,]*()', i)
    local after = comment(s, i)
    if not after then
      return i
    end
    i = after
  end
end

-- The entries of the object literal whose { is at s[i], as { key, from, to }:
-- its key, written as a name or a string, and the span of its value. Strings
-- and comments are skipped, so their braces and commas count for nothing.
-- It stops at what it does not read: a computed key, a spread, a method.
local function entries(s, i)
  local out, k = {}, i + 1
  while true do
    k = gap(s, k)
    local key
    if s:sub(k, k):find('["\'`]') then
      key, k = literal(s, k)
    else
      key, k = s:match('^([%a_$][%w_$]*)()', k)
    end
    k = key and s:match('^%s*:%s*()', k)
    if not k then
      return out
    end
    local from, depth = k, 0
    while k <= #s do
      local c, after = s:sub(k, k), comment(s, k)
      if after then
        k = after
      elseif c:find('["\'`]') then
        k = select(2, literal(s, k))
        if not k then
          return out
        end
      elseif c:find('[{[(]') then
        depth, k = depth + 1, k + 1
      elseif depth == 0 and c:find('[},%])]') then
        break
      elseif c:find('[}%])]') then
        depth, k = depth - 1, k + 1
      else
        k = k + 1
      end
    end
    out[#out + 1] = { key = key, from = from, to = k - 1 }
    if s:sub(k, k) ~= ',' then
      return out
    end
  end
end

-- The page's macros, as the engine reads window.LUCCET.macros
-- (docs/math.html#macros), given in `window.LUCCET = { macros: {…} }` or
-- `window.LUCCET.macros = {…}`: each entry whose value is a string, its name
-- written with or without the backslash, letters or one other character; a
-- body's arguments are the highest #n in it.
function M.macros(buf)
  local n = M.lines(buf)
  local out = {}
  if not n then
    return out
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, n, false), '\n')
  local objects = {}
  local i = text:match('%f[%w_$.]window%.LUCCET%s*=%s*(){')
  for _, e in ipairs(i and entries(text, i) or {}) do
    if e.key == 'macros' and text:sub(e.from, e.from) == '{' then
      objects[#objects + 1] = e.from
    end
  end
  objects[#objects + 1] = text:match('%f[%w_$.]window%.LUCCET%.macros%s*=%s*(){')
  for _, o in ipairs(objects) do
    for _, m in ipairs(entries(text, o)) do
      local body, after = literal(text, m.from)
      local name = m.key:gsub('^\\', '')
      if body and not text:sub(after, m.to):find('%S') and (name:find('^[A-Za-z]+$') or vim.fn.strchars(name) == 1) then
        local args = 0
        for d in body:gmatch('#([1-9])') do
          args = math.max(args, tonumber(d))
        end
        out['\\' .. name] = { n = args, body = body }
      end
    end
  end
  return out
end

function M.foldtext()
  local n = M.lines(0)
  if n and vim.v.foldstart == 1 and vim.v.foldend == n then
    return M.summary(0)
  end
  return vim.fn.foldtext()
end

api.nvim_create_autocmd('BufWipeout', {
  group = api.nvim_create_augroup('luccet.head', { clear = true }),
  callback = function(a)
    cache[a.buf] = nil
  end,
})

return M
