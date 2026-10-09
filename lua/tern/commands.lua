-- SPDX-License-Identifier: MIT
-- :TernInit, :TernCheck and :TernBuild. Each takes the user command's args.
--   init(args)   write the canonical first line at the top of the buffer, as
--                `tern new` writes it (cli/commands.js newNote)
--   check(args)  `tern check --json` on the paths, or the buffer's file, into
--                the quickfix list
--   build(args)  `tern build FILE -o OUT`; OUT defaults to NAME.built.html
--                beside the note, so its relative URLs still resolve
local M = {}

local INFO, WARN, ERROR = vim.log.levels.INFO, vim.log.levels.WARN, vim.log.levels.ERROR

local function say(msg, level)
  vim.notify(msg, level or INFO)
end

-- The buffer's file, absolute, or nil for an unnamed or special buffer.
local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
end

-- A path argument, with %, # and ~ expanded as on the command line.
local function expand(arg)
  return arg:match('^[%%#<~$]') and vim.fn.expandcmd(arg) or arg
end

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st and st.type == 'file'
end

-- The path from directory `from` to `to`, with forward slashes.
local function relative(from, to)
  local a = vim.split(from, '/', { trimempty = true })
  local b = vim.split(to, '/', { trimempty = true })
  if from:match('^%a:') and a[1] ~= b[1] then
    return to -- another drive
  end
  local i = 1
  while a[i] and b[i] and a[i] == b[i] do
    i = i + 1
  end
  local parts = {}
  for _ = i, #a do
    parts[#parts + 1] = '..'
  end
  for j = i, #b do
    parts[#parts + 1] = b[j]
  end
  return table.concat(parts, '/')
end

local function esc_attr(s)
  return (s:gsub('[&"<>]', { ['&'] = '&amp;', ['"'] = '&quot;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

-- The lines of stderr that a command wrote itself (not an add-on's console).
local function own_lines(stderr, name)
  local out = {}
  for l in vim.gsplit(stderr or '', '\n', { plain = true }) do
    if l:find('^tern ' .. name .. ':') then
      out[#out + 1] = l
    end
  end
  return out
end

local function failure(name, res)
  local err = vim.trim(res.stderr or '')
  say(('tern %s failed (exit %d)%s'):format(name, res.code, err ~= '' and ':\n' .. err or ''), ERROR)
end

-- ---------------------------------------------------------------- :TernInit

function M.init(args)
  local buf = vim.api.nvim_get_current_buf()
  local file = file_of(buf)
  if not file then
    return say('tern: this buffer has no file; save it first (:write NAME.html), then :TernInit', ERROR)
  end
  local found = require('tern.detect').buffer(buf)
  if found then
    return say(('tern: this buffer is already a note: line %d loads tern.js'):format(found.lnum), WARN)
  end
  if not vim.bo[buf].modifiable then
    return say('tern: this buffer is not modifiable', ERROR)
  end

  -- The src: the argument (a file is made relative to the note; anything
  -- else, such as a URL, is written as given), else the nearest tern.js in
  -- the note's directory or above, else tern.js beside the note.
  local dir = vim.fs.dirname(file)
  local arg = args and args.fargs and args.fargs[1]
  local src, note
  if arg and arg ~= '' then
    local p = vim.fs.normalize(vim.fn.fnamemodify(expand(arg), ':p'))
    if not is_file(p) and is_file(p .. '/tern.js') then
      p = p .. '/tern.js'
    end
    src = is_file(p) and relative(dir, p) or arg
  else
    local near = vim.fs.find('tern.js', { upward = true, path = dir, type = 'file', limit = 1 })[1]
    src = near and relative(dir, vim.fs.normalize(near)) or 'tern.js'
    if not near then
      note = ('no tern.js in %s or above; the note loads tern.js from its own directory'):format(vim.fn.fnamemodify(dir, ':~:.'))
    end
  end
  local line = ('<!doctype html><meta charset="utf-8"><script src="%s"></script>'):format(esc_attr(src))
  if not require('tern.detect').line(line) then
    return say(('tern: <script src="%s"> would not make this buffer a note: the src must name a file called tern.js'):format(src), ERROR)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == '' then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line, '' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  else
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { line })
  end
  vim.bo[buf].filetype = 'tern'
  if vim.fn.isdirectory(dir) == 0 then
    note = (note and note .. '; ' or '') .. ('there is no directory %s yet'):format(vim.fn.fnamemodify(dir, ':~:.'))
  end
  if not file:lower():match('%.html?$') then
    note = (note and note .. '; ' or '') .. 'the file name does not end in .html, so a browser will not render it'
  end
  say(('tern: this buffer is a note now, loading %s%s'):format(src, note and ' (' .. note .. ')' or ''), note and WARN or INFO)
end

-- ---------------------------------------------------------------- :TernCheck

local TYPE = { error = 'E', warning = 'W', info = 'I' }
local TITLE = 'tern check'

-- A 1-based UTF-16 column of a line as a 1-based byte column.
local function byte_col(line, col)
  if not line or not line:find('[\128-\255]') then
    return col
  end
  local ok, b = pcall(vim.str_byteindex, line, 'utf-16', col - 1, false)
  return ok and b + 1 or col
end

-- The lines of a file: its buffer's when loaded and unchanged, else the disk's.
local function lines_of(path)
  local b = vim.fn.bufnr(path)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) and not vim.bo[b].modified then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, l = pcall(vim.fn.readfile, path)
  return ok and l or {}
end

local function items(diags, cwd)
  local out, files = {}, {}
  for _, d in ipairs(diags) do
    local abs = d.file:match('^/') or d.file:match('^%a:[/\\]')
    local path = vim.fs.normalize(abs and d.file or cwd .. '/' .. d.file)
    files[path] = files[path] or lines_of(path)
    local s, e = d.filePosition.start, d.filePosition['end'] or d.filePosition.start
    local lines = files[path]
    out[#out + 1] = {
      filename = path,
      lnum = s.line,
      col = byte_col(lines[s.line], s.column),
      end_lnum = e.line,
      end_col = byte_col(lines[e.line], e.column),
      type = TYPE[d.severity] or 'I',
      text = ('%s: %s'):format(d.code, d.message),
      user_data = d.hint and { hint = d.hint } or nil,
    }
  end
  return out
end

-- Replaces the list when the current one is a tern check, else adds one.
local function set_list(list, what)
  local cur = vim.fn.getqflist({ title = 0 }).title or ''
  local action = cur:sub(1, #TITLE) == TITLE and 'r' or ' '
  if #list == 0 and action == ' ' then
    return
  end
  vim.fn.setqflist({}, action, { title = what, items = list })
end

function M.check(args)
  local buf = vim.api.nvim_get_current_buf()
  local paths = {}
  for _, a in ipairs(args and args.fargs or {}) do
    paths[#paths + 1] = expand(a)
  end
  local unsaved = false
  if #paths == 0 then
    local file = file_of(buf)
    if not file then
      return say('tern: this buffer has no file to check; save it, or give :TernCheck a path', ERROR)
    end
    paths[1] = file
    unsaved = vim.bo[buf].modified
  end
  local cwd = vim.fn.getcwd()
  local argv = vim.list_extend({ 'check', '--json' }, paths)
  local _, reason = require('tern.cli').run(buf, argv, function(res)
    local ok, diags = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true, array = true } })
    if res.code > 2 or not ok or type(diags) ~= 'table' then
      return failure('check', res)
    end
    local list = items(diags, cwd)
    set_list(list, TITLE .. ' ' .. table.concat(paths, ' '))
    local notes = own_lines(res.stderr, 'check')
    if res.code == 2 then
      say(#notes > 0 and table.concat(notes, '\n') or vim.trim(res.stderr or ''), ERROR)
    end
    local disk = unsaved and ' (the file on disk: the buffer has unsaved changes)' or ''
    if #list > 0 then
      vim.cmd('botright copen')
      if res.code ~= 2 then
        say((notes[#notes] or ('tern check: %d problems'):format(#list)) .. disk)
      end
    elseif res.code ~= 2 then
      local summary = notes[#notes] or ''
      if summary:find('no notes found', 1, true) then
        say(table.concat(notes, '\n'), WARN)
      else
        say('tern check: no problems' .. disk)
      end
    end
  end, { cwd = cwd })
  if reason then
    say('tern: cannot run tern check: ' .. reason, ERROR)
  end
end

-- ---------------------------------------------------------------- :TernBuild

-- A diagnostic line as tern build prints it: FILE:LINE:COL: SEVERITY CODE: …
local function is_diagnostic(l)
  return l:match(':%d+:%d+: %a+ [%w.-]+: ') ~= nil
end

function M.build(args)
  local buf = vim.api.nvim_get_current_buf()
  local file = file_of(buf)
  if not file then
    return say('tern: this buffer has no file to build; save it first', ERROR)
  end
  local arg = args and args.fargs and args.fargs[1]
  local out = (arg and arg ~= '') and expand(arg) or file:gsub('%.[^./]*$', '') .. '.built.html'
  local unsaved = vim.bo[buf].modified
  local cwd = vim.fn.getcwd()
  -- Paths relative to the current directory, for tern build's messages.
  local argv = { 'build', vim.fn.fnamemodify(file, ':.'), '-o', vim.fn.fnamemodify(out, ':.') }
  local _, reason = require('tern.cli').run(buf, argv, function(res)
    if res.code ~= 0 then
      return failure('build', res)
    end
    local wrote, warnings, diags = nil, {}, 0
    for l in vim.gsplit(res.stderr or '', '\n', { plain = true }) do
      if l:find('^tern build: wrote ') then
        wrote = l
      elseif l:find('^tern build: ') then
        warnings[#warnings + 1] = l
      elseif is_diagnostic(l) then
        diags = diags + 1
      end
    end
    local msg = { wrote or ('tern build: wrote ' .. out) }
    if diags > 0 then
      msg[#msg + 1] = ('%d diagnostic%s in the note; :TernCheck lists them'):format(diags, diags == 1 and '' or 's')
    end
    if unsaved then
      msg[#msg + 1] = 'built from the file on disk: the buffer has unsaved changes'
    end
    vim.list_extend(msg, warnings)
    say(table.concat(msg, '\n'), (#warnings > 0 or diags > 0 or unsaved) and WARN or INFO)
  end, { cwd = cwd })
  if reason then
    say('tern: cannot run tern build: ' .. reason, ERROR)
  end
end

return M
