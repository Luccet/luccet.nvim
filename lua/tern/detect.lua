-- SPDX-License-Identifier: MIT
-- Is a buffer a Tern note? A note is an HTML file one of whose lines holds a
-- plain <script> loading a file named tern.js. This is the engine's DETECT
-- rule (cli/note.js), written as a scanner because Lua patterns have no
-- lookahead; test/detect_test.lua checks it against the engine's fixtures
-- (test/fixtures/detect.json). The rule, per line:
--   - complete <!-- … --> comments are skipped; after an unclosed one,
--     nothing on the line counts;
--   - the tag is `<script` followed by whitespace, `>` or `/`, up to its `>`
--     (no `<` before it);
--   - it has no async, defer or data-built attribute and no type=module:
--     tern.js must run while the page is parsed to capture the note;
--   - its src is tern.js, optionally after a path and before ?query/#hash,
--     quoted or not, with no whitespace inside.
--   M.line(s)      -> {col = 1-based byte column of the tag, tag = '<script …>'} | nil
--   M.buffer(buf)  -> {lnum = 1-based line, col, tag} | nil
local M = {}

-- How far into a file the tern.js line is looked for. The head before it is
-- short in practice; the cap keeps detection cheap on large HTML files.
M.max_lines = 1000

local function space(c)
  return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f' or c == '\v'
end

-- An attribute `name` in the tag's inside: whitespace, the name, then
-- whitespace, `=`, `/` or the end of the tag.
local function has_attr(inner, name)
  local from = 1
  while true do
    local s, e = inner:find(name, from, true)
    if not s then
      return false
    end
    local after = inner:sub(e + 1, e + 1)
    if s > 1 and space(inner:sub(s - 1, s - 1)) and (after == '' or after == '=' or after == '/' or space(after)) then
      return true
    end
    from = s + 1
  end
end

local function is_module(inner)
  for a in inner:gmatch('%stype%s*=%s*["\']?module()') do
    local c = inner:sub(a, a)
    if c == '' or c == '"' or c == "'" or c == '/' or space(c) then
      return true
    end
  end
  return false
end

-- Does some `src=` in the tag's inside name tern.js? `tag` ends with `>`.
local function src_is_tern(inner, after_tag)
  local from = 1
  while true do
    local s, e = inner:find('%ssrc%s*=%s*', from)
    if not s then
      return false
    end
    local q = inner:sub(e + 1, e + 1)
    local v = e + 1
    if q == '"' or q == "'" then
      v = v + 1
    else
      q = ''
    end
    -- The value: a run of characters other than quotes, whitespace, < and >.
    local stop = v
    while stop <= #inner do
      local c = inner:sub(stop, stop)
      if c == '"' or c == "'" or c == '<' or c == '>' or space(c) then
        break
      end
      stop = stop + 1
    end
    local run = inner:sub(v, stop - 1)
    local nextc = stop <= #inner and inner:sub(stop, stop) or after_tag -- the char after the run
    local at = 1
    while true do
      local t1, t2 = run:find('tern.js', at, true)
      if not t1 then
        break
      end
      if t1 == 1 or run:sub(t1 - 1, t1 - 1) == '/' then
        local rest = run:sub(t2 + 1)
        local c = rest:sub(1, 1)
        local ok
        if c == '?' or c == '#' or c == '' then
          -- tern.js[?…|#…] runs to the end of the value: then the closing
          -- quote (if any), then whitespace, `>` or `/`.
          if q == '' then
            ok = nextc == '>' or space(nextc)
          else
            local after_q = stop + 1 <= #inner and inner:sub(stop + 1, stop + 1) or after_tag
            ok = nextc == q and (after_q == '>' or after_q == '/' or space(after_q))
          end
        elseif c == '/' and q == '' then
          ok = true -- an unquoted tern.js followed by `/` still ends the name
        end
        if ok then
          return true
        end
      end
      at = t1 + 1
    end
    from = s + 1
  end
end

-- The tern.js tag that starts at byte i of the line, or nil.
local function tag_at(s, low, i)
  if low:sub(i, i + 6) ~= '<script' then
    return nil
  end
  local c = low:sub(i + 7, i + 7)
  if not (c == '>' or c == '/' or space(c)) then
    return nil
  end
  local j = i + 1
  while j <= #s do
    local d = s:sub(j, j)
    if d == '<' then
      return nil
    end
    if d == '>' then
      break
    end
    j = j + 1
  end
  if j > #s then
    return nil
  end
  local inner = low:sub(i + 7, j - 1)
  if has_attr(inner, 'async') or has_attr(inner, 'defer') or has_attr(inner, 'data-built') or is_module(inner) then
    return nil
  end
  if not src_is_tern(inner, '>') then
    return nil
  end
  return s:sub(i, j)
end

function M.line(s)
  local low = s:lower()
  local i, n = 1, #s
  while i <= n do
    if s:sub(i, i) ~= '<' then
      i = i + 1
    elseif low:sub(i, i + 3) == '<!--' then
      local e = low:find('-->', i + 4, true)
      if not e then
        return nil
      end
      i = e + 3
    else
      local tag = tag_at(s, low, i)
      if tag then
        return { col = i, tag = tag }
      end
      i = i + 1
    end
  end
end

function M.buffer(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, M.max_lines, false)
  for lnum, l in ipairs(lines) do
    local d = M.line(l)
    if d then
      return { lnum = lnum, col = d.col, tag = d.tag }
    end
  end
end

return M
