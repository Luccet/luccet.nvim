-- SPDX-License-Identifier: MIT
-- Simple TeX as Unicode, for showing math in the editor.
--   unicode(src) -> string, or nil when any part of src has no faithful
--   Unicode form: a partial conversion would misread the formula.
--   lines(list) -> display math TeX lines as Unicode line by line, or nil:
--   one line, or an environment written one row a line (align, cases, a
--   matrix), its delimiters drawn as tall as its rows.
--   macros(text, into) -> the macros TeX definitions make, added to `into`:
--   \name -> { n = its number of arguments, body }
--   expand(src, macros) -> src with the macros expanded, or nil when that
--   fails (an argument missing, an expansion without end)
-- It reads a small subset of KaTeX: Greek and symbols, function names,
-- scripts Unicode has (x^2, x_i, x^{-1}), \mathbb and the other alphabets,
-- \frac and \sqrt written on one line, accents on one letter, \text,
-- \left … \right. Spacing follows TeX's atom classes (x+y = 1 -> x + y = 1),
-- not the source's, so `\forall x\in A` and `\forall x \in A` read the same.
local M = {}

-- Thrown as soon as a part has no Unicode form; unicode() returns nil.
local function fail()
  error('no unicode form', 0)
end

local function utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local CHAR = '[%z\1-\127\194-\244][\128-\191]*' -- one UTF-8 character

-- Control words by atom class: { text, class }.
local SYM = {}
local function def(class, list)
  for name, text in pairs(list) do
    SYM[name] = { text, class }
  end
end
def('ord', {
  alpha = 'α', beta = 'β', gamma = 'γ', delta = 'δ', epsilon = 'ϵ', varepsilon = 'ε', zeta = 'ζ', eta = 'η',
  theta = 'θ', vartheta = 'ϑ', iota = 'ι', kappa = 'κ', varkappa = 'ϰ', lambda = 'λ', mu = 'μ', nu = 'ν',
  xi = 'ξ', omicron = 'ο', pi = 'π', varpi = 'ϖ', rho = 'ρ', varrho = 'ϱ', sigma = 'σ', varsigma = 'ς',
  tau = 'τ', upsilon = 'υ', phi = 'ϕ', varphi = 'φ', chi = 'χ', psi = 'ψ', omega = 'ω',
  Gamma = 'Γ', Delta = 'Δ', Theta = 'Θ', Lambda = 'Λ', Xi = 'Ξ', Pi = 'Π', Sigma = 'Σ', Upsilon = 'Υ',
  Phi = 'Φ', Psi = 'Ψ', Omega = 'Ω', digamma = 'ϝ',
  infty = '∞', partial = '∂', nabla = '∇', emptyset = '∅', varnothing = '∅', forall = '∀', exists = '∃',
  nexists = '∄', neg = '¬', lnot = '¬', top = '⊤', bot = '⊥', ell = 'ℓ', hbar = 'ℏ', hslash = 'ℏ',
  imath = 'ı', jmath = 'ȷ', wp = '℘', Re = 'ℜ', Im = 'ℑ', aleph = 'ℵ', beth = 'ℶ', gimel = 'ℷ',
  complement = '∁', prime = '′', angle = '∠', measuredangle = '∡', triangle = '△', square = '□',
  Box = '□', blacksquare = '■', lozenge = '◊', clubsuit = '♣', diamondsuit = '♢', heartsuit = '♡',
  spadesuit = '♠', flat = '♭', natural = '♮', sharp = '♯', degree = '°', checkmark = '✓', surd = '√',
  ldots = '…', dots = '…', dotso = '…', dotsc = '…', cdots = '⋯', dotsb = '⋯', vdots = '⋮', ddots = '⋱',
  vert = '|', Vert = '‖', backslash = '\\', S = '§', P = '¶', dag = '†', ddag = '‡', pounds = '£',
  mho = '℧', eth = 'ð', Bbbk = '𝕜', infin = '∞',
})
def('rel', {
  to = '→', rightarrow = '→', leftarrow = '←', gets = '←', longrightarrow = '⟶', longleftarrow = '⟵',
  mapsto = '↦', longmapsto = '⟼', leftrightarrow = '↔', longleftrightarrow = '⟷', Rightarrow = '⇒',
  Leftarrow = '⇐', Leftrightarrow = '⇔', Longrightarrow = '⟹', Longleftarrow = '⟸', Longleftrightarrow = '⟺',
  implies = '⟹', impliedby = '⟸', iff = '⟺', hookrightarrow = '↪', hookleftarrow = '↩',
  twoheadrightarrow = '↠', rightharpoonup = '⇀', rightleftharpoons = '⇌', leadsto = '⇝', uparrow = '↑',
  downarrow = '↓', updownarrow = '↕', Uparrow = '⇑', Downarrow = '⇓', nearrow = '↗', searrow = '↘',
  swarrow = '↙', nwarrow = '↖',
  le = '≤', leq = '≤', ge = '≥', geq = '≥', leqslant = '⩽', geqslant = '⩾', ne = '≠', neq = '≠',
  lt = '<', gt = '>', approx = '≈', approxeq = '≊', equiv = '≡', sim = '∼', simeq = '≃', cong = '≅',
  propto = '∝', ll = '≪', gg = '≫', lll = '⋘', ggg = '⋙', prec = '≺', succ = '≻', preceq = '⪯',
  succeq = '⪰', asymp = '≍', doteq = '≐', triangleq = '≜', coloneqq = '≔', eqqcolon = '≕',
  ['in'] = '∈', notin = '∉', ni = '∋', owns = '∋', subset = '⊂', subseteq = '⊆', supset = '⊃',
  supseteq = '⊇', subsetneq = '⊊', supsetneq = '⊋', sqsubset = '⊏', sqsupset = '⊐', sqsubseteq = '⊑',
  sqsupseteq = '⊒', perp = '⊥', vdash = '⊢', dashv = '⊣', models = '⊨', vDash = '⊨', parallel = '∥',
  nparallel = '∦', mid = '∣', nmid = '∤', bowtie = '⋈', smile = '⌣', frown = '⌢', nleq = '≰',
  ngeq = '≱', nless = '≮', ngtr = '≯', nsubseteq = '⊈', nsupseteq = '⊉', ncong = '≇', nsim = '≁',
})
def('bin', {
  pm = '±', mp = '∓', times = '×', div = '÷', cdot = '⋅', ast = '∗', star = '⋆', circ = '∘',
  bullet = '∙', oplus = '⊕', ominus = '⊖', otimes = '⊗', oslash = '⊘', odot = '⊙', cup = '∪',
  cap = '∩', sqcup = '⊔', sqcap = '⊓', uplus = '⊎', setminus = '∖', smallsetminus = '∖', wedge = '∧',
  land = '∧', vee = '∨', lor = '∨', dagger = '†', ddagger = '‡', amalg = '⨿', diamond = '⋄', wr = '≀',
  bigtriangleup = '△', bigtriangledown = '▽', triangleleft = '◃', triangleright = '▹', lhd = '⊲',
  rhd = '⊳', unlhd = '⊴', unrhd = '⊵', ltimes = '⋉', rtimes = '⋊', boxplus = '⊞', boxtimes = '⊠',
  dotplus = '∔', bmod = 'mod',
})
def('op', {
  sum = '∑', prod = '∏', coprod = '∐', int = '∫', iint = '∬', iiint = '∭', oint = '∮', bigcup = '⋃',
  bigcap = '⋂', bigsqcup = '⨆', bigvee = '⋁', bigwedge = '⋀', bigoplus = '⨁', bigotimes = '⨂',
  bigodot = '⨀', biguplus = '⨄',
})
for name in ([[sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth log ln lg exp lim liminf
    limsup max min sup inf det dim ker deg gcd lcm arg hom Pr]]):gmatch('%S+') do
  SYM[name] = { name, 'op' }
