-- SPDX-License-Identifier: MIT
-- Simple TeX as Unicode, for showing math in the editor.
--   unicode(src) -> string, or nil when any part of src has no faithful
--   Unicode form: a partial conversion would misread the formula.
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
local SPACE = {
  ord = { op = true, bin = true, rel = true },
  op = { ord = true, op = true, rel = true },
  bin = { ord = true, op = true, open = true },
  rel = { ord = true, op = true, open = true },
  close = { op = true, bin = true, rel = true },
  punct = { ord = true, op = true, rel = true, open = true, close = true, punct = true },
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

function M.unicode(src)
  if type(src) ~= 'string' then
    return nil
  end
  -- Any error is a formula this cannot show, never the caller's problem.
  local ok, result = pcall(function()
    return render((parse_list(src, 1, nil)))
  end)
  if not ok then
    return nil
  end
  result = vim.trim(result)
  return result ~= '' and result or nil
end

return M
