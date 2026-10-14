-- SPDX-License-Identifier: MIT
-- tern.preview: the HTTP server over raw vim.uv TCP clients, then a real
-- browser through Playwright when node and Playwright are found
-- ($NODE_PATH, else npx's cache in ~/.npm/_npx), and a Tern checkout for
-- tern.js (T.tern_root()).
local uv = vim.uv
local P = require('tern.preview')

-- Each case runs with the preview closed after it, the options reset and
-- messages captured in T.msgs instead of printed.
local function case(name, fn)
  return {
    name,
    function(T)
      local notify = vim.notify
      T.msgs = {}
      vim.notify = function(m, l)
        table.insert(T.msgs, { m, l })
      end
      require('tern').setup({ lsp = false, render = { enabled = false }, preview = { open = false } })
      local limits = vim.deepcopy(P._limits)
      T.cleanup = {}
      local ok, err = xpcall(fn, debug.traceback, T)
      for _, f in ipairs(T.cleanup) do
        pcall(f)
      end
      P.stop(true)
      for k, v in pairs(limits) do
        P._limits[k] = v
      end
      vim.notify = notify
      require('tern').setup()
      if not ok then
        error(err, 0)
      end
    end,
  }
end

local function last_msg(T)
  local m = T.msgs[#T.msgs]
  return m and m[1] or ''
end

-- A TCP client: connect, write, collect what comes back until EOF.
local function client(T, port, text)
  local c = { tcp = uv.new_tcp(), out = {}, eof = false }
  c.tcp:connect('127.0.0.1', port, function(err)
    if err then
      c.err, c.eof = err, true
      return
    end
    c.connected = true
    c.tcp:read_start(function(e, chunk)
      if e or not chunk then
        c.eof = true
        c.err = c.err or e
        return
      end
      c.out[#c.out + 1] = chunk
    end)
    if text then
      c.tcp:write(text)
    end
  end)
  function c.text()
    return table.concat(c.out)
  end
  function c.close()
    if not c.tcp:is_closing() then
      c.tcp:close()
    end
  end
  T.wait(3000, function()
    return c.connected or c.err
  end, 'connect')
  return c
end

local function parse(resp)
  local head, body = resp:match('^(.-)\r\n\r\n(.*)$')
  if not head then
    return { status = nil, h = {}, body = resp }
  end
  local h = {}
  for k, v in head:gmatch('\r\n([^:\r\n]+):%s*([^\r]*)') do
    h[k:lower()] = v
  end
  return { status = tonumber(head:match('^HTTP/1%.1 (%d+)')), h = h, body = body }
end

-- One request: opts.method, opts.host (false: no Host), opts.headers.
local function req(T, path, opts)
  opts = opts or {}
  local port = P.info().port
  local lines = { (opts.method or 'GET') .. ' ' .. path .. ' HTTP/1.1' }
  if opts.host ~= false then
    lines[#lines + 1] = 'Host: ' .. (opts.host or ('127.0.0.1:' .. port))
  end
  vim.list_extend(lines, opts.headers or {})
  local c = client(T, port, table.concat(lines, '\r\n') .. '\r\n\r\n')
  T.wait(5000, function()
    return c.eof
  end, 'response to ' .. path)
  c.close()
  return parse(c.text())
end

local function status(T, path, opts)
  return req(T, path, opts).status
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
  return path
end

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

-- FNV-1a again, with plain arithmetic, to check data-head.
local function fnv(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i)) % 4294967296
    local lo, hi = h % 65536, math.floor(h / 65536)
    h = (lo * 16777619 + (hi * 16777619 % 65536) * 65536) % 4294967296
  end
  return ('%08x'):format(h)
end

local NOTE = '<!doctype html><meta charset="utf-8">\n<title>A</title><script src="../tern.js" nonce="abc"></script>\n# A\n\nText.\n'

local function project(T)
  local dir = vim.fs.normalize(uv.fs_realpath(T.tmpdir()))
  write(dir .. '/tern.js', '// a stand-in\n')
  write(dir .. '/notes/a.html', NOTE)
  write(dir .. '/style.css', 'body { color: red }\n')
  return dir
end

local function start(T, file)
  vim.cmd.edit(file)
  local url = P.start()
  T.ok(url, 'start returned no URL: ' .. last_msg(T))
  return url
end

-- An event stream client and the events it has received.
local function events(T)
  local c = client(T, P.info().port, ('GET /__tern/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n'):format(P.info().port))
  T.wait(3000, function()
    return c.text():find(': tern\n\n', 1, true)
  end, 'the event stream opens')
  function c.events()
    local list = {}
    for data in c.text():gmatch('\ndata: ([^\n]*)') do
      list[#list + 1] = vim.json.decode(data).changed
    end
    return list
  end
  return c
end

local function by_path(list)
  local t = {}
  for _, e in ipairs(list) do
    t[e.path] = e.note
  end
  return t
end

------------------------------------------------------------------ the browser

local function playwright()
  if vim.fn.executable('node') == 0 then
    return nil, 'no node'
  end
  local dirs = vim.split(vim.env.NODE_PATH or '', ':', { trimempty = true })
  vim.list_extend(dirs, vim.fn.glob(vim.fn.expand('~/.npm/_npx') .. '/*/node_modules', false, true))
  for _, d in ipairs(dirs) do
    if uv.fs_stat(d .. '/playwright/package.json') then
      return d
    end
  end
  return nil, 'no Playwright: set $NODE_PATH to a node_modules that has it'
end

-- Prints "STEP {json}" lines that the Lua side waits for; Neovim writes
-- between the steps.
local DRIVER = [==[
const pw = require('playwright');
const [url, which] = process.argv.slice(2);
const say = (step, data) => console.log(`${step} ${JSON.stringify(data || {})}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  let browser;
  try {
    browser = await pw[which].launch();
  } catch (e) {
    return say('SKIP', { why: String(e.message).split('\n')[0] });
  }
  const logs = [];
  try {
    const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
    page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));
    // Evaluates fn until it returns something truthy, across reloads.
    const poll = async (fn, ms = 15000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        try {
          const v = await page.evaluate(fn);
          if (v) return v;
        } catch {}
        await sleep(50);
      }
      throw new Error(`timed out waiting for ${fn}`);
    };
    const state = () => page.evaluate(async () => {
      await tern.ready;
      const a = document.querySelector('.t-diagnostics');
      return { marker: window.__marker, y: Math.round(scrollY), title: document.title, panel: a && a.textContent, text: document.querySelector('main.tern').textContent };
    });
    await page.goto(url);
    await poll(() => window.tern && document.querySelector('main.tern'));
    await page.evaluate(() => tern.ready);
    await page.evaluate(() => { window.__marker = 42; window.scrollTo(0, 1500); });
    say('STEP1', await state());
    await poll(() => document.body.textContent.includes('Changed in Neovim'));
    await sleep(300);
    say('STEP2', await state());
    await poll(() => document.body.textContent.includes('Typed, not written'));
    await sleep(300);
    say('TYPED', await state());
    await poll(() => document.title === 'Live 2' && !window.__marker && window.tern && document.querySelector('main.tern'));
    await sleep(300);
    const s3 = await state();
    await page.evaluate(() => { window.__marker = 7; });
    say('STEP3', s3);
    await poll(() => window.__marker === undefined && window.tern && document.querySelector('main.tern'), 20000);
    await sleep(300);
    const s4 = await state();
    await page.evaluate(() => { window.__marker = 9; });
    say('STEP4', s4);
    await poll(() => window.__marker === undefined && window.tern && document.querySelector('main.tern'));
    await sleep(300);
    say('STEP5', await state());
  } catch (e) {
    say('FAIL', { error: String(e && e.stack || e), logs });
  } finally {
    await browser.close();
  }
})();
]==]

local function browser_case(which)
  return case('in ' .. which .. ': positions match, a body change renders in place, written or not, a head change or a restart reloads', function(T)
    local tern_root = T.tern_root()
    local node_path, why = playwright()
    if not tern_root or not node_path then
      print('    (skipped: ' .. (why or 'no Tern checkout; set $TERN_ROOT') .. ')')
      return
    end
    local dir = vim.fs.normalize(uv.fs_realpath(T.tmpdir()))
    write(dir .. '/tern.js', read(tern_root .. '/tern.js'))
    local lines = { '<!doctype html><meta charset="utf-8">', '<title>Live</title>', '<script src="tern.js" data-katex="none"></script>', '# Live preview', '' }
    for i = 1, 60 do
      vim.list_extend(lines, { ('Paragraph %d: a line long enough to wrap once or twice in an 800 pixel wide window, so that the page scrolls well past 1500 pixels.'):format(i), '' })
    end
    vim.list_extend(lines, { ':::note', 'never closed' })
    local opener = #lines - 1 -- the file line of :::note
    write(dir .. '/note.html', table.concat(lines, '\n') .. '\n')
    write(dir .. '/other.html', '<!doctype html><meta charset="utf-8"><script src="tern.js" data-katex="none"></script>\n# Other\n')
    write(dir .. '/driver.js', DRIVER)

    vim.cmd.edit(dir .. '/other.html')
    local url = start(T, dir .. '/note.html')
    local note_buf = vim.api.nvim_get_current_buf()

    local out, buf = {}, ''
    local proc = vim.system({ 'node', dir .. '/driver.js', url, which }, {
      env = { NODE_PATH = node_path },
      stdout = function(_, data)
        buf = buf .. (data or '')
        while buf:find('\n') do
          local l
          l, buf = buf:match('^([^\n]*)\n(.*)$')
          local step, json = l:match('^(%u+%d*) (.*)$')
          if step then
            out[step] = vim.json.decode(json)
          end
        end
      end,
    })
    table.insert(T.cleanup, function()
      proc:kill(15)
    end)
    local function step(name)
      T.wait(40000, function()
        return out[name] or out.FAIL or out.SKIP
      end, which .. ' ' .. name)
      if out.SKIP then
        return nil
      end
      if out.FAIL then
        error(out.FAIL.error .. '\n' .. table.concat(out.FAIL.logs or {}, '\n'), 0)
      end
      return out[name]
    end
    local function panel_lines(s)
      local note_line, file_line = (s.panel or ''):match('line (%d+):%d+ %(file line (%d+)%)')
      return tonumber(note_line), tonumber(file_line)
    end

    local s1 = step('STEP1')
    if not s1 then
      print('    (skipped: ' .. which .. ' does not launch: ' .. out.SKIP.why .. ')')
      return
    end
    -- The injection kept the tern.js line on file line 3: the panel's file
    -- line is the editor's.
    T.eq({ panel_lines(s1) }, { opener - 3, opener }, 'the panel positions (note line, file line)')
    T.eq(s1.y, 1500, 'scrolled')
    T.wait(5000, function()
      return P.info().clients >= 1
    end, 'the page opened its event stream')

    -- Another note's write changes nothing; this note's body is rendered in place.
    vim.cmd.buffer(vim.fn.bufnr(dir .. '/other.html'))
    vim.cmd('silent write')
    vim.wait(100)
    vim.cmd.buffer(note_buf)
    vim.api.nvim_buf_set_lines(note_buf, 4, 4, false, { 'Changed in Neovim.', '' })
    vim.cmd('silent write')
    local s2 = step('STEP2')
    T.eq(s2.marker, 42, 'the same document (no reload)')
    T.eq(s2.y, 1500, 'the scroll kept')
    T.ok(s2.text:find('Changed in Neovim', 1, true), 'the new text')
    T.eq({ panel_lines(s2) }, { opener - 1, opener + 2 }, 'the panel after the refresh')

    -- Typing without writing renders in place too.
    vim.api.nvim_buf_set_lines(note_buf, 4, 4, false, { 'Typed, not written.', '' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = note_buf })
    local typed = step('TYPED')
    T.eq({ typed.marker, typed.y }, { 42, 1500 }, 'unsaved: the same document, the scroll kept')
    T.ok(typed.text:find('Typed, not written', 1, true), 'the unsaved text')
    T.eq({ panel_lines(typed) }, { opener + 1, opener + 4 }, 'the panel follows the buffer')

    -- A head change reloads, and the scroll comes back.
    vim.api.nvim_buf_set_lines(note_buf, 1, 2, false, { '<title>Live 2</title>' })
    vim.cmd('silent write')
    local s3 = step('STEP3')
    T.eq(s3.marker, nil, 'reloaded')
    T.eq(s3.title, 'Live 2', 'the new head')
    T.eq(s3.y, 1500, 'the scroll restored')
    T.eq({ panel_lines(s3) }, { opener + 1, opener + 4 }, 'the panel after the reload')

    -- The server goes away and comes back on its port: the page reloads.
    local port = P.info().port
    P.stop(true)
    vim.wait(300)
    require('tern').setup({ lsp = false, render = { enabled = false }, preview = { open = false, port = port } })
    T.ok(P.start(), 'restarted: ' .. last_msg(T))
    local s4 = step('STEP4')
    T.eq(s4.marker, nil, 'reloaded when the server came back')
    T.eq(s4.title, 'Live 2', 'still the note')
    T.eq(s4.y, 1500, 'the scroll restored after the restart')

    -- A write of a file that is not a note (CSS, an add-on) reloads.
    vim.cmd.edit(dir .. '/extra.css')
    vim.cmd('silent write')
    local s5 = step('STEP5')
    T.eq({ s5.marker, s5.y }, { nil, 1500 }, 'reloaded for the CSS, the scroll kept')
    proc:wait(10000)
  end)
end

------------------------------------------------------------------ the cases

return {
  case('the note gets data-diagnostics and the live script on its tern.js line, and nothing else', function(T)
    local dir = project(T)
    local url = start(T, dir .. '/notes/a.html')
    local info = P.info()
    T.eq(url, ('http://127.0.0.1:%d/notes/a.html'):format(info.port), 'the URL')
    T.eq(info.root, dir, 'the root: the folder with tern.js')
    T.ok(last_msg(T):find(url, 1, true), 'the URL is printed')

    local r = req(T, '/notes/a.html')
    T.eq(r.status, 200, 'status')
    T.eq(r.h['content-type'], 'text/html; charset=utf-8', 'type')
    T.eq(r.h['cache-control'], 'no-store', 'cache-control')
    local want = vim.split(NOTE, '\n')
    local got = vim.split(r.body, '\n')
    T.eq(#got, #want, 'the line count')
    for i = 1, #want do
      if i ~= 2 then
        T.eq(got[i], want[i], 'line ' .. i)
      end
    end
    local head = NOTE:sub(1, select(2, NOTE:find('\n', NOTE:find('\n') + 1, true)))
    T.eq(got[2], '<title>A</title><script src="/__tern/live.js" data-path="/notes/a.html" data-line="2" data-head="'
      .. fnv(head) .. '" nonce="abc"></script><script data-diagnostics src="../tern.js" nonce="abc"></script>', 'the tern.js line')
    T.eq(require('tern.detect').line(got[2]).tag, '<script data-diagnostics src="../tern.js" nonce="abc">', 'still the tern.js line')
    T.eq(req(T, '/notes/a.html', { method = 'HEAD' }).h['content-length'], tostring(#r.body), 'HEAD length')

    -- data-head follows the head only.
    local function data_head()
      return req(T, '/notes/a.html').body:match('data%-head="(%x+)"')
    end
    local h0 = data_head()
    write(dir .. '/notes/a.html', NOTE .. 'More text.\n')
    T.eq(data_head(), h0, 'a body change keeps data-head')
    write(dir .. '/notes/a.html', NOTE:gsub('<title>A', '<title>B'))
    T.ok(data_head() ~= h0, 'a head change changes it')

    -- data-diagnostics already there is kept; a tag closed on a later line
    -- disables the in-place refresh; HTML that is no note is left alone.
    write(dir .. '/b.html', '<!doctype html><script data-diagnostics=false src="tern.js"></script>\n# B\n')
    local b = req(T, '/b.html').body
    T.ok(b:find('<script data-diagnostics=false src="tern.js">', 1, true) and select(2, b:gsub('data%-diagnostics', '')) == 1, 'one data-diagnostics')
    write(dir .. '/c.html', '<!doctype html><script src="tern.js">\n</script>\n# C\n')
    T.ok(req(T, '/c.html').body:find('data-line="0"', 1, true), 'data-line 0')
    local page = '<!doctype html><title>Page</title><script src="app.js"></script>\n<p>hi</p>\n'
    write(dir .. '/page.html', page)
    T.eq(req(T, '/page.html').body, page, 'not a note')
    T.eq(req(T, '/__tern/raw/notes/a.html').body, read(dir .. '/notes/a.html'), 'the raw file')
  end),

  case('files are served with their type, in ranges, and folders through index.html', function(T)
    local dir = project(T)
    local png = '\137PNG\r\n\26\n\0\0\0\rIHDR' .. ('\0\1\2\255'):rep(64)
    write(dir .. '/img/p.png', png)
    local big = ('0123456789abcdef'):rep(20000) -- 320 KB, several chunks
    write(dir .. '/v.mp4', big)
    write(dir .. '/data.bin', 'x')
    write(dir .. '/docs/index.html', '<p>docs</p>')
    start(T, dir .. '/notes/a.html')

    local css = req(T, '/style.css')
    T.eq({ css.status, css.h['content-type'], css.body }, { 200, 'text/css; charset=utf-8', 'body { color: red }\n' }, 'a sibling asset')
    local p = req(T, '/img/p.png')
    T.eq({ p.status, p.h['content-type'], p.body == png }, { 200, 'image/png', true }, 'binary')
    for ext, want in pairs({ js = 'text/javascript; charset=utf-8', svg = 'image/svg+xml', jpg = 'image/jpeg', webp = 'image/webp', gif = 'image/gif', woff2 = 'font/woff2', json = 'application/json', webm = 'video/webm' }) do
      write(dir .. '/f.' .. ext, 'x')
      T.eq(req(T, '/f.' .. ext).h['content-type'], want, ext)
    end
    T.eq(req(T, '/data.bin').h['content-type'], 'application/octet-stream', 'unknown type')
    T.eq(req(T, '/v.mp4').body == big, true, 'a large file, whole')
    local part = req(T, '/v.mp4', { headers = { 'Range: bytes=2-5' } })
    T.eq({ part.status, part.h['content-range'], part.body }, { 206, 'bytes 2-5/' .. #big, '2345' }, 'a range')
    T.eq(req(T, '/v.mp4', { headers = { 'Range: bytes=-3' } }).body, 'def', 'a suffix range')
    T.eq(status(T, '/v.mp4', { headers = { 'Range: bytes=999999-' } }), 416, 'past the end')
    local hd = req(T, '/style.css', { method = 'HEAD' })
    T.eq({ hd.status, hd.h['content-length'], hd.body }, { 200, '20', '' }, 'HEAD')
    local moved = req(T, '/docs')
    T.eq({ moved.status, moved.h.location }, { 301, '/docs/' }, 'a folder without its slash')
    T.eq(req(T, '/docs/').body, '<p>docs</p>', 'index.html')
    T.eq(status(T, '/notes/'), 404, 'no listing')
    T.eq(status(T, '/style.css?v=2#x'), 200, 'a query')
    T.eq(req(T, '/__tern/live.js').h['content-type'], 'text/javascript; charset=utf-8', 'the live script')
    T.eq(status(T, '/__tern/nothing'), 404, 'the reserved prefix')
  end),

  case('refuses foreign hosts, cross-site requests, escapes, dotfiles and other methods', function(T)
    local dir = project(T)
    local outside = vim.fs.normalize(uv.fs_realpath(T.tmpdir()))
    write(outside .. '/secret.txt', 'secret')
    write(dir .. '/.env', 'TOKEN=1')
    write(dir .. '/.git/config', '[core]')
    write(dir .. '/notes/.draft.html', NOTE)
    write(dir .. '/.hidden/file.txt', 'hidden')
    assert(uv.fs_symlink(outside .. '/secret.txt', dir .. '/escape.txt'))
    assert(uv.fs_symlink(outside, dir .. '/away'))
    assert(uv.fs_symlink(dir .. '/style.css', dir .. '/alias.css'))
    assert(uv.fs_symlink(dir .. '/.hidden/file.txt', dir .. '/shown.txt'))
    start(T, dir .. '/notes/a.html')
    local port = P.info().port

    -- DNS rebinding: the Host must name this server.
    T.eq(status(T, '/style.css', { host = 'evil.example:' .. port }), 403, 'a foreign Host')
    T.eq(status(T, '/style.css', { host = 'evil.example' }), 403, 'a foreign Host without port')
    T.eq(status(T, '/style.css', { host = '127.0.0.1:' .. (port + 1) }), 403, 'another port')
    T.eq(status(T, '/style.css', { host = false }), 403, 'no Host')
    T.eq(status(T, '/style.css', { host = 'localhost:' .. port }), 200, 'localhost')
    T.eq(status(T, '/style.css', { host = 'LocalHost:' .. port }), 200, 'any case')
    T.eq(status(T, '/style.css', { headers = { 'Host: 127.0.0.1:' .. port } }), 400, 'two Hosts')
    -- Another site's page.
    T.eq(status(T, '/style.css', { headers = { 'Sec-Fetch-Site: cross-site', 'Sec-Fetch-Mode: no-cors' } }), 403, 'cross-site embedding')
    T.eq(status(T, '/__tern/events', { headers = { 'Sec-Fetch-Site: cross-site', 'Sec-Fetch-Mode: cors' } }), 403, 'cross-site events')
    T.eq(status(T, '/notes/a.html', { headers = { 'Sec-Fetch-Site: cross-site', 'Sec-Fetch-Mode: navigate' } }), 200, 'a link from elsewhere')
    T.eq(status(T, '/style.css', { headers = { 'Sec-Fetch-Site: same-origin', 'Sec-Fetch-Mode: no-cors' } }), 200, 'the page itself')
    -- Traversal, raw and encoded.
    for _, path in ipairs({ '/../secret.txt', '/notes/../../secret.txt', '/%2e%2e/secret.txt', '/..%2fsecret.txt', '/notes/%2E%2E/%2E%2E/secret.txt', '/__tern/raw/../secret.txt', '/a\\..\\b' }) do
      T.eq(status(T, path), 403, path)
    end
    -- Symlinks: out of the root no, within it yes.
    T.eq(status(T, '/escape.txt'), 403, 'a link to a file outside')
    T.eq(status(T, '/away/secret.txt'), 403, 'a link to a folder outside')
    T.eq(status(T, '/__tern/raw/escape.txt'), 403, 'raw, through a link')
    T.eq(req(T, '/alias.css').body, 'body { color: red }\n', 'a link inside')
    -- Dotfiles, by name or through a link.
    for _, path in ipairs({ '/.env', '/.git/config', '/notes/.draft.html', '/%2eenv', '/.hidden/file.txt', '/shown.txt', '/__tern/raw/.env' }) do
      T.eq(status(T, path), 404, path)
    end
    -- Methods.
    for _, m in ipairs({ 'POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH', 'TRACE' }) do
      local r = req(T, '/style.css', { method = m })
      T.eq({ r.status, r.h.allow }, { 405, 'GET, HEAD' }, m)
    end
    -- Malformed.
    T.eq(status(T, 'http://127.0.0.1/style.css'), 400, 'an absolute target')
    T.eq(status(T, '/style%zz.css'), 400, 'a bad escape')
    T.eq(status(T, '/style.css%00.png'), 400, 'NUL')
    T.eq(status(T, '/nothing.html'), 404, 'missing')
  end),

  case('caps the request head in size and in time, and connections in number', function(T)
    local dir = project(T)
    start(T, dir .. '/notes/a.html')
    local port = P.info().port
    local big = client(T, port, ('GET /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nX-Big: %s\r\n\r\n'):format(port, ('a'):rep(10000)))
    T.wait(3000, function()
      return big.eof
    end, 'a large head is answered')
    big.close()
    T.eq(parse(big.text()).status, 431, 'too large')
    local endless = client(T, port, ('GET /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nX-A: '):format(port))
    for _ = 1, 3 do -- trickled, never ending
      vim.wait(50)
      endless.tcp:write(('b'):rep(4000))
    end
    T.wait(3000, function()
      return endless.eof
    end, 'a head that never ends is cut')
    endless.close()
    T.eq(parse(endless.text()).status, 431, 'too large, in pieces')

    P._limits.head_ms = 200
    local slow = client(T, port, 'GET /style.css HTTP/1.1\r\n')
    T.wait(3000, function()
      return slow.eof
    end, 'a slow head times out')
    slow.close()
    T.eq(parse(slow.text()).status, 408, 'timed out')

    P._limits.head_ms = 5000
    P._limits.conns = 2
    local a, b = client(T, port), client(T, port)
    vim.wait(100)
    local c = client(T, port)
    T.wait(2000, function()
      return c.eof
    end, 'over the cap, closed')
    T.eq(c.text(), '', 'nothing sent')
    a.close()
    b.close()
    c.close()
  end),

  case('an event stream gets one event per write under the root', function(T)
    local dir = project(T)
    local outside = vim.fs.normalize(uv.fs_realpath(T.tmpdir()))
    write(dir .. '/b.html', '<!doctype html><script src="tern.js"></script>\n# B\n')
    start(T, dir .. '/notes/a.html')
    local es = events(T)
    T.wait(2000, function()
      return P.info().clients == 1
    end, 'one client')
    T.eq(parse(es.text()).h['content-type'], 'text/event-stream', 'type')

    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'More.' })
    vim.cmd('silent write')
    T.wait(2000, function()
      return #es.events() == 1
    end, 'an event for the note')
    T.eq(es.events()[1], { { path = '/notes/a.html', note = true } }, 'the note')

    vim.cmd.edit(dir .. '/style.css')
    vim.cmd('silent write')
    T.wait(2000, function()
      return #es.events() == 2
    end, 'an event for the CSS')
    T.eq(es.events()[2], { { path = '/style.css', note = false } }, 'not a note')

    vim.cmd.edit(outside .. '/x.css')
    vim.cmd('silent write')
    vim.cmd.edit(dir .. '/.hidden.css')
    vim.cmd('silent write')
    vim.wait(200)
    T.eq(#es.events(), 2, 'nothing for a file outside the root or hidden')

    vim.cmd.edit(dir .. '/b.html')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'More.' })
    vim.cmd.edit(dir .. '/style.css')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'p {}' })
    vim.cmd('silent wall')
    T.wait(2000, function()
      return #es.events() == 3
    end, 'one event for :wall')
    T.eq(by_path(es.events()[3]), { ['/b.html'] = true, ['/style.css'] = false }, ':wall')
    es.close()
  end),

  case('a second :TernPreview under the root reuses the server; outside it, the server moves', function(T)
    local dir = project(T)
    write(dir .. '/b.html', NOTE)
    local other = vim.fs.normalize(uv.fs_realpath(T.tmpdir()))
    write(other .. '/c.html', NOTE)
    start(T, dir .. '/notes/a.html')
    local port = P.info().port
    local es = events(T)

    local url = start(T, dir .. '/b.html')
    T.eq(url, ('http://127.0.0.1:%d/b.html'):format(port), 'same server')
    vim.wait(100)
    T.eq(es.eof, false, 'the stream stays open')

    url = start(T, other .. '/c.html')
    T.eq(P.info().root, other, 'the new root: the note\'s folder')
    T.eq(url, ('http://127.0.0.1:%d/c.html'):format(port), 'the same port')
    T.ok(last_msg(T):find('moved', 1, true), 'says so: ' .. last_msg(T))
    T.wait(2000, function()
      return es.eof
    end, 'the old stream closes')
    es.close()
    T.eq(status(T, '/c.html'), 200, 'the new root is served')
    T.eq(status(T, '/notes/a.html'), 404, 'the old one is not')
  end),

  case('a busy port gives a clear message, and no server', function(T)
    local dir = project(T)
    local blocker = uv.new_tcp()
    assert(blocker:bind('127.0.0.1', 0))
    assert(blocker:listen(1, function() end))
    local port = blocker:getsockname().port
    require('tern').setup({ lsp = false, preview = { open = false, port = port } })
    vim.cmd.edit(dir .. '/notes/a.html')
    T.eq(P.start(), nil, 'no URL')
    blocker:close()
    T.ok(last_msg(T):find('port is in use', 1, true) and last_msg(T):find(tostring(port), 1, true), 'the message: ' .. last_msg(T))
    T.eq(T.msgs[#T.msgs][2], vim.log.levels.ERROR, 'an error')
    T.eq(P.info(), nil, 'nothing runs')
  end),

  case('the browser is opened with preview.browser', function(T)
    local dir = project(T)
    local log = dir .. '/opened.txt'
    require('tern').setup({ lsp = false, preview = { open = true, browser = { 'sh', '-c', 'printf %s "$1" > ' .. log, 'sh' } } })
    vim.cmd.edit(dir .. '/notes/a.html')
    local url = P.start()
    T.wait(3000, function()
      return uv.fs_stat(log) and read(log) ~= ''
    end, 'the browser command ran')
    T.eq(read(log), url, 'with the URL')
  end),

  case('a modified note is served from its buffer, until it is written, reverted or unloaded', function(T)
    local dir = project(T)
    local file = dir .. '/notes/a.html'
    vim.cmd.edit(file)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'Before the preview.' })
    T.ok(P.start(), 'started')
    T.ok(not last_msg(T):find('write the buffer', 1, true), 'nothing to write: ' .. last_msg(T))
    local raw = function()
      return req(T, '/__tern/raw/notes/a.html').body
    end
    T.eq(raw(), NOTE .. 'Before the preview.\n', 'modified before :TernPreview: served at once')
    local es = events(T)
    local function typed(lines)
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    end
    local function event(n, what)
      T.wait(2000, function()
        return #es.events() >= n
      end, what)
      T.eq(es.events()[n], { { path = '/notes/a.html', note = true } }, what)
    end

    typed({ 'One.' })
    typed({ 'Two.' })
    event(1, 'one event for changes in a row')
    vim.wait(300)
    T.eq(#es.events(), 1, 'and no other')
    local text = NOTE .. 'Before the preview.\nOne.\nTwo.\n'
    T.eq(raw(), text, 'the raw note: the buffer')
    local page = req(T, '/notes/a.html').body
    T.ok(page:find('Two.', 1, true) and page:find('/__tern/live.js', 1, true), 'the page: the buffer, with the live script')
    T.eq(read(file), NOTE, 'the file is not touched')

    vim.cmd('silent edit!')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    event(2, 'reverted')
    T.eq(raw(), NOTE, 'reverted: the file')

    typed({ 'Three.' })
    event(3, 'changed again')
    vim.cmd('silent write')
    event(4, 'written')
    T.eq({ raw(), read(file) }, { NOTE .. 'Three.\n', NOTE .. 'Three.\n' }, 'written: the file')

    typed({ 'Four.' })
    event(5, 'changed again')
    vim.bo[buf].fileformat = 'dos'
    vim.bo[buf].fixeol, vim.bo[buf].eol = false, false
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    event(6, 'the file format')
    T.eq(raw(), (NOTE .. 'Three.\nFour.'):gsub('\n', '\r\n'), 'as :write would: CR LF, no final line break')
    vim.cmd('silent bwipeout!')
    event(7, 'unloaded')
    T.eq(raw(), NOTE .. 'Three.\n', 'unloaded: the file')

    -- Not a note: from disk, and nothing until it is written.
    vim.cmd.edit(dir .. '/style.css')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'p {}' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
    vim.wait(400)
    T.eq(#es.events(), 7, 'no event for CSS')
    T.eq(req(T, '/style.css').body, 'body { color: red }\n', 'CSS from disk')
    vim.cmd('silent! %bwipeout!')
    es.close()
  end),

  case('with preview.update write, only writes refresh the page', function(T)
    local dir = project(T)
    require('tern').setup({ lsp = false, render = { enabled = false }, preview = { open = false, update = 'write' } })
    vim.cmd.edit(dir .. '/notes/a.html')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'unsaved' })
    T.ok(P.start(), 'started')
    T.ok(last_msg(T):find('write the buffer', 1, true), 'unsaved: ' .. last_msg(T))
    local es = events(T)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
    vim.wait(400)
    T.eq({ #es.events(), req(T, '/__tern/raw/notes/a.html').body }, { 0, NOTE }, 'no event; the file')
    vim.cmd('silent write')
    T.wait(2000, function()
      return #es.events() == 1
    end, 'an event on write')
    vim.cmd('silent! %bwipeout!')
    es.close()
  end),

  case('stop closes the server and every connection', function(T)
    local dir = project(T)
    start(T, dir .. '/notes/a.html')
    local port = P.info().port
    local es = events(T)
    local idle = client(T, port, 'GET /style.css HTTP/1.1\r\n')
    T.eq(#vim.api.nvim_get_autocmds({ group = 'tern_preview', event = 'VimLeavePre' }), 1, 'stopped on VimLeavePre')
    P.stop()
    T.eq(last_msg(T), 'tern: preview stopped', 'the message')
    T.wait(2000, function()
      return es.eof and idle.eof
    end, 'every connection closed')
    es.close()
    idle.close()
    local after = client(T, port)
    T.ok(after.err, 'the port no longer listens')
    after.close()
    T.eq(P.info(), nil, 'no server')
    T.eq(pcall(vim.api.nvim_get_autocmds, { group = 'tern_preview' }), false, 'no autocommands')
    P.stop()
    T.eq(last_msg(T), 'tern: no preview is running', 'a second stop')
  end),

  browser_case('chromium'),
  browser_case('firefox'),
}
