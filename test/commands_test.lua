-- SPDX-License-Identifier: MIT
-- :LuccetInit, :LuccetCheck, :LuccetBuild, and :LuccetMove's refusals. The language
-- server is off here (lsp = false); :LuccetCheck and :LuccetBuild run the real
-- CLI, found next to a link to the Luccet checkout's luccet.js.
local FIRST = '<!doctype html><meta charset="utf-8"><script src="%s"></script>'

-- Runs fn(T, notices) with the server off, $LUCCET_CLI unset, no `luccet` on
-- PATH (as in CI: the CLI is found from the note) and vim.notify captured;
-- restores all four.
local function scoped(fn)
  return function(T)
    local env, path, notify = vim.env.LUCCET_CLI, vim.env.PATH, vim.notify
    local notices = {}
    vim.env.LUCCET_CLI = nil
    vim.env.PATH = '/usr/bin:/bin:' .. vim.fs.dirname(vim.fn.exepath('node'))
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
    require('luccet').setup({ lsp = false })
    local ok, err = pcall(fn, T, notices)
    vim.env.LUCCET_CLI, vim.env.PATH, vim.notify = env, path, notify
    require('luccet').setup()
    if not ok then
      error(err, 0)
    end
  end
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- A note beside a link to luccet.js; nil without a Luccet checkout.
local function note(T, text)
  local root = T.luccet_root()
  if not root then
    print('    (skipped: no Luccet checkout; set $LUCCET_ROOT)')
    return nil
  end
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p')) -- for the link
  local dir = T.tmpdir()
  assert(vim.uv.fs_symlink(root .. '/luccet.js', dir .. '/luccet.js'))
  return T.write(dir .. '/note.html', FIRST:format('luccet.js') .. '\n' .. text), dir
end