end
def('open', { langle = '⟨', lbrace = '{', lbrack = '[', lfloor = '⌊', lceil = '⌈', lvert = '|', lVert = '‖',
  lgroup = '⟮' })
def('close', { rangle = '⟩', rbrace = '}', rbrack = ']', rfloor = '⌋', rceil = '⌉', rvert = '|', rVert = '‖',
  rgroup = '⟯' })
def('punct', { colon = ':' })

-- Control symbols (a backslash and one non-letter).
local SYMBOL = {
  ['{'] = { '{', 'open' }, ['}'] = { '}', 'close' }, ['|'] = { '‖', 'ord' }, ['#'] = { '#', 'ord' },
  ['$'] = { '$', 'ord' }, ['%'] = { '%', 'ord' }, ['&'] = { '&', 'ord' }, ['_'] = { '_', 'ord' },
}
-- Explicit spaces: a backslash and a character, or a word.
local GLUE = {
  [','] = ' ', [':'] = ' ', [';'] = ' ', ['>'] = ' ', [' '] = ' ', ['!'] = '',
  thinspace = ' ', medspace = ' ', thickspace = ' ', enspace = ' ', quad = '  ', qquad = '    ',
  negthinspace = '', negmedspace = '', negthickspace = '',
}
-- Words that change nothing a line of text can show.
local IGNORE = { displaystyle = true, textstyle = true, scriptstyle = true, scriptscriptstyle = true,
  limits = true, nolimits = true }

-- Characters by atom class; letters, digits and the rest are ord.
local CHARS = {
  ['+'] = { '+', 'bin' }, ['-'] = { '−', 'bin' }, ['*'] = { '∗', 'bin' }, ['='] = { '=', 'rel' },
  ['<'] = { '<', 'rel' }, ['>'] = { '>', 'rel' }, [':'] = { ':', 'rel' }, [','] = { ',', 'punct' },
  [';'] = { ';', 'punct' }, ['('] = { '(', 'open' }, ['['] = { '[', 'open' }, [')'] = { ')', 'close' },
  [']'] = { ']', 'close' }, ['!'] = { '!', 'close' }, ['?'] = { '?', 'close' },
}

