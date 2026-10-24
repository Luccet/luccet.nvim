-- SPDX-License-Identifier: MIT
-- syntax/luccet.vim: the groups at chosen places of small notes and of the
-- Luccet repository's pages, no errors on any page, the time to highlight the
-- largest one, and (with node) agreement with the engine's own parse of
-- every example in the documentation.
local api = vim.api

local HEAD = '<!doctype html><meta charset="utf-8"><script src="luccet.js"></script>'

-- A buffer holding lines (after HEAD unless head is given), with the filetype
-- luccet but not its ftplugin, so no language server starts. vars are set as
-- buffer variables first.
local function note(lines, head, vars)
  if vim.g.syntax_on == nil then
    vim.cmd('syntax enable')
  end
  local buf = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(vim.deepcopy(head or { HEAD }), lines))
  for k, v in pairs(vars or {}) do
    vim.b[buf][k] = v
  end
  vim.b[buf].did_ftplugin = true
  vim.bo[buf].filetype = 'luccet'
  return buf
end

local function page(T, rel)
  local root = T.luccet_root()
  if not root then
    print('    (skipped: no Luccet checkout; set $LUCCET_ROOT)')
    return nil
  end
  return note(vim.fn.readfile(root .. '/' .. rel), {})
end

-- Brings the syntax state up to date after an edit, as a screen update does
-- (:redraw would too, but headless it also eats the newline of the last print).
local function refresh()
  api.nvim__redraw({ flush = true })
end

