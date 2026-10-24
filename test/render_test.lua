-- SPDX-License-Identifier: MIT
-- luccet.tex, and luccet.render's virtual text from synthetic outlines and from
-- the real server.
local api = vim.api

local function tex(s)
  return require('luccet.tex').unicode(s)
end

-- The buffer's virtual text as { row, col, text, pos, hl } sorted by position.
local function marks(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, require('luccet.render').ns, 0, -1, { details = true })) do
    local d = m[4]
    local text, hls = {}, {}
    for _, chunk in ipairs(d.virt_text or {}) do
      text[#text + 1] = chunk[1]
      hls[#hls + 1] = chunk[2]
    end
    if d.virt_text then
      out[#out + 1] = { m[2], m[3], table.concat(text), d.virt_text_pos, table.concat(hls, ',') }
    end
  end
  return out
end

-- The buffer's concealed ranges as { row, col, end_row, end_col }.
local function concealed(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, require('luccet.render').ns, 0, -1, { details = true })) do
    if m[4].conceal then
      out[#out + 1] = { m[2], m[3], m[4].end_row, m[4].end_col }
    end
  end
  return out
end

-- The buffer's tinted rows as { row, end_row }.
local function tinted(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, require('luccet.render').ns, 0, -1, { details = true })) do
    if m[4].line_hl_group then
      out[#out + 1] = { m[2], m[4].end_row, m[4].line_hl_group }
    end
  end
  return out
end

-- The buffer's highlighted ranges as { row, col, end_col, hl_group }.
local function highlighted(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, require('luccet.render').ns, 0, -1, { details = true })) do
    if m[4].hl_group and not m[4].virt_text then
      out[#out + 1] = { m[2], m[3], m[4].end_col, m[4].hl_group }
    end
  end
  return out
end

-- Moves the cursor and runs the autocommands the main loop would.
local function go(row)
  api.nvim_win_set_cursor(0, { row, 0 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_get_current_buf() })
end

-- A buffer in the current window, whose conceal options are the defaults.
local function buffer(lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  vim.wo.conceallevel = 0
  vim.wo.concealcursor = ''
  return buf
end

local function empty()
  return { headings = {}, blocks = {}, refs = {}, math = {}, tables = {}, raw = {}, inline = {} }
end

-- Replaces luccet.lsp.outline for the duration of fn.
local function with_outlines(outlines, fn)
  local lsp = require('luccet.lsp')
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
  api.nvim_exec_autocmds('User', { pattern = 'LuccetOutline', data = { buf = buf } })
end

-- A note with a numbered theorem, an equation with an id, a reference to
-- each, inline math, and an emoji so UTF-16 columns differ from bytes.
local LINES = {
  '<!doctype html><script src="luccet.js"></script>', -- 1
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

  { 'tex: aligned environments line by line', function(T)
    local function lines(t)
      return require('luccet.tex').lines(t)
    end
    local cases = {
      { { '\\begin{align}', 'a &= b + c \\\\', '  &= d', '\\end{align}' }, { '', 'a = b + c', '  = d', '' } },
      { { '\\begin{aligned}[t]', 'x &= 1 & y &= 2 \\\\', 'xx &= 3 & y &= 44', '\\end{aligned}' },
        { '', ' x = 1    y = 2', 'xx = 3    y = 44', '' } },
      { { '\\begin{alignat}{2}', 'a &= b &\\quad c &= d', '\\end{alignat}' }, { '', 'a = b  c = d', '' } },
      { { '\\begin{gather*}', 'a = b \\\\[2pt]', 'c', '\\end{gather*}' }, { '', 'a = b', '  c', '' } },
      { { '\\begin{equation}', 'x^2', '\\end{equation}' }, { '', 'x²', '' } },
      { { '\\begin{equation}', '\\begin{split}', 'f(x) &= x^2 \\nonumber \\\\', '&\\le 1 \\\\', '\\end{split}', '\\end{equation}' },
        { '', '', 'f(x) = x²', '     ≤ 1', '', '' } },
      { { '  \\begin{align*}  ', 'a & \\\\', '\\end{align*}' }, { '', 'a', '' } },
      { { '\\alpha' }, { 'α' } },
    }
    for _, c in ipairs(cases) do
      T.eq(lines(c[1]), c[2], table.concat(c[1], ' | '))
    end
    for _, t in ipairs({
      { '\\begin{align}', 'a &= b \\\\ c &= d', '\\end{align}' }, -- two rows on a line
      { '\\begin{align}', 'a &= b', '+ c \\\\', 'd &= e', '\\end{align}' }, -- a row over two lines
      { 'x = \\begin{align}', 'a &= b', '\\end{align}' }, { '\\begin{align}', 'a &= b', '\\end{align} + c' },
      { '\\begin{gather}', 'a & b', '\\end{gather}' }, { '\\begin{equation}', 'a \\\\', '\\end{equation}' },
      { '\\begin{equation}', 'a', 'b', '\\end{equation}' }, { '\\begin{align}', 'a &= b', '\\end{aligned}' },
      { '\\begin{align}', 'e^{i\\pi} &= -1', '\\end{align}' }, { '\\begin{align}', 'a &= b \\tag{1}', '\\end{align}' },
      { '\\begin{aligned}[t', 'a', '\\end{aligned}' }, { '\\begin{alignat}', 'a', '\\end{alignat}' },
      { '\\begin{align} a &= b', '\\end{align}' }, { '\\begin{align}', '\\end{align}' },
      { '\\begin{align}', 'a &= b % note', '\\end{align}' }, { '\\begin{align}', '', '\\end{align}' },
      { '\\begin{align}', '\\text{a\\\\b}', '\\end{align}' }, { 'a +', 'b' }, { '\\pi^q' }, {},
    }) do
      T.eq(lines(t), nil, table.concat(t, ' | '))
    end
    T.eq(lines('x'), nil, 'a string')
  end },

  { 'tex: cases and matrices line by line, their delimiters as tall as their rows', function(T)
    local function lines(t)
      return require('luccet.tex').lines(t)
    end
    local cases = {
      { { 'f(x) = \\begin{cases}', '  1 & x > 0 \\\\', '  0 & x = 0 \\\\', '  -1 & x < 0', '\\end{cases}' },
        { '', '       ⎧ 1   x > 0', 'f(x) = ⎨ 0   x = 0', '       ⎩ −1  x < 0', '' } },
      -- An even number of rows: the brace starts on the \begin line.
      { { '\\begin{cases}', 'x^2 & x \\ge 0 \\\\', '0 & \\text{otherwise}', '\\end{cases}.' },
        { '⎧', '⎨ x²  x ≥ 0     .', '⎩ 0   otherwise', '' } }, -- the period after the widest row
      { { '\\begin{cases}', 'a & 1 \\\\', 'b & 2 \\\\', 'c & 3 \\\\', 'd & 4', '\\end{cases}' },
        { '⎧', '⎪ a  1', '⎨ b  2', '⎪ c  3', '⎩ d  4', '' } },
      { { 'x = \\begin{cases}', '1 & \\text{if } y \\in \\mathbb{Q}', '\\end{cases}' }, { '', 'x = { 1  if y ∈ ℚ', '' } },
      { { '\\begin{dcases}', '\\frac{1}{n} & n > 0 \\\\[2pt]', '0 & \\text{else} \\\\', '\\end{dcases}' },
        { '⎧', '⎨ 1/n  n > 0', '⎩ 0    else', '' } },
      { { '\\begin{rcases}', 'a & b \\\\', 'c & d', '\\end{rcases} \\implies x' }, { '     ⎫', 'a  b ⎬ ⟹ x', 'c  d ⎭', '' } },
      { { 'A = \\begin{pmatrix}', 'a & b \\\\', 'c & d', '\\end{pmatrix}' }, { '', 'A = ⎛a  b⎞', '    ⎝c  d⎠', '' } },
      { { 'A = \\begin{pmatrix}', 'a \\\\', 'b', '\\end{pmatrix}, \\quad x' }, { '', 'A = ⎛a⎞,  x', '    ⎝b⎠', '' } }, -- no space before ,
      { { 'A = \\begin{bmatrix}', '1 & 0 & 0 \\\\', '0 & 1 & 0 \\\\', '0 & 0 & 10', '\\end{bmatrix}' },
        { '', '    ⎡1  0  0 ⎤', 'A = ⎢0  1  0 ⎥', '    ⎣0  0  10⎦', '' } },
      { { '\\begin{pmatrix}', '1 \\\\', '2 \\\\', '3', '\\end{pmatrix}' }, { '', '⎛1⎞', '⎜2⎟', '⎝3⎠', '' } },
      { { '\\begin{Bmatrix}', 'a \\\\', 'b', '\\end{Bmatrix}' }, { '⎧   ⎫', '⎨ a ⎬', '⎩ b ⎭', '' } },
      { { '\\det \\begin{vmatrix}', 'a & b \\\\', 'c & d', '\\end{vmatrix} = ad - bc' },
        { '', 'det │a  b│ = ad − bc', '    │c  d│', '' } },
      { { '\\begin{Vmatrix}', 'x', '\\end{Vmatrix}' }, { '', '‖x‖', '' } },
      { { '\\begin{matrix}', '\\alpha_1 & \\beta \\\\', 'x & y^2', '\\end{matrix}' }, { '', 'α₁  β', 'x   y²', '' } },
      { { '\\begin{smallmatrix}', 'a & b', '\\end{smallmatrix}' }, { '', 'a  b', '' } },
      { { '\\begin{pmatrix*}[r]', '-1 & 2 \\\\', '3 & -40', '\\end{pmatrix*}' }, { '', '⎛−1    2⎞', '⎝ 3  −40⎠', '' } },
      { { '\\begin{array}{rcl}', 'a & = & bbb \\\\', 'ccc & \\le & d', '\\end{array}' }, { '', '  a  =  bbb', 'ccc  ≤  d', '' } },
      { { 'f = \\left\\{ \\begin{array}{ll}', 'a & b \\\\', 'c & d', '\\end{array} \\right.' },
        { '    ⎧', 'f = ⎨ a  b', '    ⎩ c  d', '' } },
      { { '\\left\\lfloor \\begin{matrix}', 'a \\\\', 'b', '\\end{matrix} \\right\\rfloor' }, { '', '⎢a⎥', '⎣b⎦', '' } },
      { { '\\left\\langle \\begin{matrix}', 'a', '\\end{matrix} \\right\\rangle' }, { '', '⟨a⟩', '' } },
      { { 'x = \\begin{aligned}', 'a &= b \\\\', 'c &= d', '\\end{aligned}' }, { '', 'x = a = b', '    c = d', '' } },
      { { '\\begin{pmatrix}', ' & \\\\', ' & ', '\\end{pmatrix}' }, { '', '⎛  ⎞', '⎝  ⎠', '' } },
      { { '\\begin{equation}', 'f(x) = \\begin{cases}', '1 & x > 0 \\\\', '0', '\\end{cases}', '\\end{equation}' },
        { '', '       ⎧', 'f(x) = ⎨ 1  x > 0', '       ⎩ 0', '', '' } },
    }
    for _, c in ipairs(cases) do
      T.eq(lines(c[1]), c[2], table.concat(c[1], ' | '))
    end
    for _, t in ipairs({
      { '\\begin{pmatrix} a & b \\\\', 'c & d \\end{pmatrix}' }, -- rows on the \begin and \end lines
      { '\\begin{pmatrix}', 'a & b \\\\ c & d', '\\end{pmatrix}' }, -- two rows on a line
      { '\\begin{bmatrix}', 'e^{i\\pi} & 1', '\\end{bmatrix}' }, -- a cell without a Unicode form
      { '\\begin{cases}', 'a & b & c', '\\end{cases}' }, -- cases has two columns
      { '\\begin{array}{cc}', 'a & b & c', '\\end{array}' }, { '\\begin{array}{|c|}', 'a', '\\end{array}' },
      { '\\begin{array}', 'a', '\\end{array}' }, { '\\begin{pmatrix}[r]', 'a', '\\end{pmatrix}' },
      { '\\left( \\begin{pmatrix}', 'a', '\\end{pmatrix} \\right)' }, -- delimiters twice
      { '\\left( \\begin{array}{c}', 'a', '\\end{array}' }, { '\\begin{array}{c}', 'a', '\\end{array} \\right)' },
      { '\\left\\langle \\begin{matrix}', 'a \\\\', 'b', '\\end{matrix} \\right\\rangle' }, -- no tall ⟨
      { '\\begin{pmatrix}', '\\begin{matrix} a \\end{matrix} & b', '\\end{pmatrix}' },
      { '\\begin{cases}', '\\end{cases}' }, { '\\begin{matrix}', ' & \\\\', ' & ', '\\end{matrix}' },
      { '\\begin{pmatrix}', 'a \\\\', '\\hline', 'b', '\\end{pmatrix}' }, { 'a & \\begin{cases}', 'b', '\\end{cases}' },
    }) do
      T.eq(lines(t), nil, table.concat(t, ' | '))
    end
  end },

  { 'tex: macros are read from their definitions and expanded', function(T)
    local tex = require('luccet.tex')
    local m = tex.macros(table.concat({
      '\\gdef\\R{\\mathbb{R}}',
      '\\gdef\\norm#1{\\lVert #1 \\rVert}',
      '% \\gdef\\commented{x}',
      '\\newcommand{\\RR}{\\mathbb{R}}',
      '\\newcommand*\\pair[2]{(#1, #2)}',
      '\\def\\im{\\mathrm{img}}',
      '\\renewcommand{\\im}{\\operatorname{im}}',
      '\\providecommand{\\R}{\\text{not this}}',
      '\\newcommand{\\opt}[2][x]{#1 #2}', -- a default argument: skipped
      '\\def\\upto#1.{#1}', -- a delimited parameter: skipped
      '\\let\\eps=\\varepsilon',
      '\\let\\Reals\\R',
      '\\global\\def\\set#1{\\{\\, #1 \\,\\}}',
      '\\edef\\RN{\\R^n}',
      '\\def\\loop{\\loop}',
    }, '\n'))
    local names = vim.tbl_keys(m)
    table.sort(names)
    T.eq(names, { '\\R', '\\RN', '\\RR', '\\Reals', '\\eps', '\\im', '\\loop', '\\norm', '\\pair', '\\set' }, 'the names')
    T.eq(m['\\norm'], { n = 1, body = '\\lVert #1 \\rVert' }, 'an argument')
    T.eq(m['\\R'].body, '\\mathbb{R}', '\\providecommand keeps a macro')
    T.eq(m['\\im'].body, '\\operatorname{im}', '\\renewcommand replaces one')
    T.eq(m['\\RN'].body, '\\mathbb{R}^n', '\\edef expands its body')
    local cases = {
      ['\\R^n'] = 'ℝⁿ', ['\\dim \\im T'] = 'dim im T', ['\\norm{x} \\ge 0'] = '‖x‖ ≥ 0', ['\\norm x'] = '‖x‖',
      ['\\pair{a}{b}'] = '(a, b)', ['\\pair ab'] = '(a, b)', ['\\set{x \\mid x > 0}'] = '{ x ∣ x > 0 }',
      ['\\Reals \\eps'] = 'ℝε', ['\\norm{x}a'] = '‖x‖a', ['\\RR \\to \\RN'] = 'ℝ → ℝⁿ',
    }
    for src, want in pairs(cases) do
      T.eq(tex.unicode(tex.expand(src, m)), want, src)
    end
    T.eq(tex.expand('\\norm{x}a', m), '\\lVert x \\rVert a', 'a control word kept from the letter after it')
    for _, src in ipairs({ '\\loop', '\\norm', '\\pair{a}', '\\norm}' }) do
      T.eq(tex.expand(src, m), nil, src .. ': no expansion')
    end
    T.eq(tex.expand('\\Ra + \\opt', m), '\\Ra + \\opt', 'what is not a macro stays')
    T.eq(tex.expand('\\R', nil), '\\R', 'no macros')
    T.eq(tex.expand(('\\twice'):rep(3), tex.macros('\\def\\twice{\\twice\\twice}')), nil, 'an expansion without end')
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
    require('luccet.render').draw(buf, outline())
    T.eq(marks(buf), {
      { 2, 0, 'Theorem 1', 'eol', 'LuccetVirtLabel' }, -- the title is on the line
      { 3, 11, ' Theorem 1', 'inline', 'LuccetVirtRef' }, -- after "@t1", past the 4-byte emoji
      { 3, 26, ' α²', 'inline', 'LuccetVirtMath' }, -- after "$\alpha^2$"; $x$ and $e^{x^2}$ get nothing
      { 7, 0, 'x² + y² = z²  (1)', 'eol', 'LuccetVirtMath,LuccetVirtLabel' }, -- the closing line
      { 8, 7, ' (1)', 'inline', 'LuccetVirtRef' },
      { 8, 22, ' Main', 'inline', 'LuccetVirtRef' }, -- after the whole reference, {ref=title} included
      { 10, 0, 'Theorem 2', 'eol', 'LuccetVirtLabel' }, -- the opener after its attribute line
      { 13, 0, 'Figure 1', 'eol', 'LuccetVirtLabel' }, -- "A *bold* cap" shows the title
    }, 'marks')
    T.eq(concealed(buf), {}, "'conceallevel' 0: every source shows")
  end },

  { 'inline math shows in place of its source, but on the cursor line', function(T)
    local buf = buffer(LINES)
    vim.wo.conceallevel = 2
    local render = require('luccet.render')
    local function row4()
      return vim.iter(marks(buf)):filter(function(m)
        return m[1] == 3 and m[5] == 'LuccetVirtMath'
      end):totable()
    end
    local hidden = { { 3, 26, 'α²', 'inline', 'LuccetVirtMath' }, { 3, 34, 'x', 'inline', 'LuccetVirtMath' } }
    local shown = { { 3, 26, ' α²', 'inline', 'LuccetVirtMath' } } -- $x$ reads the same as x
    with_outlines({ [buf] = outline() }, function()
      render.attach(buf)
      T.eq(row4(), hidden, 'the cursor elsewhere: in place of the source')
      T.eq(vim.tbl_filter(function(c)
        return c[1] == 3 or (c[1] >= 5 and c[1] <= 7)
      end, concealed(buf)), { { 3, 16, 3, 26 }, { 3, 31, 3, 34 }, { 5, 0, 5, 2 }, { 6, 0, 6, 15 }, { 7, 0, 7, 8 } },
        'the sources hidden, and the $$ of display math')
      go(4)
      T.eq(row4(), shown, 'the cursor on the line: after the source')
      go(9)
      T.eq(row4(), hidden, 'the cursor moved off')
      go(4)
      vim.wo.concealcursor = 'n'
      api.nvim_exec_autocmds('OptionSet', { pattern = 'concealcursor' })
      T.eq(row4(), hidden, "'concealcursor' hides the cursor line too")
      vim.wo.concealcursor = ''
      vim.wo.conceallevel = 0
      go(9)
      api.nvim_exec_autocmds('OptionSet', { pattern = 'conceallevel' })
      T.eq(row4(), shown, "'conceallevel' 0: every source shows")
      vim.wo.conceallevel = 2
      api.nvim_exec_autocmds('OptionSet', { pattern = 'conceallevel' })
      T.eq(row4(), hidden, "'conceallevel' 2 again")
      fire(buf)
      T.eq(row4(), hidden, 'a redraw keeps the state')
      go(4)
      fire(buf)
      T.eq(row4(), shown, 'and on the cursor line')
      require('luccet').setup({ render = { conceal = false } })
      go(9)
      fire(buf)
      T.eq(concealed(buf), {}, 'render.conceal off: nothing hidden')
      T.eq(row4(), shown, 'and the Unicode form after the source')
      require('luccet').setup()
    end)
  end },

  { 'display math shows in place of its source, but while the cursor is in it', function(T)
    local buf = buffer({
      'x', -- 1
      '$$', -- 2
      '\\alpha^2', -- 3
      '$$ {#eq}', -- 4
      '$$ x $$ {#e2}', -- 5: one line, and x reads the same as its source
      '  $$', -- 6
      '    \\beta + 1', -- 7: indented deeper than its $$
      '  $$', -- 8
      '$$ \\sum_i x_i', -- 9: TeX on two lines
      '+ y $$', -- 10
      '$$', -- 11
      'e^{i\\pi}', -- 12: no Unicode form
      '$$', -- 13
    })
    vim.wo.conceallevel = 2
    local o = empty()
    o.math = {
      { line = 2, col = 1, endLine = 4, ['end'] = 9, display = true, number = '(1)', tex = '\\alpha^2' },
      { line = 5, col = 1, endLine = 5, ['end'] = 14, display = true, number = '(2)', tex = 'x' },
      { line = 6, col = 3, endLine = 8, ['end'] = 5, display = true, tex = '  \\beta + 1' },
      { line = 9, col = 1, endLine = 10, ['end'] = 7, display = true, tex = '\\sum_i x_i\n+ y' },
      { line = 11, col = 1, endLine = 13, ['end'] = 3, display = true, tex = 'e^{i\\pi}' },
    }
    local render = require('luccet.render')
    local closed = {
      { 2, 8, 'α²', 'inline', 'LuccetVirtMath' }, -- in place of the TeX line
      { 3, 0, '(1)', 'eol', 'LuccetVirtLabel' }, -- the number stays on the closing line
      { 3, 8, '{#eq}', 'inline', 'LuccetVirtId' }, -- in place of "$$ {#eq}"
      { 4, 0, '(2)', 'eol', 'LuccetVirtLabel' },
      { 4, 7, 'x', 'inline', 'LuccetVirtMath' }, -- in place of "$$ x $$"
      { 4, 13, ' {#e2}', 'inline', 'LuccetVirtId' },
      { 6, 13, 'β + 1', 'inline', 'LuccetVirtMath' }, -- after the indentation
      { 9, 0, '∑ᵢ xᵢ + y', 'eol', 'LuccetVirtMath' }, -- two lines: at the end, as before
    }
    with_outlines({ [buf] = o }, function()
      render.attach(buf)
      T.eq(marks(buf), closed, 'the cursor elsewhere')
      local list = { { 5, 2, 5, 4 }, { 6, 2, 6, 13 }, { 7, 2, 7, 4 } } -- from the $$'s indentation
      local one = { { 4, 0, 4, 7 }, { 4, 7, 4, 13 } }
      T.eq(concealed(buf), vim.list_extend(vim.list_extend({ { 1, 0, 1, 2 }, { 2, 0, 2, 8 }, { 3, 0, 3, 8 } }, one), list),
        'the sources hidden: $$, the TeX, and "$$ {#eq}"')
      local open = vim.list_slice(closed, 4)
      table.insert(open, 1, { 3, 0, 'α²  (1)', 'eol', 'LuccetVirtMath,LuccetVirtLabel' })
      for _, line in ipairs({ 2, 3, 4 }) do
        go(line)
        T.eq(marks(buf), open, 'the cursor on line ' .. line .. ': the source, the Unicode form on the closing line')
        T.eq(concealed(buf), vim.list_extend(vim.deepcopy(one), list), 'the cursor on line ' .. line .. ': the whole block shows')
      end
      go(5)
      local shown = vim.deepcopy(closed)
      table.remove(shown, 6)
      table.remove(shown, 5) -- x adds nothing beside its source
      T.eq(marks(buf), shown, 'the one-line form shows its source; the block above hides again')
      go(1)
      T.eq(marks(buf), closed, 'all hidden')
      api.nvim_buf_set_lines(buf, 2, 3, false, { '\\alpha^3' })
      render.draw(buf, o)
      T.eq(marks(buf)[1], { 3, 0, 'α²  (1)', 'eol', 'LuccetVirtMath,LuccetVirtLabel' }, 'a TeX line that changed: at the end')
      require('luccet').setup({ render = { conceal = false } })
      api.nvim_buf_set_lines(buf, 2, 3, false, { '\\alpha^2' })
      render.draw(buf, o)
      T.eq(concealed(buf), {}, 'render.conceal off: nothing hidden')
      T.eq(marks(buf)[1], { 3, 0, 'α²  (1)', 'eol', 'LuccetVirtMath,LuccetVirtLabel' }, 'and the Unicode form at the end')
      require('luccet').setup()
    end)
  end },

  { 'an aligned environment shows row by row', function(T)
    local buf = buffer({
      'x', -- 1
      '> $$', -- 2
      '> \\begin{align}', -- 3
      '> f(x) &= x^2 + 1 \\\\', -- 4
      '>   &\\ge 1', -- 5
      '> \\end{align}', -- 6
      '> $$ {#eq}', -- 7
      '$$', -- 8
      '\\begin{cases}', -- 9
      'e^{i\\pi} & x > 0', -- 10: no Unicode form
      '\\end{cases}', -- 11
      '$$', -- 12
    })
    vim.wo.conceallevel = 2
    local o = empty()
    o.math = {
      { line = 2, col = 3, endLine = 7, ['end'] = 11, display = true, number = '(1)',
        tex = '\\begin{align}\nf(x) &= x^2 + 1 \\\\\n  &\\ge 1\n\\end{align}' },
      { line = 8, col = 1, endLine = 12, ['end'] = 3, display = true, tex = '\\begin{cases}\ne^{i\\pi} & x > 0\n\\end{cases}' },
    }
    local render = require('luccet.render')
    with_outlines({ [buf] = o }, function()
      render.attach(buf)
      T.eq(marks(buf), {
        { 3, 20, 'f(x) = x² + 1', 'inline', 'LuccetVirtMath' },
        { 4, 10, '     ≥ 1', 'inline', 'LuccetVirtMath' }, -- ≥ under =
        { 6, 0, '(1)', 'eol', 'LuccetVirtLabel' },
        { 6, 10, '{#eq}', 'inline', 'LuccetVirtId' },
      }, 'the rows, aligned at &')
      T.eq(concealed(buf), { { 1, 2, 1, 4 }, { 2, 2, 2, 15 }, { 3, 2, 3, 20 }, { 4, 2, 4, 10 }, { 5, 2, 5, 13 }, { 6, 2, 6, 10 } },
        'after the quote marks: $$, \\begin, the rows, \\end, "$$ {#eq}"')
      go(5)
      T.eq(marks(buf), { { 6, 0, '(1)', 'eol', 'LuccetVirtLabel' } }, 'the cursor in it: the source, and the number')
      T.eq(concealed(buf), {}, 'nothing hidden')
    end)
  end },

  { 'cases show in place with a brace as tall as their rows', function(T)
    local lines = {
      'x', -- 1
      '$$', -- 2
      'f(x) = \\begin{cases}', -- 3
      '  x^2 & x \\ge 0 \\\\', -- 4
      '  0 & \\text{otherwise}', -- 5
      '\\end{cases}', -- 6
      '$$ {#eq-f}', -- 7
    }
    local buf = buffer(lines)
    vim.wo.conceallevel = 2
    local o = empty()
    o.math = { { line = 2, col = 1, endLine = 7, ['end'] = 3, display = true, number = '(2)',
      tex = table.concat(lines, '\n', 3, 6) } }
    local render = require('luccet.render')
    with_outlines({ [buf] = o }, function()
      render.attach(buf)
      T.eq(marks(buf), {
        { 2, #lines[3], '       ⎧', 'inline', 'LuccetVirtMath' }, -- two rows: the brace starts on the \begin line
        { 3, #lines[4], 'f(x) = ⎨ x²  x ≥ 0', 'inline', 'LuccetVirtMath' },
        { 4, #lines[5], '       ⎩ 0   otherwise', 'inline', 'LuccetVirtMath' },
        { 6, 0, '(2)', 'eol', 'LuccetVirtLabel' },
        { 6, 10, '{#eq-f}', 'inline', 'LuccetVirtId' },
      }, 'the rows beside a brace, f(x) = on its middle')
      T.eq(#concealed(buf), 6, 'every line hidden: $$, \\begin, the rows, \\end, "$$ {#eq-f}"')
      go(4)
      T.eq(marks(buf), { { 6, 0, '(2)', 'eol', 'LuccetVirtLabel' } }, 'the cursor in it: the source')
    end)
  end },

  { 'inline elements show as their content, but on the cursor line', function(T)
    local lines = {
      'x', -- 1
      'Press :kbd[Ctrl]+:kbd[S] 😀 :abbr[HTML]{title="a b" #ab}.', -- 2
      'H :sub[2]O, x :sup[-1], :sup[*]{.c}, :q[so]{#q1} and :ruby[漢:rt[kan]].', -- 3
      'Empty :wbr[] and :term[]{#t}, :kbd[`]`].', -- 4
      'Multi :kbd[Ctrl', -- 5
      'S] and :kbd[a', -- 6
      'changed', -- 7
    }
    local buf = buffer(lines)
    vim.wo.conceallevel = 2
    -- The outline's entry for `text` on line l, in 1-based UTF-16 columns.
    local function at(l, text, name)
      local col = vim.str_utfindex(lines[l], 'utf-16', lines[l]:find(text, 1, true) - 1) + 1
      return { line = l, col = col, ['end'] = col + vim.str_utfindex(text, 'utf-16'), name = name }
    end
    local o = empty()
    o.inline = {
      at(2, ':kbd[Ctrl]', 'kbd'), at(2, ':kbd[S]', 'kbd'), at(2, ':abbr[HTML]{title="a b" #ab}', 'abbr'),
      at(3, ':sub[2]', 'sub'), at(3, ':sup[-1]', 'sup'), at(3, ':sup[*]{.c}', 'sup'), at(3, ':q[so]{#q1}', 'q'),
      at(3, ':ruby[漢:rt[kan]]', 'ruby'), at(3, ':rt[kan]', 'rt'),
      at(4, ':wbr[]', 'wbr'), at(4, ':term[]{#t}', 'term'), at(4, ':kbd[`]`]', 'kbd'),
      { line = 5, col = 7, ['end'] = 3, name = 'kbd' }, -- over two lines: the end is on the next
      at(6, ':kbd[a', 'kbd'), -- not closed there
      { line = 7, col = 1, ['end'] = 8, name = 'kbd' }, -- a line that changed
    }
    local render = require('luccet.render')
    with_outlines({ [buf] = o }, function()
      render.attach(buf)
      local abbr = #'Press :kbd[Ctrl]+:kbd[S] 😀 :abbr[HTML]'
      local closed = {
        { 1, abbr + #'{title="a b" #ab}', '{#ab}', 'inline', 'LuccetVirtId' },
        { 2, 9, '₂', 'inline', 'LuccetInline' },
        { 2, 22, '⁻¹', 'inline', 'LuccetInline' },
        { 2, 40, '“', 'inline', 'LuccetInline' }, -- q between quotes
        { 2, 48, '”{#q1}', 'inline', 'LuccetInline,LuccetVirtId' },
        { 3, 12, '⟨wbr⟩', 'inline', 'LuccetVirtName' }, -- no content: the name
        { 3, 28, '⟨term⟩{#t}', 'inline', 'LuccetVirtName,LuccetVirtId' },
      }
      T.eq(marks(buf), closed, 'the cursor elsewhere')
      T.eq(concealed(buf), {
        { 1, 6, 1, 11 }, { 1, 15, 1, 16 }, { 1, 17, 1, 22 }, { 1, 23, 1, 24 }, { 1, 30, 1, 36 }, { 1, 40, 1, abbr + 17 },
        { 2, 2, 2, 9 }, { 2, 14, 2, 22 }, { 2, 24, 2, 29 }, { 2, 30, 2, 35 }, { 2, 37, 2, 40 }, { 2, 42, 2, 48 },
        { 2, 53, 2, 59 }, { 2, 62, 2, 66 }, { 2, 69, 2, 70 }, { 2, 70, 2, 71 }, -- ruby and its rt
        { 3, 6, 3, 12 }, { 3, 17, 3, 28 }, { 3, 30, 3, 35 }, { 3, 38, 3, 39 },
      }, ':name[ and ]{…} hidden; sub, sup and empty ones whole')
      T.eq(highlighted(buf), {
        { 1, 11, 15, 'LuccetInlineCode' }, { 1, 22, 23, 'LuccetInlineCode' }, { 1, 36, 40, 'LuccetInline' },
        { 2, 29, 30, 'LuccetInline' }, { 2, 40, 42, 'LuccetInline' }, { 2, 59, 70, 'LuccetInline' }, { 2, 66, 69, 'LuccetInline' },
        { 3, 35, 38, 'LuccetInlineCode' },
      }, 'the content left to show, kbd as code; :sup[*] has no superscript: as an element')
      go(3)
      T.eq(marks(buf), { closed[1], closed[6], closed[7] }, 'the cursor on a line: its source')
      T.eq(#concealed(buf), 10, 'the other lines still hidden')
      require('luccet').setup({ render = { conceal = false } })
      render.draw(buf, o)
      T.eq({ marks(buf), concealed(buf), highlighted(buf) }, { {}, {}, {} }, 'render.conceal off: nothing')
      require('luccet').setup()
    end)
  end },

  { 'blocks show in place of their syntax, but on the cursor line', function(T)
    local buf = buffer({
      'x', -- 1
      '{#a1 .wide}', -- 2: an attribute line of the theorem
      '{.only-a-class}', -- 3
      ':::theorem[Main *idea*]{#t1 .big key=v}', -- 4
      'Body.', -- 5
      ':::', -- 6
      ':::proof', -- 7
      'Done.', -- 8
      ':::/proof', -- 9
      '> :::row{cols=2}', -- 10: no label, in a quote
      '> a', -- 11
      '> :::', -- 12
      '::figure[A *bold* cap]{#f1}', -- 13
      '::toc{depth=2}', -- 14: a leaf without a label
      ':::macros', -- 15: verbatim bodies
      '{#not-an-attribute-line}', -- 16
      ':::', -- 17
      ':::chart{raw #c}', -- 18
      ':::', -- 19: in the body
      ':::', -- 20
    })
    vim.wo.conceallevel = 2
    local o = empty()
    o.blocks = {
      { line = 2, endLine = 6, kind = 'container', name = 'theorem', id = 't1', title = 'Main idea', label = 'Theorem 1', colons = 3 },
      { line = 7, endLine = 9, kind = 'container', name = 'proof', label = 'Proof', colons = 3 },
      { line = 10, endLine = 12, kind = 'container', name = 'row', colons = 3 },
      { line = 13, endLine = 13, kind = 'leaf', name = 'figure', id = 'f1', title = 'A bold cap', label = 'Figure 1' },
      { line = 14, endLine = 14, kind = 'leaf', name = 'toc' },
      { line = 15, endLine = 17, kind = 'container', name = 'macros', colons = 3 },
      { line = 18, endLine = 20, kind = 'container', name = 'chart', id = 'c', colons = 3 },
    }
    local render = require('luccet.render')
    local hidden = {
      { 1, 11, '{#a1}', 'inline', 'LuccetVirtId' },
      { 3, 11, 'Theorem 1 ', 'inline', 'LuccetVirtLabel' }, -- before the title, which stays
      { 3, 39, ' {#t1}', 'inline', 'LuccetVirtId' }, -- the id of "{#t1 .big key=v}"
      { 6, 8, 'Proof', 'inline', 'LuccetVirtLabel' },
      { 9, 16, 'row', 'inline', 'LuccetVirtName' }, -- no label: the name
      { 12, 9, 'Figure 1 ', 'inline', 'LuccetVirtLabel' },
      { 12, 27, ' {#f1}', 'inline', 'LuccetVirtId' },
      { 13, 14, '⟨toc⟩', 'inline', 'LuccetVirtName' }, -- a leaf: what the page puts there
      { 14, 9, 'macros', 'inline', 'LuccetVirtVerbatim' },
      { 17, 16, 'chart {#c}', 'inline', 'LuccetVirtVerbatim,LuccetVirtId' },
    }
    local tints = { { 14, 16, 'LuccetVerbatim' }, { 17, 19, 'LuccetVerbatim' } } -- opener to closer
    with_outlines({ [buf] = o }, function()
      render.attach(buf)
      T.eq(marks(buf), hidden, 'the cursor elsewhere')
      T.eq(concealed(buf), {
        { 1, 0, 1, 11 }, { 2, 0, 2, 15 }, -- the attribute lines
        { 3, 0, 3, 11 }, { 3, 22, 3, 39 }, -- ":::theorem[" and "]{#t1 .big key=v}"
        { 5, 0, 5, 3 }, { 6, 0, 6, 8 }, { 8, 0, 8, 9 }, -- a closer, an opener, a named closer
        { 9, 2, 9, 16 }, { 11, 2, 11, 5 }, -- after the quote marks
        { 12, 0, 12, 9 }, { 12, 21, 12, 27 }, { 13, 0, 13, 14 },
        { 14, 0, 14, 9 }, { 16, 0, 16, 3 }, { 17, 0, 17, 16 }, { 19, 0, 19, 3 }, -- the bodies stay
      }, 'the syntax hidden')
      T.eq(tinted(buf), tints, 'the verbatim blocks tinted')
      go(4)
      local shown = vim.deepcopy(hidden)
      table.remove(shown, 3)
      shown[2] = { 3, 0, 'Theorem 1', 'eol', 'LuccetVirtLabel' } -- as without conceal
      T.eq(marks(buf), shown, 'the cursor on the opener: its source, and the label at the end')
      T.eq(#concealed(buf), 14, 'only that line shows: its two parts')
      go(6)
      T.eq(#concealed(buf), 15, 'the closer shows its source, the opener hides again')
      go(16)
      T.eq(tinted(buf), tints, 'the tint stays while the cursor is in a verbatim block')
      require('luccet').setup({ render = { labels = false } })
      go(1)
      fire(buf)
      T.eq(marks(buf)[2], { 3, 11, 'theorem ', 'inline', 'LuccetVirtName' }, 'render.labels off: the name')
      require('luccet').setup({ render = { conceal = false } })
      fire(buf)
      T.eq(concealed(buf), {}, 'render.conceal off: nothing hidden')
      T.eq(tinted(buf), {}, 'and nothing tinted')
      T.eq(marks(buf), {
        { 3, 0, 'Theorem 1', 'eol', 'LuccetVirtLabel' },
        { 6, 0, 'Proof', 'eol', 'LuccetVirtLabel' },
        { 12, 0, 'Figure 1', 'eol', 'LuccetVirtLabel' },
      }, 'and the labels at the end of the line')
      require('luccet').setup()
      -- The outline lags: the opener is no longer a theorem.
      api.nvim_buf_set_lines(buf, 3, 4, false, { 'Plain text.' })
      fire(buf)
      T.ok(not vim.iter(marks(buf)):any(function(m)
        return m[1] == 3
      end), 'nothing on a line that is no longer the opener')
    end)
  end },

  { 'the head stays folded, but while the cursor is in it', function(T)
    require('luccet').setup({ lsp = false })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(buf, 0, -1, false, {
      '<!doctype html>', '<script>window.LUCCET = {}</script>', '<script src="luccet.js"></script>', -- 1-3: the head
      '# A', 'x', 'y', '# B', 'z', -- 4-8
    })
    api.nvim_set_current_buf(buf)
    local fillchars = vim.go.fillchars
    local ok, err = pcall(function()
      vim.go.fillchars = 'eob: '
      vim.bo[buf].filetype = 'luccet' -- the ftplugin: folds by headings, and the virtual text
      T.eq({ vim.fn.foldclosed(1), vim.fn.foldclosedend(1) }, { 1, 3 }, 'folded when the note opens')
      T.eq(vim.fn.foldtextresult(1), '⟨head⟩ schema', 'its summary')
      T.eq(vim.wo.fillchars, 'eob: ,fold: ', 'spaces after it, not dots; the other fillchars kept')
      go(6)
      T.eq({ vim.fn.foldclosed(5), vim.fn.foldclosed(8) }, { -1, -1 }, 'the folds after the head stay open')
      go(4)
      vim.cmd('normal! k')
      api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
      T.eq(vim.fn.foldclosed(1), -1, 'up into the head: open')
      T.eq(vim.fn.line('.'), 3, 'on its last line')
      go(5)
      T.eq(vim.fn.foldclosed(1), 1, 'out of it: folded')
      go(2)
      T.eq({ vim.fn.foldclosed(1), vim.fn.line('.') }, { -1, 2 }, 'into it from afar: open, the cursor where it went')
      go(6)
      vim.cmd('LuccetRender off')
      T.eq(vim.fn.foldclosed(1), -1, ':LuccetRender off: open')
      go(1)
      go(6)
      T.eq(vim.fn.foldclosed(1), -1, 'and it stays open')
      vim.cmd('LuccetRender on')
      T.eq(vim.fn.foldclosed(1), 1, ':LuccetRender on: folded again')
      T.eq(vim.fn.foldclosed(5), -1, 'and only the head')
      -- A fold character of your own stays.
      vim.go.fillchars = 'fold:-'
      local other = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(other, 0, -1, false, api.nvim_buf_get_lines(buf, 0, -1, false))
      api.nvim_set_current_buf(other)
      vim.bo[other].filetype = 'luccet'
      T.eq(vim.wo.fillchars, 'fold:-', 'your fold character')
    end)
    vim.go.fillchars = fillchars
    require('luccet').setup()
    if not ok then
      error(err, 0)
    end
  end },

  { 'without the plugin\'s folds, a one-line head is drawn in place', function(T)
    local line = '<!doctype html><title>T</title><script src="luccet.js"></script>'
    local buf = buffer({ line, '# x', 'y' })
    vim.wo.conceallevel = 2
    api.nvim_win_set_cursor(0, { 3, 0 })
    local render = require('luccet.render')
    render.draw(buf, empty())
    T.eq(concealed(buf), {}, 'with them, the fold does it')
    require('luccet').setup({ fold = false })
    render.draw(buf, empty())
    require('luccet').setup()
    T.eq(marks(buf), { { 0, #line, '⟨head⟩ T', 'inline', 'LuccetVirtVerbatim,LuccetVirtName' } }, 'the summary')
    T.eq(concealed(buf), { { 0, 0, 0, #line } }, 'in place of the line')
  end },

  { '<style> and <script> blocks read as code', function(T)
    local buf = buffer({
      'x', -- 1
      '<style>', 'p { color: red }', '</style>', -- 2-4
      '<script type="module">', 'f()', '</SCRIPT>', -- 5-7
      '<style>a{}</style>', -- 8: on one line
      '<textarea>', 'text', '</textarea>', -- 9-11: not code
    })
    vim.wo.conceallevel = 2
    local o = empty()
    o.raw = {
      { line = 2, endLine = 4, kind = 'rawtext' }, { line = 5, endLine = 7, kind = 'rawtext' },
      { line = 8, endLine = 8, kind = 'rawtext' }, { line = 9, endLine = 11, kind = 'rawtext' },
    }
    require('luccet.render').draw(buf, o)
    T.eq(marks(buf), {
      { 1, 7, 'style', 'inline', 'LuccetVirtVerbatim' },
      { 4, 22, 'script', 'inline', 'LuccetVirtVerbatim' },
    }, 'the name in place of the start tag')
    T.eq(concealed(buf), { { 1, 0, 1, 7 }, { 3, 0, 3, 8 }, { 4, 0, 4, 22 }, { 6, 0, 6, 9 } }, 'the lines of the tags hidden')
    T.eq(tinted(buf), { { 1, 3, 'LuccetVerbatim' }, { 4, 6, 'LuccetVerbatim' }, { 7, 7, 'LuccetVerbatim' } },
      'tinted, a block on one line too; a textarea is no code')
  end },

  { 'the note\'s macros, wherever their block is, and window.LUCCET\'s', function(T)
    local buf = buffer({
      '<script>window.LUCCET = { katex: { macros: { "\\\\C": "\\\\mathbb{C}", \'\\\\abs\': \'|#1|\' } } }</script>', -- 1
      '<script src="luccet.js"></script>', -- 2
      'In $\\R^n$ and $\\C$, $\\abs{x} = \\norm{y}$, $\\bad$.', -- 3
      '$$', -- 4
      '\\begin{align}', -- 5
      '\\norm{x} &= \\R \\\\', -- 6
      '&= \\C', -- 7
      '\\end{align}', -- 8
      '$$', -- 9
      '> :::macros', -- 10
      '> \\gdef\\R{\\mathbb{R}}', -- 11
      '> \\gdef\\norm#1{\\lVert #1 \\rVert}', -- 12
      '> \\gdef\\bad{\\bad}', -- 13
      '> :::', -- 14
    })
    vim.wo.conceallevel = 2
    api.nvim_win_set_cursor(0, { 10, 0 })
    local line = api.nvim_buf_get_lines(buf, 2, 3, false)[1]
    local function math(tex)
      local s = line:find('$' .. tex .. '$', 1, true)
      return { line = 3, col = s, endLine = 3, ['end'] = s + #tex + 2, display = false, tex = tex }
    end
    local o = empty()
    o.math = { math('\\R^n'), math('\\C'), math('\\abs{x} = \\norm{y}'), math('\\bad'),
      { line = 4, col = 1, endLine = 9, ['end'] = 3, display = true, tex = '\\begin{align}\n\\norm{x} &= \\R \\\\\n&= \\C\n\\end{align}' } }
    o.blocks = { { line = 10, endLine = 14, kind = 'container', name = 'macros', colons = 3 } }
    require('luccet.render').draw(buf, o)
    local texts = vim.tbl_map(function(mk)
      return mk[3]
    end, vim.tbl_filter(function(mk)
      return mk[5] == 'LuccetVirtMath'
    end, marks(buf)))
    T.eq(texts, { 'ℝⁿ', 'ℂ', '|x| = ‖y‖', '‖x‖ = ℝ', '    = ℂ' }, 'expanded; \\bad never ends, so its source stays')
  end },

  { 'inline math over two lines is not hidden', function(T)
    local buf = buffer({ 'a $\\alpha', '+ \\beta$ b', 'c' })
    vim.wo.conceallevel = 2
    local o = empty()
    o.math = { { line = 1, col = 3, endLine = 2, ['end'] = 9, display = false, tex = '\\alpha\n+ \\beta' } }
    require('luccet.render').draw(buf, o)
    T.eq(concealed(buf), {}, 'no conceal')
    T.eq(marks(buf), { { 1, 8, ' α + β', 'inline', 'LuccetVirtMath' } }, 'after the source')
  end },

  { 'a title not on the opener line follows an em dash', function(T)
    local buf = buffer({ ':::theorem{#t}', 'x', ':::' })
    local o = empty()
    o.blocks = { { line = 1, endLine = 3, kind = 'container', name = 'theorem', title = 'Zorn', label = 'Lemma 4', colons = 3 } }
    require('luccet.render').draw(buf, o)
    T.eq(marks(buf), { { 0, 0, 'Lemma 4 — Zorn', 'eol', 'LuccetVirtLabel' } })
  end },

  { 'each kind follows its options.render flag', function(T)
    local buf = buffer(LINES)
    local render = require('luccet.render')
    local function kinds()
      local seen = {}
      for _, m in ipairs(marks(buf)) do
        for hl in m[5]:gmatch('[^,]+') do
          seen[hl] = true
        end
      end
      return seen
    end
    require('luccet').setup({ render = { labels = false } })
    render.draw(buf, outline())
    T.eq(kinds(), { LuccetVirtRef = true, LuccetVirtMath = true, LuccetVirtLabel = true }, 'the equation number stays with math')
    T.ok(not vim.iter(marks(buf)):any(function(m)
      return m[3]:find('Theorem 1', 1, true) and m[4] == 'eol'
    end), 'no block label')
    require('luccet').setup({ render = { refs = false, math = false } })
    render.draw(buf, outline())
    T.eq(kinds(), { LuccetVirtLabel = true }, 'labels only')
    require('luccet').setup()
  end },

  { 'a stale outline draws no errors and drops what no longer matches', function(T)
    local buf = buffer(LINES)
    local render = require('luccet.render')
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

  { 'LuccetOutline redraws; an outline older than the buffer is skipped', function(T)
    local buf = buffer(LINES)
    local render = require('luccet.render')
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

  { ':LuccetRender on, off and toggle, per buffer', function(T)
    local buf = buffer(LINES)
    local other = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(other, 0, -1, false, LINES)
    local render = require('luccet.render')
    with_outlines({ [buf] = outline(), [other] = outline() }, function()
      render.attach(buf)
      render.attach(other)
      T.eq(#marks(buf), 8, 'attached')
      vim.cmd('LuccetRender off')
      T.eq(#marks(buf), 0, 'off')
      T.ok(not render.enabled(buf), 'disabled')
      T.eq(#marks(other), 8, 'the other buffer keeps its marks')
      fire(buf)
      T.eq(#marks(buf), 0, 'an outline does not redraw while off')
      vim.cmd('LuccetRender')
      T.eq(#marks(buf), 8, 'toggle: on')
      vim.cmd('LuccetRender toggle')
      T.eq(#marks(buf), 0, 'toggle: off')
      vim.cmd('LuccetRender on')
      T.eq(#marks(buf), 8, 'on')
      local errors = {}
      local notify = vim.notify
      vim.notify = function(msg)
        errors[#errors + 1] = msg
      end
      vim.cmd('LuccetRender sideways')
      vim.notify = notify
      T.eq(#errors, 1, 'a bad argument is reported')
      T.eq(#marks(buf), 8, 'and changes nothing')
    end)
  end },

  { 'highlights link by default and survive a colorscheme', function(T)
    require('luccet.render').attach(buffer({ 'x' }))
    for _, name in ipairs({ 'LuccetVirtLabel', 'LuccetVirtRef', 'LuccetVirtMath', 'LuccetVirtName', 'LuccetVirtId', 'LuccetVirtVerbatim',
      'LuccetVerbatim' }) do
      T.ok(api.nvim_get_hl(0, { name = name }).link, name .. ' is linked')
    end
    api.nvim_set_hl(0, 'LuccetVirtRef', { link = 'Title' })
    vim.cmd('doautocmd ColorScheme')
    T.eq(api.nvim_get_hl(0, { name = 'LuccetVirtRef' }).link, 'Title', 'a user link wins (default = true)')
    vim.cmd('highlight clear')
    vim.cmd('doautocmd ColorScheme')
    T.ok(api.nvim_get_hl(0, { name = 'LuccetVirtLabel' }).link, 'redefined after :highlight clear')
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
    local render = require('luccet.render')
    render.draw(buf, o) -- warm the TeX cache as a real session would
    local t0 = vim.uv.hrtime()
    render.draw(buf, o)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    T.eq(#marks(buf), 3000, 'every mark')
    T.ok(ms < 150, ('drew in %.1f ms'):format(ms))
  end },

  { 'end to end: the server\'s outline draws the label, the refs and the equation number', function(T)
    local root = T.luccet_root()
    if not root or vim.fn.executable('node') == 0 then
      print('    (skipped: no Luccet checkout or no node)')
      return
    end
    local dir = T.tmpdir()
    local file = T.write(dir .. '/note.html', table.concat({
      '<!doctype html><meta charset="utf-8"><script>window.LUCCET = { schema: { block: { theorem: '
        .. '{ tag: \'section\', counter: \'theorem\', label: (n) => `Theorem ${n}` } } } };</script>'
        .. '<script src="luccet.js"></script>',
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
    require('luccet').setup({ cmd = { 'node', root .. '/luccet-cli.js', 'lsp' } })
    local ok, err = pcall(function()
      vim.cmd.edit(file)
      local buf = api.nvim_get_current_buf()
      T.eq(vim.bo[buf].filetype, 'luccet', 'filetype')
      local function find(row, text)
        for _, m in ipairs(marks(buf)) do
          if m[1] == row and m[3] == text then
            return m
          end
        end
      end
      T.wait(15000, function()
        return find(9, '(1)') ~= nil
      end, 'the equation number from the server')
      T.eq((find(8, 'x² + y² = z²') or {})[2], #'x^2 + y^2 = z^2', 'display math, in place of the TeX')
      T.ok(find(3, 'Theorem 1 ') and find(3, ' {#t1}'), 'the label in place of the opener: ' .. vim.inspect(marks(buf)))
      T.eq((find(11, ' Theorem 1') or {})[2], #'See @t1', 'the ref text, after @t1')
      T.eq((find(11, ' (1)') or {})[2], #'See @t1 and @eq', 'the equation\'s number, after @eq')
      T.eq(vim.wo.conceallevel, 2, "the ftplugin sets 'conceallevel'")
      T.eq((find(4, 'α² ≥ 0') or {})[2], #'Every 😀 $\\alpha^2 \\ge 0$', 'inline math, in place of the formula')
      -- Typing: each change makes the last outline stale until the server's
      -- next one. A line above moves every mark; @t1 becomes @t9, unresolved.
      api.nvim_buf_set_lines(buf, 2, 2, false, { 'Inserted $\\beta$.' })
      api.nvim_buf_set_lines(buf, 12, 13, false, { 'See @t9 and @eq.' })
      T.wait(15000, function()
        return find(12, ' (1)') and not find(12, ' Theorem 1') and find(2, 'β')
      end, 'redrawn after the edits: ' .. vim.inspect(marks(buf)))
      T.ok(find(4, 'Theorem 1 ') and find(10, '(1)') and find(9, 'x² + y² = z²'), 'the label and the equation moved down')
    end)
    require('luccet').setup()
    if not ok then
      error(err, 0)
    end
  end },
}