-- Scripts that Unicode has; a script with any other character fails.
local SUP = {
  ['0'] = '⁰', ['1'] = '¹', ['2'] = '²', ['3'] = '³', ['4'] = '⁴', ['5'] = '⁵', ['6'] = '⁶', ['7'] = '⁷',
  ['8'] = '⁸', ['9'] = '⁹', ['+'] = '⁺', ['−'] = '⁻', ['='] = '⁼', ['('] = '⁽', [')'] = '⁾',
  a = 'ᵃ', b = 'ᵇ', c = 'ᶜ', d = 'ᵈ', e = 'ᵉ', f = 'ᶠ', g = 'ᵍ', h = 'ʰ', i = 'ⁱ', j = 'ʲ', k = 'ᵏ',
  l = 'ˡ', m = 'ᵐ', n = 'ⁿ', o = 'ᵒ', p = 'ᵖ', r = 'ʳ', s = 'ˢ', t = 'ᵗ', u = 'ᵘ', v = 'ᵛ', w = 'ʷ',
  x = 'ˣ', y = 'ʸ', z = 'ᶻ',
  A = 'ᴬ', B = 'ᴮ', D = 'ᴰ', E = 'ᴱ', G = 'ᴳ', H = 'ᴴ', I = 'ᴵ', J = 'ᴶ', K = 'ᴷ', L = 'ᴸ', M = 'ᴹ',
  N = 'ᴺ', O = 'ᴼ', P = 'ᴾ', R = 'ᴿ', T = 'ᵀ', U = 'ᵁ', V = 'ⱽ', W = 'ᵂ',
  ['α'] = 'ᵅ', ['β'] = 'ᵝ', ['γ'] = 'ᵞ', ['δ'] = 'ᵟ', ['ε'] = 'ᵋ', ['θ'] = 'ᶿ', ['ι'] = 'ᶥ',
  ['ϕ'] = 'ᶲ', ['φ'] = 'ᶲ', ['χ'] = 'ᵡ',
  ['′'] = '′', ['∘'] = '°', ['∗'] = '*', ['⊤'] = 'ᵀ', ['†'] = '†',
}
local SUB = {
  ['0'] = '₀', ['1'] = '₁', ['2'] = '₂', ['3'] = '₃', ['4'] = '₄', ['5'] = '₅', ['6'] = '₆', ['7'] = '₇',
  ['8'] = '₈', ['9'] = '₉', ['+'] = '₊', ['−'] = '₋', ['='] = '₌', ['('] = '₍', [')'] = '₎',
  a = 'ₐ', e = 'ₑ', h = 'ₕ', i = 'ᵢ', j = 'ⱼ', k = 'ₖ', l = 'ₗ', m = 'ₘ', n = 'ₙ', o = 'ₒ', p = 'ₚ',
  r = 'ᵣ', s = 'ₛ', t = 'ₜ', u = 'ᵤ', v = 'ᵥ', x = 'ₓ',
  ['β'] = 'ᵦ', ['γ'] = 'ᵧ', ['ρ'] = 'ᵨ', ['ϕ'] = 'ᵩ', ['φ'] = 'ᵩ', ['χ'] = 'ᵪ',
}

local function alphabet(upper, lower, digits, holes)
  local t = {}
  for k = 0, 25 do
    if upper then
      t[string.char(65 + k)] = utf8(upper + k)
    end
    if lower then
      t[string.char(97 + k)] = utf8(lower + k)
    end
  end
  for k = 0, digits and 9 or -1 do
    t[tostring(k)] = utf8(digits + k)
  end
  for k, v in pairs(holes or {}) do
    t[k] = v
  end
  return t
end
-- Letter-only alphabets: anything else in them fails.
local ALPHABET = {
  mathbb = alphabet(0x1D538, nil, nil, { C = 'ℂ', H = 'ℍ', N = 'ℕ', P = 'ℙ', Q = 'ℚ', R = 'ℝ', Z = 'ℤ' }),
  mathcal = alphabet(0x1D49C, nil, nil, { B = 'ℬ', E = 'ℰ', F = 'ℱ', H = 'ℋ', I = 'ℐ', L = 'ℒ', M = 'ℳ', R = 'ℛ' }),
  mathfrak = alphabet(0x1D504, 0x1D51E, nil, { C = 'ℭ', H = 'ℌ', I = 'ℑ', R = 'ℜ', Z = 'ℨ' }),
}
ALPHABET.Bbb = ALPHABET.mathbb
ALPHABET.mathscr = ALPHABET.mathcal
-- Fonts over any math: letters and digits change, the rest stays.
local BOLD = alphabet(0x1D400, 0x1D41A, 0x1D7CE)
local FONT = { mathbf = BOLD, boldsymbol = BOLD, bm = BOLD, mathrm = false, mathup = false, mathit = false,
  mathnormal = false, mathsf = false, mathtt = false }
local TEXT = { text = true, textrm = true, textnormal = true, textit = true, textbf = true, textsf = true,
  texttt = true, textup = true, textmd = true, mbox = true, hbox = true }

local ACCENT = { hat = '\u{302}', widehat = '\u{302}', check = '\u{30C}', tilde = '\u{303}',
  widetilde = '\u{303}', acute = '\u{301}', grave = '\u{300}', dot = '\u{307}', ddot = '\u{308}',
  breve = '\u{306}', bar = '\u{304}', vec = '\u{20D7}', mathring = '\u{30A}', overline = '\u{305}',
  underline = '\u{332}' }
local SPANS = { overline = true, underline = true } -- may cover several letters

local NOT = { ['='] = '≠', ['<'] = '≮', ['>'] = '≯', ['in'] = '∉', le = '≰', leq = '≰', ge = '≱', geq = '≱',
  subset = '⊄', supset = '⊅', subseteq = '⊈', supseteq = '⊉', equiv = '≢', sim = '≁', approx = '≉',
  cong = '≇', mid = '∤', parallel = '∦', ni = '∌', simeq = '≄' }

