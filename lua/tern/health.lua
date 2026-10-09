-- SPDX-License-Identifier: MIT
-- :checkhealth tern: Neovim, node, the command line the buffer would use,
-- the language server, the buffer's detection and the options. The buffer
-- is the one :checkhealth was run from, else the current directory's.
local M = {}

local h = vim.health

-- The buffer :checkhealth was run from: the health buffer is current by now.
local function target()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == 'checkhealth' or vim.api.nvim_buf_get_name(buf):match('^health://') then
    buf = vim.fn.bufnr('#')
  end
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' then
    return buf
  end
end

function M.check()
  local cli = require('tern.cli')
  local buf = target()
  local name = buf and vim.api.nvim_buf_get_name(buf) or ''
  local where = name ~= '' and vim.fn.fnamemodify(name, ':~:.') or 'the current directory'

  h.start('Neovim')
  local v = vim.version()
  local version = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
  if vim.fn.has('nvim-0.11') == 1 then
    h.ok('Neovim ' .. version)
  else
    h.error('Neovim ' .. version .. ': tern.nvim needs 0.11 or later')
  end

  h.start('Node')
  local n = cli.node()
  if n.ok then
    h.ok(('node %s (%s)'):format(n.version, n.path))
  else
    h.error(n.reason, { 'Install Node ' .. cli.min_node .. ' or later, and make sure `node` is on PATH' })
  end

  h.start('Command line')
  if vim.env.TERN_CLI and vim.env.TERN_CLI ~= '' then
    h.info('$TERN_CLI is ' .. vim.env.TERN_CLI)
  end
  local info, reason = cli.find(buf)
  if info then
    local cmd = type(info.lsp) == 'table' and table.concat(info.lsp, ' ') or '(a function)'
    h.ok(('for %s, found by %s: %s'):format(where, info.how, cmd))
    if not info.cli then
      h.warn('cmd has no `lsp` argument and no other source finds the CLI: :TernCheck and :TernBuild cannot run', { cli.fix })
    end
  else
    h.error(('for %s: %s'):format(where, reason))
  end

  h.start('Language server')
  local o = require('tern.config').options
  if not o.lsp then
    h.info('off (lsp = false in setup())')
  end
  local clients = vim.lsp.get_clients({ name = 'tern' })
  for _, c in ipairs(clients) do
    h.ok(('client %d, root %s, %d buffer(s)%s'):format(c.id, c.root_dir or '(none)', vim.tbl_count(c.attached_buffers), c:is_stopped() and ', stopping' or ''))
  end
  if #clients == 0 then
    h.info('no tern client is running')
  end
  if buf and vim.bo[buf].filetype == 'tern' then
    local c = require('tern.lsp').client(buf)
    if c then
      local outline = require('tern.lsp').outline(buf)
      h.ok(('this buffer is attached to client %d%s'):format(c.id, outline and ', outline received' or ', no outline yet'))
    elseif o.lsp then
      h.warn('this note has no tern client', { 'See the Command line and Node sections above' })
    end
  end

  h.start('This buffer')
  if not buf then
    h.info('no file buffer')
  else
    local d = require('tern.detect').buffer(buf)
    if d then
      h.ok(('%s is a note: line %d loads tern.js with %s'):format(where, d.lnum, d.tag))
    else
      h.info(('%s is not a note: no line loads tern.js'):format(where))
    end
    h.info(("filetype is '%s'"):format(vim.bo[buf].filetype))
  end

  h.start('Options')
  local keys = vim.tbl_keys(o)
  if o.cmd == nil then
    keys[#keys + 1] = 'cmd'
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    h.info(('%s = %s'):format(k, vim.inspect(o[k], { newline = ' ', indent = '' })))
  end
end

return M
