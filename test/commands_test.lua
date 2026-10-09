-- SPDX-License-Identifier: MIT
-- :TernInit, :TernCheck and :TernBuild. The language server is off here
-- (lsp = false); :TernCheck and :TernBuild run the real CLI, found next to a
-- link to the Tern checkout's tern.js.
local FIRST = '<!doctype html><meta charset="utf-8"><script src="%s"></script>'

-- Runs fn(T, notices) with the server off, $TERN_CLI unset and vim.notify
-- captured; restores all three.
local function scoped(fn)
  return function(T)
    local env, notify = vim.env.TERN_CLI, vim.notify
    local notices = {}
    vim.env.TERN_CLI = nil
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
    require('tern').setup({ lsp = false })
    local ok, err = pcall(fn, T, notices)
    vim.env.TERN_CLI, vim.notify = env, notify
    require('tern').setup()
    if not ok then
      error(err, 0)
    end
  end
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- A note beside a link to tern.js; nil without a Tern checkout.
local function note(T, text)
  local root = T.tern_root()
  if not root then
    print('    (skipped: no Tern checkout; set $TERN_ROOT)')
    return nil
  end
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p')) -- for the link
  local dir = T.tmpdir()
  assert(vim.uv.fs_symlink(root .. '/tern.js', dir .. '/tern.js'))
  return T.write(dir .. '/note.html', FIRST:format('tern.js') .. '\n' .. text), dir
end

