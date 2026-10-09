" SPDX-License-Identifier: MIT
" Vim syntax for Tern notes (filetype tern).
"
" A lexical approximation: every construct is recognised from its own text,
" so it is fast and never breaks on a long note. Exact structure (raw HTML
" depth, emphasis pairing, which lines a list item owns) comes from the
" language server. Line constructs also match after `>` quote markers.
"
" Highlight groups, linked with `hi def link` (restyle any of them):
"   ternHeading         a heading line              ternHeadingDelim  its #s
"   ternBlockDelim      ::: of an opener            ternBlockName     its name
"   ternBlockTitle      [Title] of an opener/fence  ternTitleDelim    its [ ]
"   ternLeafDelim       :: of a leaf                ternLeafName      its name
"   ternCloser          ::: or :::/name             ternCloserName    the name
"   ternCellSep         +++                         ternRule          ---
"   ternQuote           > markers                   ternListMarker    - 1.
"   ternTask            [ ] [x]                     ternFootnoteDef   [^x]:
"   ternTablePipe       | in a table row            ternTableSep      |---|
"   ternAttr            {…} group                   ternAttrId        #id
"   ternAttrClass       .class                      ternAttrKey       key
"   ternAttrValue       =value                      ternFenceDelim    ``` ~~~
"   ternFenceLang       a fence's language          ternFenceCode     its body
"   ternMathBlock       $$ … $$                     ternMathDelim     $$
"   ternHtmlComment     <!-- -->                    ternMetaKey       :::meta keys
"   ternMetaBody        :::meta values              ternMacrosBody    :::macros body
"   ternRawText         the body of a {raw} or :::script/style/html container
"   ternEscape          \*                          ternHardBreak     \ at EOL
"   ternCode            `code`                      ternMath          $x$, $`x`
"   ternEmphasis        *em*                        ternStrong        **strong**
"   ternStrongEmphasis  ***both***                  ternEmphasisDelim * ** ~~ ==
"   ternStrike          ~~gone~~                    ternMark          ==key==
"   ternLink            [text] of a link or image   ternLinkDelim     [ ]( ) !
"   ternLinkDest        (destination "title")       ternLinkTitle     its title
"   ternSpanDelim       [ ] of [text]{…}            ternElement       :name
"   ternElementDelim    [ ] of :name[…]             ternRef           @id
"   ternFootnoteRef     [^x]                        ternAutolink      URLs
"   ternEntity          &amp;                       ternHtmlInline    <b> </b>
" Regions without a style of their own, which synstack() shows: ternHead
" (HTML inside), ternHtmlBlock (HTML inside), ternFence, ternFenceCode_{syntax}
" (that syntax inside), ternMeta, ternMacros, ternRaw, ternReserved,
" ternTableRow, ternAttrLine, ternSpan, ternElementText, ternLeafContent.
"
" Fenced code is highlighted in its language for the syntaxes named in
" b:tern_fence_languages or g:tern_fence_languages (default: javascript, css
" and html, which the HTML syntax brings in at no cost). Each extra one, such
" as 'python' or 'sh', loads that syntax file with every note: [] turns
" languages off. An entry matches its own name and the usual aliases (py,
" bash, js …); a {'name': ['word', …]} dict sets the info words explicitly.

if !exists('main_syntax')
  if exists('b:current_syntax')
    finish
  endif
  let main_syntax = 'tern'
endif

let s:cpo_save = &cpo
set cpo&vim
" Compile every pattern, the included syntaxes' too, for the backtracking
" regexp engine: on notes it parses about twice as fast as the NFA engine,
" whose cost grows with long alternations such as the HTML tag names.
let s:re_save = &regexpengine
set regexpengine=1

" html.vim also includes JavaScript and CSS (@htmlJavaScript, @htmlCss).
syn include @ternHtml syntax/html.vim
unlet! b:current_syntax
syn case match
syn spell toplevel

" ---------------------------------------------------------------------------
" Pattern pieces. Letters outside ASCII are approximated by every non-ASCII
" character but the common punctuation, symbol and space blocks (s:X); the
" ranges stay under 257 characters for the backtracking regexp engine.
let s:X = '\u0080-\u00bf\u00d7\u00f7\u2000-\u206f\u20a0-\u20cf'
      \ . '\u2190-\u21ff\u2200-\u22ff\u2300-\u23ff\u2500-\u25ff\u2600-\u26ff\u2700-\u27bf'
      \ . '\u3000-\u303f\uff00-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65'
