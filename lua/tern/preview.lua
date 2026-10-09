-- SPDX-License-Identifier: MIT
-- :TernPreview serves the current note's project over HTTP from inside
-- Neovim (vim.uv TCP, a minimal HTTP/1.1) and refreshes the browser when a
-- file under it is written.
--   M.start(args)  serve the current buffer's file, print its URL, open a browser
--   M.stop(quiet)  close the server and every connection (also on VimLeavePre)
--   M.info()       {root, url, host, port, clients} of the running server, or nil
--
-- Roots and ports. One server per Neovim, rooted at the note's project (the
-- nearest folder holding tern.js or .git, else the note's folder); a file's
-- URL is its path under the root. :TernPreview on a file inside the running
-- root reuses the server. On a file outside it, the server moves to that
-- file's root: with preview.port 0 it keeps its port when it can, so pages
-- of the old root reload into a 404 instead of retrying forever.
--
-- Security. GET and HEAD only. The Host header must be HOST:PORT,
-- localhost:PORT or 127.0.0.1:PORT (against DNS rebinding). A request from
-- another site's page (Sec-Fetch-Site) is refused unless it navigates, and
-- every response is no-store, nosniff and Cross-Origin-Resource-Policy
-- same-origin, so other pages cannot embed the files. The request head is
-- capped in size and time, and connections in number. A path must resolve
-- (realpath) inside the root, so neither .. nor a symlink leaves it; no
-- file or folder whose name starts with a dot is served, nor anything but
-- regular files (a FIFO would hang a read); no directory listings.
--
-- Live reload. A served note (an .html that tern.detect calls one) gets
-- data-diagnostics on its tern.js tag, and <script src="/__tern/live.js">
-- just before that tag, on the same line. tern.js takes everything after
-- its line as the note (<plaintext>), so nothing can go after it; on the
-- line, a tag without line breaks keeps every file line where it was, and
-- the runtime counts the same lines before the note, so the diagnostics
-- panel's file lines stay right. The script listens on /__tern/events
-- (Server-Sent Events); see LIVE for what it does with each write.
local uv = vim.uv
local bit = require('bit')
local config = require('tern.config')
-- Required here: request handlers run in luv callbacks, where a first
-- require would search the runtimepath through the API.
local detect = require('tern.detect')

local M = {}

-- Limits, exposed for the tests as M._limits.
local LIMITS = {
  head_bytes = 8192, -- the request line and headers
  head_ms = 5000, -- to receive them
  conns = 64, -- open connections, event streams included
  linger_ms = 1000, -- after a response, for the client to close first
  note_bytes = 16 * 1024 * 1024, -- larger .html files are served unchanged
}
M._limits = LIMITS
local CHUNK = 64 * 1024
local PING_MS = 20000

local TYPES = {
  html = 'text/html; charset=utf-8',
  htm = 'text/html; charset=utf-8',
  js = 'text/javascript; charset=utf-8',
  mjs = 'text/javascript; charset=utf-8',
  css = 'text/css; charset=utf-8',
  json = 'application/json',
  map = 'application/json',
  svg = 'image/svg+xml',
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
  avif = 'image/avif',
  ico = 'image/x-icon',
  woff = 'font/woff',
  woff2 = 'font/woff2',
  ttf = 'font/ttf',
  otf = 'font/otf',
  mp4 = 'video/mp4',
  webm = 'video/webm',
  ogg = 'audio/ogg',
  mp3 = 'audio/mpeg',
  wav = 'audio/wav',
  pdf = 'application/pdf',
  wasm = 'application/wasm',
  txt = 'text/plain; charset=utf-8',
  md = 'text/markdown; charset=utf-8',
  csv = 'text/csv; charset=utf-8',
  xml = 'application/xml',
}

