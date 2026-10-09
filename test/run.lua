-- SPDX-License-Identifier: MIT
-- The test runner, headless and without a user config:
--   nvim --headless -u NONE -l test/run.lua [FILTER]
-- Each test/*_test.lua returns a list of { name, fn }; fn gets the helpers
-- below and fails by raising an error. FILTER keeps the tests whose
-- "file: name" contains it. Exit status: 0 when all pass.
-- The Tern engine (for the language server) is $TERN_ROOT, else a checkout
-- next to this one: ../tern.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.opt.runtimepath:prepend(root)
vim.cmd('filetype plugin on')
vim.cmd('runtime plugin/tern.lua')

local T = {}
T.root = root

function T.tern_root()
  -- Not a list literal: an unset $TERN_ROOT would be a nil hole that ipairs stops at.
  for _, dir in ipairs({ vim.env.TERN_ROOT or false, root .. '/../tern' }) do
    if dir and vim.uv.fs_stat(dir .. '/tern-cli.js') then
      return vim.fs.normalize(vim.fn.fnamemodify(dir, ':p'))
    end
  end
end

function T.eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(('%s: expected %s, got %s'):format(what or 'value', vim.inspect(want), vim.inspect(got)), 2)
  end
end

function T.ok(v, what)
  if not v then
    error(what or 'expected a true value', 2)
  end
  return v
end

-- Waits up to ms for cond() to be true; fails with what otherwise.
function T.wait(ms, cond, what)
  if not vim.wait(ms, cond, 20) then
    error('timed out: ' .. (what or 'condition'), 2)
  end
end

-- A fresh temporary directory, removed at exit.
function T.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

-- Writes a file and returns its path.
function T.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
  return path
end

-- Closes every buffer and stops every language client between tests.
function T.reset()
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
  vim.cmd('silent! %bwipeout!')
end

local filter = arg[1]
local files = vim.fn.globpath(root .. '/test', '*_test.lua', false, true)
table.sort(files)
local passed, failed = 0, 0
for _, file in ipairs(files) do
  local name = vim.fn.fnamemodify(file, ':t:r')
  local ok, cases = pcall(dofile, file)
  if not ok then
    failed = failed + 1
    print(('✗ %s: cannot load: %s'):format(name, cases))
  else
    for _, case in ipairs(cases) do
      local id = name .. ': ' .. case[1]
      if not filter or id:find(filter, 1, true) then
        local ok2, err = xpcall(case[2], debug.traceback, T)
        pcall(T.reset)
        if ok2 then
          passed = passed + 1
          print('✓ ' .. id)
        else
          failed = failed + 1
          print('✗ ' .. id .. '\n    ' .. tostring(err):gsub('\n', '\n    '))
        end
      end
    end
  end
end
print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
