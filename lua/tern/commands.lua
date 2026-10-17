-- SPDX-License-Identifier: MIT
-- :TernInit, :TernCheck, :TernBuild, :TernMove and :TernSearch. Each takes
-- the user command's args.
--   init(args)   write the canonical first line at the top of the buffer, as
--                `tern new` writes it (cli/commands.js newNote)
--   check(args)  `tern check --json` on the paths, or the buffer's file, into
--                the quickfix list
--   build(args)  `tern build FILE -o OUT`; OUT defaults to NAME.built.html
--                beside the note, so its relative URLs still resolve
--   move(args)   move the buffer's file, or FROM, to TO, with the link edits
--                the server's workspace/willRenameFiles gives (tern mv's)
--   search(args) `tern search --json` over the paths among the args, or the
--                working directory, into the quickfix list
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

-- ---------------------------------------------------------------- :TernSearch

local SEARCH = 'tern search'

local function is_dir(p)
  local st = vim.uv.fs_stat(p)
  return st and st.type == 'directory'
end

-- The args that name a file or a folder are the paths; one starting with --
-- is an option for tern search, as it is (`--index=search.json`, its value
-- expanded as a path); the rest, in order, are the query. Without a path the
-- working directory is searched.
function M.search(args)
  local buf = vim.api.nvim_get_current_buf()
  local paths, query, opts = {}, {}, {}
  for _, a in ipairs(args and args.fargs or {}) do
    if a:sub(1, 2) == '--' then
      local k, v = a:match('^(%-%-[%w%-]+=)(.+)$')
      opts[#opts + 1] = k and (k .. expand(v)) or a
    else
      local p = expand(a)
      if is_file(p) or is_dir(p) then
        paths[#paths + 1] = p
      else
        query[#query + 1] = a
      end
    end
  end
  if #query == 0 then
    return say('tern: give :TernSearch a word to search for', ERROR)
  end
  local words = table.concat(query, ' ')
  local cwd = vim.fn.getcwd()
  local argv = vim.list_extend({ 'search', '--json' }, opts)
  argv[#argv + 1] = words
  vim.list_extend(argv, paths)
  local _, reason = require('tern.cli').run(buf, argv, function(res)
    local ok, hits = pcall(vim.json.decode, res.stdout or '', { luanil = { object = true, array = true } })
    if res.code > 2 or not ok or type(hits) ~= 'table' then
      return failure('search', res)
    end
    local list = {}
    for _, h in ipairs(hits) do
      local abs = h.file:match('^/') or h.file:match('^%a:[/\\]')
      local heading = h.label or ''
      if h.title and h.title ~= '' then
        heading = heading .. ' ' .. h.title
      end
      list[#list + 1] = {
        filename = vim.fs.normalize(abs and h.file or cwd .. '/' .. h.file),
        lnum = h.line or 1,
        col = 1,
        end_lnum = h.endLine,
        text = heading .. ': ' .. (h.snippet or ''),
        user_data = { id = h.id, kind = h.kind, page = h.page, score = h.score },
      }
    end
    local cur = vim.fn.getqflist({ title = 0 }).title or ''
    local action = cur:sub(1, #SEARCH) == SEARCH and 'r' or ' '
    local notes = own_lines(res.stderr, 'search')
    if res.code == 2 then
      return say(#notes > 0 and table.concat(notes, '\n') or vim.trim(res.stderr or ''), ERROR)
    end
    if #list > 0 or action == 'r' then
      vim.fn.setqflist({}, action, { title = SEARCH .. ' ' .. words, items = list })
    end
    if #list > 0 then
      vim.cmd('botright copen')
      say(notes[#notes] or ('tern search: %d results'):format(#list))
    else
      say(notes[#notes] or 'tern search: no results', WARN)
    end
  end, { cwd = cwd })
  if reason then
    say('tern: cannot run tern search: ' .. reason, ERROR)
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

-- ---------------------------------------------------------------- :TernMove

local function shown(p)
  return vim.fn.fnamemodify(p, ':~:.')
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

-- The loaded buffer of a file, or nil.
local function loaded(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and file_of(b) == path then
      return b
    end
  end
end

-- The tern client whose root holds path, the buffer's first; else the
-- buffer's. One client only: two would edit a note twice.
local function client_for(buf, path)
  local own = require('tern.lsp').client(buf)
  local list = vim.lsp.get_clients({ name = 'tern' })
  if own then
    table.insert(list, 1, own)
  end
  for _, c in ipairs(list) do
    local root = c.root_dir and vim.fs.normalize(c.root_dir)
    if root and (path == root or vim.startswith(path, root .. '/')) then
      return c
    end
  end
  return own
end

-- Edits a file no buffer shows, in a buffer that runs no autocommands (no
-- filetype, server, or format on save) and keeps the file's bytes but for
-- the edits; then the buffer goes, or unloads if it was there before.
local function edit_file(path, edits, encoding)
  local existed = vim.fn.bufexists(path) == 1
  local b = vim.fn.bufadd(path)
  local listed = vim.bo[b].buflisted
  vim.bo[b].swapfile = false
  vim.cmd(('noautocmd call bufload(%d)'):format(b))
  local ok, err = pcall(function()
    vim.bo[b].fixendofline = false
    vim.lsp.util.apply_text_edits(edits, b, encoding)
    vim.api.nvim_buf_call(b, function()
      vim.cmd('silent noautocmd write')
    end)
  end)
  if existed then
    vim.bo[b].buflisted = listed
    vim.cmd(('silent! noautocmd %dbunload!'):format(b))
  else
    vim.cmd(('silent! noautocmd %dbwipeout!'):format(b))
  end
  if not ok then
    error(err, 0)
  end
end

-- The server's edits are for the files where they are; the files move
-- first, as tern mv does, so a move that fails changes nothing, and each
-- edit is made at the file's new path. A loaded buffer gets its edits and
-- is written, unless it had unsaved changes; vim.lsp.util.rename writes a
-- moved buffer at its new path.
function M.move(args)
  local buf = vim.api.nvim_get_current_buf()
  local fargs = args and args.fargs or {}
  if #fargs < 1 or #fargs > 2 then
    return say('tern: :TernMove [FROM] TO', ERROR)
  end
  local from = #fargs == 2 and vim.fs.normalize(vim.fn.fnamemodify(expand(fargs[1]), ':p')) or file_of(buf)
  if not from then
    return say('tern: this buffer has no file to move', ERROR)
  end
  local st = vim.uv.fs_stat(from)
  if not st then
    return say(('tern: %s does not exist%s'):format(shown(from), #fargs == 1 and '; write it first' or ''), ERROR)
  end
  local arg = expand(fargs[#fargs])
  local to = vim.fs.normalize(vim.fn.fnamemodify(arg, ':p'))
  if arg:match('[/\\]$') or vim.fn.isdirectory(to) == 1 then
    to = to .. '/' .. vim.fs.basename(from)
  end
  local there = vim.uv.fs_stat(to)
  local same = there and there.ino == st.ino and there.dev == st.dev -- a change of case, on a disk that ignores case
  if from == to then
    return say(('tern: %s is already there'):format(shown(from)), ERROR)
  elseif vim.startswith(to, from .. '/') then
    return say(('tern: cannot move %s into itself'):format(shown(from)), ERROR)
  elseif there and not same then
    return say(('tern: %s exists; move or remove it first'):format(shown(to)), ERROR)
  end
  local client = client_for(buf, from)
  if not client then
    return say(('tern: :TernMove needs the language server, and none is running for %s; open a note there first'):format(shown(from)), ERROR)
  end
  if not vim.tbl_get(client.server_capabilities or {}, 'workspace', 'fileOperations', 'willRename') then
    return say('tern: this tern lsp does not fix links on a move (workspace/willRenameFiles); update Tern', ERROR)
  end

  local files = { { oldUri = vim.uri_from_fname(from), newUri = vim.uri_from_fname(to) } }
  local res, why = client:request_sync('workspace/willRenameFiles', { files = files }, 10000)
  if not res or res.err then
    return say(('tern: the language server gave no edits (%s); nothing was moved'):format(res and res.err.message or why or 'no answer'), ERROR)
  end
  local ok, err = pcall(vim.lsp.util.rename, from, to, { overwrite = same })
  if not ok or not vim.uv.fs_stat(to) or (not same and vim.uv.fs_stat(from)) then
    return say(('tern: cannot move %s%s; nothing was changed'):format(shown(from), ok and '' or ': ' .. tostring(err)), ERROR)
  end

  local function moved(p)
    if p == from or vim.startswith(p, from .. '/') then
      return to .. p:sub(#from + 1)
    end
    return p
  end
  local links, notes, unsaved, failed = 0, 0, {}, {}
  for uri, edits in pairs(res.result and res.result.changes or {}) do
    local path = moved(vim.fs.normalize(vim.uri_to_fname(uri)))
    local done, e = pcall(function()
      local b = loaded(path)
      if not b then
        return edit_file(path, edits, client.offset_encoding)
      end
      local dirty = vim.bo[b].modified
      vim.lsp.util.apply_text_edits(edits, b, client.offset_encoding)
      if dirty then
        unsaved[#unsaved + 1] = shown(path)
      else
        vim.api.nvim_buf_call(b, function()
          vim.cmd('silent update')
        end)
      end
    end)
    if done then
      links, notes = links + #edits, notes + 1
    else
      failed[#failed + 1] = ('%s (%s)'):format(shown(path), tostring(e))
    end
  end
  client:notify('workspace/didRenameFiles', { files = files })

  local msg = { ('tern: moved %s → %s; %s in %s'):format(shown(from), shown(to), plural(links, 'link'), plural(notes, 'note')) }
  if #unsaved > 0 then
    msg[#msg + 1] = ('edited but not written, as they have unsaved changes: %s'):format(table.concat(unsaved, ', '))
  end
  if #failed > 0 then
    msg[#msg + 1] = ('not edited: %s'):format(table.concat(failed, ', '))
  end
  say(table.concat(msg, '\n'), (#unsaved > 0 or #failed > 0) and WARN or INFO)
end

return M