local REASONS = {
  [400] = 'Bad Request',
  [403] = 'Forbidden',
  [404] = 'Not Found',
  [405] = 'Method Not Allowed',
  [408] = 'Request Timeout',
  [416] = 'Range Not Satisfiable',
  [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error',
}

-- The browser side. On a write of a file under the root, the server sends
-- {"changed": [{path, note}]}. For this page's own file, it fetches the raw
-- file and splits it as the runtime does: the note is everything after the
-- tern.js line (data-line), with CR LF and CR read as LF and NUL as U+FFFD,
-- like the HTML parser's input. If the lines up to it still hash to
-- data-head, it calls tern.render(main.tern, note) and keeps the scroll;
-- otherwise, or for a written file that is not a note (CSS, an add-on, an
-- image), it reloads, keeping the scroll through sessionStorage. Writes of
-- other notes are ignored. The stream opens once the note has rendered
-- (tern.ready, or after 5 s for a page tern.js does not render); when it
-- drops, it reopens with a backoff and reloads once the server is back.
local LIVE = [==[
(function () {
  'use strict';
  var me = document.currentScript;
  if (!me) return;
  var path = me.getAttribute('data-path');
  var line = Number(me.getAttribute('data-line')) || 0;
  var head = me.getAttribute('data-head');
  var key = 'tern-preview-scroll:' + path;
  var rendered = false, started = false, dropped = false, busy = false, again = false, wait = 500;

  // A reload restores the scroll itself once the note has rendered; the
  // browser's restoration comes before that, and Chromium applies a stale
  // one when it is switched back on. So a reloaded entry stays 'manual',
  // and each unload of it saves the scroll, a later F5 included.
  function save() {
    try { sessionStorage.setItem(key, String(window.scrollY)); } catch (e) {}
  }
  function reload() {
    try { history.scrollRestoration = 'manual'; } catch (e) {}
    save();
    location.reload();
  }
  window.addEventListener('pagehide', function () {
    if (history.scrollRestoration === 'manual') save();
  });

  // FNV-1a over the bytes, as preview.lua computes data-head.
  function hash(b, n) {
    var h = 0x811c9dc5;
    for (var i = 0; i < n; i++) h = Math.imul(h ^ b[i], 16777619);
    return ('0000000' + (h >>> 0).toString(16)).slice(-8);
  }

  function refresh() {
    var main = document.querySelector('main.tern');
    if (!line || !rendered || !main || !window.tern) return reload();
    if (busy) { again = true; return; }
    busy = true;
    var y = window.scrollY;
    fetch('/__tern/raw' + path, { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.arrayBuffer();
      })
      .then(function (buf) {
        var b = new Uint8Array(buf), at = -1;
        for (var n = 0; n < line; n++) if ((at = b.indexOf(10, at + 1)) < 0) return reload();
        if (hash(b, at + 1) !== head) return reload();
        var note = new TextDecoder('utf-8', { ignoreBOM: true }).decode(b.subarray(at + 1))
          .replace(/\r\n?/g, '\n').replace(/\0/g, '�');
        return window.tern.render(main, note).then(function () {
          if (window.scrollY !== y) window.scrollTo(window.scrollX, y);
          busy = false;
          if (again) { again = false; refresh(); }
        });
      })
      .catch(function (e) {
        console.warn('tern preview: reloading the page:', e);
        reload();
      });
  }

  function changed(list) {
    var self = false, other = false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].path === path) self = true;
      else if (!list[i].note) other = true;
    }
    if (other) reload();
    else if (self) refresh();
  }

  function connect() {
    var es = new EventSource('/__tern/events');
    es.onopen = function () {
      if (dropped) return reload();
      wait = 500;
    };
    es.onmessage = function (e) {
      var m;
      try { m = JSON.parse(e.data); } catch (x) { return; }
      if (m && m.changed) changed(m.changed);
    };
    es.onerror = function () {
      es.close();
      dropped = true;
      setTimeout(connect, wait);
      wait = Math.min(wait * 2, 8000);
    };
  }

  function start() {
    if (started) return;
    started = true;
    try {
      var y = sessionStorage.getItem(key);
      if (y !== null) {
        sessionStorage.removeItem(key);
        window.scrollTo(0, Number(y));
      }
    } catch (e) {}
    connect();
  }

  document.addEventListener('DOMContentLoaded', function () {
    var t = window.tern;
    if (t && t.ready) t.ready.then(function () { rendered = true; start(); });
    setTimeout(start, 5000);
  });
})();
]==]

