-- SPDX-License-Identifier: MIT
-- tern.lsp against the real server: a note in a temporary directory beside a
-- link to the Tern checkout's tern.js, so tern.cli finds tern-cli.js next to it.
local lsp = require('tern.lsp')

local NOTE = [[
<!doctype html><meta charset="utf-8"><script src="tern.js" data-use="theorems.js"></script>
# Kernel {#kernel}

See @kernel, @rn and @nowhere.

:::theorem[Rank–nullity]{#rn}
Every linear map has a kernel.

$$
\dim V = r + n
$$
:::/theorem

Again @kernel and [the kernel](#kernel).

## Image

```js
# not a heading
```

:::aside
never closed
]]

local THEOREMS = "tern.block('theorem', { tag: 'section', counter: 'theorem', label: 'Theorem' });\n"

-- Lets the answers in flight land. Neovim 0.11 asserts when a folding range
-- arrives for a buffer that was unloaded meanwhile.
local function settle()
  vim.wait(2000, function()
    return vim.iter(vim.lsp.get_clients({ name = 'tern' })):all(function(c)
      return next(c.requests) == nil
    end)
  end, 10)
  vim.wait(20)
end

-- Runs fn(T) with $TERN_CLI unset and the default options.
local function clean(fn)
  return function(T)
    local env = vim.env.TERN_CLI
    vim.env.TERN_CLI = nil
    require('tern').setup()
    lsp._reset()
    local ok, err = pcall(fn, T)
    settle()
    vim.env.TERN_CLI = env
    require('tern').setup()
    lsp._reset()
    if not ok then
      error(err, 0)
    end
  end
end

-- Writes the note beside a link to tern.js; nil without a Tern checkout.
local function files(T, text)
  local root = T.tern_root()
  if not root then
    print('    (skipped: no Tern checkout; set $TERN_ROOT)')
    return nil
  end
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p')) -- for the link
  local dir = T.tmpdir()
  assert(vim.uv.fs_symlink(root .. '/tern.js', dir .. '/tern.js'))
  T.write(dir .. '/theorems.js', THEOREMS)
  return T.write(dir .. '/note.html', text or NOTE), root
end

-- Opens the note and waits for its client and first outline.
local function open(T, text)
  local path, root = files(T, text)
  if not path then
    return nil
  end
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  T.wait(5000, function()
    return lsp.client(buf) and lsp.outline(buf)
  end, 'the client and the outline')
  return buf, path, root
end

local function request(buf, method, params)
  params.textDocument = { uri = vim.uri_from_bufnr(buf) }
  local id = lsp.client(buf).id
  local res = vim.lsp.buf_request_sync(buf, method, params, 5000) or {}
  assert(res[id], method .. ': no answer')
  assert(not res[id].err, method .. ': ' .. vim.inspect(res[id].err))
  return res[id].result
end

local function at(line, character)
  return { position = { line = line, character = character } }
end

-- The 0-based byte column of text in a buffer line.
local function col_of(buf, lnum, text)
  return (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, true)[1]:find(text, 1, true)) - 1
end

return {
  { 'the client attaches; its diagnostics are those of tern check', clean(function(T)
    local buf, path, root = open(T)
    if not buf then
      return
    end
    local c = lsp.client(buf)
    T.eq(c.name, 'tern', 'name')
    T.eq(c.root_dir, vim.fs.dirname(path), 'root: the directory holding tern.js')

    local res = vim.system({ require('tern.cli').node().path, root .. '/tern-cli.js', 'check', '--json', path }, { text = true }):wait(10000)
    local want = {}
    for _, d in ipairs(vim.json.decode(res.stdout)) do
      local s, e = d.filePosition.start, d.filePosition['end']
      want[#want + 1] = { d.code, s.line - 1, s.column - 1, e.line - 1, e.column - 1 }
    end
    T.ok(#want >= 2, 'tern check finds the dangling reference and the unclosed aside')
    T.wait(5000, function()
      return #vim.diagnostic.get(buf) == #want
    end, 'the diagnostics')
    local got = {}
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      got[#got + 1] = { d.code, d.lnum, d.col, d.end_lnum, d.end_col }
    end
    table.sort(got, function(a, b)
      return a[2] < b[2]
    end)
    T.eq(got, want, 'diagnostics by code and position')
  end) },

  { 'tern/outline arrives and fires User TernOutline', clean(function(T)
    local fired = {}
    local au = vim.api.nvim_create_autocmd('User', {
      pattern = 'TernOutline',
      callback = function(a)
        fired[#fired + 1] = a.data
      end,
    })
    local ok, err = pcall(function()
      local buf = open(T)
      if not buf then
        return
      end
      T.wait(2000, function()
        return #fired > 0
      end, 'User TernOutline')
      T.eq(fired[1], { buf = buf }, 'data')
      local o = lsp.outline(buf)
      T.eq(o.uri, vim.uri_from_bufnr(buf), 'uri')
      T.eq(o.headings[1], { line = 2, depth = 1, id = 'kernel', text = 'Kernel' }, 'a heading, at its file line')
      local thm = o.blocks[1]
      T.eq({ thm.name, thm.line, thm.endLine, thm.label, thm.title }, { 'theorem', 6, 12, 'Theorem 1', 'Rank–nullity' }, 'the theorem')
      T.eq(o.refs[1], { line = 4, col = 5, ['end'] = 12, id = 'kernel', text = 'Kernel', resolved = true }, 'a reference')
    end)
    vim.api.nvim_del_autocmd(au)
    assert(ok, err)
  end) },

  { 'folds come from the server', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    T.eq(vim.wo.foldmethod, 'expr', 'foldmethod')
    T.eq(vim.wo.foldexpr, "v:lua.require'tern.lsp'.serverfold(v:lnum)", 'foldexpr')
    T.eq(vim.wo.foldtext, "v:lua.require'tern.head'.foldtext()", 'foldtext')
    T.eq(vim.wo.foldminlines, 0, 'a one-line head can close')
    T.ok(vim.wo.fillchars:find('fold: ', 1, true), 'no dots after a closed fold: ' .. vim.wo.fillchars)
    T.ok(vim.wo.foldlevel >= 20, 'nothing starts folded')
    T.wait(5000, function()
      return vim.fn.foldlevel(10) == 3
    end, 'the folds')
    -- The theorem (lines 6-12) inside Kernel's section, the math inside it.
    T.eq(vim.lsp.foldexpr(6), '>2', 'the theorem opens a fold')
    T.eq({ vim.fn.foldlevel(2), vim.fn.foldlevel(7), vim.fn.foldlevel(12), vim.fn.foldlevel(14) }, { 1, 2, 2, 1 }, 'levels')
    T.eq(vim.fn.foldclosed(7), -1, 'open')
    T.eq(require('tern.lsp').serverfold(1), '>2', 'the head, line 1, is a fold of its own')
    T.eq(require('tern.lsp').serverfold(2), vim.lsp.foldexpr(2), 'the server folds the rest')
  end) },

  { 'completion offers a name after :::', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    vim.api.nvim_buf_set_lines(buf, 14, 15, true, { ':::' })
    local items = request(buf, 'textDocument/completion', at(14, 3))
    items = items.items or items
    local labels = {}
    for _, it in ipairs(items) do
      labels[it.label] = it.detail or ''
    end
    T.ok(labels.theorem and labels.theorem:find('schema', 1, true), 'theorem, from the add-on')
    T.ok(labels.aside, 'aside, an HTML element')
  end) },

  { 'definition from @id lands on the id', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    vim.api.nvim_win_set_cursor(0, { 4, col_of(buf, 4, '@rn') + 1 })
    vim.lsp.buf.definition()
    local want = { 6, col_of(buf, 6, '#rn') }
    T.wait(5000, function()
      return vim.deep_equal(vim.api.nvim_win_get_cursor(0), want)
    end, 'the cursor on #rn, at ' .. vim.inspect(want))
  end) },

  { 'rename of an id edits each reference the engine finds', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    local pos = at(3, col_of(buf, 4, '@kernel') + 1)
    local refs = request(buf, 'textDocument/references', vim.tbl_extend('force', pos, { context = { includeDeclaration = true } }))
    T.eq(#refs, 4, 'the declaration, two @kernel and a link')
    local edits = request(buf, 'textDocument/rename', vim.tbl_extend('force', pos, { newName = 'core' })).changes[vim.uri_from_bufnr(buf)]
    T.eq(#edits, #refs, 'one edit per reference')
    for i, e in ipairs(edits) do
      local r = refs[i].range
      T.ok(e.range.start.line == r.start.line and e.range.start.character >= r.start.character and e.range['end'].character <= r['end'].character, 'edit ' .. i .. ' inside reference ' .. i)
    end

    vim.api.nvim_win_set_cursor(0, { 4, pos.position.character })
    vim.lsp.buf.rename('core')
    T.wait(5000, function()
      return vim.api.nvim_buf_get_lines(buf, 1, 2, true)[1] == '# Kernel {#core}'
    end, 'the rename applied')
    T.eq(vim.api.nvim_buf_get_lines(buf, 3, 4, true)[1], 'See @core, @rn and @nowhere.', 'line 4')
    T.eq(vim.api.nvim_buf_get_lines(buf, 13, 14, true)[1], 'Again @core and [the kernel](#core).', 'line 14')
    local after = request(buf, 'textDocument/references', vim.tbl_extend('force', pos, { context = { includeDeclaration = true } }))
    T.eq(#after, #refs, 'every reference follows the new id')
  end) },

  { 'hover over a reference shows its label', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    local h = request(buf, 'textDocument/hover', at(3, col_of(buf, 4, '@rn') + 1))
    T.ok(h.contents.value:find('Theorem 1 — Rank–nullity', 1, true), h.contents.value)
  end) },

  { 'notes in one directory share a client; unloading clears the outline', clean(function(T)
    local buf, path = open(T)
    if not buf then
      return
    end
    local other = T.write(vim.fs.dirname(path) .. '/other.html', '<!doctype html><script src="tern.js"></script>\n# Other\n')
    vim.cmd.edit(other)
    local buf2 = vim.api.nvim_get_current_buf()
    T.wait(5000, function()
      return lsp.outline(buf2)
    end, 'the second outline')
    T.eq(lsp.client(buf2).id, lsp.client(buf).id, 'one client')
    settle()
    vim.cmd('bunload ' .. buf2)
    T.eq(lsp.outline(buf2), nil, 'outline after unload')
    T.ok(lsp.outline(buf), 'the other note keeps its outline')
  end) },

  { 'no server: no error, one notice, folds by headings', clean(function(T)
    local dir = T.tmpdir()
    local notices = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg, level }
    end
    require('tern').setup({ cmd = { 'tern-no-such-command', 'lsp' } })
    local ok, err = pcall(function()
      vim.cmd.edit(T.write(dir .. '/a.html', NOTE))
      vim.cmd.edit(T.write(dir .. '/b.html', NOTE))
    end)
    vim.notify = notify
    assert(ok, err)
    T.eq(#notices, 1, 'notices: ' .. vim.inspect(notices))
    T.ok(notices[1][1]:find('tern-no-such-command', 1, true) and notices[1][2] == vim.log.levels.WARN, notices[1][1])
    T.eq(lsp.client(0), nil, 'client')
    T.eq(vim.wo.foldexpr, "v:lua.require'tern.lsp'.foldexpr(v:lnum)", 'foldexpr')
    local levels = {}
    for l = 1, 19 do
      levels[l] = vim.fn.foldlevel(l)
    end
    T.eq(levels, { 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2 }, 'levels: the head, then by headings; # in a fence is no heading')
    T.eq({ lsp.foldexpr(1), lsp.foldexpr(2) }, { '>2', '>1' }, 'the head is a fold of its own, before the first heading')
  end) },

  { 'a command that exits at once is not restarted', clean(function(T)
    local node = require('tern.cli').node()
    if not node.ok then
      print('    (skipped: ' .. node.reason .. ')')
      return
    end
    local notices = {}
    local notify = vim.notify
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    require('tern').setup({ cmd = { node.path, '-e', 'process.exit(2)', 'lsp' } })
    local ok, err = pcall(function()
      vim.cmd.edit(T.write(T.tmpdir() .. '/a.html', NOTE))
      T.wait(5000, function()
        return vim.iter(notices):any(function(m)
          return m:find('exited before it started (exit code 2)', 1, true)
        end)
      end, 'the notice')
    end)
    vim.notify = notify
    assert(ok, err)
    T.eq(lsp.client(0), nil, 'client')
    T.eq(vim.wo.foldexpr, "v:lua.require'tern.lsp'.foldexpr(v:lnum)", 'folds by headings')
  end) },

  { 'a crashed server is restarted once', clean(function(T)
    local buf = open(T)
    if not buf then
      return
    end
    local function kill()
      for _, pid in ipairs(vim.api.nvim_get_proc_children(vim.fn.getpid())) do
        local p = vim.api.nvim_get_proc(pid)
        if p and p.name == 'node' then
          vim.uv.kill(pid, 'sigkill')
        end
      end
    end
    local notices = {}
    local notify = vim.notify
    vim.notify = function(msg)
      notices[#notices + 1] = msg
    end
    local ok, err = pcall(function()
      local first = lsp.client(buf).id
      kill()
      T.wait(5000, function()
        local c = lsp.client(buf)
        return c and c.id ~= first and c.initialized
      end, 'a new client')
      kill()
      T.wait(5000, function()
        return vim.iter(notices):any(function(m)
          return m:find('not restarted', 1, true)
        end)
      end, 'the notice')
    end)
    vim.notify = notify
    assert(ok, err)
    T.eq(lsp.client(buf), nil, 'no client')
    T.eq(vim.wo.foldexpr, "v:lua.require'tern.lsp'.foldexpr(v:lnum)", 'folds by headings')
  end) },
}
