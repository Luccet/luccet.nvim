-- SPDX-License-Identifier: MIT
-- tern.cli: each source of the command, in temporary directories with fake
-- tern-cli.js files. Buffers are made by hand so that no server starts.
local cli = require('tern.cli')

-- Runs fn with environment variables set (false: unset) and setup(opts),
-- restoring both afterwards.
local function scoped(env, opts, fn)
  local saved = {}
  for k, v in pairs(env) do
    saved[k] = vim.env[k] or false
    vim.env[k] = v or nil
  end
  require('tern').setup(opts)
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    vim.env[k] = v or nil
  end
  require('tern').setup()
  if not ok then
    error(err, 0)
  end
end

-- A buffer named path holding text, without filetype detection.
local function buffer(path, text)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or '', '\n'))
  return buf
end

local NOTE = '<!doctype html><meta charset="utf-8"><script src="%s"></script>\n# Hi\n'

-- No Tern above the temporary directories, and no `tern` on PATH but ours.
local function clean(dir)
  return { TERN_CLI = false, PATH = dir .. '/bin:/usr/bin:/bin:' .. vim.fs.dirname(vim.fn.exepath('node')) }
end

local function needs_node(T)
  if not cli.node().ok then
    print('    (skipped: ' .. cli.node().reason .. ')')
    return true
  end
end