return {
  { ':LuccetInit refuses an unnamed buffer at once', scoped(function(T, notices)
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '# Hi' })
    local t = vim.uv.hrtime()
    vim.cmd('LuccetInit')
    T.ok((vim.uv.hrtime() - t) / 1e6 < 200, 'quick')
    T.eq(lines(), { '# Hi' }, 'unchanged')
    T.ok(notices[1] and notices[1].msg:find('save it first', 1, true), vim.inspect(notices))
  end) },

  { ':LuccetInit writes the line with the nearest luccet.js, in one undo step', scoped(function(T, notices)
    local dir = T.tmpdir()
    T.write(dir .. '/luccet.js', '')
    vim.cmd.edit(T.write(dir .. '/notes/deep/kernel.html', '# Kernel\n'))
    T.eq(vim.bo.filetype, 'html', 'not a note yet')
    vim.cmd('LuccetInit')
    T.eq(lines(), { FIRST:format('../../luccet.js'), '# Kernel' }, 'lines')
    T.eq(vim.bo.filetype, 'luccet', 'filetype')
    T.ok(notices[1].msg:find('../../luccet.js', 1, true), notices[1].msg)
    vim.cmd('silent undo')
    T.eq(lines(), { '# Kernel' }, 'after one undo')
  end) },

  { ':LuccetInit on an empty buffer leaves the cursor on the note', scoped(function(T)
    local dir = T.tmpdir()
    vim.cmd.edit(dir .. '/new.html')
    vim.cmd('LuccetInit')
    T.eq(lines(), { FIRST:format('luccet.js'), '' }, 'no luccet.js above: luccet.js beside the note')
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 }, 'cursor')
  end) },

  { ':LuccetInit PATH: a file made relative, anything else as given', scoped(function(T, notices)
    local dir = T.tmpdir()
    local lib = T.write(dir .. '/lib/luccet.js', '')
    vim.cmd.edit(dir .. '/notes/a.html')
    vim.cmd('LuccetInit ' .. lib)
    T.eq(lines()[1], FIRST:format('../lib/luccet.js'), 'a file')
    vim.cmd.edit(dir .. '/notes/b.html')
    vim.cmd('LuccetInit ' .. dir .. '/lib')
    T.eq(lines()[1], FIRST:format('../lib/luccet.js'), 'a directory holding luccet.js')
    vim.cmd.edit(dir .. '/notes/c.html')
    vim.cmd('LuccetInit https://cdn.example/luccet/luccet.js')
    T.eq(lines()[1], FIRST:format('https://cdn.example/luccet/luccet.js'), 'a URL')
    vim.cmd.edit(dir .. '/notes/d.html')
    vim.cmd('LuccetInit lib/luccet.min.js')
    T.eq(lines(), { '' }, 'luccet.min.js is refused')
    T.ok(notices[#notices].msg:find('called luccet.js', 1, true), notices[#notices].msg)
  end) },

  { ':LuccetInit refuses a note and a non-modifiable buffer', scoped(function(T, notices)
    local dir = T.tmpdir()
    local text = { FIRST:format('luccet.js'), '# Hi' }
    vim.cmd.edit(T.write(dir .. '/note.html', table.concat(text, '\n') .. '\n'))
    vim.cmd('LuccetInit')
    T.eq(lines(), text, 'a note is unchanged')
    T.ok(notices[1].msg:find('already a note', 1, true), notices[1].msg)
    vim.cmd.edit(T.write(dir .. '/locked.html', '# Hi\n'))
    vim.bo.modifiable = false
    vim.cmd('LuccetInit')
    T.eq(lines(), { '# Hi' }, 'a non-modifiable buffer is unchanged')
    T.ok(notices[2].msg:find('not modifiable', 1, true), notices[2].msg)
  end) },

  { ':LuccetCheck fills the quickfix list', scoped(function(T, notices)
    local path = note(T, '# Kernel\n\nSee @nowhere.\n\n:::aside\nopen\n')
    if not path then
      return
    end
    vim.fn.setqflist({}, 'f')
    vim.cmd.edit(path)
    vim.cmd('LuccetCheck')
    T.wait(10000, function()
      return #vim.fn.getqflist() > 0
    end, 'the quickfix list')
    local qf = vim.fn.getqflist()
    T.eq(#qf, 2, 'entries')
    local w = qf[1]
    T.eq({ vim.api.nvim_buf_get_name(w.bufnr), w.lnum, w.col, w.type }, { path, 4, 5, 'W' }, 'the warning')
    T.ok(w.text:find('^ref%.dangling: no id'), w.text)
    T.eq({ qf[2].lnum, qf[2].type, qf[2].text:match('^[%w.]+') }, { 6, 'E', 'block.unclosed' }, 'the error')
    T.ok(vim.fn.getqflist({ title = 0 }).title:find('^luccet check'), 'title')
    T.ok(vim.fn.getqflist({ winid = 0 }).winid ~= 0, 'the list is open')
    T.ok(notices[#notices].msg:find('1 error, 1 warning', 1, true), notices[#notices].msg)
  end) },

  { ':LuccetSearch fills the quickfix list with the hits, at their lines', scoped(function(T, notices)
    local path, dir = note(T, '# Kernel\n\nA map has a kernel.\n\n:::aside{#py}\nPythagoras proved it with squares.\n:::\n')
    if not path then
      return
    end
    vim.fn.setqflist({}, 'f')
    vim.cmd.edit(path)
    vim.cmd.cd(dir)
    vim.cmd('LuccetSearch pythag')
    T.wait(10000, function()
      return #vim.fn.getqflist() > 0
    end, 'the quickfix list')
    local qf = vim.fn.getqflist()
    T.eq(#qf, 1, 'entries')
    T.eq({ vim.api.nvim_buf_get_name(qf[1].bufnr), qf[1].lnum, qf[1].col }, { path, 6, 1 }, 'the hit at the block')
    T.ok(qf[1].text:find('^aside: Pythagoras proved'), qf[1].text)
    T.eq(qf[1].user_data.id, 'py', 'the id')
    T.ok(vim.fn.getqflist({ title = 0 }).title:find('^luccet search pythag'), 'title')
    T.ok(vim.fn.getqflist({ winid = 0 }).winid ~= 0, 'the list is open')
    T.ok(notices[#notices].msg:find('1 result', 1, true), notices[#notices].msg)
    vim.cmd('LuccetSearch kernel ' .. dir)
    T.wait(10000, function()
      return (vim.fn.getqflist({ title = 0 }).title or ''):find('^luccet search kernel') ~= nil
    end, 'the list replaced')
    T.eq({ #vim.fn.getqflist(), vim.fn.getqflist()[1].lnum }, { 1, 2 }, "the heading's section alone, at the heading")
    vim.cmd('LuccetSearch nothingofthesort')
    T.wait(10000, function()
      return notices[#notices].msg:find('0 results', 1, true) ~= nil
    end, 'the miss reported')
    T.eq(#vim.fn.getqflist(), 0, 'the list replaced, as a new check replaces a check list')
    local ok, err = pcall(vim.cmd, 'LuccetSearch')
    T.ok(not ok and tostring(err):find('E471'), 'no words: an argument is required')
    vim.cmd('LuccetSearch ' .. dir)
    T.wait(10000, function()
      return notices[#notices].msg:find('a word to search for', 1, true) ~= nil
    end, 'a path alone refused')
    -- An option goes to luccet search as it is: --index=FILE searches the
    -- index luccet index wrote, so the hit comes from the file, at its line.
    local r = vim.system({ 'node', T.luccet_root() .. '/luccet-cli.js', 'index', dir }, { text = true }):wait()
    T.eq(r.code, 0, 'luccet index: ' .. (r.stderr or ''))
    vim.cmd('LuccetSearch --index=search.json pythag')
    T.wait(10000, function()
      return #vim.fn.getqflist() == 1 and (vim.fn.getqflist({ title = 0 }).title or ''):find('^luccet search pythag') ~= nil
    end, 'the hit from the index')
    T.eq({ vim.api.nvim_buf_get_name(vim.fn.getqflist()[1].bufnr), vim.fn.getqflist()[1].lnum, vim.fn.getqflist()[1].user_data.id }, { path, 6, 'py' }, 'the file resolved from the index, at the block')
    T.ok(notices[#notices].msg:find('in search.json: 1 result', 1, true), notices[#notices].msg)
  end) },

  { ':LuccetCheck on a clean note says so', scoped(function(T, notices)
    local path = note(T, '# Kernel\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('LuccetCheck')
    T.wait(10000, function()
      return #notices > 0
    end, 'the report')
    T.eq(notices[1].msg, 'luccet check: no problems', 'message')
  end) },

  { ':LuccetCheck shows a usage error', scoped(function(T, notices)
    local path = note(T, '# Kernel\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('LuccetCheck ' .. vim.fs.dirname(path) .. '/missing.html')
    T.wait(10000, function()
      return #notices > 0
    end, 'the report')
    T.eq(notices[1].level, vim.log.levels.ERROR, 'an error')
    T.ok(notices[1].msg:find('exit 2', 1, true) and notices[1].msg:find('missing.html: no such file', 1, true), notices[1].msg)
  end) },

  { ':LuccetBuild writes NAME.built.html beside the note', scoped(function(T, notices)
    local path, dir = note(T, '# Kernel\n\n$$\nx\n$$\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('LuccetBuild')
    T.wait(10000, function()
      return #notices > 0
    end, 'the report')
    local out = dir .. '/note.built.html'
    T.ok(vim.uv.fs_stat(out), 'the page')
    T.ok(notices[1].msg:find('note.built.html; 1 formula', 1, true), notices[1].msg)
    T.eq(notices[1].level, vim.log.levels.INFO, 'no warnings')
    local f = assert(io.open(out))
    local html = f:read('a')
    f:close()
    T.ok(html:find('data-built', 1, true), 'a built page')

    vim.cmd('LuccetBuild ' .. dir .. '/dist/')
    T.wait(10000, function()
      return #notices > 1
    end, 'the second report')
    T.ok(vim.uv.fs_stat(dir .. '/dist/note.html'), 'into a directory')
    T.eq(notices[2].level, vim.log.levels.WARN, 'warns that relative URLs moved')
  end) },

  { ':LuccetMove refuses, and moves nothing, when it cannot fix the links', scoped(function(T, notices)
    local dir = vim.fs.normalize(T.tmpdir())
    local a = T.write(dir .. '/notes/a.html', FIRST:format('../luccet.js') .. '\n# A\n')
    local b = T.write(dir .. '/notes/b.html', FIRST:format('../luccet.js') .. '\n# B\n')
    local function last()
      return notices[#notices].msg
    end
    vim.cmd.enew()
    vim.cmd('LuccetMove ' .. dir .. '/x.html')
    T.eq(last(), 'luccet: this buffer has no file to move', 'an unnamed buffer')
    vim.cmd.edit(dir .. '/notes/new.html')
    vim.cmd('LuccetMove ' .. dir .. '/x.html')
    T.ok(last():find('new.html does not exist; write it first', 1, true), last())
    vim.cmd.edit(a)
    vim.cmd('LuccetMove one two three')
    T.eq(last(), 'luccet: :LuccetMove [FROM] TO', 'three arguments')
    vim.cmd('LuccetMove ' .. b)
    T.ok(last():find('b.html exists; move or remove it first', 1, true), last())
    vim.cmd('LuccetMove ' .. a)
    T.ok(last():find('a.html is already there', 1, true), last())
    vim.cmd(('LuccetMove %s/notes %s/notes/old'):format(dir, dir))
    T.ok(last():find('cannot move .*notes into itself'), last())
    vim.cmd('LuccetMove ' .. dir .. '/c.html')
    T.ok(last():find('needs the language server, and none is running for', 1, true), last())
    for _, n in ipairs(notices) do
      T.eq(n.level, vim.log.levels.ERROR, n.msg)
    end
    T.ok(vim.uv.fs_stat(a) and vim.uv.fs_stat(b) and not vim.uv.fs_stat(dir .. '/c.html'), 'nothing moved')
    T.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), a, 'the buffer keeps its name')
  end) },
}