-- Delimiters after \left, \right, \bigl …
local DELIM = { ['('] = '(', [')'] = ')', ['['] = '[', [']'] = ']', ['|'] = '|', ['/'] = '/', ['.'] = '',
  ['<'] = '⟨', ['>'] = '⟩', ['\\{'] = '{', ['\\}'] = '}', ['\\|'] = '‖', langle = '⟨', rangle = '⟩',
  lfloor = '⌊', rfloor = '⌋', lceil = '⌈', rceil = '⌉', vert = '|', Vert = '‖', lvert = '|', rvert = '|',
  lVert = '‖', rVert = '‖', lbrace = '{', rbrace = '}', lbrack = '[', rbrack = ']', uparrow = '↑',
  downarrow = '↓', updownarrow = '↕', backslash = '\\' }
local SIZED = { left = 'open', right = 'close', middle = 'rel' }
for _, size in ipairs({ 'big', 'Big', 'bigg', 'Bigg' }) do
  SIZED[size] = 'ord'
  SIZED[size .. 'l'] = 'open'
  SIZED[size .. 'r'] = 'close'
  SIZED[size .. 'm'] = 'rel'
end

-- TeX's spacing between atom classes, as one space or none; scripts get none.
-- inner is an environment between delimiters, beside the math around it; a
-- comma after it reads as its own without TeX's thin space.
local SPACE = {
  ord = { op = true, bin = true, rel = true, inner = true },
  op = { ord = true, op = true, rel = true, inner = true },
  bin = { ord = true, op = true, open = true, inner = true },
  rel = { ord = true, op = true, open = true, inner = true },
  close = { op = true, bin = true, rel = true, inner = true },
  punct = { ord = true, op = true, rel = true, open = true, close = true, punct = true, inner = true },
  inner = { ord = true, op = true, bin = true, rel = true, open = true, inner = true },
}

-- The tokenizer: kind, value, next index. Kinds: 'eof', 'char', 'cs'
-- (a control word or symbol, value without the backslash), '{', '}', '^',
-- '_', 'space'.
local function token(s, i)
  local c = s:sub(i, i)
  if c == '' then
    return 'eof', nil, i
  elseif c == '\\' then
    local word = s:match('^%a+', i + 1)
    if word then
      return 'cs', word, i + 1 + #word
    end
    local sym = s:match('^' .. CHAR, i + 1)
    if not sym then
      fail()
    end
    return 'cs', sym, i + 1 + #sym
  elseif c == '{' or c == '}' or c == '^' or c == '_' then
    return c, c, i + 1
  elseif c:match('%s') then
    return 'space', ' ', s:match('^%s+()', i)
  elseif c == '%' or c == '&' or c == '#' or c == '$' then
    fail()
  end
  local ch = s:match('^' .. CHAR, i)
  return 'char', ch, i + #ch
end

local function skip(s, i)
  return s:match('^%s*()', i)
end

local parse_list, render

-- One argument: a group, or a single token. Returns its atoms.
local function argument(s, i, command)
  i = skip(s, i)
  local kind, v, j = token(s, i)
  if kind == '{' then
    return parse_list(s, j, '}')
  elseif kind == 'char' or kind == 'cs' then
    local atoms = {}
    return atoms, command(s, i, atoms)
  end
  fail()
end

-- Whether the atoms read as one term without parentheses ("ab", "x²", "12").
local function simple(atoms, scripts)
  for _, a in ipairs(atoms) do
    if a.class ~= 'ord' or a.glue or a.text:find(' ') or (not scripts and (a.sup or a.sub)) or a.compound then
      return false
    end
  end
  return #atoms > 0
end

local function wrap(atoms, scripts)
  local text = render(atoms)
  return simple(atoms, scripts) and text or '(' .. text .. ')'
end