return {
  { 'options.cmd is used as given, the CLI being what comes before lsp', function(T)
    local cmd = { vim.v.progpath, '/x/tern-cli.js', 'lsp', '--stdio' }
    scoped({ TERN_CLI = '/nowhere/tern-cli.js' }, { cmd = cmd }, function()
      local info = T.ok(cli.find(buffer(T.tmpdir() .. '/n.html', NOTE:format('tern.js'))))
      T.eq(info.source, 'cmd', 'source')
      T.eq(info.lsp, cmd, 'lsp')
      T.eq(info.cli, { vim.v.progpath, '/x/tern-cli.js' }, 'cli')
    end)
  end },

  { 'options.cmd that cannot run is a reason, not an error', function(T)
    scoped({}, { cmd = { 'tern-no-such-command', 'lsp' } }, function()
      local info, reason = cli.find(buffer(T.tmpdir() .. '/n.html'))
      T.eq(info, nil, 'info')
      T.ok(reason:find('tern-no-such-command', 1, true), reason)
    end)
  end },

  { '$TERN_CLI, before tern-cli.js above the file', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local env = T.write(dir .. '/elsewhere/tern-cli.js', '')
    T.write(dir .. '/proj/tern-cli.js', '')
    local e = clean(dir)
    e.TERN_CLI = env
    scoped(e, nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/proj/n.html', NOTE:format('tern.js'))))
      T.eq(info.source, 'env', 'source')
      T.eq(info.cli, { cli.node().path, env }, 'cli')
      T.eq(info.lsp, { cli.node().path, env, 'lsp' }, 'lsp')
    end)
  end },

  { '$TERN_CLI naming no file is a reason', function(T)
    local dir = T.tmpdir()
    local e = clean(dir)
    e.TERN_CLI = dir .. '/missing/tern-cli.js'
    scoped(e, nil, function()
      local info, reason = cli.find(buffer(dir .. '/n.html'))
      T.eq(info, nil, 'info')
      T.ok(reason:find('$TERN_CLI', 1, true), reason)
    end)
  end },

  { 'tern-cli.js in the directory or above', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = T.write(dir .. '/proj/tern-cli.js', '')
    scoped(clean(dir), nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/proj/a/b/n.html', NOTE:format('tern.js'))))
      T.eq(info.source, 'upward', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
    end)
  end },

  { 'tern-cli.js next to the tern.js the note loads, through a link', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = T.write(dir .. '/checkout/tern-cli.js', '')
    T.write(dir .. '/checkout/tern.js', '')
    scoped(clean(dir), nil, function()
      -- A relative src.
      local info = T.ok(cli.find(buffer(dir .. '/notes/n.html', NOTE:format('../checkout/tern.js?v=2'))))
      T.eq(info.source, 'tern.js', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
      -- tern.js beside the note, a link to the checkout's.
      vim.fn.mkdir(dir .. '/linked', 'p')
      assert(vim.uv.fs_symlink(dir .. '/checkout/tern.js', dir .. '/linked/tern.js'))
      info = T.ok(cli.find(buffer(dir .. '/linked/n.html', NOTE:format('tern.js'))))
      T.eq(info.cli, { cli.node().path, vim.uv.fs_realpath(script) }, 'cli through the link')
      -- A root-relative src, looked for in every directory above.
      info = T.ok(cli.find(buffer(dir .. '/checkout/sub/n.html', NOTE:format('/checkout/tern.js'))))
      T.eq(info.source, 'upward', 'tern-cli.js above comes first')
      info = T.ok(cli.find(buffer(dir .. '/notes/deep/n.html', NOTE:format('/checkout/tern.js'))))
      T.eq(info.source, 'tern.js', 'root-relative')
    end)
  end },

  { 'tern on PATH when it is tern-cli.js or runs it, not another tern', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = vim.uv.fs_realpath(T.write(dir .. '/checkout/tern-cli.js', ''))
    vim.uv.fs_chmod(script, 493) -- 0755, as in a checkout
    vim.fn.mkdir(dir .. '/bin', 'p')
    assert(vim.uv.fs_symlink(script, dir .. '/bin/tern'))
    scoped(clean(dir), nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/notes/n.html', NOTE:format('tern.js'))))
      T.eq(info.source, 'path', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
      T.eq(info.lsp, { cli.node().path, script, 'lsp' }, 'lsp')

      os.remove(dir .. '/bin/tern')
      T.write(dir .. '/bin/tern', '#!/bin/sh\nexec node ' .. script .. ' "$@"\n')
      vim.uv.fs_chmod(dir .. '/bin/tern', 493)
      info = T.ok(cli.find(buffer(dir .. '/notes/m.html')))
      T.eq(info.cli, { dir .. '/bin/tern' }, 'a script that runs tern-cli.js')

      T.write(dir .. '/bin/tern', '#!/bin/sh\necho "an unrelated tern"\n')
      local none, reason = cli.find(buffer(dir .. '/notes/o.html'))
      T.eq(none, nil, 'another tern is skipped')
      T.ok(reason:find('not Tern', 1, true), reason)
    end)
  end },

  { 'nothing found: a reason that says how to fix it', function(T)
    local dir = T.tmpdir()
    scoped(clean(dir), nil, function()
      local info, reason = cli.find(buffer(dir .. '/n.html', NOTE:format('tern.js')))
      T.eq(info, nil, 'info')
      T.ok(reason:find('$TERN_CLI', 1, true) and reason:find('setup', 1, true), reason)
    end)
  end },

  { 'node is checked once and is new enough', function(T)
    if needs_node(T) then
      return
    end
    local n = cli.node()
    T.ok(n == cli.node(), 'cached')
    T.ok(tonumber(n.version:match('^v(%d+)')) >= 22, n.version)
  end },

  { 'run: a subcommand, asynchronously', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    T.write(dir .. '/tern-cli.js', 'console.log(JSON.stringify(process.argv.slice(2)))\n')
    scoped(clean(dir), nil, function()
      local res
      local obj = T.ok(cli.run(buffer(dir .. '/n.html'), { 'check', '--json', 'a b.html' }, function(r)
        res = r
      end))
      T.ok(obj.pid, 'a process')
      T.wait(5000, function()
        return res
      end, 'the command')
      T.eq(res.code, 0, 'exit code')
      T.eq(vim.json.decode(res.stdout), { 'check', '--json', 'a b.html' }, 'arguments')
    end)
  end },
}
