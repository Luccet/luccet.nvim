-- SPDX-License-Identifier: MIT
-- doc/tern.txt against the code: its tags build, and it documents every
-- command, option and highlight group the plugin defines. :helptags runs on
-- a copy of doc/, so the checkout gets no doc/tags file.
local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('a')
  f:close()
  return text
end

local function doc(T)
  return read(T.root .. '/doc/tern.txt')
end

-- The tags :helptags builds from doc/tern.txt, as a set.
local function helptags(T)
  local dir = T.tmpdir()
  T.write(dir .. '/tern.txt', doc(T))
  local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(dir))
  T.ok(ok, ':helptags failed: ' .. tostring(err))
  local tags = {}
  for line in io.lines(dir .. '/tags') do
    tags[line:match('^[^\t]+')] = true
  end
  return tags
end

-- Whether text holds word, not as part of a longer name (ternMath is not
-- found in ternMathBlock).
local function has_word(text, word)
  return text:find('%f[%w_.]' .. vim.pesc(word) .. '%f[^%w_.]') ~= nil
end

-- Every option path in config.defaults, nested ones as `render.labels`. Read
-- from the source: an option whose default is nil (cmd) is not in the table.
local function option_paths(T)
  local block = read(T.root .. '/lua/tern/config.lua'):match('M%.defaults = (%b{})')
  T.ok(block, 'M.defaults in lua/tern/config.lua')
  local paths, stack = {}, {}
  for line in block:gmatch('[^\n]+') do
    local code = line:gsub('%s*%-%-.*$', '')
    local key, value = code:match('^%s*([%a_][%w_]*)%s*=%s*(.-),?$')
    if key then
      local path = table.concat(stack, '.') .. (#stack > 0 and '.' or '') .. key
      paths[#paths + 1] = path
      if value == '{' then
        stack[#stack + 1] = key
      end
    elseif code:match('^%s*},?$') then
      stack[#stack] = nil
    end
  end
  -- The parse finds every key the table has.
  local found = {}
  for _, p in ipairs(paths) do
    found[p] = true
  end
  local function walk(t, prefix)
    for k, v in pairs(t) do
      T.ok(found[prefix .. k], 'the parse of config.lua missed ' .. prefix .. k)
      if type(v) == 'table' then
        walk(v, prefix .. k .. '.')
      end
    end
  end
  walk(require('tern.config').defaults, '')
  return paths
end

return {
  { ':helptags builds the tags, none of them a duplicate', function(T)
    local text = doc(T)
    T.ok(text:find('^%*tern%.txt%*'), 'the first line starts with *tern.txt*')
    T.ok(text:find('\n%s*vim:tw=78:ts=8:ft=help:norl:%s*$'), 'the modeline ends the file')
    -- A tag defined twice fails :helptags (E154).
    local tags = helptags(T)
    -- A tag Neovim defines too is refused here: :help would find Neovim's.
    for line in io.lines(vim.env.VIMRUNTIME .. '/doc/tags') do
      local tag = line:match('^[^\t]+')
      T.ok(not tags[tag], 'tag also defined by Neovim: ' .. tag)
    end
    T.ok(tags['tern.txt'] and tags['tern'], 'the tags tern.txt and tern')
  end },

  { 'every command in plugin/tern.lua has a *:Name* tag', function(T)
    local tags = helptags(T)
    local names = {}
    for name in read(T.root .. '/plugin/tern.lua'):gmatch("cmd%('(%w+)'") do
      names[#names + 1] = name
      T.ok(tags[':' .. name], 'doc/tern.txt has no *:' .. name .. '*')
    end
    T.ok(#names >= 6, 'found the commands in plugin/tern.lua')
  end },

  { 'every option in config.defaults is documented', function(T)
    local text, tags = doc(T), helptags(T)
    local paths = option_paths(T)
    T.ok(vim.tbl_contains(paths, 'cmd') and vim.tbl_contains(paths, 'preview.browser'), 'options defaulting to nil')
    for _, path in ipairs(paths) do
      T.ok(has_word(text, path), 'doc/tern.txt does not name the option ' .. path)
      T.ok(tags['tern-option-' .. path], 'doc/tern.txt has no *tern-option-' .. path .. '*')
    end
  end },

  { 'every highlight group the code defines is documented', function(T)
    local text = doc(T)
    local groups = {}
    for _, file in ipairs(vim.fn.globpath(T.root .. '/lua', '**/*.lua', false, true)) do
      for group in read(file):gmatch("nvim_set_hl%(0, '([%w_]+)'") do
        groups[#groups + 1] = group
      end
    end
    T.ok(vim.tbl_contains(groups, 'TernVirtLabel'), 'found the TernVirt groups')
    local n = #groups
    for line in io.lines(T.root .. '/syntax/tern.vim') do
      local group = line:match('^hi def link (tern[%w_]+)') or line:match('^hi def (tern[%w_]+)')
      if group then
        groups[#groups + 1] = group
      end
    end
    T.ok(#groups - n >= 50, 'found the tern groups in syntax/tern.vim')
    for _, group in ipairs(groups) do
      T.ok(has_word(text, group), 'doc/tern.txt does not name the group ' .. group)
    end
  end },
}