return {
  { ':TernInit refuses an unnamed buffer at once', scoped(function(T, notices)
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '# Hi' })
    local t = vim.uv.hrtime()
    vim.cmd('TernInit')
    T.ok((vim.uv.hrtime() - t) / 1e6 < 200, 'quick')
    T.eq(lines(), { '# Hi' }, 'unchanged')
    T.ok(notices[1] and notices[1].msg:find('save it first', 1, true), vim.inspect(notices))
  end) },

  { ':TernInit writes the line with the nearest tern.js, in one undo step', scoped(function(T, notices)
    local dir = T.tmpdir()
    T.write(dir .. '/tern.js', '')
    vim.cmd.edit(T.write(dir .. '/notes/deep/kernel.html', '# Kernel\n'))
    T.eq(vim.bo.filetype, 'html', 'not a note yet')
    vim.cmd('TernInit')
    T.eq(lines(), { FIRST:format('../../tern.js'), '# Kernel' }, 'lines')
    T.eq(vim.bo.filetype, 'tern', 'filetype')
    T.ok(notices[1].msg:find('../../tern.js', 1, true), notices[1].msg)
    vim.cmd('silent undo')
    T.eq(lines(), { '# Kernel' }, 'after one undo')
  end) },

  { ':TernInit on an empty buffer leaves the cursor on the note', scoped(function(T)
    local dir = T.tmpdir()
    vim.cmd.edit(dir .. '/new.html')
    vim.cmd('TernInit')
    T.eq(lines(), { FIRST:format('tern.js'), '' }, 'no tern.js above: tern.js beside the note')
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 }, 'cursor')
  end) },

  { ':TernInit PATH: a file made relative, anything else as given', scoped(function(T, notices)
    local dir = T.tmpdir()
    local lib = T.write(dir .. '/lib/tern.js', '')
    vim.cmd.edit(dir .. '/notes/a.html')
    vim.cmd('TernInit ' .. lib)
    T.eq(lines()[1], FIRST:format('../lib/tern.js'), 'a file')
    vim.cmd.edit(dir .. '/notes/b.html')
    vim.cmd('TernInit ' .. dir .. '/lib')
    T.eq(lines()[1], FIRST:format('../lib/tern.js'), 'a directory holding tern.js')
    vim.cmd.edit(dir .. '/notes/c.html')
    vim.cmd('TernInit https://cdn.example/tern/tern.js')
    T.eq(lines()[1], FIRST:format('https://cdn.example/tern/tern.js'), 'a URL')
    vim.cmd.edit(dir .. '/notes/d.html')
    vim.cmd('TernInit lib/tern.min.js')
    T.eq(lines(), { '' }, 'tern.min.js is refused')
    T.ok(notices[#notices].msg:find('called tern.js', 1, true), notices[#notices].msg)
  end) },

  { ':TernInit refuses a note and a non-modifiable buffer', scoped(function(T, notices)
    local dir = T.tmpdir()
    local text = { FIRST:format('tern.js'), '# Hi' }
    vim.cmd.edit(T.write(dir .. '/note.html', table.concat(text, '\n') .. '\n'))
    vim.cmd('TernInit')
    T.eq(lines(), text, 'a note is unchanged')
    T.ok(notices[1].msg:find('already a note', 1, true), notices[1].msg)
    vim.cmd.edit(T.write(dir .. '/locked.html', '# Hi\n'))
    vim.bo.modifiable = false
    vim.cmd('TernInit')
    T.eq(lines(), { '# Hi' }, 'a non-modifiable buffer is unchanged')
    T.ok(notices[2].msg:find('not modifiable', 1, true), notices[2].msg)
  end) },

  { ':TernCheck fills the quickfix list', scoped(function(T, notices)
    local path = note(T, '# Kernel\n\nSee @nowhere.\n\n:::aside\nopen\n')
    if not path then
      return
    end
    vim.fn.setqflist({}, 'f')
    vim.cmd.edit(path)
    vim.cmd('TernCheck')
    T.wait(10000, function()
      return #vim.fn.getqflist() > 0
    end, 'the quickfix list')
    local qf = vim.fn.getqflist()
    T.eq(#qf, 2, 'entries')
    local w = qf[1]
    T.eq({ vim.api.nvim_buf_get_name(w.bufnr), w.lnum, w.col, w.type }, { path, 4, 5, 'W' }, 'the warning')
    T.ok(w.text:find('^ref%.dangling: no id'), w.text)
    T.eq({ qf[2].lnum, qf[2].type, qf[2].text:match('^[%w.]+') }, { 6, 'E', 'block.unclosed' }, 'the error')
    T.ok(vim.fn.getqflist({ title = 0 }).title:find('^tern check'), 'title')
    T.ok(vim.fn.getqflist({ winid = 0 }).winid ~= 0, 'the list is open')
    T.ok(notices[#notices].msg:find('1 error, 1 warning', 1, true), notices[#notices].msg)
  end) },

  { ':TernCheck on a clean note says so', scoped(function(T, notices)
    local path = note(T, '# Kernel\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('TernCheck')
    T.wait(10000, function()
      return #notices > 0
    end, 'the report')
    T.eq(notices[1].msg, 'tern check: no problems', 'message')
  end) },

  { ':TernCheck shows a usage error', scoped(function(T, notices)
    local path = note(T, '# Kernel\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('TernCheck ' .. vim.fs.dirname(path) .. '/missing.html')
    T.wait(10000, function()
      return #notices > 0
    end, 'the report')
    T.eq(notices[1].level, vim.log.levels.ERROR, 'an error')
    T.ok(notices[1].msg:find('exit 2', 1, true) and notices[1].msg:find('missing.html: no such file', 1, true), notices[1].msg)
  end) },

  { ':TernBuild writes NAME.built.html beside the note', scoped(function(T, notices)
    local path, dir = note(T, '# Kernel\n\n$$\nx\n$$\n')
    if not path then
      return
    end
    vim.cmd.edit(path)
    vim.cmd('TernBuild')
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

    vim.cmd('TernBuild ' .. dir .. '/dist/')
    T.wait(10000, function()
      return #notices > 1
    end, 'the second report')
    T.ok(vim.uv.fs_stat(dir .. '/dist/note.html'), 'into a directory')
    T.eq(notices[2].level, vim.log.levels.WARN, 'warns that relative URLs moved')
  end) },
}
