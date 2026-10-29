-- SPDX-License-Identifier: MIT
-- luccet.cli: each source of the command, in temporary directories with fake
-- luccet-cli.js files. Buffers are made by hand so that no server starts.
local cli = require('luccet.cli')

-- Runs fn with environment variables set (false: unset) and setup(opts),
-- restoring both afterwards.
local function scoped(env, opts, fn)
  local saved = {}
  for k, v in pairs(env) do
    saved[k] = vim.env[k] or false
    vim.env[k] = v or nil
  end
  require('luccet').setup(opts)
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    vim.env[k] = v or nil
  end
  require('luccet').setup()
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

-- No Luccet above the temporary directories, and no `luccet` on PATH but ours.
local function clean(dir)
  return { LUCCET_CLI = false, PATH = dir .. '/bin:/usr/bin:/bin:' .. vim.fs.dirname(vim.fn.exepath('node')) }
end

local function needs_node(T)
  if not cli.node().ok then
    print('    (skipped: ' .. cli.node().reason .. ')')
    return true
  end
end

return {
  { 'options.cmd is used as given, the CLI being what comes before lsp', function(T)
    local cmd = { vim.v.progpath, '/x/luccet-cli.js', 'lsp', '--stdio' }
    scoped({ LUCCET_CLI = '/nowhere/luccet-cli.js' }, { cmd = cmd }, function()
      local info = T.ok(cli.find(buffer(T.tmpdir() .. '/n.html', NOTE:format('luccet.js'))))
      T.eq(info.source, 'cmd', 'source')
      T.eq(info.lsp, cmd, 'lsp')
      T.eq(info.cli, { vim.v.progpath, '/x/luccet-cli.js' }, 'cli')
    end)
  end },

  { 'options.cmd that cannot run is a reason, not an error', function(T)
    scoped({}, { cmd = { 'luccet-no-such-command', 'lsp' } }, function()
      local info, reason = cli.find(buffer(T.tmpdir() .. '/n.html'))
      T.eq(info, nil, 'info')
      T.ok(reason:find('luccet-no-such-command', 1, true), reason)
    end)
  end },

  { '$LUCCET_CLI, before luccet-cli.js above the file', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local env = T.write(dir .. '/elsewhere/luccet-cli.js', '')
    T.write(dir .. '/proj/luccet-cli.js', '')
    local e = clean(dir)
    e.LUCCET_CLI = env
    scoped(e, nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/proj/n.html', NOTE:format('luccet.js'))))
      T.eq(info.source, 'env', 'source')
      T.eq(info.cli, { cli.node().path, env }, 'cli')
      T.eq(info.lsp, { cli.node().path, env, 'lsp' }, 'lsp')
    end)
  end },

  { '$LUCCET_CLI naming no file is a reason', function(T)
    local dir = T.tmpdir()
    local e = clean(dir)
    e.LUCCET_CLI = dir .. '/missing/luccet-cli.js'
    scoped(e, nil, function()
      local info, reason = cli.find(buffer(dir .. '/n.html'))
      T.eq(info, nil, 'info')
      T.ok(reason:find('$LUCCET_CLI', 1, true), reason)
    end)
  end },

  { 'luccet-cli.js in the directory or above', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = T.write(dir .. '/proj/luccet-cli.js', '')
    scoped(clean(dir), nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/proj/a/b/n.html', NOTE:format('luccet.js'))))
      T.eq(info.source, 'upward', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
    end)
  end },

  { 'luccet-cli.js next to the luccet.js the note loads, through a link', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = T.write(dir .. '/checkout/luccet-cli.js', '')
    T.write(dir .. '/checkout/luccet.js', '')
    scoped(clean(dir), nil, function()
      -- A relative src.
      local info = T.ok(cli.find(buffer(dir .. '/notes/n.html', NOTE:format('../checkout/luccet.js?v=2'))))
      T.eq(info.source, 'luccet.js', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
      -- luccet.js beside the note, a link to the checkout's.
      vim.fn.mkdir(dir .. '/linked', 'p')
      assert(vim.uv.fs_symlink(dir .. '/checkout/luccet.js', dir .. '/linked/luccet.js'))
      info = T.ok(cli.find(buffer(dir .. '/linked/n.html', NOTE:format('luccet.js'))))
      T.eq(info.cli, { cli.node().path, vim.uv.fs_realpath(script) }, 'cli through the link')
      -- A root-relative src, looked for in every directory above.
      info = T.ok(cli.find(buffer(dir .. '/checkout/sub/n.html', NOTE:format('/checkout/luccet.js'))))
      T.eq(info.source, 'upward', 'luccet-cli.js above comes first')
      info = T.ok(cli.find(buffer(dir .. '/notes/deep/n.html', NOTE:format('/checkout/luccet.js'))))
      T.eq(info.source, 'luccet.js', 'root-relative')
    end)
  end },

  { 'luccet on PATH when it is luccet-cli.js or runs it, not another luccet', function(T)
    if needs_node(T) then
      return
    end
    local dir = T.tmpdir()
    local script = vim.uv.fs_realpath(T.write(dir .. '/checkout/luccet-cli.js', ''))
    vim.uv.fs_chmod(script, 493) -- 0755, as in a checkout
    vim.fn.mkdir(dir .. '/bin', 'p')
    assert(vim.uv.fs_symlink(script, dir .. '/bin/luccet'))
    scoped(clean(dir), nil, function()
      local info = T.ok(cli.find(buffer(dir .. '/notes/n.html', NOTE:format('luccet.js'))))
      T.eq(info.source, 'path', 'source')
      T.eq(info.cli, { cli.node().path, script }, 'cli')
      T.eq(info.lsp, { cli.node().path, script, 'lsp' }, 'lsp')

      os.remove(dir .. '/bin/luccet')
      T.write(dir .. '/bin/luccet', '#!/bin/sh\nexec node ' .. script .. ' "$@"\n')
      vim.uv.fs_chmod(dir .. '/bin/luccet', 493)
      info = T.ok(cli.find(buffer(dir .. '/notes/m.html')))
      T.eq(info.cli, { dir .. '/bin/luccet' }, 'a script that runs luccet-cli.js')

      T.write(dir .. '/bin/luccet', '#!/bin/sh\necho "an unrelated luccet"\n')
      local none, reason = cli.find(buffer(dir .. '/notes/o.html'))
      T.eq(none, nil, 'another luccet is skipped')
      T.ok(reason:find('not Luccet', 1, true), reason)
    end)
  end },

  { 'nothing found: a reason that says how to fix it', function(T)
    local dir = T.tmpdir()
    scoped(clean(dir), nil, function()
      local info, reason = cli.find(buffer(dir .. '/n.html', NOTE:format('luccet.js')))
      T.eq(info, nil, 'info')
      T.ok(reason:find('$LUCCET_CLI', 1, true) and reason:find('setup', 1, true), reason)
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
    T.write(dir .. '/luccet-cli.js', 'console.log(JSON.stringify(process.argv.slice(2)))\n')
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