let s:L = '[^\x01-\x40\x5b-\x60\x7b-\x7f' . s:X . ']'                 " a letter: starts a NAME
let s:C = '[^\x01-\x2c\x2e\x2f\x3a-\x40\x5b-\x5e\x60\x7b-\x7f' . s:X . ']'  " letter, digit, _ or -
let s:NAME = s:L . s:C . '*'
let s:NB = '\%(' . s:C . '\)\@!'                                       " the end of a NAME
" An IDENT starts with a letter or _; trailing hyphens are not part of it.
let s:IDENT = '[^\x01-\x40\x5b-\x5e\x60\x7b-\x7f' . s:X . ']\%(' . s:C . '*[^\x01-\x2f\x3a-\x40\x5b-\x5e\x60\x7b-\x7f' . s:X . ']\)\='
let s:LABEL = s:C . '\+'
" The start of a line, after any quote markers and indentation.
let s:Q = '^\%([ \t>]*\)\@>'
" Verbatim regions come in two variants: unquoted, and quoted, which also
" ends at the first line that leaves the quote.
let s:VARIANTS = [['^\s*', ''], ['^\s*>\%([ \t>]*\)\@>', ' end=/^\ze\%(\s*>\)\@!/']]
" A fence may also open on a list item's marker line; it closes indented.
let s:ITEM = '\%([-*+]\|\d\{1,9}[.)]\)[ \t]\+'
" An attribute group: { to the first } outside quotes, no { inside, not empty.
" No backtick either: a code span binds tighter than an attribute value.
let s:GROUP = '{\s*\%([^{}"''` \t]\|"[^"`]*"\|''[^''`]*''\)[^{}"''`]*\%(\%("[^"`]*"\|''[^''`]*''\)[^{}"''`]*\)\{,99}}'
" A line that ends a paragraph; inline spans never reach past one.
let s:STOP = '\s*\%($\|#\{1,6}\%(\s\|$\)\|:::\|```\|\~\~\~\|\$\$\|+++\|>\|[-*+]\%(\s\|$\)\|\d\{1,9}[.)]\%(\s\|$\)\)'
let s:NL = '\n\%(' . s:STOP . '\)\@!'
let s:P = '\%(.\|' . s:NL . '\)'                " a character of the same paragraph
" How far an inline construct may reach for its closer: bounded, so that a
" paragraph full of unmatched openers stays linear and within maxmempattern.
let s:MAX = 600
" Bracket text, with one level of nested brackets; a code span in it may
" hold a bracket.
let s:BC = '\%([^\[\]\\`]\|\\.\|`[^`]*`\|`\%([^`]*`\)\@!\|' . s:NL . '\)'
let s:BT = '\%(' . s:BC . '\|\[' . s:BC . '\{,' . s:MAX . '}\]\)\{,' . s:MAX . '}'

" ---------------------------------------------------------------------------
" Inline constructs. Defined first: a line construct starting at the same
" column wins over them.
syn cluster ternInline contains=@Spell,ternEscape,ternHardBreak,ternCode,ternMath,ternEntity,
      \ ternAutolink,ternHtmlInline,ternHtmlComment,ternRef,ternFootnoteRef,ternLink,ternSpan,
      \ ternElement,ternEmphasis,ternStrong,ternStrongEmphasis,ternStrike,ternMark

