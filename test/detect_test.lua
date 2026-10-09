-- SPDX-License-Identifier: MIT
-- tern.detect against the engine's detection fixtures. A copy lives in
-- test/fixtures/detect.json; when the engine is next to this checkout, the
-- copy must equal its test/fixtures/detect.json.
local function fixtures(T)
  local f = assert(io.open(T.root .. '/test/fixtures/detect.json'))
  local text = f:read('a')
  f:close()
  return vim.json.decode(text), text
end

return {
  { 'the fixture copy equals the engine\'s', function(T)
    local engine = T.tern_root()
    if not engine then
      print('    (skipped: no Tern checkout; set $TERN_ROOT)')
      return
    end
    local _, copy = fixtures(T)
    local f = assert(io.open(engine .. '/test/fixtures/detect.json'))
    local theirs = f:read('a')
    f:close()
    T.ok(copy == theirs, 'test/fixtures/detect.json is out of date: copy it from ' .. engine)
  end },
  { 'every line the engine detects, with its tag', function(T)
    local d = require('tern.detect')
    for _, case in ipairs(fixtures(T).match) do
      local got = d.line(case.line)
      T.ok(got, 'detects: ' .. case.why .. ': ' .. case.line)
      T.eq(got.tag, case.tag, case.why)
    end
  end },
  { 'no line the engine refuses', function(T)
    local d = require('tern.detect')
    for _, case in ipairs(fixtures(T).noMatch) do
      T.ok(not d.line(case.line), 'refuses: ' .. case.why .. ': ' .. case.line)
    end
  end },
  { 'a note buffer gets the filetype tern, other HTML keeps html', function(T)
    local dir = T.tmpdir()
    vim.cmd.edit(T.write(dir .. '/note.html', '<!doctype html><meta charset="utf-8"><script src="tern.js"></script>\n# Hi\n'))
    T.eq(vim.bo.filetype, 'tern', 'note.html')
    vim.cmd.edit(T.write(dir .. '/page.html', '<!doctype html><title>x</title><script src="app.js"></script>\n'))
    T.eq(vim.bo.filetype, 'html', 'page.html')
  end },
}
