-- SPDX-License-Identifier: MIT
-- The client of `tern lsp`, one server per root: the nearest directory
-- holding tern-cli.js or tern.js, else the note's own directory.
--   start(buf)      start the server for the buffer, or attach it to its root's
--   outline(buf)    the last tern/outline params for the buffer, or nil. Every
--                   line/endLine is a 1-based file line, every col/end a
--                   1-based UTF-16 column
--   client(buf)     the tern client attached to the buffer, or nil
--   lexical(buf)    fold by headings, without a server
--   foldexpr(lnum)  the 'foldexpr' of lexical()
--   serverfold(lnum) the 'foldexpr' with a server: its folds, and the head's
--   folding(win)    whether the window folds a note this way
-- After each outline it fires User TernOutline with data = {buf = buf}.
-- When no server can start it says why once a session, folds by headings and
-- goes on. A server that crashes is restarted once.
local M = {}

local group = vim.api.nvim_create_augroup('tern.lsp', { clear = true })
local outlines = {} -- buf -> tern/outline params
local fold_mode = {} -- buf -> 'lsp' | 'lexical'
local fold_cache = {} -- buf -> {tick, levels}
local restarted = {} -- root -> vim.uv.now() of its last restart
local notified = false

-- A second crash within this many ms of a restart is not restarted.
M.restart_window = 60000

local EXPR = {
  lsp = "v:lua.require'tern.lsp'.serverfold(v:lnum)",
  lexical = "v:lua.require'tern.lsp'.foldexpr(v:lnum)",
}
local FOLDTEXT = "v:lua.require'tern.head'.foldtext()"

local function notify(msg, level)
  vim.notify('tern.nvim: ' .. msg, level or vim.log.levels.WARN)
end

function M.client(buf)
  return vim.lsp.get_clients({ bufnr = buf == 0 and vim.api.nvim_get_current_buf() or buf, name = 'tern' })[1]
end

function M.outline(buf)
  return outlines[buf == 0 and vim.api.nvim_get_current_buf() or buf]
end

local function root_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return vim.fn.getcwd()
  end
  return vim.fs.root(buf, function(n)
    return n == 'tern-cli.js' or n == 'tern.js'
  end) or vim.fs.dirname(vim.fs.normalize(name))
end

-- ---------------------------------------------------------------- folding

-- The head's fold: its lines, up to the tern.js line, are a fold of their
-- own, inside one more of the same lines. tern.render closes the inner fold;
-- the outer one stays open, so that the folds after it, which take the state
-- of the fold before them when they appear, are not closed with it.
local function head(lnum)
  return lnum == 1 and '>2' or 2
end

-- Fold levels by heading, outside fences, after the head's fold.
local function levels(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start = require('tern.head').lines(buf) or 0
  local out, depth = {}, 0
  local fence, fence_len
  for i, l in ipairs(lines) do
    if i <= start then
      out[i] = head(i)
    else
      if fence then
        local f = l:match('^%s*([`~]+)%s*$')
        if f and #f >= fence_len and f == fence:rep(#f) then
          fence = nil
        end
      else
        local f = l:match('^%s*(```+)') or l:match('^%s*(~~~+)')
        local h = l:match('^%s*(#+)%s') or l:match('^%s*(#+)$')
        if f then
          fence, fence_len = f:sub(1, 1), #f
        elseif h and #h <= 6 then
          depth = #h
          out[i] = '>' .. depth
        end
      end
    end
    out[i] = out[i] or depth
  end
  return out
end

function M.foldexpr(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = fold_cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, levels = levels(buf) }
    fold_cache[buf] = c
  end
  return c.levels[lnum or vim.v.lnum] or 0
end

function M.serverfold(lnum)
  lnum = lnum or vim.v.lnum
  local start = require('tern.head').lines(0)
  if start and lnum <= start then
    return head(lnum)
  end
  return vim.lsp.foldexpr(lnum)
end

function M.folding(win)
  local wo = vim.wo[win]
  return wo.foldmethod == 'expr' and (wo.foldexpr == EXPR.lsp or wo.foldexpr == EXPR.lexical)
end

-- Window-local, as :setlocal, so other buffers in the window keep their own.
-- A window already folding this way keeps its foldlevel.
local function apply_folds(win, buf)
  local mode = fold_mode[buf]
  if not mode or not require('tern.config').options.fold or vim.bo[buf].filetype ~= 'tern' then
    return
  end
  local wo = vim.wo[win][0]
  if wo.foldmethod == 'expr' and wo.foldexpr == EXPR[mode] then
    return
  end
  wo.foldmethod = 'expr'
  wo.foldexpr = EXPR[mode]
  wo.foldlevel = 99
  wo.foldtext = FOLDTEXT
  wo.foldminlines = 0 -- a one-line head folds too
  -- Spaces, not dots, after a closed fold's text, unless 'fillchars' says.
  local fill = vim.wo[win].fillchars
  if not fill:find('fold:') then
    wo.fillchars = (fill == '' and '' or fill .. ',') .. 'fold: '
  end
end

local function set_folds(buf, mode)
  fold_mode[buf] = mode
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    apply_folds(win, buf)
  end
end

local function track(buf)
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function(a)
      apply_folds(vim.api.nvim_get_current_win(), a.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufUnload', {
    group = group,
    buffer = buf,
    callback = function(a)
      outlines[a.buf], fold_mode[a.buf], fold_cache[a.buf] = nil, nil, nil
    end,
  })