local S = nil -- the running server

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local WINDOWS = uv.os_uname().sysname == 'Windows_NT'
local function norm(p)
  return WINDOWS and (p:gsub('\\', '/')) or p
end

-- FNV-1a, 32 bits, over the first n bytes of s; 8 hex digits.
local function fnv(s, n)
  local h = bit.tobit(0x811c9dc5)
  for i = 1, n do
    h = bit.bxor(h, s:byte(i))
    h = bit.tobit(bit.lshift(h, 24) + h * 403) -- h * 16777619, mod 2^32
  end
  return bit.tohex(h)
end

local function encode(rel)
  return (rel:gsub('[^%w%-._~/]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

local function decode(s)
  if s:gsub('%%%x%x', ''):find('%', 1, true) then
    return nil
  end
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function url_host(host)
  return host:find(':', 1, true) and '[' .. host .. ']' or host
end

-- The path of real under the server's root ('' for the root), or nil.
local function inside(srv, real)
  if real == srv.real then
    return ''
  end
  local prefix = srv.real:sub(-1) == '/' and srv.real or srv.real .. '/'
  if real:sub(1, #prefix) == prefix then
    return real:sub(#prefix + 1)
  end
end

local function dotted(rel)
  return ('/' .. rel):find('/%.') ~= nil
end

------------------------------------------------------------------ responses

local COMMON = 'Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\n'

local function head(status, fields)
  return 'HTTP/1.1 ' .. status .. '\r\n' .. COMMON .. table.concat(fields) .. 'Connection: close\r\n\r\n'
end

local function close(conn)
  if conn.closed then
    return
  end
  conn.closed = true
  local srv = conn.srv
  srv.conns[conn] = nil
  srv.clients[conn] = nil
  srv.nconns = srv.nconns - 1
  for _, h in ipairs({ conn.timer, conn.sock }) do
    if not h:is_closing() then
      h:close()
    end
  end
end

-- After the response: send FIN, and close when the client does, or after
-- linger_ms. Closing at once with unread input would reset the connection,
-- and the client could lose the response.
local function finish(conn)
  if conn.closed or conn.finishing then
    return
  end
  conn.finishing = true
  conn.state = 'done'
  conn.timer:stop()
  conn.timer:start(LIMITS.linger_ms, 0, function()
    close(conn)
  end)
  conn.sock:shutdown(function() end)
end

local function send(conn, status, ctype, body, fields, no_body)
  if conn.closed or conn.responded then
    return
  end
  conn.responded = true
  local f = { 'Content-Type: ' .. ctype .. '\r\n', 'Content-Length: ' .. #body .. '\r\n' }
  vim.list_extend(f, fields or {})
  conn.sock:write(head(status, f) .. (no_body and '' or body), function()
    finish(conn)
  end)
end

local function fail(conn, code, fields, no_body)
  local status = code .. ' ' .. REASONS[code]
  send(conn, status, 'text/plain; charset=utf-8', status .. '\n', fields, no_body)
end

local function broadcast(srv, text)
  for conn in pairs(srv.clients) do
    if not conn.closed then
      conn.sock:write(text, function(err)
        if err then
          close(conn)
        end
      end)
    end
  end
end

------------------------------------------------------------------ files

-- The file a URL path names: real path, path under the root, stat; or nil
-- and a status (301 with the Location for a folder without its slash).
local function resolve(srv, path, dirs)
  local segs = {}
  for seg in path:gmatch('[^/]+') do
    if seg == '..' or seg:find('\\', 1, true) then
      return nil, 403
    end
    if seg ~= '.' then
      if seg:sub(1, 1) == '.' then
        return nil, 404
      end
      segs[#segs + 1] = seg
    end
  end
  local real = uv.fs_realpath(srv.real .. '/' .. table.concat(segs, '/'))
  if not real then
    return nil, 404
  end
  real = norm(real)
  local rel = inside(srv, real)
  if not rel then
    return nil, 403
  end
  if dotted(rel) then
    return nil, 404
  end
  local st = uv.fs_stat(real)
  if st and st.type == 'directory' and dirs then
    if path:sub(-1) ~= '/' then
      return nil, 301, '/' .. (#segs > 0 and encode(table.concat(segs, '/')) .. '/' or '')
    end
    return resolve(srv, path .. 'index.html', false)
  end
  if not st or st.type ~= 'file' then
    return nil, 404
  end
  return real, rel, st
end

-- bytes=a-b, a- or -n against size: {first, last}; false when it cannot be
-- satisfied; nil to ignore it (malformed, or several ranges).
local function range(v, size)
  local a, b = v:match('^%s*bytes%s*=%s*(%d*)%s*%-%s*(%d*)%s*$')
  if not a or (a == '' and b == '') then
    return nil
  end
  if a == '' then
    local n = tonumber(b)
    if n == 0 or size == 0 then
      return false
    end
    return { math.max(size - n, 0), size - 1 }
  end
  local first, last = tonumber(a), tonumber(b)
  if last and last < first then
    return nil
  end
  if first >= size then
    return false
  end
  return { first, math.min(last or size - 1, size - 1) }
end

-- Streams a file in chunks, waiting for each write: a large video neither
-- sits in memory nor blocks the editor.
local function stream(conn, real, st, h, ctype, no_body)
  local size = st.size
  local first, last, status = 0, size - 1, '200 OK'
  local fields = { 'Accept-Ranges: bytes\r\n' }
  local r = h.range and range(h.range, size)
  if r == false then
    return fail(conn, 416, { ('Content-Range: bytes */%d\r\n'):format(size) }, no_body)
  elseif r then
    first, last, status = r[1], r[2], '206 Partial Content'
    fields[#fields + 1] = ('Content-Range: bytes %d-%d/%d\r\n'):format(first, last, size)
  end
  local len = last - first + 1
  fields[#fields + 1] = 'Content-Type: ' .. ctype .. '\r\n'
  fields[#fields + 1] = 'Content-Length: ' .. len .. '\r\n'
  conn.responded = true
  conn.sock:write(head(status, fields))
  if no_body or len <= 0 then
    return finish(conn)
  end
  uv.fs_open(real, 'r', 0, function(_, fd)
    if not fd then
      return close(conn)
    end
    local function done(ok)
      uv.fs_close(fd, function() end)
      if ok then
        finish(conn)
      else
        close(conn)
      end
    end
    local function pump(pos, left)
      if conn.closed then
        return done(false)
      end
      uv.fs_read(fd, math.min(CHUNK, left), pos, function(err, data)
        if conn.closed or err or not data or data == '' then
          return done(false)
        end
        conn.sock:write(data, function(werr)
          if werr then
            return done(false)
          end
          left = left - #data
          if left <= 0 then
            return done(true)
          end
          pump(pos + #data, left)
        end)
      end)
    end
    pump(first, len)
  end)
end

local function read_all(path, cb)
  uv.fs_open(path, 'r', 0, function(_, fd)
    if not fd then
      return cb(nil)
    end
    local parts = {}
    local function more(pos)
      uv.fs_read(fd, 1024 * 1024, pos, function(err, data)
        if err or not data or data == '' then
          uv.fs_close(fd, function() end)
          return cb(not err and table.concat(parts) or nil)
        end
        parts[#parts + 1] = data
        more(pos + #data)
      end)
    end
    more(0)
  end)
end

-- An attribute's value in a tag, as written.
local function attr(tag, name)
  local _, e = tag:lower():find('%s' .. name .. '%s*=%s*')
  if not e then
    return nil
  end
  local q = tag:sub(e + 1, e + 1)
  if q == '"' or q == "'" then
    return tag:match('^([^' .. q .. ']*)' .. q, e + 2)
  end
  return tag:match('^[^%s>]+', e + 1)
end

-- The note's page as served: the live script and data-diagnostics on the
-- tern.js line (see the header). nil when body is not a note.
local function inject(body, path)
  local pos, lnum = 1, 0
  while lnum < detect.max_lines and pos <= #body do
    lnum = lnum + 1
    local nl = body:find('\n', pos, true)
    local line = body:sub(pos, (nl or #body + 1) - 1)
    local d = line:lower():find('tern.js', 1, true) and detect.line(line)
    if d then
      local tag = d.tag
      -- Same-document refresh needs the tag closed on its line, so that the
      -- runtime's note starts on the next one; else every write reloads.
      local whole = nl and line:lower():find('</script', d.col + #tag, true)
      local nonce = attr(tag, 'nonce') or attr(tag, 'data%-nonce')
      local live = ('<script src="/__tern/live.js" data-path="%s" data-line="%d" data-head="%s"%s></script>'):format(
        path,
        whole and lnum or 0,
        whole and fnv(body, nl) or '',
        nonce and (' nonce="' .. nonce:gsub('[&"<]', { ['&'] = '&amp;', ['"'] = '&quot;', ['<'] = '&lt;' }) .. '"') or ''
      )
      if not tag:lower():find('%sdata%-diagnostics[%s=/>]') then
        tag = tag:sub(1, 7) .. ' data-diagnostics' .. tag:sub(8)
      end
      local at = pos + d.col - 1
      return body:sub(1, at - 1) .. live .. tag .. body:sub(at + #d.tag)
    end
    if not nl then
      return nil
    end
    pos = nl + 1
  end
end

local function file(conn, path, h, no_body, raw)
  local srv = conn.srv
  local real, rel, st = resolve(srv, path, not raw)
  if not real then
    if rel == 301 then
      return send(conn, '301 Moved Permanently', 'text/plain; charset=utf-8', '', { 'Location: ' .. st .. '\r\n' }, no_body)
    end
    return fail(conn, rel, nil, no_body)
  end
  if raw then
    return stream(conn, real, st, h, 'text/plain; charset=utf-8', no_body)
  end
  local ext = (real:match('%.([^./]+)$') or ''):lower()
  if (ext == 'html' or ext == 'htm') and st.size <= LIMITS.note_bytes then
    return read_all(real, function(body)
      if not body then
        return fail(conn, 404, nil, no_body)
      end
      send(conn, '200 OK', TYPES.html, inject(body, '/' .. encode(rel)) or body, nil, no_body)
    end)
  end
  stream(conn, real, st, h, TYPES[ext] or 'application/octet-stream', no_body)
end

------------------------------------------------------------------ requests

local function events(conn, no_body)
  if no_body then
    return send(conn, '200 OK', 'text/event-stream', '', nil, true)
  end
  conn.state = 'events'
  conn.responded = true
  conn.sock:write('HTTP/1.1 200 OK\r\n' .. COMMON .. 'Content-Type: text/event-stream\r\n\r\n: tern\n\n')
  conn.srv.clients[conn] = true
end

local function handle(conn, text)
  local srv = conn.srv
  local reqline, rest = text:match('^([^\r\n]*)(.*)$')
  local method, target, version = reqline:match('^(%S+) (%S+) HTTP/(%d%.%d)$')
  if not method or (version ~= '1.1' and version ~= '1.0') then
    return fail(conn, 400)
  end
  local h = {}
  for l in rest:gmatch('[^\r\n]+') do
    local k, v = l:match('^([^%s:]+):%s*(.-)%s*$')
    if not k then
      return fail(conn, 400)
    end
    k = k:lower()
    if h[k] and k == 'host' then
      return fail(conn, 400)
    end
    h[k] = h[k] and h[k] .. ', ' .. v or v
  end
  local no_body = method == 'HEAD'
  if not srv.hosts[(h.host or ''):lower()] then
    return fail(conn, 403, nil, no_body)
  end
  local site = h['sec-fetch-site']
  if (site == 'cross-site' or site == 'same-site') and h['sec-fetch-mode'] ~= 'navigate' then
    return fail(conn, 403, nil, no_body)
  end
  if method ~= 'GET' and method ~= 'HEAD' then
    return fail(conn, 405, { 'Allow: GET, HEAD\r\n' })
  end
  if target:sub(1, 1) ~= '/' then
    return fail(conn, 400, nil, no_body)
  end
  local path = decode((target:gsub('[?#].*$', '')))
  if not path or path:find('\0', 1, true) then
    return fail(conn, 400, nil, no_body)
  end
  if path == '/__tern/events' then
    return events(conn, no_body)
  elseif path == '/__tern/live.js' then
    return send(conn, '200 OK', TYPES.js, LIVE, nil, no_body)
  end
  local raw = path:match('^/__tern/raw(/.*)$')
  if not raw and (path == '/__tern' or path:find('^/__tern/')) then
    return fail(conn, 404, nil, no_body)
  end
  file(conn, raw or path, h, no_body, raw ~= nil)
end

local function accept(srv)
  local sock = uv.new_tcp()
  if not sock then
    return
  end
  if not srv.tcp:accept(sock) or srv.nconns >= LIMITS.conns then
    return sock:close()
  end
  local conn = { srv = srv, sock = sock, timer = uv.new_timer(), data = '', state = 'head' }
  srv.conns[conn] = true
  srv.nconns = srv.nconns + 1
  conn.timer:start(LIMITS.head_ms, 0, function()
    if conn.state == 'head' then
      conn.state = 'done'
      fail(conn, 408)
    end
  end)
  sock:read_start(function(err, chunk)
    if err or not chunk then
      return close(conn)
    end
    if conn.state ~= 'head' then
      return -- a request body, or anything after the request: ignored
    end
    local data = (conn.data .. chunk):gsub('^[\r\n]+', '')
    conn.data = data
    local s = data:find('\r?\n\r?\n')
    if (s and s - 1 or #data) > LIMITS.head_bytes then
      conn.state = 'done'
      return fail(conn, 431)
    end
    if not s then
      return
    end
    conn.state = 'busy'
    conn.data = nil
    conn.timer:stop()
    local ok = pcall(handle, conn, data:sub(1, s - 1))
    if not ok then
      fail(conn, 500)
    end
  end)
end

------------------------------------------------------------------ the server

local function shutdown(srv)
  for conn in pairs(srv.conns) do
    close(conn)
  end
  for _, h in ipairs({ srv.ping, srv.flush, srv.tcp }) do
    if not h:is_closing() then
      h:close()
    end
  end
end

local function bind(srv, addr, port)
  local tcp = assert(uv.new_tcp())
  local ok, err, name = tcp:bind(addr, port)
  if ok then
    -- libuv reports EADDRINUSE from listen, not bind.
    ok, err, name = tcp:listen(128, function(e)
      if not e then
        accept(srv)
      end
    end)
  end
  if not ok then
    tcp:close()
    return nil, name or err
  end
  return tcp
end

local function listen(root, real, prefer)
  local o = config.options.preview or {}
  local host, port = o.host or '127.0.0.1', tonumber(o.port) or 0
  local srv = { root = root, real = real, host = host, conns = {}, clients = {}, nconns = 0, pending = {} }
  local addr = host
  if not host:find(':', 1, true) and not host:match('^[%d.]+$') then
    local ai = uv.getaddrinfo(host, nil, { socktype = 'stream' })
    addr = ai and ai[1] and ai[1].addr
    if not addr then
      return nil, ('tern: cannot serve the preview: preview.host %q does not resolve'):format(host)
    end
  end
  local tcp, err
  if port == 0 and prefer then
    tcp = bind(srv, addr, prefer)
  end
  if not tcp then
    tcp, err = bind(srv, addr, port)
  end
  if not tcp then
    local why = err == 'EADDRINUSE' and 'the port is in use; set preview.port to another, or to 0 for any free port'
      or err == 'EACCES' and 'permission denied; choose a port above 1023'
      or err == 'EADDRNOTAVAIL' and 'this machine has no such address'
      or tostring(err)
    return nil, ('tern: cannot serve the preview on %s:%d: %s'):format(url_host(host), port, why)
  end
  srv.tcp = tcp
  srv.port = tcp:getsockname().port
  srv.base = ('http://%s:%d'):format(url_host(host), srv.port)
  srv.hosts = {}
  for _, n in ipairs({ url_host(host):lower(), 'localhost', '127.0.0.1' }) do
    srv.hosts[n .. ':' .. srv.port] = true
    if srv.port == 80 then
      srv.hosts[n] = true
    end
  end
  srv.flush = uv.new_timer()
  srv.ping = uv.new_timer()
  srv.ping:start(PING_MS, PING_MS, function()
    broadcast(srv, ': ping\n\n')
  end)
  return srv
end

-- A written file under the root: one event for the writes of the next
-- 30 ms (:wall), each file with whether it is a note. A uv timer, not
-- vim.defer_fn, so that the event goes out while Neovim waits on fast
-- events only (vim.system():wait()); the JSON is built by hand, the paths
-- being percent-encoded already.
local function written(buf, name)
  local srv = S
  local real = srv and name ~= '' and uv.fs_realpath(name)
  local rel = real and inside(srv, norm(real))
  if not rel or rel == '' or dotted(rel) then
    return
  end
  local ext = (rel:match('%.([^./]+)$') or ''):lower()
  srv.pending['/' .. encode(rel)] = (ext == 'html' or ext == 'htm') and detect.buffer(buf) ~= nil
  if srv.flush:is_active() then
    return
  end
  srv.flush:start(30, 0, function()
    local list = {}
    for path, note in pairs(srv.pending) do
      list[#list + 1] = ('{"path":"%s","note":%s}'):format(path, tostring(note))
    end
    srv.pending = {}
    broadcast(srv, 'data: {"changed":[' .. table.concat(list, ',') .. ']}\n\n')
  end)
end

local function open(url)
  local b = config.options.preview.browser
  if b then
    local cmd = type(b) == 'string' and { b } or vim.deepcopy(b)
    cmd[#cmd + 1] = url
    local ok, err = pcall(vim.system, cmd, { detach = true, stdout = false, stderr = false })
    if not ok then
      notify(('tern: cannot run the browser %s: %s'):format(cmd[1], err), vim.log.levels.WARN)
    end
  else
    local _, err = vim.ui.open(url)
    if err then
      notify('tern: cannot open a browser: ' .. err, vim.log.levels.WARN)
    end
  end
end

function M.start()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local real = name ~= '' and uv.fs_realpath(name)
  if not real then
    return notify(name == '' and 'tern: this buffer has no file to preview' or 'tern: write the file before previewing it', vim.log.levels.WARN)
  end
  real = norm(real)
  local moved
  if not (S and inside(S, real)) then
    local root = vim.fs.root(buf, { 'tern.js', '.git' }) or vim.fs.dirname(name)
    local root_real = uv.fs_realpath(root)
    if not root_real then
      return notify('tern: cannot read the folder ' .. root, vim.log.levels.ERROR)
    end
    local prefer = S and S.port
    moved = S and S.root
    if S then
      shutdown(S)
      S = nil
    end
    local srv, err = listen(root, norm(root_real), prefer)
    if not srv then
      pcall(vim.api.nvim_del_augroup_by_name, 'tern_preview')
      return notify(err, vim.log.levels.ERROR)
    end
    S = srv
    local g = vim.api.nvim_create_augroup('tern_preview', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = g,
      callback = function(a)
        written(a.buf, a.match)
      end,
    })
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = g,
      callback = function()
        M.stop(true)
      end,
    })
  end
  local rel = inside(S, real)
  if not rel then
    return notify(('tern: %s is a link to a file outside %s, which the preview does not serve'):format(name, S.root), vim.log.levels.ERROR)
  elseif dotted(rel) then
    return notify(('tern: %s is hidden (a name starting with a dot), which the preview does not serve'):format(rel), vim.log.levels.WARN)
  end
  local url = S.base .. '/' .. encode(rel)
  local msg = moved and ('tern: the preview moved from %s to %s: %s'):format(vim.fn.fnamemodify(moved, ':~'), vim.fn.fnamemodify(S.root, ':~'), url)
    or 'tern: preview at ' .. url
  if vim.bo[buf].modified then
    msg = msg .. ' (write the buffer to show your changes)'
  end
  notify(msg)
  if config.options.preview.open then
    open(url)
  end
  return url
end

function M.stop(quiet)
  local srv = S
  S = nil
  pcall(vim.api.nvim_del_augroup_by_name, 'tern_preview')
  if srv then
    shutdown(srv)
  end
  if not quiet then
    notify(srv and 'tern: preview stopped' or 'tern: no preview is running')
  end
end

function M.info()
  if not S then
    return nil
  end
  local n = 0
  for _ in pairs(S.clients) do
    n = n + 1
  end
  return { root = S.root, url = S.base, host = S.host, port = S.port, clients = n }
end

return M
