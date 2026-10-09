-- SPDX-License-Identifier: MIT
-- tern.tex, and tern.render's virtual text from synthetic outlines and from
-- the real server.
local api = vim.api

local function tex(s)
  return require('tern.tex').unicode(s)
end

-- The buffer's marks as { row, col, text, pos, hl } sorted by position.
local function marks(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, require('tern.render').ns, 0, -1, { details = true })) do
    local d = m[4]
    local text, hls = {}, {}
    for _, chunk in ipairs(d.virt_text or {}) do
      text[#text + 1] = chunk[1]
      hls[#hls + 1] = chunk[2]
    end
    out[#out + 1] = { m[2], m[3], table.concat(text), d.virt_text_pos, table.concat(hls, ',') }
  end
  return out
end

local function buffer(lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  return buf
end

local function empty()
  return { headings = {}, blocks = {}, refs = {}, math = {}, tables = {}, raw = {}, inline = {} }
end

-- Replaces tern.lsp.outline for the duration of fn.
local function with_outlines(outlines, fn)
  local lsp = require('tern.lsp')
  local saved = lsp.outline
  lsp.outline = function(buf)
    return outlines[buf]
  end
  local ok, err = pcall(fn)
  lsp.outline = saved
  if not ok then
    error(err, 0)
  end
end

local function fire(buf)
  api.nvim_exec_autocmds('User', { pattern = 'TernOutline', data = { buf = buf } })
end

-- A note with a numbered theorem, an equation with an id, a reference to
-- each, inline math, and an emoji so UTF-16 columns differ from bytes.
local LINES = {
  '<!doctype html><script src="tern.js"></script>', -- 1
  '# Notes', -- 2
  ':::theorem[Main]{#t1}', -- 3
  'By 😀 @t1 and $\\alpha^2$ and $x$ and $e^{x^2}$.', -- 4
  ':::', -- 5
  '$$', -- 6
  'x^2 + y^2 = z^2', -- 7
  '$$ {#eq}', -- 8
  'See @eq, @t1{ref=title}, @nowhere.', -- 9
  '{#t2}', -- 10
  ':::theorem', -- 11
  'Body.', -- 12
  ':::', -- 13
  '::figure[A *bold* cap]{#f1}', -- 14
}
local function outline()
  local o = empty()
  o.blocks = {
    { line = 3, endLine = 5, kind = 'container', name = 'theorem', id = 't1', title = 'Main', label = 'Theorem 1', colons = 3 },
    { line = 10, endLine = 13, kind = 'container', name = 'theorem', id = 't2', label = 'Theorem 2', colons = 3 },
    { line = 14, endLine = 14, kind = 'leaf', name = 'figure', id = 'f1', title = 'A bold cap', label = 'Figure 1' },
    { line = 12, endLine = 12, kind = 'leaf', name = 'aside' }, -- no label: nothing
  }
  o.refs = {
    { line = 4, col = 7, ['end'] = 10, id = 't1', text = 'Theorem 1', resolved = true },
    { line = 9, col = 5, ['end'] = 8, id = 'eq', text = '(1)', resolved = true },
    { line = 9, col = 10, ['end'] = 23, id = 't1', text = 'Main', resolved = true },
    { line = 9, col = 25, ['end'] = 33, id = 'nowhere', resolved = false },
  }
  o.math = {
    { line = 4, col = 15, endLine = 4, ['end'] = 25, display = false, tex = '\\alpha^2' },
    { line = 4, col = 30, endLine = 4, ['end'] = 33, display = false, tex = 'x' },
    { line = 4, col = 38, endLine = 4, ['end'] = 47, display = false, tex = 'e^{x^2}' },
    { line = 6, col = 1, endLine = 8, ['end'] = 9, display = true, number = '(1)', tex = 'x^2 + y^2 = z^2' },
  }
  return o
end

return {
  { 'tex: clean conversions', function(T)
    local cases = {
      ['\\alpha'] = 'α', ['x^2'] = 'x²', ['\\mathbb{R}'] = 'ℝ', ['\\mathbb R^n'] = 'ℝⁿ', ['\\to'] = '→',
      ['x_i'] = 'xᵢ', ['x_{ij}^{2}'] = 'xᵢⱼ²', ['x^{-1}'] = 'x⁻¹', ['A^T'] = 'Aᵀ', ['a_n'] = 'aₙ',
      ['x+y=1'] = 'x + y = 1', ['x = -1'] = 'x = −1', ['\\forall x\\in A'] = '∀x ∈ A',
      ['\\forall x \\in A'] = '∀x ∈ A', ['f\\colon A\\to B'] = 'f: A → B',
      ['\\sum_{i=1}^n x_i'] = '∑ᵢ₌₁ⁿ xᵢ', ['\\int_0^1 f(x)\\,dx'] = '∫₀¹ f(x) dx',
      ['\\sin^2 x + \\cos^2 x = 1'] = 'sin² x + cos² x = 1', ['\\frac{1}{2}'] = '1/2',
      ['\\frac{a+b}{2}'] = '(a + b)/2', ['\\frac{a}{b}^2'] = '(a/b)²', ['\\sqrt{2}'] = '√2',
      ['\\sqrt{x^2+1}'] = '√(x² + 1)', ['\\sqrt[3]{x}'] = '∛x', ["f'(x)"] = 'f′(x)', ["f'^2"] = 'f′²',
      ['\\hat{x}'] = 'x̂', ['\\bar{x}_1'] = 'x̄₁', ['\\vec v'] = 'v⃗', ['\\text{if } x > 0'] = 'if x > 0',
      ['\\mathcal{O}(n \\log n)'] = '𝒪(n log n)', ['\\mathfrak{g}'] = '𝔤', ['\\mathbf{v}'] = '𝐯',
      ['\\operatorname{rank} A'] = 'rank A', ['\\{x \\mid x > 0\\}'] = '{x ∣ x > 0}',
      ['\\left( \\frac{a}{b} \\right)^2'] = '(a/b)²', ['\\left\\| x \\right\\|'] = '‖x‖',
      ['a \\equiv b \\pmod{n}'] = 'a ≡ b (mod n)', ['\\not\\in'] = '∉', ['\\not='] = '≠',
      ['{}^{14}C'] = '¹⁴C', ['90^\\circ'] = '90°', ['2\\pi r'] = '2πr', ['\\epsilon > 0'] = 'ϵ > 0',
      ['\\displaystyle\\sum_k k'] = '∑ₖ k', ['\\mathrm{d}x'] = 'dx', ['x\ny'] = 'xy',
      ['\\dim V = \\dim \\ker T + \\dim \\operatorname{im} T.'] = 'dim V = dim ker T + dim im T.',
    }
    for src, want in pairs(cases) do
      T.eq(tex(src), want, src)
    end
  end },

  { 'tex: nil when any part has no Unicode form', function(T)
    for _, src in ipairs({
      'e^{i\\pi}', -- no superscript π
      'x^q', -- no superscript q
      'e^{x^2}', -- a script in a script
      '\\lim_{n\\to\\infty} a_n', -- no subscript arrow
      '\\begin{pmatrix} a \\end{pmatrix}', 'a \\\\ b', 'a & b', '\\binom{n}{k}',
      '\\foo', '\\mathbb{1}', '\\mathbb{x}', '\\hat{xy}', '\\sqrt[5]{x}', '\\tag{1}', '\\label{x}',
      '\\color{red}{x}', 'x % comment', '\\text{\\alpha}',
    }) do
      T.eq(tex(src), nil, src)
    end
  end },

  { 'tex: malformed and empty input', function(T)
    for _, src in ipairs({ '', '   ', '\\,', '\\quad', 'x^', 'x_', '{', '}', '{x', 'x}', '\\', '\\frac{1}',
      '\\sqrt', 'x^{2}^{3}', 'x_1_2', "x^2'", '\\left', '\\left x', '\\not', '\\text', '\\text{a' }) do
      T.eq(tex(src), nil, vim.inspect(src))
    end
    T.eq(tex(nil), nil, 'nil')
    T.eq(tex(42), nil, 'a number')
    T.eq(tex(('{'):rep(5000) .. 'x' .. ('}'):rep(5000)), 'x', 'deep nesting')
    T.eq(tex(('{'):rep(100000) .. 'x' .. ('}'):rep(100000)) ~= false, true, 'very deep nesting does not throw')
    local long = ('x + '):rep(5000) .. 'y'
    T.eq(#tex(long), #long, 'a long formula')
    T.eq(tex('é + 1'), 'é + 1', 'other characters pass through')
  end },

  { 'labels, refs and math from an outline', function(T)
    local buf = buffer(LINES)
    require('tern.render').draw(buf, outline())
    T.eq(marks(buf), {
      { 2, 0, 'Theorem 1', 'eol', 'TernVirtLabel' }, -- the title is on the line
      { 3, 11, ' Theorem 1', 'inline', 'TernVirtRef' }, -- after "@t1", past the 4-byte emoji
      { 3, 26, ' α²', 'inline', 'TernVirtMath' }, -- after "$\alpha^2$"; $x$ and $e^{x^2}$ get nothing
      { 7, 0, 'x² + y² = z²  (1)', 'eol', 'TernVirtMath,TernVirtLabel' }, -- the closing line
      { 8, 7, ' (1)', 'inline', 'TernVirtRef' },
      { 8, 22, ' Main', 'inline', 'TernVirtRef' }, -- after the whole reference, {ref=title} included
      { 10, 0, 'Theorem 2', 'eol', 'TernVirtLabel' }, -- the opener after its attribute line
      { 13, 0, 'Figure 1', 'eol', 'TernVirtLabel' }, -- "A *bold* cap" shows the title
    }, 'marks')
  end },

  { 'a title not on the opener line follows an em dash', function(T)
    local buf = buffer({ ':::theorem{#t}', 'x', ':::' })
    local o = empty()
    o.blocks = { { line = 1, endLine = 3, kind = 'container', name = 'theorem', title = 'Zorn', label = 'Lemma 4', colons = 3 } }
    require('tern.render').draw(buf, o)
    T.eq(marks(buf), { { 0, 0, 'Lemma 4 — Zorn', 'eol', 'TernVirtLabel' } })
  end },

  { 'each kind follows its options.render flag', function(T)
    local buf = buffer(LINES)
    local render = require('tern.render')
    local function kinds()
      local seen = {}
      for _, m in ipairs(marks(buf)) do
        for hl in m[5]:gmatch('[^,]+') do
          seen[hl] = true
        end
      end
      return seen
    end
    require('tern').setup({ render = { labels = false } })
    render.draw(buf, outline())
    T.eq(kinds(), { TernVirtRef = true, TernVirtMath = true, TernVirtLabel = true }, 'the equation number stays with math')
    T.ok(not vim.iter(marks(buf)):any(function(m)
      return m[3]:find('Theorem 1', 1, true) and m[4] == 'eol'
    end), 'no block label')
    require('tern').setup({ render = { refs = false, math = false } })
    render.draw(buf, outline())
    T.eq(kinds(), { TernVirtLabel = true }, 'labels only')
    require('tern').setup()
  end },

  { 'a stale outline draws no errors and drops what no longer matches', function(T)
    local buf = buffer(LINES)
    local render = require('tern.render')
    -- Lines deleted, a line shortened, columns past the end, lines past the end.
    api.nvim_buf_set_lines(buf, 1, 2, false, {})
    api.nvim_buf_set_lines(buf, 7, 8, false, { 'See @' })
    local o = outline()
    o.refs[#o.refs + 1] = { line = 40, col = 1, ['end'] = 4, id = 'x', text = 'X', resolved = true }
    o.refs[#o.refs + 1] = { line = 1, col = 400, ['end'] = 404, id = 'x', text = 'X', resolved = true }
    o.math[#o.math + 1] = { line = 50, col = 1, endLine = 52, ['end'] = 3, display = true, number = '(9)', tex = 'x' }
    o.math[#o.math + 1] = { line = 3, col = 0, endLine = 3, ['end'] = -2, display = false, tex = '\\alpha' }
    o.blocks[#o.blocks + 1] = { line = 99, endLine = 120, name = 'theorem', label = 'Theorem 9', colons = 3 }
    render.draw(buf, o)
    -- The text moved up a line: the refs and inline math on old line 4 now
    -- point at line 4 = old line 5 (":::"), so they are dropped.
    for _, m in ipairs(marks(buf)) do
      T.ok(m[3] ~= ' Theorem 1' and m[3] ~= ' α²' and m[3] ~= ' (1)' and m[3] ~= ' X', 'dropped: ' .. vim.inspect(m))
    end
    render.draw(buf, { blocks = 'junk', refs = { {} }, math = { { display = true } } })
    T.eq(marks(buf), {}, 'malformed entries are skipped')
  end },

  { 'TernOutline redraws; an outline older than the buffer is skipped', function(T)
    local buf = buffer(LINES)
    local render = require('tern.render')
    local outlines = {}
    with_outlines(outlines, function()
      render.attach(buf)
      T.eq(marks(buf), {}, 'no outline yet')
      outlines[buf] = outline()
      fire(buf)
      T.eq(#marks(buf), 8, 'drawn on the event')
      -- The buffer is at version 5 (as the LSP client counts); an outline of
      -- version 4 lags it, so the marks drawn before stay.
      vim.lsp.util.buf_versions[buf] = 5
      local o = empty()
      o.version = 4
      outlines[buf] = o
      fire(buf)
      T.eq(#marks(buf), 8, 'stale: kept')
      o.version = 5
      fire(buf)
      T.eq(#marks(buf), 0, 'current: redrawn')
      vim.lsp.util.buf_versions[buf] = nil
      fire(api.nvim_create_buf(false, true)) -- another buffer's event changes nothing here
    end)
  end },

  { ':TernRender on, off and toggle, per buffer', function(T)
    local buf = buffer(LINES)
    local other = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(other, 0, -1, false, LINES)
    local render = require('tern.render')
    with_outlines({ [buf] = outline(), [other] = outline() }, function()
      render.attach(buf)
      render.attach(other)
      T.eq(#marks(buf), 8, 'attached')
      vim.cmd('TernRender off')
      T.eq(#marks(buf), 0, 'off')
      T.ok(not render.enabled(buf), 'disabled')
      T.eq(#marks(other), 8, 'the other buffer keeps its marks')
      fire(buf)
      T.eq(#marks(buf), 0, 'an outline does not redraw while off')
      vim.cmd('TernRender')
      T.eq(#marks(buf), 8, 'toggle: on')
      vim.cmd('TernRender toggle')
      T.eq(#marks(buf), 0, 'toggle: off')
      vim.cmd('TernRender on')
      T.eq(#marks(buf), 8, 'on')
      local errors = {}
      local notify = vim.notify
      vim.notify = function(msg)
        errors[#errors + 1] = msg
      end
      vim.cmd('TernRender sideways')
      vim.notify = notify
      T.eq(#errors, 1, 'a bad argument is reported')
      T.eq(#marks(buf), 8, 'and changes nothing')
    end)
  end },

  { 'highlights link by default and survive a colorscheme', function(T)
    require('tern.render').attach(buffer({ 'x' }))
    for _, name in ipairs({ 'TernVirtLabel', 'TernVirtRef', 'TernVirtMath' }) do
      T.ok(api.nvim_get_hl(0, { name = name }).link, name .. ' is linked')
    end
    api.nvim_set_hl(0, 'TernVirtRef', { link = 'Title' })
    vim.cmd('doautocmd ColorScheme')
    T.eq(api.nvim_get_hl(0, { name = 'TernVirtRef' }).link, 'Title', 'a user link wins (default = true)')
    vim.cmd('highlight clear')
    vim.cmd('doautocmd ColorScheme')
    T.ok(api.nvim_get_hl(0, { name = 'TernVirtLabel' }).link, 'redefined after :highlight clear')
  end },

  { 'a 3,000-line note draws quickly', function(T)
    local lines, o = {}, empty()
    for i = 1, 3000, 3 do
      lines[i] = (':::theorem[T%d]{#t%d}'):format(i, i)
      lines[i + 1] = ('By é @t%d, $\\alpha_%d^2 + \\beta$ and $x^{%d}$.'):format(i, i % 10, i % 10)
      lines[i + 2] = ':::'
      o.blocks[#o.blocks + 1] = { line = i, endLine = i + 2, name = 'theorem', title = 'T' .. i, label = 'Theorem ' .. i, colons = 3 }
      local id = 't' .. i
      o.refs[#o.refs + 1] = { line = i + 1, col = 6, ['end'] = 7 + #id, id = id, text = 'Theorem ' .. i, resolved = true }
      local m = lines[i + 1]:find('$', 1, true)
      local c = vim.str_utfindex(lines[i + 1], 'utf-16', m - 1)
      local tex1 = ('\\alpha_%d^2 + \\beta'):format(i % 10)
      o.math[#o.math + 1] = { line = i + 1, col = c + 1, endLine = i + 1, ['end'] = c + 3 + #tex1, display = false, tex = tex1 }
    end
    local buf = buffer(lines)
    local render = require('tern.render')
    render.draw(buf, o) -- warm the TeX cache as a real session would
    local t0 = vim.uv.hrtime()
    render.draw(buf, o)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    T.eq(#marks(buf), 3000, 'every mark')
    T.ok(ms < 150, ('drew in %.1f ms'):format(ms))
  end },

  { 'end to end: the server\'s outline draws the label, the refs and the equation number', function(T)
    local root = T.tern_root()
    if not root or vim.fn.executable('node') == 0 then
      print('    (skipped: no Tern checkout or no node)')
      return
    end
    local dir = T.tmpdir()
    local file = T.write(dir .. '/note.html', table.concat({
      '<!doctype html><meta charset="utf-8"><script>window.TERN = { schema: { block: { theorem: '
        .. '{ tag: \'section\', counter: \'theorem\', label: (n) => `Theorem ${n}` } } } };</script>'
        .. '<script src="tern.js"></script>',
      '# End to end', -- row 1
      '',
      ':::theorem[Main]{#t1}', -- row 3
      'Every 😀 $\\alpha^2 \\ge 0$.', -- row 4
      ':::',
      '',
      '$$',
      'x^2 + y^2 = z^2',
      '$$ {#eq}', -- row 9
      '',
      'See @t1 and @eq.', -- row 11
      '',
    }, '\n'))
    require('tern').setup({ cmd = { 'node', root .. '/tern-cli.js', 'lsp' } })
    local ok, err = pcall(function()
      vim.cmd.edit(file)
      local buf = api.nvim_get_current_buf()
      T.eq(vim.bo[buf].filetype, 'tern', 'filetype')
      local function find(row, text)
        for _, m in ipairs(marks(buf)) do
          if m[1] == row and m[3] == text then
            return m
          end
        end
      end
      T.wait(15000, function()
        return find(9, 'x² + y² = z²  (1)') ~= nil
      end, 'the equation number from the server')
      T.ok(find(3, 'Theorem 1'), 'the label on the opener: ' .. vim.inspect(marks(buf)))
      T.eq((find(11, ' Theorem 1') or {})[2], #'See @t1', 'the ref text, after @t1')
      T.eq((find(11, ' (1)') or {})[2], #'See @t1 and @eq', 'the equation\'s number, after @eq')
      T.eq((find(4, ' α² ≥ 0') or {})[2], #'Every 😀 $\\alpha^2 \\ge 0$', 'inline math, after the formula')
      -- Typing: each change makes the last outline stale until the server's
      -- next one. A line above moves every mark; @t1 becomes @t9, unresolved.
      api.nvim_buf_set_lines(buf, 2, 2, false, { 'Inserted $\\beta$.' })
      api.nvim_buf_set_lines(buf, 12, 13, false, { 'See @t9 and @eq.' })
      T.wait(15000, function()
        return find(12, ' (1)') and not find(12, ' Theorem 1') and find(2, ' β')
      end, 'redrawn after the edits: ' .. vim.inspect(marks(buf)))
      T.ok(find(4, 'Theorem 1') and find(10, 'x² + y² = z²  (1)'), 'the label and the number moved down')
    end)
    require('tern').setup()
    if not ok then
      error(err, 0)
    end
  end },
}