end

function M.lexical(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  track(buf)
  set_folds(buf, 'lexical')
end

-- ---------------------------------------------------------------- the server

-- The buffer an outline is for: one the client is attached to, never a new one.
local function buf_of(uri, client_id)
  local c = vim.lsp.get_client_by_id(client_id)
  for b in pairs(c and c.attached_buffers or {}) do
    if vim.uri_from_bufnr(b) == uri then
      return b
    end
  end
end

local function on_outline(_, params, ctx)
  local buf = type(params) == 'table' and type(params.uri) == 'string' and buf_of(params.uri, ctx.client_id)
  if not buf then
    return
  end
  outlines[buf] = params
  vim.api.nvim_exec_autocmds('User', { pattern = 'TernOutline', data = { buf = buf }, modeline = false })
end

local function reuse(client, config)
  return client.name == config.name and client.root_dir == config.root_dir and not client:is_stopped()
end

local crashed, fallback

local function shown(cmd)
  return type(cmd) == 'table' and table.concat(cmd, ' ') or 'cmd'
end

local function launch(buf)
  local info, reason = require('tern.cli').find(buf)
  if not info then
    return nil, reason
  end
  local root = root_of(buf)
  -- The server asks a client that can watch files to (an add-on edited on
  -- disk is then seen at once); Neovim can, when asked to.
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  if require('tern.config').options.watch then
    capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = true, relativePatternSupport = true }
  end
  local ok, id = pcall(vim.lsp.start, {
    name = 'tern',
    cmd = info.lsp,
    root_dir = root,
    capabilities = capabilities,
    handlers = { ['tern/outline'] = on_outline },
    on_exit = function(code, signal, client_id)
      local c = vim.lsp.get_client_by_id(client_id)
      -- A stop Neovim asked for (client:stop) exits 0 or by SIGTERM.
      if (c and c._is_stopping) or (code == 0 and (signal == 0 or signal == 15)) then
        return
      end
      local bufs = c and vim.tbl_keys(c.attached_buffers) or {}
      local early = not (c and c.initialized)
      vim.schedule(function()
        bufs = vim.tbl_filter(function(b)
          return vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == 'tern'
        end, bufs)
        if not early then
          return crashed(root, bufs, code, signal)
        end
        -- Not a crash: the command does not run a language server.
        local reason = ('`%s` exited before it started (exit code %d); run it in a terminal to see why'):format(shown(info.lsp), code)
        for _, b in ipairs(bufs) do
          fallback(b, reason)
        end
      end)
    end,
  }, { bufnr = buf, reuse_client = reuse, silent = true })
  if not ok then
    return nil, tostring(id)
  end
  if not id then
    return nil, ('`%s` did not start'):format(shown(info.lsp))
  end
  return id
end

fallback = function(buf, reason)
  if not notified then
    notified = true
    notify(('the language server cannot start: %s. Notes fold by headings only, without diagnostics or completion (:checkhealth tern).'):format(reason))
  end
  M.lexical(buf)
end

crashed = function(root, bufs, code, signal)
  local last = restarted[root]
  if last and vim.uv.now() - last < M.restart_window then
    notify(('tern lsp stopped again (exit code %d, signal %d); it is not restarted. Notes fold by headings; :edit a note to try again.'):format(code, signal))
    for _, b in ipairs(bufs) do
      M.lexical(b)
    end
    return
  end
  restarted[root] = vim.uv.now()
  for _, b in ipairs(bufs) do
    M.start(b)
  end
end

function M.start(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  track(buf)
  local id, reason = launch(buf)
  if not id then
    return fallback(buf, reason)
  end
  set_folds(buf, 'lsp')
  return id
end

-- For tests: forget the session's notice and restarts.
function M._reset()
  notified = false
  restarted = {}
end

return M