local function script_text(map, atoms)
  local out = {}
  for ch in render(atoms, true):gmatch(CHAR) do
    out[#out + 1] = map[ch] or fail()
  end
  return table.concat(out)
end

-- Reads one token at i and appends its atoms; returns the next index.
local function command(s, i, atoms)
  local kind, v, j = token(s, i)
  local function push(text, class, extra)
    local a = extra or {}
    a.text, a.class = text, class
    atoms[#atoms + 1] = a
  end
  if kind == 'char' then
    if v == "'" then -- f' is f^{\prime}
      local last = atoms[#atoms]
      if last and last.caret then
        fail()
      elseif not last or last.glue then
        push('', 'ord')
        last = atoms[#atoms]
      end
      last.sup = (last.sup or '') .. '′'
      return j
    elseif v == '~' then
      push(' ', 'glue', { glue = true })
      return j
    end
    local c = CHARS[v]
    push(c and c[1] or v, c and c[2] or 'ord')
    return j
  elseif kind ~= 'cs' then
    fail()
  end
  local sym = SYM[v] or SYMBOL[v]
  if sym then
    push(sym[1], sym[2])
  elseif GLUE[v] then
    push(GLUE[v], 'glue', { glue = true })
  elseif IGNORE[v] then
    return j
  elseif ALPHABET[v] then
    local arg
    arg, j = argument(s, j, command)
    local out = {}
    for _, a in ipairs(arg) do
      if a.class ~= 'ord' or a.sup or a.sub or not ALPHABET[v][a.text] then
        fail()
      end
      out[#out + 1] = ALPHABET[v][a.text]
    end
    push(table.concat(out), 'ord')
  elseif FONT[v] ~= nil then
    local arg
    arg, j = argument(s, j, command)
    local text = render(arg)
    if FONT[v] then
      text = text:gsub('%w', FONT[v])
    end
    push(text, #arg == 1 and arg[1].class or 'ord')
  elseif TEXT[v] then
    local body, k = s:match('^{([^{}\\$^_&#%%]*)}()', skip(s, j))
    if not body then
      fail()
    end
    push((body:gsub('~', ' '):gsub('%s+', ' ')), 'ord')
    j = k
  elseif v == 'operatorname' then
    j = s:match('^%*?()', skip(s, j))
    local arg
    arg, j = argument(s, j, command)
    push(render(arg), 'op')
  elseif ACCENT[v] then
    local arg
    arg, j = argument(s, j, command)
    local text = render(arg)
    local list = {}
    for ch in text:gmatch(CHAR) do
      list[#list + 1] = ch
    end
    if #list == 0 or (#list > 1 and not (SPANS[v] and text:match('^%w+$'))) then
      fail()
    end
    push(table.concat(list, ACCENT[v]) .. ACCENT[v], 'ord')
  elseif v == 'frac' or v == 'dfrac' or v == 'tfrac' then
    local num, den
    num, j = argument(s, j, command)
    den, j = argument(s, j, command)
    push(wrap(num, true) .. '/' .. wrap(den, true), 'ord', { compound = true })
  elseif v == 'sqrt' then
    local root = '√'
    local index, k = s:match('^%[%s*(%d)%s*%]()', skip(s, j))
    if index then
      root = ({ ['2'] = '√', ['3'] = '∛', ['4'] = '∜' })[index] or fail()
      j = k
    elseif s:sub(skip(s, j), skip(s, j)) == '[' then
      fail()
    end
    local arg
    arg, j = argument(s, j, command)
    push(root .. wrap(arg, false), 'ord', { compound = true })
  elseif v == 'not' then
    j = skip(s, j)
    local k2, v2, j2 = token(s, j)
    local t = (k2 == 'char' or k2 == 'cs') and NOT[v2] or fail()
    push(t, 'rel')
    j = j2
  elseif SIZED[v] then
    j = skip(s, j)
    local k2, v2, j2 = token(s, j)
    local key = k2 == 'cs' and (v2:match('^%a') and v2 or '\\' .. v2) or v2
    local d = (k2 == 'char' or k2 == 'cs') and DELIM[key] or fail()
    if d ~= '' then
      push(d, SIZED[v])
    end
    j = j2
  elseif v == 'pmod' then
    local arg
    arg, j = argument(s, j, command)
    push(' ', 'glue', { glue = true })
    push('(mod ' .. render(arg) .. ')', 'ord')
  elseif v == 'mod' then
    push(' ', 'glue', { glue = true })
    push('mod', 'ord')
    push(' ', 'glue', { glue = true })
  else
    fail()
  end
  return j
end

-- Atoms until `stop` ('}' or the end). Returns the atoms and the index after.
function parse_list(s, i, stop)
  local atoms = {}
  while true do
    local kind, _, j = token(s, i)
    if kind == 'eof' then
      if stop then
        fail()
      end
      return atoms, i
    elseif kind == '}' then
      if stop ~= '}' then
        fail()
      end
      return atoms, j
    elseif kind == 'space' then
      i = j
    elseif kind == '{' then
      -- A group is one ordinary atom; a script on it reads after its last
      -- character, as TeX sets it ({a+b}^2 is a + b²).
      local inner
      inner, i = parse_list(s, j, '}')
      atoms[#atoms + 1] = { text = render(inner), class = 'ord', compound = #inner == 1 and inner[1].compound }
    elseif kind == '^' or kind == '_' then
      local arg
      arg, i = argument(s, j, command)
      local last = atoms[#atoms]
      if not last or last.glue then
        last = { text = '', class = 'ord' }
        atoms[#atoms + 1] = last
      end
      if kind == '^' then
        if last.caret then
          fail()
        end
        last.caret = true
        last.sup = (last.sup or '') .. script_text(SUP, arg)
      else
        if last.sub then
          fail()
        end
        last.sub = script_text(SUB, arg)
      end
    else
      i = command(s, i, atoms)
    end
  end
end

-- Atoms as text: TeX's binary-to-ordinary rule, then the class spacing.
-- In a script (`tight`) there is no spacing at all.
function render(atoms, tight)
  local prev
  for _, a in ipairs(atoms) do
    if not a.glue then
      if a.class == 'bin' and (not prev or prev.class == 'bin' or prev.class == 'op' or prev.class == 'rel'
          or prev.class == 'open' or prev.class == 'punct') then
        a.class = 'ord'
      elseif prev and prev.class == 'bin' and (a.class == 'rel' or a.class == 'close' or a.class == 'punct') then
        prev.class = 'ord'
      end
      prev = a
    end
  end
  if prev and prev.class == 'bin' then
    prev.class = 'ord'
  end
  local out, glue = {}, nil
  prev = nil
  for _, a in ipairs(atoms) do
    if a.glue then
      glue = (glue or '') .. (tight and '' or a.text)
    else
      if glue then
        out[#out + 1] = glue
      elseif prev and not tight and SPACE[prev.class] and SPACE[prev.class][a.class] then
        out[#out + 1] = ' '
      end
      glue = nil
      local text = a.text
      if a.compound and (a.sup or a.sub) then
        text = '(' .. text .. ')'
      end
      out[#out + 1] = text .. (a.sub or '') .. (a.sup or '')
      prev = a
    end
  end
  return table.concat(out)
end

local function convert(src)
  return render((parse_list(src, 1, nil)))
end

function M.unicode(src)
  if type(src) ~= 'string' then
    return nil
  end
  -- Any error is a formula this cannot show, never the caller's problem.
  local ok, result = pcall(convert, src)
  if not ok then
    return nil
  end
  result = vim.trim(result)
  return result ~= '' and result or nil
end

-- Environments shown row by row, a row a line: how their columns align (rl:
-- right, left, repeated; c, l: every column so), the space between columns
-- (rl: between pairs), the most columns, and what may follow \begin{name}.
-- spec: the argument says how columns align, one letter for all of them or
-- each its own. equation holds one row, or one of these. An inner
-- environment may have math before its \begin and after its \end, drawn
-- beside its middle row, and delimiters as tall as its rows: its own, or
-- \left and \right around it.
local ENV = {}
local NONE, PLACE, COUNT = { '^$' }, { '^$', '^%[[tcb]%]$' }, { '^{%s*%d+%s*}$' }
for _, name in ipairs({ 'align', 'align*', 'split' }) do
  ENV[name] = { cols = 'rl', gap = '    ', arg = NONE }
end
ENV.aligned = { cols = 'rl', gap = '    ', arg = PLACE, inner = true }
for _, name in ipairs({ 'alignat', 'alignat*' }) do
  ENV[name] = { cols = 'rl', gap = '', arg = COUNT }
end
ENV.alignedat = { cols = 'rl', gap = '', arg = COUNT, inner = true }
for _, name in ipairs({ 'gather', 'gather*' }) do
  ENV[name] = { cols = 'c', max = 1, arg = NONE }
end
ENV.gathered = { cols = 'c', max = 1, arg = PLACE, inner = true }
for _, name in ipairs({ 'equation', 'equation*' }) do
  ENV[name] = { cols = 'c', max = 1, arg = NONE, one = true }
end
for name, d in pairs({ matrix = { '', '' }, pmatrix = { '(', ')' }, bmatrix = { '[', ']' }, Bmatrix = { '{', '}' },
    vmatrix = { '|', '|' }, Vmatrix = { '‖', '‖' } }) do
  ENV[name] = { cols = 'c', gap = '  ', arg = NONE, inner = true, left = d[1], right = d[2] }
  ENV[name .. '*'] = { cols = 'c', gap = '  ', arg = { '^$', '^%[[lcr]%]$' }, spec = 'all', inner = true,
    left = d[1], right = d[2] }
end
ENV.smallmatrix = ENV.matrix
for _, name in ipairs({ 'cases', 'dcases' }) do
  ENV[name] = { cols = 'l', gap = '  ', max = 2, arg = NONE, inner = true, left = '{' }
end
for _, name in ipairs({ 'rcases', 'drcases' }) do
  ENV[name] = { cols = 'l', gap = '  ', max = 2, arg = NONE, inner = true, right = '}' }
end
for _, name in ipairs({ 'array', 'darray' }) do
  ENV[name] = { gap = '  ', arg = { '^{[lcr%s]+}$' }, spec = 'each', inner = true }
end

-- Delimiters over several lines, in pieces: top, extension, bottom, and a
-- brace's middle, which needs an odd height.
local TALL = {
  ['('] = { '⎛', '⎜', '⎝' }, [')'] = { '⎞', '⎟', '⎠' }, ['['] = { '⎡', '⎢', '⎣' }, [']'] = { '⎤', '⎥', '⎦' },
  ['{'] = { '⎧', '⎪', '⎩', '⎨' }, ['}'] = { '⎫', '⎪', '⎭', '⎬' }, ['⌊'] = { '⎢', '⎢', '⎣' },
  ['⌋'] = { '⎥', '⎥', '⎦' }, ['⌈'] = { '⎡', '⎢', '⎢' }, ['⌉'] = { '⎤', '⎥', '⎥' },
  ['|'] = { '│', '│', '│' }, ['‖'] = { '‖', '‖', '‖' },
}

-- Line t of delimiter d drawn h lines tall.
local function piece(d, t, h)
  if d == '' or h == 1 then
    return d
  end
  local p = TALL[d] or fail()
  return t == 1 and p[1] or t == h and p[3] or (p[4] and t == (h + 1) / 2) and p[4] or p[2]
end

-- The delimiter after \left at the end of s, or after \right at its start:
-- s without them, and the delimiter's text; s alone when it has none.
local function delimited(s, start)
  for _, d in ipairs({ '(\\%a+)', '(\\?[^%s%a])' }) do
    local rest, key
    if start then
      key, rest = s:match('^%s*\\right%s*' .. d .. '(.*)$')
    else
      rest, key = s:match('^(.-)\\left%s*' .. d .. '%s*$')
    end
    if key then
      return rest, DELIM[key:match('^\\(%a+)$') or key] or fail()
    end
  end
  return s
end

-- The math before an inner environment of atom class `class`, or after it,
-- with the space TeX sets between them.
local function beside(src, class, before)
  if src:find('^%s*$') then
    return ''
  end
  local atoms = parse_list(src, 1, nil)
  table.insert(atoms, before and #atoms + 1 or 1, { text = '', class = class })
  return render(atoms)
end

-- A row written on one line: its cells, split at the &s outside braces, and
-- whether it ends with \\ (and a [space]). Anything after that \\ fails,
-- so a line holds at most one row.
local function row(line)
  local cells, depth, start, i = {}, 0, 1, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '\\' then
      if depth == 0 and line:sub(i + 1, i + 1) == '\\' then
        if not (line:find('^%s*$', i + 2) or line:find('^%s*%[[^%]]*%]%s*$', i + 2)) then
          fail()
        end
        cells[#cells + 1] = line:sub(start, i - 1)
        return cells, true
      end
      i = i + 1
    elseif c == '{' then
      depth = depth + 1
    elseif c == '}' then
      depth = depth - 1
    elseif c == '&' and depth == 0 then
      cells[#cells + 1] = line:sub(start, i - 1)
      start = i + 1
    end
    i = i + 1
  end
  cells[#cells + 1] = line:sub(start)
  return cells, false
end

local function environment(lines)
  local before, name, arg = vim.trim(lines[1]):match('^(.-)\\begin%s*{(%a+%*?)}(.*)$')
  local env = ENV[name] or fail()
  local after = vim.trim(lines[#lines]):match('^\\end%s*{' .. vim.pesc(name) .. '}(.*)$')
  arg = vim.trim(arg)
  if not after or not vim.iter(env.arg):any(function(pat)
    return arg:find(pat) ~= nil
  end) or not env.inner and (before ~= '' or after ~= '') then
    fail()
  end
  if env.one and #lines > 3 then
    -- equation around an aligned environment.
    local inner = environment(vim.list_slice(lines, 2, #lines - 1))
    table.insert(inner, 1, '')
    inner[#inner + 1] = ''
    return inner
  end
  local left, right = env.left or '', env.right or ''
  local pre, l = delimited(before, false)
  local post, r = delimited(after, true)
  if l or r then
    if not (l and r) or left ~= '' or right ~= '' then
      fail()
    end
    left, right = l, r
  end
  local cols, max = env.cols, env.max
  if env.spec == 'all' then
    cols = arg:match('^%[(%a)%]$') or cols
  elseif env.spec == 'each' then
    cols = arg:gsub('[{}%s]', '')
    max = #cols
  end
  local rows, widths = {}, {}
  for i = 2, #lines - 1 do
    local cells, broken = row(lines[i])
    if (broken and env.one) or (not broken and i < #lines - 1) or (max and #cells > max) then
      fail()
    end
    for j, cell in ipairs(cells) do
      cell = cell:gsub('\\nonumber%f[%A]', ''):gsub('\\notag%f[%A]', '')
      -- A right-hand cell starts after an empty group, as amsmath sets it:
      -- &= b reads " = b".
      cells[j] = convert((env.cols == 'rl' and j % 2 == 0) and '{}' .. cell or cell)
      widths[j] = math.max(widths[j] or 0, vim.api.nvim_strwidth(cells[j]))
    end
    rows[#rows + 1] = cells
  end
  local k = #rows
  if k == 0 then
    fail()
  end
  -- Each row as wide as all of them.
  local texts = {}
  for i, cells in ipairs(rows) do
    local parts = {}
    for j, width in ipairs(widths) do
      if j > 1 and (env.cols ~= 'rl' or j % 2 == 1) then
        parts[#parts + 1] = env.gap
      end
      local text = cells[j] or ''
      local pad = width - vim.api.nvim_strwidth(text)
      local a = cols:sub((j - 1) % #cols + 1, (j - 1) % #cols + 1)
      local lead = a == 'r' and pad or a == 'c' and math.floor(pad / 2) or 0
      parts[#parts + 1] = (' '):rep(lead) .. text .. (' '):rep(pad - lead)
    end
    texts[i] = table.concat(parts)
  end
  -- A line for \begin, one for each row, one for \end.
  local out = {}
  for i = 1, k + 2 do
    out[i] = texts[i - 1] or ''
  end
  if env.inner then
    local class = (left ~= '' or right ~= '') and 'inner' or 'ord'
    local p, s = beside(pre, class, true), beside(post, class, false)
    -- The delimiters' lines: the rows, and the \begin line when a brace
    -- needs an odd height. What is around them goes on their middle line.
    local first = k % 2 == 0 and ((TALL[left] or {})[4] or (TALL[right] or {})[4]) and 1 or 2
    local h = k + 2 - first
    local middle = first + math.floor((h - 1) / 2)
    local indent = (' '):rep(vim.api.nvim_strwidth(p))
    local blank = (' '):rep(vim.api.nvim_strwidth(texts[1]))
    local lpad, rpad = left == '{' and ' ' or '', right == '}' and ' ' or ''
    for i = first, k + 1 do
      local t = i - first + 1
      out[i] = (i == middle and p or indent) .. piece(left, t, h) .. lpad .. (texts[i - 1] or blank) .. rpad
        .. piece(right, t, h) .. (i == middle and s or '')
    end
  end
  for i, text in ipairs(out) do
    out[i] = text:gsub('%s+$', '')
  end
  -- Nothing to show: the source says more.
  if table.concat(out) == '' then
    fail()
  end
  return out
end

-- The end of the group that opens at s[i]: the index of its `}`.
local function group_end(s, i)
  local depth = 0
  while i <= #s do
    local c = s:sub(i, i)
    if c == '\\' then
      i = i + 1
    elseif c == '{' then
      depth = depth + 1
    elseif c == '}' then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
    i = i + 1
  end
end

-- The control sequence at s[i] (`\name` or `\` and one character), or nil.
local function control(s, i)
  return s:match('^\\%a+', i) or s:match('^\\' .. CHAR, i)
end

-- A macro's argument at s[i]: a group, without its braces, or one token.
-- Returns it and the index after it; nil when there is none.
local function argument_text(s, i)
  i = s:match('^%s*()', i)
  local c = s:sub(i, i)
  if c == '{' then
    local e = group_end(s, i)
    return e and s:sub(i + 1, e - 1), e and e + 1
  elseif c == '\\' then
    local cs = control(s, i)
    return cs, cs and i + #cs
  elseif c == '' or c == '}' then
    return nil
  end
  local ch = s:match('^' .. CHAR, i)
  return ch, i + #ch
end

-- The number of arguments in a \def's parameter text, #1#2…; nil for any
-- other parameter text (delimited parameters).
local function parameters(text)
  text = text:gsub('%s', '')
  local n = 0
  for d in text:gmatch('#(%d)') do
    n = n + 1
    if tonumber(d) ~= n then
      return nil
    end
  end
  return text:gsub('#%d', '') == '' and n or nil
end

local DEF = { def = true, gdef = true, edef = true, xdef = true }
local NEWCOMMAND = { newcommand = true, renewcommand = true, providecommand = true }

function M.macros(text, into)
  into = into or {}
  if type(text) ~= 'string' then
    return into
  end
  -- The name after a definition command: \name, or {\name}.
  local function name_at(k)
    k = text:match('^%s*()', k)
    if text:sub(k, k) == '{' then
      local inner = text:match('^{%s*()', k)
      local cs = control(text, inner)
      local e = cs and text:match('^%s*}()', inner + #cs)
      return e and cs, e
    end
    local cs = control(text, k)
    return cs, cs and k + #cs
  end
  -- The body group at or after k: its text and the index after it.
  local function body_at(k)
    local b = k and text:match('^%s*(){', k)
    local e = b and group_end(text, b)
    return e and text:sub(b + 1, e - 1), e and e + 1
  end
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '%' then
      i = (text:find('\n', i, true) or #text) + 1
    elseif c ~= '\\' then
      i = i + 1
    else
      local word = text:match('^\\(%a*)', i)
      local k = i + 1 + #word
      if DEF[word] then
        local name, at = name_at(k)
        local ptext, b = text:match('^([^{]*)(){', at or k)
        local body, e = body_at(b)
        local n = ptext and parameters(ptext)
        if name and body and n then
          if word == 'edef' or word == 'xdef' then
            body = M.expand(body, into) or body
          end
          into[name] = { n = n, body = body }
        end
        i = e or k
      elseif NEWCOMMAND[word] then
        local name, at = name_at(text:match('^%*?()', k))
        local n, opt = 0, nil
        if name then
          local count, after = text:match('^%s*%[%s*(%d)%s*%]()', at)
          if count then
            n, at = tonumber(count), after
          end
          -- An optional argument's default: not read, the definition skipped.
          opt = text:match('^%s*()%[', at)
          if opt then
            at = text:match('^%b[]()', opt)
          end
        end
        local body, e = body_at(at)
        if name and body and not opt and not (word == 'providecommand' and into[name]) then
          into[name] = { n = n, body = body }
        end
        i = e or at or k
      elseif word == 'let' then
        local name, at = name_at(k)
        at = at and text:match('^%s*=?%s*()', at)
        local target = at and control(text, at)
        if name and target then
          into[name] = into[target] and vim.deepcopy(into[target]) or { n = 0, body = target }
          i = at + #target
        else
          i = at or k
        end
      else
        i = k + (word == '' and 1 or 0)
      end
    end
  end
  return into
end

function M.expand(src, macros)
  if type(src) ~= 'string' or not macros or next(macros) == nil then
    return src
  end
  local budget = 20000
  local function run(s, depth)
    if depth > 32 then
      fail()
    end
    local out, i = {}, 1
    while i <= #s do
      local j = s:find('\\', i, true)
      if not j then
        out[#out + 1] = s:sub(i)
        break
      end
      out[#out + 1] = s:sub(i, j - 1)
      local cs = control(s, j) or '\\'
      local k = j + #cs
      local m = macros[cs]
      if m then
        local args = {}
        for a = 1, m.n do
          args[a], k = argument_text(s, k)
          if not args[a] then
            fail()
          end
        end
        local text = run((m.body:gsub('#([#1-9])', function(d)
          return d == '#' and '#' or args[tonumber(d)] or fail()
        end)), depth + 1)
        budget = budget - #text
        if budget < 0 then
          fail()
        end
        out[#out + 1] = text
        -- A control word at the end must not run into a letter after it.
        if text:match('\\%a+$') and s:sub(k, k):match('%a') then
          out[#out + 1] = ' '
        end
      else
        out[#out + 1] = cs
      end
      i = k
    end
    return table.concat(out)
  end
  local ok, result = pcall(run, src, 0)
  return ok and result or nil
end

function M.lines(lines)
  if type(lines) ~= 'table' or #lines == 0 then
    return nil
  elseif #lines == 1 then
    local u = M.unicode(lines[1])
    return u and { u } or nil
  end
  local ok, result = pcall(environment, lines)
  return ok and result or nil
end

return M
