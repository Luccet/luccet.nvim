-- SPDX-License-Identifier: MIT
-- syntax/tern.vim: the groups at chosen places of small notes and of the
-- Tern repository's pages, no errors on any page, the time to highlight the
-- largest one, and (with node) agreement with the engine's own parse of
-- every example in the documentation.
local api = vim.api

local HEAD = '<!doctype html><meta charset="utf-8"><script src="tern.js"></script>'

-- A buffer holding lines (after HEAD unless head is given), with the filetype
-- tern but not its ftplugin, so no language server starts. vars are set as
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
  vim.bo[buf].filetype = 'tern'
  return buf
end

local function page(T, rel)
  local root = T.tern_root()
  if not root then
    print('    (skipped: no Tern checkout; set $TERN_ROOT)')
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
-- defined first (say TernMath) keeps its spelling.
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
-- group; '!group' must be absent, 'none' means no tern group at all.
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
        return n:match('^tern') ~= nil
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
  { 'the head is HTML, up to and including the tern.js line', function()
    note({ '', '# Title', 'text <b>x</b>' }, {
      '<!doctype html>',
      '<html lang="en">',
      '<script>window.TERN = {schema: {}};</script>',
      '<title>T</title><script src="../tern.js?v=2" data-use="a.js"></script> <!-- c -->',
    })
    check({
      { '<html', 'ternHead' }, { '<html', 'htmlTag' }, { 'window.TERN', 'ternHead' },
      { '<title>', 'ternHead' }, { 'tern.js', 'ternHead' }, { '<!-- c', 'ternHead' },
      { '# Title', '!ternHead' }, { '# Title', 'ternHeading' }, { '<b>x', 'ternHtmlInline' },
    }, true)
  end },
  { 'the head follows edits above the tern.js line', function()
    local buf = note({ '# Title' })
    api.nvim_buf_set_lines(buf, 0, 0, false, { '<!doctype html>', '<style>p { color: red }</style>' })
    refresh()
    check({ { '<style>', 'ternHead' }, { HEAD, 'ternHead' }, { '# Title', 'ternHeading' } }, true)
    api.nvim_buf_set_lines(buf, 0, 3, false, { HEAD, '# Moved' })
    refresh()
    check({ { HEAD, 'ternHead' }, { '# Moved', 'ternHeading' }, { '# Moved', '!ternHead' } }, true)
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
      { '# Linear', 'ternHeading' }, { '# Linear', 'ternHeadingDelim' }, { 'Linear maps', 'ternHeading' },
      { '{#maps', 'ternAttr' }, { '#maps', 'ternAttrId' }, { '.wide', 'ternAttrClass' },
      { '######', 'ternHeading' }, { '#hashtag', 'none' }, { '####### Seven', 'none' },
      { '{#k} more', '!ternAttr' }, { '{#k} more', 'ternHeading' },
      { ':::theorem', 'ternBlockDelim' }, { 'theorem[', 'ternBlockName' }, { 'Rank', 'ternBlockTitle' },
      { '*x*', 'ternEmphasis' }, { '$f[x]$', 'ternMath' }, { '#thm-rn', 'ternAttrId' }, { '.big', 'ternAttrClass' },
      { '+++', 'ternCellSep' }, { '.muted', 'ternAttrClass' },
      { '::video', 'ternLeafDelim' }, { 'video[', 'ternLeafName' }, { 'Fallback', 'ternLeafContent' },
      { 'src=', 'ternAttrKey' }, { 'tide.mp4', 'ternAttrValue' }, { 'controls', 'ternAttrKey' },
      { ':::/theorem', 'ternCloser' }, { ':::/theorem', 'ternCloserName', 4 }, { ':::', 'ternCloser', 0, from = 11 },
      { '::: spaced', 'none' },
      { '> # Quoted', 'ternQuote' }, { 'Quoted heading', 'ternHeading' },
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
      { '---', 'ternRule' }, { '* * *', 'ternRule' }, { '--- text', '!ternRule' },
      { '> quoted', 'ternQuote' }, { '*text*', 'ternEmphasis' },
      { '- item', 'ternListMarker' }, { '[x]', 'ternTask' }, { '10.', 'ternListMarker' }, { '-no', 'none' },
      { '[^note]:', 'ternFootnoteDef' },
      { '{#intro', 'ternAttrLine' }, { '#intro', 'ternAttrId' }, { '.lead', 'ternAttrClass' }, { '{x}', 'none' },
      { '| Key', 'ternTablePipe' }, { '`a|b`', 'ternCode', 2 }, { '`a|b`', '!ternTablePipe', 2 },
      { '$|x|$', 'ternMath', 1 }, { '|---|', 'ternTableSep' },
    })
  end },
  { 'fences: runs, info strings, nesting and their end', function()
    note({
      '````tern {.live}',
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
      { '````tern', 'ternFence' }, { '````tern', 'ternFenceDelim' }, { 'tern {', 'ternFenceLang' },
      { '.live', 'ternAttrClass' }, { '```js', 'ternFenceCode' }, { '# not a heading', 'ternFenceCode' },
      { '# not a heading', '!ternHeading' }, { '````', 'ternFenceDelim', 0, from = 6 },
      { '~~~python', 'ternFence' }, { 'python', 'ternFenceLang' }, { 'A *title*', 'ternBlockTitle' },
      { '#lst', 'ternAttrId' }, { 'lines', 'ternAttrKey' }, { '``` not', 'ternFenceCode' },
      { '```a`b```', '!ternFence' }, { '```a`b```', 'ternCode' }, { 'para *after*', '!ternFence' },
      { '> ```', 'ternQuote' }, { '# quoted code', 'ternFenceCode' }, { 'after *the* quote', '!ternFence' },
      { '- ```js', 'ternListMarker' }, { 'let x', 'ternFenceCode_javascript' }, { 'after *the* item', '!ternFence' },
      { 'unclosed', 'ternFenceCode' }, { '# h', 'ternFenceCode' },
    })
  end },
  { 'fences in their language: js, css and html by default, others by option', function()
    local lines = { '```js', 'const a = 1;', '```', '```=html', '<b>raw</b>', '```', '```css', 'p { color: red }', '```',
      '```python', 'import os', '```' }
    note(lines)
    check({
      { 'const', 'ternFenceCode_javascript' }, { 'const', 'javaScriptReserved' },
      { '<b>raw', 'ternFenceCode_html' }, { '<b>raw', 'htmlTag' }, { 'p {', 'ternFenceCode_css' },
      { 'import', 'ternFenceCode' }, { 'import', '!ternFenceCode_python' },
    })
    note(lines, nil, { tern_fence_languages = { 'python' } })
    check({ { 'import', 'ternFenceCode_python' }, { 'import', 'pythonInclude' }, { 'const', 'ternFenceCode' } })
    note(lines, nil, { tern_fence_languages = vim.empty_dict() })
    check({ { 'const', 'ternFenceCode' }, { 'const', '!ternFenceCode_javascript' } })
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
      { '\\dim V', 'ternMathBlock' }, { '$$ {#eq-rn', 'ternMathDelim' }, { '#eq-rn', 'ternAttrId' },
      { 'e^{i', 'ternMathBlock' }, { '#eq-e', 'ternAttrId' }, { '$$ x $$ is', '!ternMathBlock' },
      { '\\$$', 'ternEscape' }, { '\\$$', '!ternMathBlock', 1 },
      { 'after the blank', 'none' }, { '## A heading ends', 'ternHeading' }, { '## A heading ends', '!ternMathBlock' },
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
      'A *Tern* paragraph',
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
      { '# not a heading', 'ternHtmlComment' }, { '# in pre', 'ternHtmlBlock' }, { '</pre >', 'ternHtmlBlock' },
      { '# after pre', 'ternHeading' }, { '<div class', 'ternHtmlBlock' }, { '<div class', 'htmlTag' },
      { 'inner', 'ternHtmlBlock' }, { '*x*', '!ternEmphasis' }, { '# still inside', 'ternHtmlBlock' },
      { '# still inside', '!ternHeading' }, { '# after div', 'ternHeading' }, { '<hr', 'ternHtmlBlock' },
      { '<p>', 'ternHtmlBlock' }, { '*Tern*', 'ternEmphasis' }, { '*Tern*', '!ternHtmlBlock' },
      { '**raw**', 'ternHtmlBlock' }, { '**raw**', '!ternStrong' }, { '<b>Bold', 'ternHtmlInline' },
      { '<b>Bold', '!ternHtmlBlock' }, { '*paragraph*', 'ternEmphasis' }, { '<divider>', '!ternHtmlBlock' },
      { '*em*', 'ternEmphasis' }, { 'unclosed', 'ternHtmlBlock' }, { ':::', 'ternCloser', 0, from = 27 },
      { '# after aside', 'ternHeading' },
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
      { ':::meta', 'ternMeta' }, { ':::meta', 'ternBlockDelim' }, { 'meta', 'ternBlockName' },
      { 'title', 'ternMetaKey' }, { 'Linear maps', 'ternMetaBody' }, { ':::aside', 'ternMetaBody' },
      { ':::aside', '!ternBlockDelim' }, { '\\gdef', 'ternMacrosBody' }, { ':::/macros', 'ternCloser' },
      { 'Flow', 'ternBlockTitle' }, { 'raw #flow', 'ternAttrKey' }, { '*not em*', 'ternRawText' },
      { '*not em*', '!ternEmphasis' }, { 'alert', 'ternRawText' }, { '*em*', 'ternEmphasis' },
      { '*em*', '!ternRawText' },
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
      { '`a``b`', 'ternCode' }, { '``a`b``', 'ternCode' }, { 'lone `', '!ternCode', 5 },
      { '$5 and $10', '!ternMath' }, { '$10', '!ternMath' }, { '$x$', 'ternMath' }, { '$\\$$', 'ternMath' },
      { '$]0,1[$', '!ternMath' }, { '$`]0,1[`', 'ternMath' }, { '$a$2', '!ternMath' },
      { '*em*', 'ternEmphasis' }, { '**strong**', 'ternStrong' }, { '***both***', 'ternStrongEmphasis' },
      { '2 * 3', '!ternEmphasis', 2 }, { '~~gone~~', 'ternStrike' }, { '==key==', 'ternMark' }, { 'a==b', '!ternMark', 1 },
      { '[link]', 'ternLink', 1 }, { 'https://x.org "T"', 'ternLinkDest' }, { '"T"', 'ternLinkTitle' },
      { '.btn', 'ternAttrClass' }, { '![alt]', 'ternLink', 2 }, { '[span]', 'ternSpan', 1 }, { '.term', 'ternAttrClass' },
      { ':kbd', 'ternElement' }, { 'Ctrl', 'ternElementText' }, { '30[x]', 'none', 2 },
      { '@thm-rn', 'ternRef' }, { '@kernel--', 'ternRef' }, { '@kernel--', '!ternRef', 7 }, { 'me@x.org', '!ternRef', 2 },
      { '[^a]', 'ternFootnoteRef' }, { 'Wow!', '!ternLink', 3 }, { '<https://a.b>', 'ternAutolink' },
      { 'https://x.org/a.', 'ternAutolink' }, { 'https://x.org/a.', '!ternAutolink', 15 },
      { '&amp;', 'ternEntity' }, { '&copy', '!ternEntity' }, { '\\*', 'ternEscape' }, { '\\alpha', 'none' },
      { '<b class', 'ternHtmlInline' }, { '<b class', 'htmlTag' }, { '<div>x', 'none' }, { '<!-- c', 'ternHtmlComment' },
      { '`c`{.x}', 'ternAttrClass', 4 },
      { '==重要', 'ternMark' }, { '@kernelです', 'ternRef' },
      { 'break\\', 'ternHardBreak', 5 },
      { 'span`', 'ternCode' }, { 'x_i$', 'ternMath' }, { '*not', 'none' }, { 'closed*', 'none' },
    })
  end },
  { 'the groups keep their default links', function(T)
    note({ '# x' })
    local links = {
      ternHeading = 'Title', ternBlockName = 'Statement', ternAttrId = 'Identifier', ternAttrValue = 'String',
      ternMath = 'Special', ternMathBlock = 'ternMath', ternRef = 'Identifier', ternCode = 'String',
      ternFenceCode = 'String', ternFenceDelim = 'Delimiter', ternLink = 'Underlined', ternHtmlComment = 'Comment',
    }
    for group, want in pairs(links) do
      -- Names are case-insensitive: a TernMath defined elsewhere is this group.
      T.eq(api.nvim_get_hl(0, { name = group }).link, want, group .. ' links to')
    end
  end },
  { 'examples/code.html', function(T)
    if not page(T, 'examples/code.html') then
      return
    end
    check({
      { 'window.TERN', 'ternHead' }, { '<script src="../tern.js">', 'ternHead' }, { 'title: Notes', 'ternMetaKey' },
      { '# Notes on iterators', 'ternHeading' }, { 'function* fib', 'ternFenceCode_javascript' },
      { 'A lazy Fibonacci', 'ternBlockTitle' }, { '#lst-fib', 'ternAttrId' }, { '@lst-fib yields', 'ternRef' },
      { '`` ` ``', 'ternCode' }, { '``a`b``', 'ternCode' }, { 'Vec<T> and', '!ternHtmlInline', 3 },
      { 'def take', 'ternFenceCode' }, { 'asterisk \\*', 'ternEscape', 9 }, { '$5 (no', '!ternMath' },
      { '\\$x\\$', 'ternEscape' }, { '\\# Not a heading', '!ternHeading' }, { '<!-- TODO', 'ternHtmlComment' },
      { '<form id', 'ternHtmlBlock' }, { '<button>Check', 'ternHtmlBlock' }, { '<table class', 'ternHtmlBlock' },
      { '[data-t="note"]', 'ternHtmlBlock' }, { '[data-t="note"]', 'cssStyle' }, { 'for (const pre', 'javaScript' },
    }, true)
  end },
  { 'docs/syntax-blocks.html', function(T)
    if not page(T, 'docs/syntax-blocks.html') then
      return
    end
    check({
      { ':::meta', 'ternMeta' }, { '# Syntax: blocks {#top}', 'ternHeading' }, { '::toc', 'ternLeafDelim' },
      { '=====', 'ternFenceCode' }, { '> # code, not a heading', 'ternFenceCode' },
      { '<!doctype html><html lang="en">', 'ternHead' }, { '## The eight rules', 'ternHeading' },
    }, true)
  end },
  { 'no errors on any page of the Tern repository', function(T)
    local root = T.tern_root()
    if not root then
      print('    (skipped: no Tern checkout; set $TERN_ROOT)')
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
    local root = T.tern_root()
    if not root then
      print('    (skipped: no Tern checkout; set $TERN_ROOT)')
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
    local root = T.tern_root()
    if not root or vim.fn.executable('node') == 0 then
      print('    (skipped: needs node and a Tern checkout)')
      return
    end
    -- Each ```tern fence of the docs, with the start of every node of its AST.
    local script = [[
      const fs = require('fs'), path = require('path'), root = process.argv[1];
      const tern = require(path.join(root, 'tern.js')), out = [];
      for (const f of fs.readdirSync(path.join(root, 'docs')).filter((f) => f.endsWith('.html'))) {
        const lines = fs.readFileSync(path.join(root, 'docs', f), 'utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
          const m = /^(\s*)(`{3,})tern\b/.exec(lines[i]);
          if (!m) continue;
          const close = new RegExp('^\\s*' + m[2] + '`*\\s*$'), body = [];
          while (++i < lines.length && !close.test(lines[i])) body.push(lines[i].slice(m[1].length));
          const nodes = [];
          (function walk(n) {
            if (n.type !== 'root' && n.type !== 'text' && n.position)
              nodes.push([n.type + (n.data && n.data.tern && n.data.tern.kind ? ':' + n.data.tern.kind : ''), n.position.start.line, n.position.start.column]);
            (n.children || []).forEach(walk);
          })(tern.parse(body.join('\n')).ast);
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
      containerDirective = set('ternBlockDelim', 'ternMeta', 'ternMacros', 'ternRaw', 'ternReserved'),
      leafDirective = set('ternLeafDelim'), textDirective = set('ternElement'), inlineCode = set('ternCode'),
      code = set('ternFence'), ['html:fence'] = set('ternFence'), heading = set('ternHeading'), ref = set('ternRef'),
      inlineMath = set('ternMath'), tableRow = set('ternTableRow', 'ternTableSep'), math = set('ternMathBlock'),
      footnoteReference = set('ternFootnoteRef'), footnoteDefinition = set('ternFootnoteDef'),
      blockquote = set('ternQuote'), listItem = set('ternListMarker'), ['html:generic'] = set('ternHtmlBlock'),
      ['html:rawtext'] = set('ternHtmlBlock'), ['html:oneline'] = set('ternHtmlBlock'),
      ['html:comment'] = set('ternHtmlComment'), ['html:inline'] = set('ternHtmlInline', 'ternHtmlComment'),
      strong = set('ternStrong', 'ternStrongEmphasis'), emphasis = set('ternEmphasis', 'ternStrongEmphasis'),
      delete = set('ternStrike'), mark = set('ternMark'), span = set('ternSpan'),
      link = set('ternLink', 'ternAutolink'), image = set('ternLink'), thematicBreak = set('ternRule'),
    }
    local verbatim = set('ternFence', 'ternMathBlock', 'ternHtmlBlock', 'ternHtmlComment', 'ternMeta', 'ternMacros',
      'ternRaw', 'ternReserved', 'ternHead')
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
