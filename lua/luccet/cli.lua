-- SPDX-License-Identifier: MIT
-- Where the luccet command line is, for a buffer. The sources, in order:
--   1. options.cmd, the language server command, used as given;
--   2. $LUCCET_CLI, the path of luccet-cli.js;
--   3. luccet-cli.js in the buffer's directory or above, else next to the
--      luccet.js the note loads (symbolic links followed, so a note beside a
--      link to a checkout's luccet.js finds that checkout);
--   4. `luccet` on PATH, when it is luccet-cli.js (npm link, ln -s) or a script
--      that runs it. Any other `luccet` is skipped: an unrelated npm package
--      has that name.
-- Node 22 or later is required; each node binary is checked once a session.
--   M.find(buf)  -> info | nil, reason. buf nil: from the current directory.
--     info = {lsp = argv | function, cli = argv | nil, source, how}
--     source: 'cmd' | 'env' | 'upward' | 'luccet.js' | 'path'
--   M.node(exe)  -> {ok, path, version, reason}
--   M.run(buf, args, on_done, opts) -> vim.SystemObj | nil, reason.
--     Runs the CLI with args; on_done(result) runs on the main loop.
local M = {}

M.min_node = 22

M.fix = "set $LUCCET_CLI to the path of luccet-cli.js, put `luccet` on PATH (npm link in a Luccet checkout), or set cmd in require('luccet').setup()"

local function is_file(p)
  local st = p and vim.uv.fs_stat(p)
  return st and st.type == 'file' or false
end

local nodes = {} -- exe -> result of M.node

function M.node(exe)
  exe = exe or 'node'
  if nodes[exe] then
    return nodes[exe]
  end
  local path = vim.fn.exepath(exe)
  local r
  if path == '' then
    r = { ok = false, reason = ('%s is not on PATH; Luccet needs Node %d or later'):format(exe, M.min_node) }
  else
    local ok, res = pcall(function()
      return vim.system({ path, '--version' }, { text = true }):wait(5000)
    end)
    local version = ok and res.code == 0 and vim.trim(res.stdout or '') or nil
    local major = tonumber(version and version:match('^v?(%d+)%.'))
    if not major then
      r = { ok = false, path = path, reason = ('`%s --version` failed; Luccet needs Node %d or later'):format(path, M.min_node) }
    elseif major < M.min_node then
      r = {
        ok = false,
        path = path,
        version = version,
        reason = ('node is %s (%s); Luccet needs Node %d or later'):format(version, path, M.min_node),
      }
    else
      r = { ok = true, path = path, version = version }
    end
  end
  nodes[exe] = r
  return r
end

local function buf_file(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:match('^%a[%w+.-]*://') then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
end

-- The src of a luccet.js tag, without its query or fragment.
local function tag_src(tag)
  local low = tag:lower()
  local from = 1
  while true do
    local _, e = low:find('%ssrc%s*=%s*', from)
    if not e then
      return nil
    end
    local rest = tag:sub(e + 1)
    local v = rest:match('^"([^"]*)"') or rest:match("^'([^']*)'") or rest:match('^([^%s"\'<>]+)')
    v = v and v:gsub('[?#].*$', '')
    if v and (v:lower() == 'luccet.js' or v:lower():sub(-10) == '/luccet.js') then
      return v
    end
    from = e + 1
  end
end

-- luccet-cli.js next to the luccet.js the buffer's note loads.
local function beside_tern_js(buf, dir)
  local d = buf and require('luccet.detect').buffer(buf)
  local src = d and tag_src(d.tag)
  if not src or src:match('^%a[%w+.-]*:') or src:match('^//') then
    return nil
  end
  local candidates = {}
  if src:sub(1, 1) == '/' then
    -- Root-relative: the site root is unknown, so try every ancestor.
    for p in vim.fs.parents(dir .. '/x') do
      candidates[#candidates + 1] = p:gsub('/$', '') .. src
    end
  else
    candidates[1] = vim.fs.normalize(dir .. '/' .. src)
  end
  for _, c in ipairs(candidates) do
    local real = is_file(c) and vim.uv.fs_realpath(c)
    local cli = real and vim.fs.dirname(real) .. '/luccet-cli.js'
    if cli and is_file(cli) then
      return cli
    end
  end
end

-- A `luccet` on PATH that is Luccet's: luccet-cli.js itself, or a script naming it.
local function on_path()
  local exe = vim.fn.exepath('luccet')
  if exe == '' then
    return nil
  end
  local real = vim.uv.fs_realpath(exe)
  if real and vim.fs.basename(real) == 'luccet-cli.js' then
    return real, nil
  end
  local f = io.open(exe, 'rb')
  local head = f and f:read(4096) or ''
  if f then
    f:close()
  end
  if head:find('luccet-cli.js', 1, true) then
    return nil, exe
  end
  return nil, nil, ('the `luccet` on PATH (%s) is not Luccet\'s luccet-cli.js'):format(exe)
end

-- Sources 2 to 4: {cli, source, how} or nil, reason.
local function find_cli(buf)
  local file = buf_file(buf)
  local dir = file and vim.fs.dirname(file) or vim.fn.getcwd()
  local function script(path, source, how)
    local n = M.node()
    if not n.ok then
      return nil, n.reason
    end
    return { cli = { n.path, path }, source = source, how = how, script = path }
  end

  local env = vim.env.LUCCET_CLI
  if env and env ~= '' then
    local p = vim.fs.normalize(vim.fn.fnamemodify(env, ':p'))
    if not is_file(p) then
      return nil, ('$LUCCET_CLI is %s, which is not a file; point it at luccet-cli.js'):format(env)
    end
    return script(p, 'env', '$LUCCET_CLI')
  end

  local up = vim.fs.find('luccet-cli.js', { upward = true, path = dir, type = 'file', limit = 1 })[1]
  if up then
    return script(vim.fs.normalize(up), 'upward', 'luccet-cli.js in ' .. vim.fs.dirname(up))
  end
  local beside = beside_tern_js(buf, dir)
  if beside then
    return script(beside, 'luccet.js', 'luccet-cli.js next to the luccet.js the note loads')
  end

  local real, wrapper, skipped = on_path()
  if real then
    return script(real, 'path', '`luccet` on PATH')
  elseif wrapper then
    local n = M.node()
    if not n.ok then
      return nil, n.reason
    end
    return { cli = { wrapper }, source = 'path', how = '`luccet` on PATH' }
  end
  return nil, (skipped and skipped .. '; ' or 'no luccet-cli.js found: ') .. M.fix
end

function M.find(buf)
  local cmd = require('luccet.config').options.cmd
  if cmd == nil then
    local info, reason = find_cli(buf)
    if not info then
      return nil, reason
    end
    info.lsp = vim.list_extend(vim.list_slice(info.cli), { 'lsp' })
    return info
  end

  local info = { lsp = cmd, source = 'cmd', how = "cmd in require('luccet').setup()" }
  if type(cmd) == 'function' then
    info.cli = (find_cli(buf) or {}).cli
    return info
  end
  if type(cmd) ~= 'table' or type(cmd[1]) ~= 'string' then
    return nil, "cmd in require('luccet').setup() must be a list, such as { 'node', '/path/to/luccet-cli.js', 'lsp' }"
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil, ("%s, the first item of cmd in require('luccet').setup(), is not an executable"):format(cmd[1])
  end
  if vim.fs.basename(cmd[1]):match('^node[%d.]*$') or vim.fs.basename(cmd[1]) == 'nodejs' then
    local n = M.node(cmd[1])
    if not n.ok then
      return nil, n.reason
    end
  end
  -- The CLI is cmd up to its `lsp` argument; without one, the other sources.
  for i, a in ipairs(cmd) do
    if a == 'lsp' and i > 1 then
      info.cli = vim.list_slice(cmd, 1, i - 1)
      break
    end
  end
  info.cli = info.cli or (find_cli(buf) or {}).cli
  return info
end

function M.run(buf, args, on_done, opts)
  local info, reason = M.find(buf)
  if not info then
    return nil, reason
  end
  if not info.cli then
    return nil, 'cmd in setup() has no `lsp` argument, so the command line is unknown; ' .. M.fix
  end
  local argv = vim.list_extend(vim.list_slice(info.cli), args)
  local ok, obj = pcall(vim.system, argv, { text = true, cwd = opts and opts.cwd }, function(res)
    vim.schedule(function()
      on_done(res)
    end)
  end)
  if not ok then
    return nil, tostring(obj)
  end
  return obj
end

return M
