-- SPDX-License-Identifier: MIT
-- A note's head: its lines up to the tern.js line, which the page does not
-- show (the doctype, <meta>, <title>, a window.TERN script, styles). The
-- folds give it a fold of its own, and tern.render keeps that fold closed
-- but while the cursor is in it.
--   lines(buf)     -> the number of lines in the head, or nil (not a note)
--   summary(buf)   -> virtual text chunks: ⟨head⟩, then what the head holds
--   macros(buf)    -> the macros of window.TERN.katex.macros, as
--                     tern.tex.macros returns them
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
    local d = require('tern.detect').buffer(buf)
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
  local chunks = { { '⟨head⟩', 'TernVirtVerbatim' } }
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
  local schema = text:find('window%.TERN') ~= nil
  items[#items + 1] = schema and 'schema' or nil
  -- Scripts besides tern.js and the schema's.
  local _, scripts = low:gsub('<script[%s>/]', '')
  local others = scripts - 1 - (schema and 1 or 0)
  items[#items + 1] = others == 1 and 'script' or others > 1 and others .. ' scripts' or nil
  items[#items + 1] = low:find('<style[%s>]') and 'style' or nil
  local use = attribute(cache[buf].tag or '', 'data%-use')
  items[#items + 1] = use and vim.trim(use) ~= '' and (vim.trim(use):gsub('%s+', ' ')) or nil
  if #items > 0 then
    local rest = table.concat(items, ' · ')
    if vim.fn.strchars(rest) > 72 then
      rest = vim.fn.strcharpart(rest, 0, 71) .. '…'
    end
    chunks[2] = { ' ' .. rest, 'TernVirtName' }
  end
  return chunks
end

-- A JavaScript string literal at s[i]: its value and the index after it.
local function literal(s, i)
  local q = s:sub(i, i)
  if q ~= "'" and q ~= '"' then
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
    elseif c == '\n' then
      return nil
    else
      out[#out + 1] = c
      k = k + 1
    end
  end
end

-- KaTeX's macros option: `'\\name': 'body'` pairs; a body's arguments are
-- the highest #n in it. Reading stops at the first value that is not a
-- string literal.
function M.macros(buf)
  local n = M.lines(buf)
  local out = {}
  if not n then
    return out
  end
  local text = table.concat(api.nvim_buf_get_lines(buf, 0, n, false), '\n')
  local i = text:match('katex%s*:.-macros%s*:%s*(){')
  while i do
    i = text:match('^[%s,]*()', i + (text:sub(i, i) == '{' and 1 or 0))
    local name, value
    name, i = literal(text, i)
    i = name and text:match('^%s*:%s*()', i)
    value, i = literal(text, i or 0)
    if not value then
      break
    end
    if name:match('^\\') then
      local args = 0
      for d in value:gmatch('#(%d)') do
        args = math.max(args, tonumber(d))
      end
      out[name] = { n = args, body = value }
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
  group = api.nvim_create_augroup('tern.head', { clear = true }),
  callback = function(a)
    cache[a.buf] = nil
  end,
})

return M