-- The names of the syntax groups at a byte position, outermost first, in
-- lower case: group names are case-insensitive, and a group someone else
-- defined first (say LuccetMath) keeps its spelling.
local function stack(l, c)
  local out = {}
  for _, id in ipairs(vim.fn.synstack(l, c)) do
    out[#out + 1] = vim.fn.synIDattr(id, 'name'):lower()
  end
  return out
end

-- Each spec is { needle, group, offset, from = line }: at the first
-- occurrence of needle on or after line from (default: after the HEAD line,
-- or from the first line with from_first), offset bytes in, the stack holds
-- group; '!group' must be absent, 'none' means no luccet group at all.
local function check(specs, from_first)
  local lines = api.nvim_buf_get_lines(0, 0, -1, false)
  for _, s in ipairs(specs) do
    local needle, group = s[1], s[2]
    local l, c
    for i = s.from or (from_first and 1 or 2), #lines do
      c = lines[i]:find(needle, 1, true)
      if c then
        l = i
        break
      end
    end
    if not l then
      error('not in the buffer: ' .. needle, 2)
    end
    local st = stack(l, c + (s[3] or 0))
    group = group:lower()
    local ok
    if group == 'none' then
      ok = not vim.iter(st):any(function(n)
        return n:match('^luccet') ~= nil
      end)
    elseif group:sub(1, 1) == '!' then
      ok = not vim.tbl_contains(st, group:sub(2))
    else
      ok = vim.tbl_contains(st, group)
    end
    if not ok then
      error(('%q +%d (line %d): expected %s, got [%s]'):format(needle, s[3] or 0, l, group, table.concat(st, '>')), 2)
    end
  end
end

return {
  { 'the head is HTML, up to and including the luccet.js line', function()
    note({ '', '# Title', 'text <b>x</b>' }, {
      '<!doctype html>',
      '<html lang="en">',
      '<script>window.LUCCET = {schema: {}};</script>',
      '<title>T</title><script src="../luccet.js?v=2" data-use="a.js"></script> <!-- c -->',
    })
    check({
      { '<html', 'luccetHead' }, { '<html', 'htmlTag' }, { 'window.LUCCET', 'luccetHead' },
      { '<title>', 'luccetHead' }, { 'luccet.js', 'luccetHead' }, { '<!-- c', 'luccetHead' },
      { '# Title', '!luccetHead' }, { '# Title', 'luccetHeading' }, { '<b>x', 'luccetHtmlInline' },
    }, true)
  end },
  { 'the head follows edits above the luccet.js line', function()
    local buf = note({ '# Title' })
    api.nvim_buf_set_lines(buf, 0, 0, false, { '<!doctype html>', '<style>p { color: red }</style>' })
    refresh()
    check({ { '<style>', 'luccetHead' }, { HEAD, 'luccetHead' }, { '# Title', 'luccetHeading' } }, true)
    api.nvim_buf_set_lines(buf, 0, 3, false, { HEAD, '# Moved' })
    refresh()
    check({ { HEAD, 'luccetHead' }, { '# Moved', 'luccetHeading' }, { '# Moved', '!luccetHead' } }, true)
  end },
  { 'headings, containers, closers, leaves and cells', function()
    note({
      '# Linear maps {#maps .wide}',
      '###### Six',
      '#hashtag stays text',
      '####### Seven is text',
      '## Not at the end {#k} more',
      ':::theorem[Rank *x* $f[x]$]{#thm-rn .big}',
      '+++ {.muted}',
      '::video[Fallback]{src=tide.mp4 controls}',
      ':::/theorem',
      ':::',
      '::: spaced',
      '> # Quoted heading',
    })
    check({
      { '# Linear', 'luccetHeading' }, { '# Linear', 'luccetHeadingDelim' }, { 'Linear maps', 'luccetHeading' },
      { '{#maps', 'luccetAttr' }, { '#maps', 'luccetAttrId' }, { '.wide', 'luccetAttrClass' },
      { '######', 'luccetHeading' }, { '#hashtag', 'none' }, { '####### Seven', 'none' },
      { '{#k} more', '!luccetAttr' }, { '{#k} more', 'luccetHeading' },
      { ':::theorem', 'luccetBlockDelim' }, { 'theorem[', 'luccetBlockName' }, { 'Rank', 'luccetBlockTitle' },
      { '*x*', 'luccetEmphasis' }, { '$f[x]$', 'luccetMath' }, { '#thm-rn', 'luccetAttrId' }, { '.big', 'luccetAttrClass' },
      { '+++', 'luccetCellSep' }, { '.muted', 'luccetAttrClass' },
      { '::video', 'luccetLeafDelim' }, { 'video[', 'luccetLeafName' }, { 'Fallback', 'luccetLeafContent' },
      { 'src=', 'luccetAttrKey' }, { 'tide.mp4', 'luccetAttrValue' }, { 'controls', 'luccetAttrKey' },
      { ':::/theorem', 'luccetCloser' }, { ':::/theorem', 'luccetCloserName', 4 }, { ':::', 'luccetCloser', 0, from = 11 },
      { '::: spaced', 'none' },
      { '> # Quoted', 'luccetQuote' }, { 'Quoted heading', 'luccetHeading' },
    })
  end },
  { 'rules, quotes, lists, footnotes, attribute lines and tables', function()
    note({
      '---',
      '* * *',
      '--- text after',
      '> quoted *text*',
      '- item',
      '- [x] done',
      '10. ten',
      '-no space',
      '[^note]: The footnote.',
      '{#intro .lead}',
      '{x}',
      '| Key | `a|b` | $|x|$ |',
      '|---|--:|',
    })
    check({
      { '---', 'luccetRule' }, { '* * *', 'luccetRule' }, { '--- text', '!luccetRule' },
      { '> quoted', 'luccetQuote' }, { '*text*', 'luccetEmphasis' },
      { '- item', 'luccetListMarker' }, { '[x]', 'luccetTask' }, { '10.', 'luccetListMarker' }, { '-no', 'none' },
      { '[^note]:', 'luccetFootnoteDef' },
      { '{#intro', 'luccetAttrLine' }, { '#intro', 'luccetAttrId' }, { '.lead', 'luccetAttrClass' }, { '{x}', 'none' },
      { '| Key', 'luccetTablePipe' }, { '`a|b`', 'luccetCode', 2 }, { '`a|b`', '!luccetTablePipe', 2 },
      { '$|x|$', 'luccetMath', 1 }, { '|---|', 'luccetTableSep' },
    })
  end },
  { 'fences: runs, info strings, nesting and their end', function()
    note({
      '````luccet {.live}',
      '```js',
      '# not a heading',
      '```',
      '````',
      '~~~python [A *title*]{#lst lines}',
      '``` not a closer',
      '~~~',
      '```a`b``` is a code span',
      'para *after*',
      '> ```',
      '> # quoted code',
      'after *the* quote',
      '- ```js',
      '  let x = 1;',
      '  ```',
      'after *the* item',
      '```',
      'unclosed, to the end',
      ':::',
      '# h',
    })
    check({
      { '````luccet', 'luccetFence' }, { '````luccet', 'luccetFenceDelim' }, { 'luccet {', 'luccetFenceLang' },
      { '.live', 'luccetAttrClass' }, { '```js', 'luccetFenceCode' }, { '# not a heading', 'luccetFenceCode' },
      { '# not a heading', '!luccetHeading' }, { '````', 'luccetFenceDelim', 0, from = 6 },
      { '~~~python', 'luccetFence' }, { 'python', 'luccetFenceLang' }, { 'A *title*', 'luccetBlockTitle' },
      { '#lst', 'luccetAttrId' }, { 'lines', 'luccetAttrKey' }, { '``` not', 'luccetFenceCode' },
      { '```a`b```', '!luccetFence' }, { '```a`b```', 'luccetCode' }, { 'para *after*', '!luccetFence' },
      { '> ```', 'luccetQuote' }, { '# quoted code', 'luccetFenceCode' }, { 'after *the* quote', '!luccetFence' },
      { '- ```js', 'luccetListMarker' }, { 'let x', 'luccetFenceCode_javascript' }, { 'after *the* item', '!luccetFence' },
      { 'unclosed', 'luccetFenceCode' }, { '# h', 'luccetFenceCode' },
    })
  end },
  { 'fences in their language: js, css and html by default, others by option', function()
    local lines = { '```js', 'const a = 1;', '```', '```=html', '<b>raw</b>', '```', '```css', 'p { color: red }', '```',
      '```python', 'import os', '```' }
    note(lines)
    check({
      { 'const', 'luccetFenceCode_javascript' }, { 'const', 'javaScriptReserved' },
      { '<b>raw', 'luccetFenceCode_html' }, { '<b>raw', 'htmlTag' }, { 'p {', 'luccetFenceCode_css' },
      { 'import', 'luccetFenceCode' }, { 'import', '!luccetFenceCode_python' },
    })
    note(lines, nil, { luccet_fence_languages = { 'python' } })
    check({ { 'import', 'luccetFenceCode_python' }, { 'import', 'pythonInclude' }, { 'const', 'luccetFenceCode' } })
    note(lines, nil, { luccet_fence_languages = vim.empty_dict() })
    check({ { 'const', 'luccetFenceCode' }, { 'const', '!luccetFenceCode_javascript' } })
  end },
  { 'display math, its closer group and its terminators', function()
    note({
      '$$',
      '\\dim V = \\dim \\ker T',
      '$$ {#eq-rn}',
      '$$ e^{i\\pi} + 1 = 0 $$ {#eq-e}',
      '$$ x $$ is not display math when text follows.',
      '\\$$ is two dollars.',
      '$$',
      'x',
      '',
      'after the blank line',
      '$$',
      'y',
      '## A heading ends it',
    })
    check({
      { '\\dim V', 'luccetMathBlock' }, { '$$ {#eq-rn', 'luccetMathDelim' }, { '#eq-rn', 'luccetAttrId' },
      { 'e^{i', 'luccetMathBlock' }, { '#eq-e', 'luccetAttrId' }, { '$$ x $$ is', '!luccetMathBlock' },
      { '\\$$', 'luccetEscape' }, { '\\$$', '!luccetMathBlock', 1 },
      { 'after the blank', 'none' }, { '## A heading ends', 'luccetHeading' }, { '## A heading ends', '!luccetMathBlock' },
    })
  end },
  { 'raw HTML blocks: comments, raw text, generic, one-line', function()
    note({
      '<!--',
      '# not a heading',
      '-->',
      '<pre>',
      '# in pre',
      '',
      '</pre >',
      '# after pre',
      '<div class="box">',
      '<div>',
      'inner *x*',
      '</div>',
      '# still inside',
      '</DIV>',
      '# after div',
      '<hr class="fancy">',
      '<p>',
      'A *Luccet* paragraph',
      '<tide-clock station="x">',
      '**raw**',
      '</tide-clock>',
      '<b>Bold</b> starts a *paragraph*',
      '<divider>not a block</divider> *em*',
      ':::aside',
      '<div>',
      'unclosed',
      ':::',
      '# after aside',
    })
    check({
      { '# not a heading', 'luccetHtmlComment' }, { '# in pre', 'luccetHtmlBlock' }, { '</pre >', 'luccetHtmlBlock' },
      { '# after pre', 'luccetHeading' }, { '<div class', 'luccetHtmlBlock' }, { '<div class', 'htmlTag' },
      { 'inner', 'luccetHtmlBlock' }, { '*x*', '!luccetEmphasis' }, { '# still inside', 'luccetHtmlBlock' },
      { '# still inside', '!luccetHeading' }, { '# after div', 'luccetHeading' }, { '<hr', 'luccetHtmlBlock' },
      { '<p>', 'luccetHtmlBlock' }, { '*Luccet*', 'luccetEmphasis' }, { '*Luccet*', '!luccetHtmlBlock' },
      { '**raw**', 'luccetHtmlBlock' }, { '**raw**', '!luccetStrong' }, { '<b>Bold', 'luccetHtmlInline' },
      { '<b>Bold', '!luccetHtmlBlock' }, { '*paragraph*', 'luccetEmphasis' }, { '<divider>', '!luccetHtmlBlock' },
      { '*em*', 'luccetEmphasis' }, { 'unclosed', 'luccetHtmlBlock' }, { ':::', 'luccetCloser', 0, from = 27 },
      { '# after aside', 'luccetHeading' },
    })
  end },
  { 'raw bodies: meta, macros, {raw} and reserved names', function()
    note({
      ':::meta',
      'title: Linear maps',
      ':::aside',
      ':::',
      ':::macros',
      '\\gdef\\R{\\mathbb{R}}',
      ':::/macros',
      ':::mermaid[Flow]{raw #flow}',
      '*not em*',
      ':::',
      ':::script',
      'alert(1)',
      ':::',
      'after *em*',
    })
    check({
      { ':::meta', 'luccetMeta' }, { ':::meta', 'luccetBlockDelim' }, { 'meta', 'luccetBlockName' },
      { 'title', 'luccetMetaKey' }, { 'Linear maps', 'luccetMetaBody' }, { ':::aside', 'luccetMetaBody' },
      { ':::aside', '!luccetBlockDelim' }, { '\\gdef', 'luccetMacrosBody' }, { ':::/macros', 'luccetCloser' },
      { 'Flow', 'luccetBlockTitle' }, { 'raw #flow', 'luccetAttrKey' }, { '*not em*', 'luccetRawText' },
      { '*not em*', '!luccetEmphasis' }, { 'alert', 'luccetRawText' }, { '*em*', 'luccetEmphasis' },
      { '*em*', '!luccetRawText' },
    })
  end },
  { 'inline constructs', function()
    note({
      '`a``b` and ``a`b`` and a lone ` tick',
      '',
      'costs $5 and $10',
      '',
      'costs $5 and $x$ and $\\$$-valued',
      '',
      '$]0,1[$ and $`]0,1[` and $a$2 b',
      '',
      '*em* **strong** ***both*** 2 * 3 ~~gone~~ ==key== a==b',
      '',
      '[link](https://x.org "T"){.btn} ![alt](a.png) [span]{.term} :kbd[Ctrl] 10:30[x]',
      '',
      '@thm-rn @kernel-- me@x.org Wow![^a] <https://a.b> https://x.org/a. ',
      '',
      '&amp; &copy \\* \\alpha <b class="x">b</b> <div>x</div> <!-- c --> `c`{.x}',
      '',
      'これは==重要==です and これは@kernelです',
      '',
      'hard break\\',
      '',
      'A `code',
      'span` across lines and $\\sum_i',
      'x_i$ too.',
      '',
      '*not',
      '',
      'closed* here',
    })
    check({
      { '`a``b`', 'luccetCode' }, { '``a`b``', 'luccetCode' }, { 'lone `', '!luccetCode', 5 },
      { '$5 and $10', '!luccetMath' }, { '$10', '!luccetMath' }, { '$x$', 'luccetMath' }, { '$\\$$', 'luccetMath' },
      { '$]0,1[$', '!luccetMath' }, { '$`]0,1[`', 'luccetMath' }, { '$a$2', '!luccetMath' },
      { '*em*', 'luccetEmphasis' }, { '**strong**', 'luccetStrong' }, { '***both***', 'luccetStrongEmphasis' },
      { '2 * 3', '!luccetEmphasis', 2 }, { '~~gone~~', 'luccetStrike' }, { '==key==', 'luccetMark' }, { 'a==b', '!luccetMark', 1 },
      { '[link]', 'luccetLink', 1 }, { 'https://x.org "T"', 'luccetLinkDest' }, { '"T"', 'luccetLinkTitle' },
      { '.btn', 'luccetAttrClass' }, { '![alt]', 'luccetLink', 2 }, { '[span]', 'luccetSpan', 1 }, { '.term', 'luccetAttrClass' },
      { ':kbd', 'luccetElement' }, { 'Ctrl', 'luccetElementText' }, { '30[x]', 'none', 2 },
      { '@thm-rn', 'luccetRef' }, { '@kernel--', 'luccetRef' }, { '@kernel--', '!luccetRef', 7 }, { 'me@x.org', '!luccetRef', 2 },
      { '[^a]', 'luccetFootnoteRef' }, { 'Wow!', '!luccetLink', 3 }, { '<https://a.b>', 'luccetAutolink' },
      { 'https://x.org/a.', 'luccetAutolink' }, { 'https://x.org/a.', '!luccetAutolink', 15 },
      { '&amp;', 'luccetEntity' }, { '&copy', '!luccetEntity' }, { '\\*', 'luccetEscape' }, { '\\alpha', 'none' },
      { '<b class', 'luccetHtmlInline' }, { '<b class', 'htmlTag' }, { '<div>x', 'none' }, { '<!-- c', 'luccetHtmlComment' },
      { '`c`{.x}', 'luccetAttrClass', 4 },
      { '==重要', 'luccetMark' }, { '@kernelです', 'luccetRef' },
      { 'break\\', 'luccetHardBreak', 5 },
      { 'span`', 'luccetCode' }, { 'x_i$', 'luccetMath' }, { '*not', 'none' }, { 'closed*', 'none' },
    })
  end },
  { 'the groups keep their default links', function(T)
    note({ '# x' })
    local links = {
      luccetHeading = 'Title', luccetBlockName = 'Statement', luccetAttrId = 'Identifier', luccetAttrValue = 'String',
      luccetMath = 'Special', luccetMathBlock = 'luccetMath', luccetRef = 'Identifier', luccetCode = 'String',
      luccetFenceCode = 'String', luccetFenceDelim = 'Delimiter', luccetLink = 'Underlined', luccetHtmlComment = 'Comment',
    }
    for group, want in pairs(links) do
      -- Names are case-insensitive: a LuccetMath defined elsewhere is this group.
      T.eq(api.nvim_get_hl(0, { name = group }).link, want, group .. ' links to')
    end
  end },
  { 'examples/code.html', function(T)
    if not page(T, 'examples/code.html') then
      return
    end
    check({
      { 'window.LUCCET', 'luccetHead' }, { '<script src="../luccet.js"', 'luccetHead' }, { 'title: Notes', 'luccetMetaKey' },
      { '# Notes on iterators', 'luccetHeading' }, { 'function* fib', 'luccetFenceCode_javascript' },
      { 'A lazy Fibonacci', 'luccetBlockTitle' }, { '#lst-fib', 'luccetAttrId' }, { '@lst-fib yields', 'luccetRef' },
      { '`` ` ``', 'luccetCode' }, { '``a`b``', 'luccetCode' }, { 'Vec<T> and', '!luccetHtmlInline', 3 },
      { 'def take', 'luccetFenceCode' }, { 'asterisk \\*', 'luccetEscape', 9 }, { '$5 (no', '!luccetMath' },
      { '\\$x\\$', 'luccetEscape' }, { '\\# Not a heading', '!luccetHeading' }, { '<!-- TODO', 'luccetHtmlComment' },
      { '<form id', 'luccetHtmlBlock' }, { '<button>Check', 'luccetHtmlBlock' }, { '<table class', 'luccetHtmlBlock' },
      { '[data-t="note"]', 'luccetHtmlBlock' }, { '[data-t="note"]', 'cssStyle' }, { 'for (const pre', 'javaScript' },
    }, true)
  end },
  { 'docs/syntax-blocks.html', function(T)
    if not page(T, 'docs/syntax-blocks.html') then
      return
    end
    check({
      { ':::meta', 'luccetMeta' }, { '# Syntax: blocks {#top}', 'luccetHeading' }, { '::toc', 'luccetLeafDelim' },
      { '=====', 'luccetFenceCode' }, { '> # code, not a heading', 'luccetFenceCode' },
      { '<!doctype html><html lang="en">', 'luccetHead' }, { '## The eight rules', 'luccetHeading' },
    }, true)
  end },
  { 'no errors on any page of the Luccet repository', function(T)
    local root = T.luccet_root()
    if not root then
      print('    (skipped: no Luccet checkout; set $LUCCET_ROOT)')
      return
    end
    local files = vim.fn.glob(root .. '/{docs,examples}/*.html', false, true)
    T.ok(#files > 10, 'pages found under ' .. root)
    for _, f in ipairs(files) do
      vim.v.errmsg = ''
      local buf = note(vim.fn.readfile(f), {})
      local ok, err = pcall(function()
        for l = 1, api.nvim_buf_line_count(buf), 7 do
          vim.fn.synID(l, 1, 0)
        end
        vim.fn.synID(api.nvim_buf_line_count(buf), 1, 0)
      end)
      T.ok(ok and vim.v.errmsg == '', f .. ': ' .. tostring(err or vim.v.errmsg))
      api.nvim_buf_delete(buf, { force = true })
    end
  end },
  { 'highlighting docs/syntax-blocks.html stays fast', function(T)
    local root = T.luccet_root()
    if not root then
      print('    (skipped: no Luccet checkout; set $LUCCET_ROOT)')
      return
    end
    local lines = vim.fn.readfile(root .. '/docs/syntax-blocks.html')
    local t0 = vim.uv.hrtime()
    local buf = note(lines, {})
    local t1 = vim.uv.hrtime()
    vim.fn.synID(api.nvim_buf_line_count(buf), 1, 0)
    local t2 = vim.uv.hrtime()
    local load, parse = (t1 - t0) / 1e6, (t2 - t1) / 1e6
    print(('    (%d lines: syntax loaded in %.0f ms, parsed to the end in %.0f ms)'):format(#lines, load, parse))
    T.ok(load + parse < 2000, 'highlighting took longer than 2 s')
  end },
  { 'agrees with the engine on every example of the documentation', function(T)
    local root = T.luccet_root()
    if not root or vim.fn.executable('node') == 0 then
      print('    (skipped: needs node and a Luccet checkout)')
      return
    end
    -- Each ```luccet fence of the docs, with the start of every node of its AST.
    local script = [[
      const fs = require('fs'), path = require('path'), root = process.argv[1];
      const luccet = require(path.join(root, 'luccet.js')), out = [];
      for (const f of fs.readdirSync(path.join(root, 'docs')).filter((f) => f.endsWith('.html'))) {
        const lines = fs.readFileSync(path.join(root, 'docs', f), 'utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
          const m = /^(\s*)(`{3,})luccet\b/.exec(lines[i]);
          if (!m) continue;
          const close = new RegExp('^\\s*' + m[2] + '`*\\s*$'), body = [];
          while (++i < lines.length && !close.test(lines[i])) body.push(lines[i].slice(m[1].length));
          const nodes = [];
          (function walk(n) {
            if (n.type !== 'root' && n.type !== 'text' && n.position)
              nodes.push([n.type + (n.data && n.data.luccet && n.data.luccet.kind ? ':' + n.data.luccet.kind : ''), n.position.start.line, n.position.start.column]);
            (n.children || []).forEach(walk);
          })(luccet.parse(body.join('\n')).ast);
          out.push({ where: f + ':' + (i - body.length), lines: body, nodes });
        }
      }
      process.stdout.write(JSON.stringify(out));
    ]]
    local res = vim.system({ 'node', '-e', script, root }, { text = true }):wait()
    T.eq(res.code, 0, 'node: ' .. (res.stderr or ''))
    local examples = vim.json.decode(res.stdout)
    local function set(...)
      local s = {}
      for _, v in ipairs({ ... }) do
        s[v:lower()] = true
      end
      return s
    end
    -- The group expected at the start of each kind of node; for a paragraph,
    -- that no verbatim region swallowed it.
    local expect = {
      containerDirective = set('luccetBlockDelim', 'luccetMeta', 'luccetMacros', 'luccetRaw', 'luccetReserved'),
      leafDirective = set('luccetLeafDelim'), textDirective = set('luccetElement'), inlineCode = set('luccetCode'),
      code = set('luccetFence'), ['html:fence'] = set('luccetFence'), heading = set('luccetHeading'), ref = set('luccetRef'),
      inlineMath = set('luccetMath'), tableRow = set('luccetTableRow', 'luccetTableSep'), math = set('luccetMathBlock'),
      footnoteReference = set('luccetFootnoteRef'), footnoteDefinition = set('luccetFootnoteDef'),
      blockquote = set('luccetQuote'), listItem = set('luccetListMarker'), ['html:generic'] = set('luccetHtmlBlock'),
      ['html:rawtext'] = set('luccetHtmlBlock'), ['html:oneline'] = set('luccetHtmlBlock'),
      ['html:comment'] = set('luccetHtmlComment'), ['html:inline'] = set('luccetHtmlInline', 'luccetHtmlComment'),
      strong = set('luccetStrong', 'luccetStrongEmphasis'), emphasis = set('luccetEmphasis', 'luccetStrongEmphasis'),
      delete = set('luccetStrike'), mark = set('luccetMark'), span = set('luccetSpan'),
      link = set('luccetLink', 'luccetAutolink'), image = set('luccetLink'), thematicBreak = set('luccetRule'),
    }
    local verbatim = set('luccetFence', 'luccetMathBlock', 'luccetHtmlBlock', 'luccetHtmlComment', 'luccetMeta', 'luccetMacros',
      'luccetRaw', 'luccetReserved', 'luccetHead')
    local buf = note({})
    local agree, total, misses = 0, 0, {}
    for _, ex in ipairs(examples) do
      api.nvim_buf_set_lines(buf, 1, -1, false, ex.lines)
      refresh()
      for _, n in ipairs(ex.nodes) do
        local kind, l = n[1], n[2] + 1
        local text = ex.lines[n[2]] or ''
        -- A node whose attribute line comes first starts at that line.
        if (expect[kind] or kind == 'paragraph') and not text:match('^%s*{') then
          local col = vim.str_byteindex(text, 'utf-16', n[3] - 1, false) + 1
          local want = expect[kind] or verbatim
          local found = vim.iter(stack(l, col)):any(function(name)
            return want[name] == true
          end)
          local ok = found == (kind ~= 'paragraph')
          total = total + 1
          if ok then
            agree = agree + 1
          elseif #misses < 12 then
            misses[#misses + 1] = ('%s at %s+%d: %s'):format(kind, ex.where, n[2], text)
          end
        end
      end
    end
    print(('    (%d of %d nodes in %d examples agree; first misses:\n      %s)'):format(agree, total, #examples,
      table.concat(misses, '\n      ')))
    T.ok(total > 3000, 'examples found')
    T.ok(agree / total > 0.99, ('only %d of %d nodes agree'):format(agree, total))
  end },
}