exe 'syn match ternAttr /' . s:GROUP . '/ contained contains=ternAttrId,ternAttrClass,ternAttrKey,ternAttrValue'
syn match ternAttrId /[{[:space:]]\@1<=#[^[:space:]{}"'#.=]\+/ contained
syn match ternAttrClass /[{[:space:]]\@1<=\.[^[:space:]{}"'#.=]\+/ contained
syn match ternAttrKey /[{[:space:]]\@1<=[^[:space:]{}"'#.=][^[:space:]{}"'=]*/ contained
syn match ternAttrValue /=\zs\%("[^"]*"\|'[^']*'\|[^[:space:]"'=<>`{}]\+\)/ contained

" Brackets that are none of the constructs below, so that their ] does not
" end the construct around them.
exe 'syn region ternBracket start=/\[/ end=/\]/ end=/^\ze' . s:STOP . '/ contained transparent contains=@ternInline,ternBracket'

exe 'syn region ternEmphasis matchgroup=ternEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\@!\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*\@!/ end=/^\ze' . s:STOP . '/ contains=@ternInline nextgroup=ternAttr'
exe 'syn region ternStrong matchgroup=ternEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\*\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*/ end=/^\ze' . s:STOP . '/ contains=@ternInline nextgroup=ternAttr'
exe 'syn region ternStrongEmphasis matchgroup=ternEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\*\*\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\*\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*\*/ end=/^\ze' . s:STOP . '/ contains=@ternInline nextgroup=ternAttr'
" ~~ and ==: runs of exactly two, not glued to an ASCII letter or digit.
for [s:group, s:ch, s:cc] in [['ternStrike', '\~', '~'], ['ternMark', '=', '=']]
  exe 'syn region ' . s:group . ' matchgroup=ternEmphasisDelim'
        \ . ' start=/' . s:ch . '\%([' . s:cc . 'A-Za-z0-9]' . s:ch . '\)\@6<!' . s:ch . '\%([^[:space:]' . s:cc . ']\%(' . s:P
        \ . '\{-,' . s:MAX . '}[^[:space:]' . s:cc . ']\)\=' . s:ch . s:ch . '[' . s:cc . 'A-Za-z0-9]\@!\)\@=/'
        \ . ' end=/[^[:space:]' . s:cc . ']\@4<=' . s:ch . s:ch . '[' . s:cc . 'A-Za-z0-9]\@!/'
        \ . ' end=/^\ze' . s:STOP . '/ contains=@ternInline nextgroup=ternAttr'
endfor

" [text](dest), ![alt](src): only when the brackets close and a destination
" follows, without a backtick (a code span would take it).
let s:DEST = '\%([^`()\\<]\|\\.\|([^`()]*)\|<[^<>`\n]*>\)\{,' . s:MAX . '}'
exe 'syn region ternLink matchgroup=ternLinkDelim start=/\[\%(\^\)\@!\%(' . s:BT . '\](' . s:DEST . ')\)\@=/'
      \ . ' end=/\]\%((\)\@=/ end=/^\ze' . s:STOP . '/ contains=@ternInline,ternBracket nextgroup=ternLinkDest'
exe 'syn region ternLink matchgroup=ternLinkDelim start=/!\[\%(\^\)\@!\%(' . s:BT . '\](' . s:DEST . ')\)\@=/'
      \ . ' end=/\]\%((\)\@=/ end=/^\ze' . s:STOP . '/ contains=@ternInline,ternBracket nextgroup=ternLinkDest'
syn region ternLinkDest matchgroup=ternLinkDelim start=/(/ skip=/\\./ end=/)/ oneline contained contains=ternEscape,ternLinkAngle,ternLinkParen,ternLinkTitle nextgroup=ternAttr
syn match ternLinkAngle /<[^<>]*>/ contained transparent contains=NONE
syn region ternLinkParen start=/(/ end=/)/ oneline contained transparent contains=ternLinkParen
syn region ternLinkTitle start=/\s\zs"/ skip=/\\./ end=/"/ oneline contained
syn region ternLinkTitle start=/\s\zs'/ skip=/\\./ end=/'/ oneline contained
" [text]{attrs}
exe 'syn region ternSpan matchgroup=ternSpanDelim start=/\[\%(\^\)\@!\%(' . s:BT . '\]' . s:GROUP . '\)\@=/'
      \ . ' end=/\]\%({\)\@=/ end=/^\ze' . s:STOP . '/ transparent contains=@ternInline,ternBracket nextgroup=ternAttr'
" :name[content]{attrs}; the : is not glued to an ASCII word, : or /.
exe 'syn match ternElement /:\%([A-Za-z0-9_:\/]:\)\@2<!' . s:NAME . '\ze\[' . s:BT . '\]/ nextgroup=ternElementText'
exe 'syn region ternElementText matchgroup=ternElementDelim start=/\[/ end=/\]/ end=/^\ze' . s:STOP . '/'
      \ . ' contained transparent contains=@ternInline,ternBracket nextgroup=ternAttr'

exe 'syn match ternFootnoteRef /\[\^' . s:LABEL . '\]/ nextgroup=ternAttr'
exe 'syn match ternRef /@\%([A-Za-z0-9_.\/@-]@\)\@2<!' . s:IDENT . '/ nextgroup=ternAttr'

" Autolinks: <scheme:…>, <a@b.c>, and bare http(s) URLs, which stop at
" whitespace and < > [ ] { } | " ` and give back trailing punctuation and an
" unbalanced ).
syn match ternAutolink /<[A-Za-z][A-Za-z0-9+.-]\{1,31}:[^[:space:]<>[:cntrl:]]*>/ nextgroup=ternAttr
syn match ternAutolink /<[^[:space:]<>@\\]\+@[A-Za-z0-9][-A-Za-z0-9.]*>/ nextgroup=ternAttr
let s:UC = '[^[:space:]<>\[\]{}|"`]'
let s:UE = '[^[:space:]<>\[\]{}|"`.,:;!?''*~=\\)]'
exe 'syn match ternAutolink /[hH]\%(\%(^\|[[:space:](\[|*~="''>]\)[hH]\)\@2<=[tT][tT][pP][sS]\=:\/\/\%(' . s:UC . '*([^()[:space:]<>\[\]{}|"`]*)\%('
      \ . s:UC . '*' . s:UE . '\)\=\|' . s:UC . '*' . s:UE . '\)/ nextgroup=ternAttr'

" Raw inline HTML: lower-case phrasing and custom-element tags, comments, and
" svg, math and textarea, which run verbatim to their closing tag.
let s:PHRASING = 'a\|abbr\|audio\|b\|bdi\|bdo\|br\|button\|canvas\|cite\|code\|data\|datalist\|del\|dfn'
      \ . '\|em\|embed\|i\|iframe\|img\|input\|ins\|kbd\|label\|mark\|meter\|object\|optgroup\|option'
      \ . '\|output\|picture\|progress\|q\|rp\|rt\|ruby\|s\|samp\|select\|small\|source\|span\|strong'
      \ . '\|sub\|sup\|time\|track\|u\|var\|video\|wbr'
let s:CUSTOM = '[a-z][-.0-9_a-z]*-[-.0-9_a-z]*'
let s:TB = '[-.0-9_a-zA-Z]\@!'                   " the end of a tag name
let s:TAG = '\%(' . s:PHRASING . '\|' . s:CUSTOM . '\)' . s:TB
let s:ATTR = '\_s\+[A-Za-z_:][A-Za-z0-9_.:-]*\%(\_s*=\_s*\%([^[:space:]"''=<>`]\+\|''[^'']*''\|"[^"]*"\)\)\='
exe 'syn match ternHtmlInline /<' . s:TAG . '\%(' . s:ATTR . '\)\{,49}\_s*\/\=>/ contains=htmlTag'
exe 'syn match ternHtmlInline /<\/' . s:TAG . '\_s*>/ contains=htmlEndTag'
exe 'syn match ternHtmlInline /<\(svg\|math\|textarea\)' . s:TB . s:P . '\{-,' . s:MAX . '}<\/\1\s*>/ contains=@ternHtml'
exe 'syn match ternHtmlComment /<!--\%(-\=>\|' . s:P . '\{-,' . s:MAX . '}-->\)/'

syn match ternEntity /&\%(#\d\{1,7}\|#[xX]\x\{1,6}\|[A-Za-z][A-Za-z0-9]\{1,31}\);/

" After a backtick run \1: up to the next run of the same length, through
" text, line breaks and runs of other lengths. Runs of more than 16
" backticks open nothing here: a long run would be tried from each of its
" backticks.
let s:TICKS = '\%(\%([^`]*\)\@>\%(\%(\1`\@!\)\@!\%(`\+\)\@>\|' . s:NL . '\)\)\{-,99}\%([^`]*\)\@>\1`\@!'
" $`…`: $ and a backtick run, to the next run of the same length.
exe 'syn match ternMath /\$\(\%(`\{1,16}\)\@>\)`\@!' . s:TICKS . '/ nextgroup=ternAttr'
" $…$, by the dollar rule: the opener is not next to another (unescaped) $,
" and is followed by neither space nor ) ] } , . ; : `; the next unescaped $
" decides: it closes when no space and no unescaped ( [ { comes before it,
" no digit or $ after it, and at most one line break lies in between.
let s:MB = '\%([^$\\]\|\\.\)'
exe 'syn match ternMath /\$\%(\%(^\|[^\\]\)\$\$\)\@6<!\%([[:space:]$`)\]},.;:]\|$\)\@!\%(' . s:MB . '\{,' . s:MAX . '}\n\)\='
      \ . s:MB . '\{,' . s:MAX . '}\%(\\.\|[^$\\[:space:]([{]\)\$\%(\d\|\$\)\@!/ nextgroup=ternAttr'

" `code`: a backtick run, to the next run of exactly the same length.
exe 'syn match ternCode /\(`\%(\%(^\|[^\\]\)``\)\@6<!\%(`\{,15}\)\@>\)`\@!' . s:TICKS . '/ nextgroup=ternAttr'

syn match ternEscape /\\[!-\/:-@\[\\\]^_`{|}~]/
syn match ternHardBreak /\\$/

" ---------------------------------------------------------------------------
" Line constructs. Each marker holds any quote markers before it.
syn match ternQuote /^\s*>\%(\s\|$\)\@=[ \t>]*/

exe 'syn match ternListMarker /' . s:Q . '\%([-*+]\|\d\{1,9}[.)]\)\%(\s\|$\)\@=/ contains=ternQuote nextgroup=ternTask skipwhite'
syn match ternTask /\[[ xX]\]\%(\s\|$\)\@=/ contained
exe 'syn match ternRule /' . s:Q . '\%(-\s*-\s*-[-[:space:]]*\|\*\s*\*\s*\*[*[:space:]]*\|_\s*_\s*_[_[:space:]]*\)$/ contains=ternQuote'

exe 'syn match ternFootnoteDef /' . s:Q . '\[\^' . s:LABEL . '\]:\%(\s\|$\)\@=/ contains=ternQuote'

exe 'syn match ternTableRow /' . s:Q . '|.*$/ contains=ternQuote,ternTablePipe,@ternInline'
syn match ternTablePipe /|/ contained
exe 'syn match ternTableSep /' . s:Q . '|[-:| \t]*-[-:| \t]*$/ contains=ternQuote'

" {#id .class key=value} alone on a line; one of # . = makes it strong.
exe 'syn match ternAttrLine /' . s:Q . '\%([^}]*[#.=]\)\@=\%(' . s:GROUP . '\s*\)\+$/ contains=ternQuote,ternAttr'

" ## Heading {#id}: the text runs to a trailing group, if any.
exe 'syn match ternHeading /' . s:Q . '#\{1,6}\%(\s.*\)\=$/ contains=ternHeadingDelim'
exe 'syn match ternHeadingDelim /' . s:Q . '#\{1,6}/ contained contains=ternQuote nextgroup=ternHeadingText'
exe 'syn match ternHeadingText /.\{-}\ze\%(\s*' . s:GROUP . '\)\=\s*$/ contained transparent'
      \ . ' contains=@ternInline nextgroup=ternAttr skipwhite'

" :::name[Title]{attrs}, ::name[content]{attrs}, ::: and :::/name, +++ {attrs}
exe 'syn match ternBlockDelim /' . s:Q . ':\{3,}\ze' . s:L . '/ contains=ternQuote nextgroup=ternBlockName'
exe 'syn match ternBlockName /' . s:NAME . '/ contained nextgroup=ternBlockTitle,ternAttr skipwhite'
exe 'syn region ternBlockTitle matchgroup=ternTitleDelim start=/\[/ end=/\]/ oneline contained'
      \ . ' contains=@ternInline,ternBracket nextgroup=ternAttr skipwhite'
exe 'syn match ternLeafDelim /' . s:Q . '::\ze' . s:L . '/ contains=ternQuote nextgroup=ternLeafName'
exe 'syn match ternLeafName /' . s:NAME . '/ contained nextgroup=ternLeafContent,ternAttr skipwhite'
exe 'syn region ternLeafContent matchgroup=ternTitleDelim start=/\[/ end=/\]/ oneline contained transparent'
      \ . ' contains=@ternInline,ternBracket nextgroup=ternAttr skipwhite'
exe 'syn match ternCloser /' . s:Q . ':\{3,}\%(\/' . s:NAME . '\)\=\s*$/ contains=ternQuote,ternCloserName'
exe 'syn match ternCloserName /\/\zs' . s:NAME . '/ contained'
exe 'syn match ternCellSep /' . s:Q . '+\{3,}\ze\s*\%(' . s:GROUP . '\)\=\s*$/ contains=ternQuote nextgroup=ternAttr skipwhite'

" $$ display math $$ {#eq}: to the next unescaped $$, or up to a line that
" terminates it (blank, heading, fence, ::: or +++), which stays outside.
" A line with $$ … $$ and more text after it is no display math.
for [s:pre, s:quoted] in s:VARIANTS
  exe 'syn region ternMathBlock matchgroup=ternMathDelim start=/' . s:pre . '\$\$\%(\%([^\\$]\|\\.\|\$\$\@!\)\{,'
        \ . s:MAX . '}\$\$\%(\s*\%(' . s:GROUP . '\)\=\s*$\)\@!\)\@!/ skip=/\\./ end=/\$\$/' . s:quoted
        \ . ' end=/^\ze[ \t>]*\%($\|#\{1,6}\%(\s\|$\)\|```\|\~\~\~\|:::\|+++\)/ keepend nextgroup=ternAttr skipwhite'
endfor

" ---------------------------------------------------------------------------
" Verbatim regions. The opener line is matched inside the region (so its
" parts can be highlighted), and its nextgroup is a body that runs to the
" region's end: nothing in the body is ever read as an opener again.

" Fences: a run of 3+ backticks (no backtick in the info) or tildes, closed
" by a run of the same character at least as long.
" [run, rest of the opener line, closing line] per fence character.
let s:fence = [['\%(`\{3,}\)\@>', '[^`]*$', '\z1`*\s*$'], ['\%(\~\{3,}\)\@>', '.*$', '\z1\~*\s*$']]
function! s:Fence(suffix, info, cluster) abort
  let l:info = a:info ==# '' ? '' : '\s*\%(' . a:info . '\)\%([[{ \t]\|$\)\@='
  for [l:run, l:rest, l:close] in s:fence
    for [l:pre, l:quoted] in s:VARIANTS + [['^\s*' . s:ITEM, '']]
      exe 'syn region ternFence start=/' . l:pre . '\z(' . l:run . '\)' . l:info . l:rest . '/'
            \ . ' matchgroup=ternFenceDelim end=/' . (l:quoted ==# '' ? '^\s*' : l:pre) . l:close . '/' . l:quoted
            \ . ' keepend contains=ternFenceOpen' . a:suffix
    endfor
  endfor
  exe 'syn match ternFenceOpen' . a:suffix . ' /.*$/ contained contains=ternFenceDelim nextgroup=ternFenceCode' . a:suffix . ' skipnl'
  exe 'syn region ternFenceCode' . a:suffix . ' start=/^/ end=/\%$/ contained' . (a:cluster ==# '' ? '' : ' contains=' . a:cluster)
endfunction

exe 'syn match ternFenceDelim /' . s:Q . '\%(' . s:ITEM . '\)\=\%(`\{3,}\|\~\{3,}\)/ contained contains=ternQuote,ternListMarker'
      \ . ' nextgroup=ternFenceLang,ternBlockTitle,ternAttr skipwhite'
syn match ternFenceLang /[^[:space:][\]{}`]\+/ contained nextgroup=ternBlockTitle,ternAttr skipwhite
call s:Fence('', '', '')

let s:fence_words = {
      \ 'javascript': ['js', 'javascript', 'mjs', 'cjs', 'jsx'],
      \ 'typescript': ['ts', 'typescript', 'tsx'],
      \ 'html': ['html', '=html', 'xhtml'],
      \ 'python': ['py', 'python', 'python3'],
      \ 'sh': ['sh', 'bash', 'shell', 'zsh', 'console'],
      \ 'ruby': ['rb', 'ruby'],
      \ 'rust': ['rs', 'rust'],
      \ 'vim': ['vim', 'viml'],
      \ 'tex': ['tex', 'latex'],
      \ 'yaml': ['yaml', 'yml'],
      \ 'markdown': ['md', 'markdown'],
      \ 'cpp': ['cpp', 'c++', 'cxx'],
      \ }
let s:free = {'html': '@ternHtml', 'javascript': '@htmlJavaScript', 'css': '@htmlCss'}
let s:langs = get(b:, 'tern_fence_languages', get(g:, 'tern_fence_languages', ['javascript', 'css', 'html']))
if type(s:langs) == v:t_list
  let s:langs = map(copy(s:langs), {_, n -> [n, get(s:fence_words, n, [n])]})
elseif type(s:langs) == v:t_dict
  let s:langs = items(s:langs)
else
  let s:langs = []
endif
for [s:name, s:words] in s:langs
  if s:name !~# '^[A-Za-z0-9_]\+$' || empty(s:words)
    continue
  endif
  if type(s:words) == v:t_string
    let s:words = [s:words]
  endif
  let s:cluster = get(s:free, s:name, '')
  if s:cluster ==# ''
    if empty(globpath(&runtimepath, 'syntax/' . s:name . '.vim'))
      continue
    endif
    let s:cluster = '@ternLang_' . s:name
    exe 'syn include ' . s:cluster . ' syntax/' . s:name . '.vim'
    unlet! b:current_syntax
    syn case match
  endif
  call s:Fence('_' . s:name, join(map(copy(s:words), {_, w -> escape(w, '\.*$^~[]/')}), '\|'), s:cluster)
endfor

" Raw HTML blocks, by their first line. Comments run to -->, raw-text
" elements to their end tag, generic block-level and custom elements to their
" balancing end tag or up to a ::: line; one-line tags (end tags, void,
" self-closed, end-tag-optional) are their line. The whole closing line
" belongs to the block.
let s:BLOCK = 'address\|article\|aside\|audio\|blockquote\|canvas\|details\|dialog\|div\|dl\|fieldset'
      \ . '\|figcaption\|figure\|footer\|form\|h[1-6]\|header\|hgroup\|iframe\|math\|menu\|nav\|noscript'
      \ . '\|object\|ol\|picture\|search\|section\|summary\|svg\|table\|template\|ul\|video'
let s:RAWTEXT = 'script\|style\|pre\|textarea'
let s:ONELINE = 'p\|li\|dd\|dt\|tr\|td\|th\|thead\|tbody\|tfoot'
let s:VOID = 'hr\|link'
for [s:pre, s:quoted] in s:VARIANTS
  exe 'syn region ternHtmlComment start=/' . s:pre . '<!\ze--/ end=/-->.*$/' . s:quoted . ' keepend contains=ternQuote'
  exe 'syn region ternHtmlBlock start=/\c' . s:pre . '<\z(' . s:RAWTEXT . '\)' . s:TB . '/ end=/\c<\/\z1\s*>.*\zs$/' . s:quoted
        \ . ' keepend contains=ternQuote,@ternHtml'
endfor
" A generic block is its first element (ternHtmlNest, which extends it to
" that element's end tag, counting nested elements) and the rest of the line
" where that ends; another element still open on that line extends it again.
for [s:names, s:case] in [[s:BLOCK, '\c'], [s:CUSTOM, '']]
  for [s:pre, s:quoted] in s:VARIANTS
    exe 'syn region ternHtmlBlock start=/' . s:case . s:pre . '<\%(' . s:names . '\)' . s:TB . '/'
          \ . ' end=/^\ze[ \t>]*:::/' . s:quoted . ' end=/.*\zs$/ keepend contains=ternHtmlNest,ternQuote,@ternHtml'
  endfor
  exe 'syn region ternHtmlNest start=/' . s:case . '<\z(' . s:names . '\)' . s:TB . '\%([^>]*\/>\)\@!/'
        \ . ' end=/' . s:case . '<\/\z1\s*>/ end=/^\ze[ \t>]*:::/ contained keepend extend transparent contains=ternHtmlNest,ternQuote,@ternHtml'
endfor
exe 'syn match ternHtmlBlock /\c' . s:Q . '\%(<\/\%(' . s:BLOCK . '\|' . s:RAWTEXT . '\|' . s:ONELINE . '\|' . s:VOID . '\)' . s:TB
      \ . '\|<\%(' . s:VOID . '\|' . s:ONELINE . '\)' . s:TB . '\|<\%(' . s:BLOCK . '\)' . s:TB . '[^>]*\/>\).*$/ contains=ternQuote,@ternHtml'
exe 'syn match ternHtmlBlock /' . s:Q . '\%(<\/' . s:CUSTOM . s:TB . '\|<' . s:CUSTOM . s:TB . '[^>]*\/>\).*$/ contains=ternQuote,@ternHtml'

" Raw-body containers: :::meta, :::macros, :::script/style/html (reserved)
" and :::name{raw}, to a bare closer or their own named closer.
function! s:Raw(group, name, rest, body, contains) abort
  exe 'syn region ' . a:group . ' start=/' . s:Q . ':\{3,}\z(' . a:name . '\)' . a:rest . '.*$/'
        \ . ' matchgroup=ternCloser end=/' . s:Q . ':\{3,}\%(\/\z1\)\=\s*$/ keepend contains=' . a:group . 'Open'
  exe 'syn match ' . a:group . 'Open /.*$/ contained contains=ternBlockDelim nextgroup=' . a:body . ' skipnl'
  exe 'syn region ' . a:body . ' start=/^/ end=/\%$/ contained' . (a:contains ==# '' ? '' : ' contains=' . a:contains)
endfunction
call s:Raw('ternRaw', s:NAME, '[^{]*{\%([^}]*\s\)\=raw[[:space:]}=]', 'ternRawText', '')
call s:Raw('ternReserved', 'script\|style\|html', s:NB, 'ternRawText', '')
call s:Raw('ternMacros', 'macros', s:NB, 'ternMacrosBody', '')
call s:Raw('ternMeta', 'meta', s:NB, 'ternMetaBody', 'ternMetaKey')
syn match ternMetaKey /^\s*[^:[:space:]][^:]*\ze:/ contained

" The head: everything up to and including the tern.js line, as HTML. It is
" found by its text, the first <script …tern.js…> tag (a looser match than
" tern.detect, so it never ends after the real one), and follows edits.
syn region ternHead start=/\%^/ end=/\c<script\>[^>]*tern\.js[^>]*>.*\zs$/ keepend contains=@ternHtml

" Verbatim regions span many lines, so parse from the start of the file:
" exact, and Vim keeps the state of every line, so only the first full parse
" costs, about 50 ms per 1,000 lines. Past 20,000 lines that would near
" 'redrawtime', so start 500 lines above the screen instead: a fence or raw
" block longer than that may then be misread until it scrolls into view.
syn sync clear
if line('$') <= 20000
  syn sync fromstart linebreaks=1
else
  syn sync minlines=500 linebreaks=1
endif

" ---------------------------------------------------------------------------
hi def link ternHeading Title
hi def link ternHeadingDelim Delimiter
hi def link ternBlockDelim Delimiter
hi def link ternBlockName Statement
hi def link ternBlockTitle Title
hi def link ternTitleDelim Delimiter
hi def link ternLeafDelim Delimiter
hi def link ternLeafName ternBlockName
hi def link ternCloser Delimiter
hi def link ternCloserName Statement
hi def link ternCellSep Delimiter
hi def link ternRule Delimiter
hi def link ternQuote Delimiter
hi def link ternListMarker Delimiter
hi def link ternTask Special
hi def link ternFootnoteDef Identifier
hi def link ternTablePipe Delimiter
hi def link ternTableSep Delimiter
hi def link ternAttr Delimiter
hi def link ternAttrId Identifier
hi def link ternAttrClass Type
hi def link ternAttrKey Special
hi def link ternAttrValue String
hi def link ternFenceDelim Delimiter
hi def link ternFenceLang Type
hi def link ternFenceCode String
hi def link ternMathBlock ternMath
hi def link ternMathDelim Delimiter
hi def link ternHtmlComment Comment
hi def link ternMetaKey Identifier
hi def link ternMetaBody String
hi def link ternMacrosBody ternMath
hi def link ternRawText String
hi def link ternEscape Special
hi def link ternHardBreak Special
hi def link ternCode String
hi def link ternMath Special
hi def ternEmphasis term=italic cterm=italic gui=italic
hi def ternStrong term=bold cterm=bold gui=bold
hi def ternStrongEmphasis term=bold,italic cterm=bold,italic gui=bold,italic
hi def link ternEmphasisDelim Delimiter
hi def ternStrike term=strikethrough cterm=strikethrough gui=strikethrough
hi def link ternMark Search
hi def link ternLink Underlined
hi def link ternLinkDelim Delimiter
hi def link ternLinkDest String
hi def link ternLinkTitle String
hi def link ternSpanDelim Delimiter
hi def link ternElement Statement
hi def link ternElementDelim Delimiter
hi def link ternRef Identifier
hi def link ternFootnoteRef Identifier
hi def link ternAutolink Underlined
hi def link ternEntity Special

delfunction s:Fence
delfunction s:Raw
let b:current_syntax = 'tern'
if main_syntax ==# 'tern'
  unlet main_syntax
endif
let &regexpengine = s:re_save
let &cpo = s:cpo_save
unlet s:cpo_save s:re_save
