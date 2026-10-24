" SPDX-License-Identifier: MIT
" Vim syntax for Luccet notes (filetype luccet).
"
" A lexical approximation: every construct is recognised from its own text,
" so it is fast and never breaks on a long note. Exact structure (raw HTML
" depth, emphasis pairing, which lines a list item owns) comes from the
" language server. Line constructs also match after `>` quote markers.
"
" Highlight groups, linked with `hi def link` (restyle any of them):
"   luccetHeading         a heading line              luccetHeadingDelim  its #s
"   luccetBlockDelim      ::: of an opener            luccetBlockName     its name
"   luccetBlockTitle      [Title] of an opener/fence  luccetTitleDelim    its [ ]
"   luccetLeafDelim       :: of a leaf                luccetLeafName      its name
"   luccetCloser          ::: or :::/name             luccetCloserName    the name
"   luccetCellSep         +++                         luccetRule          ---
"   luccetQuote           > markers                   luccetListMarker    - 1.
"   luccetTask            [ ] [x]                     luccetFootnoteDef   [^x]:
"   luccetTablePipe       | in a table row            luccetTableSep      |---|
"   luccetAttr            {…} group                   luccetAttrId        #id
"   luccetAttrClass       .class                      luccetAttrKey       key
"   luccetAttrValue       =value                      luccetFenceDelim    ``` ~~~
"   luccetFenceLang       a fence's language          luccetFenceCode     its body
"   luccetMathBlock       $$ … $$                     luccetMathDelim     $$
"   luccetHtmlComment     <!-- -->                    luccetMetaKey       :::meta keys
"   luccetMetaBody        :::meta values              luccetMacrosBody    :::macros body
"   luccetRawText         the body of a {raw} or :::script/style/html container
"   luccetEscape          \*                          luccetHardBreak     \ at EOL
"   luccetCode            `code`                      luccetMath          $x$, $`x`
"   luccetEmphasis        *em*                        luccetStrong        **strong**
"   luccetStrongEmphasis  ***both***                  luccetEmphasisDelim * ** ~~ ==
"   luccetStrike          ~~gone~~                    luccetMark          ==key==
"   luccetLink            [text] of a link or image   luccetLinkDelim     [ ]( ) !
"   luccetLinkDest        (destination "title")       luccetLinkTitle     its title
"   luccetSpanDelim       [ ] of [text]{…}            luccetElement       :name
"   luccetElementDelim    [ ] of :name[…]             luccetRef           @id
"   luccetFootnoteRef     [^x]                        luccetAutolink      URLs
"   luccetEntity          &amp;                       luccetHtmlInline    <b> </b>
" Regions without a style of their own, which synstack() shows: luccetHead
" (HTML inside), luccetHtmlBlock (HTML inside), luccetFence, luccetFenceCode_{syntax}
" (that syntax inside), luccetMeta, luccetMacros, luccetRaw, luccetReserved,
" luccetTableRow, luccetAttrLine, luccetSpan, luccetElementText, luccetLeafContent.
"
" Fenced code is highlighted in its language for the syntaxes named in
" b:luccet_fence_languages or g:luccet_fence_languages (default: javascript, css
" and html, which the HTML syntax brings in at no cost). Each extra one, such
" as 'python' or 'sh', loads that syntax file with every note: [] turns
" languages off. An entry matches its own name and the usual aliases (py,
" bash, js …); a {'name': ['word', …]} dict sets the info words explicitly.

if !exists('main_syntax')
  if exists('b:current_syntax')
    finish
  endif
  let main_syntax = 'luccet'
endif

let s:cpo_save = &cpo
set cpo&vim
" Compile every pattern, the included syntaxes' too, for the backtracking
" regexp engine: on notes it parses about twice as fast as the NFA engine,
" whose cost grows with long alternations such as the HTML tag names.
let s:re_save = &regexpengine
set regexpengine=1

" html.vim also includes JavaScript and CSS (@htmlJavaScript, @htmlCss).
syn include @luccetHtml syntax/html.vim
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
syn cluster luccetInline contains=@Spell,luccetEscape,luccetHardBreak,luccetCode,luccetMath,luccetEntity,
      \ luccetAutolink,luccetHtmlInline,luccetHtmlComment,luccetRef,luccetFootnoteRef,luccetLink,luccetSpan,
      \ luccetElement,luccetEmphasis,luccetStrong,luccetStrongEmphasis,luccetStrike,luccetMark

exe 'syn match luccetAttr /' . s:GROUP . '/ contained contains=luccetAttrId,luccetAttrClass,luccetAttrKey,luccetAttrValue'
syn match luccetAttrId /[{[:space:]]\@1<=#[^[:space:]{}"'#.=]\+/ contained
syn match luccetAttrClass /[{[:space:]]\@1<=\.[^[:space:]{}"'#.=]\+/ contained
syn match luccetAttrKey /[{[:space:]]\@1<=[^[:space:]{}"'#.=][^[:space:]{}"'=]*/ contained
syn match luccetAttrValue /=\zs\%("[^"]*"\|'[^']*'\|[^[:space:]"'=<>`{}]\+\)/ contained

" Brackets that are none of the constructs below, so that their ] does not
" end the construct around them.
exe 'syn region luccetBracket start=/\[/ end=/\]/ end=/^\ze' . s:STOP . '/ contained transparent contains=@luccetInline,luccetBracket'

exe 'syn region luccetEmphasis matchgroup=luccetEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\@!\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*\@!/ end=/^\ze' . s:STOP . '/ contains=@luccetInline nextgroup=luccetAttr'
exe 'syn region luccetStrong matchgroup=luccetEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\*\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*/ end=/^\ze' . s:STOP . '/ contains=@luccetInline nextgroup=luccetAttr'
exe 'syn region luccetStrongEmphasis matchgroup=luccetEmphasisDelim'
      \ . ' start=/\*\%(\%(^\|[^\\]\)\*\*\)\@6<!\*\*\%([^[:space:]*]\%(' . s:P . '\{-,' . s:MAX . '}[^[:space:]*]\)\=\*\*\*\)\@=/'
      \ . ' end=/[^[:space:]*]\@4<=\*\*\*/ end=/^\ze' . s:STOP . '/ contains=@luccetInline nextgroup=luccetAttr'
" ~~ and ==: runs of exactly two, not glued to an ASCII letter or digit.
for [s:group, s:ch, s:cc] in [['luccetStrike', '\~', '~'], ['luccetMark', '=', '=']]
  exe 'syn region ' . s:group . ' matchgroup=luccetEmphasisDelim'
        \ . ' start=/' . s:ch . '\%([' . s:cc . 'A-Za-z0-9]' . s:ch . '\)\@6<!' . s:ch . '\%([^[:space:]' . s:cc . ']\%(' . s:P
        \ . '\{-,' . s:MAX . '}[^[:space:]' . s:cc . ']\)\=' . s:ch . s:ch . '[' . s:cc . 'A-Za-z0-9]\@!\)\@=/'
        \ . ' end=/[^[:space:]' . s:cc . ']\@4<=' . s:ch . s:ch . '[' . s:cc . 'A-Za-z0-9]\@!/'
        \ . ' end=/^\ze' . s:STOP . '/ contains=@luccetInline nextgroup=luccetAttr'
endfor

" [text](dest), ![alt](src): only when the brackets close and a destination
" follows, without a backtick (a code span would take it).
let s:DEST = '\%([^`()\\<]\|\\.\|([^`()]*)\|<[^<>`\n]*>\)\{,' . s:MAX . '}'
exe 'syn region luccetLink matchgroup=luccetLinkDelim start=/\[\%(\^\)\@!\%(' . s:BT . '\](' . s:DEST . ')\)\@=/'
      \ . ' end=/\]\%((\)\@=/ end=/^\ze' . s:STOP . '/ contains=@luccetInline,luccetBracket nextgroup=luccetLinkDest'
exe 'syn region luccetLink matchgroup=luccetLinkDelim start=/!\[\%(\^\)\@!\%(' . s:BT . '\](' . s:DEST . ')\)\@=/'
      \ . ' end=/\]\%((\)\@=/ end=/^\ze' . s:STOP . '/ contains=@luccetInline,luccetBracket nextgroup=luccetLinkDest'
syn region luccetLinkDest matchgroup=luccetLinkDelim start=/(/ skip=/\\./ end=/)/ oneline contained contains=luccetEscape,luccetLinkAngle,luccetLinkParen,luccetLinkTitle nextgroup=luccetAttr
syn match luccetLinkAngle /<[^<>]*>/ contained transparent contains=NONE
syn region luccetLinkParen start=/(/ end=/)/ oneline contained transparent contains=luccetLinkParen
syn region luccetLinkTitle start=/\s\zs"/ skip=/\\./ end=/"/ oneline contained
syn region luccetLinkTitle start=/\s\zs'/ skip=/\\./ end=/'/ oneline contained
" [text]{attrs}
exe 'syn region luccetSpan matchgroup=luccetSpanDelim start=/\[\%(\^\)\@!\%(' . s:BT . '\]' . s:GROUP . '\)\@=/'
      \ . ' end=/\]\%({\)\@=/ end=/^\ze' . s:STOP . '/ transparent contains=@luccetInline,luccetBracket nextgroup=luccetAttr'
" :name[content]{attrs}; the : is not glued to an ASCII word, : or /.
exe 'syn match luccetElement /:\%([A-Za-z0-9_:\/]:\)\@2<!' . s:NAME . '\ze\[' . s:BT . '\]/ nextgroup=luccetElementText'
exe 'syn region luccetElementText matchgroup=luccetElementDelim start=/\[/ end=/\]/ end=/^\ze' . s:STOP . '/'
      \ . ' contained transparent contains=@luccetInline,luccetBracket nextgroup=luccetAttr'

exe 'syn match luccetFootnoteRef /\[\^' . s:LABEL . '\]/ nextgroup=luccetAttr'
exe 'syn match luccetRef /@\%([A-Za-z0-9_.\/@-]@\)\@2<!' . s:IDENT . '/ nextgroup=luccetAttr'

" Autolinks: <scheme:…>, <a@b.c>, and bare http(s) URLs, which stop at
" whitespace and < > [ ] { } | " ` and give back trailing punctuation and an
" unbalanced ).
syn match luccetAutolink /<[A-Za-z][A-Za-z0-9+.-]\{1,31}:[^[:space:]<>[:cntrl:]]*>/ nextgroup=luccetAttr
syn match luccetAutolink /<[^[:space:]<>@\\]\+@[A-Za-z0-9][-A-Za-z0-9.]*>/ nextgroup=luccetAttr
let s:UC = '[^[:space:]<>\[\]{}|"`]'
let s:UE = '[^[:space:]<>\[\]{}|"`.,:;!?''*~=\\)]'
exe 'syn match luccetAutolink /[hH]\%(\%(^\|[[:space:](\[|*~="''>]\)[hH]\)\@2<=[tT][tT][pP][sS]\=:\/\/\%(' . s:UC . '*([^()[:space:]<>\[\]{}|"`]*)\%('
      \ . s:UC . '*' . s:UE . '\)\=\|' . s:UC . '*' . s:UE . '\)/ nextgroup=luccetAttr'

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
exe 'syn match luccetHtmlInline /<' . s:TAG . '\%(' . s:ATTR . '\)\{,49}\_s*\/\=>/ contains=htmlTag'
exe 'syn match luccetHtmlInline /<\/' . s:TAG . '\_s*>/ contains=htmlEndTag'
exe 'syn match luccetHtmlInline /<\(svg\|math\|textarea\)' . s:TB . s:P . '\{-,' . s:MAX . '}<\/\1\s*>/ contains=@luccetHtml'
exe 'syn match luccetHtmlComment /<!--\%(-\=>\|' . s:P . '\{-,' . s:MAX . '}-->\)/'

syn match luccetEntity /&\%(#\d\{1,7}\|#[xX]\x\{1,6}\|[A-Za-z][A-Za-z0-9]\{1,31}\);/

" After a backtick run \1: up to the next run of the same length, through
" text, line breaks and runs of other lengths. Runs of more than 16
" backticks open nothing here: a long run would be tried from each of its
" backticks.
let s:TICKS = '\%(\%([^`]*\)\@>\%(\%(\1`\@!\)\@!\%(`\+\)\@>\|' . s:NL . '\)\)\{-,99}\%([^`]*\)\@>\1`\@!'
" $`…`: $ and a backtick run, to the next run of the same length.
exe 'syn match luccetMath /\$\(\%(`\{1,16}\)\@>\)`\@!' . s:TICKS . '/ nextgroup=luccetAttr'
" $…$, by the dollar rule: the opener is not next to another (unescaped) $,
" and is followed by neither space nor ) ] } , . ; : `; the next unescaped $
" decides: it closes when no space and no unescaped ( [ { comes before it,
" no digit or $ after it, and at most one line break lies in between.
let s:MB = '\%([^$\\]\|\\.\)'
exe 'syn match luccetMath /\$\%(\%(^\|[^\\]\)\$\$\)\@6<!\%([[:space:]$`)\]},.;:]\|$\)\@!\%(' . s:MB . '\{,' . s:MAX . '}\n\)\='
      \ . s:MB . '\{,' . s:MAX . '}\%(\\.\|[^$\\[:space:]([{]\)\$\%(\d\|\$\)\@!/ nextgroup=luccetAttr'

" `code`: a backtick run, to the next run of exactly the same length.
exe 'syn match luccetCode /\(`\%(\%(^\|[^\\]\)``\)\@6<!\%(`\{,15}\)\@>\)`\@!' . s:TICKS . '/ nextgroup=luccetAttr'

syn match luccetEscape /\\[!-\/:-@\[\\\]^_`{|}~]/
syn match luccetHardBreak /\\$/

" ---------------------------------------------------------------------------
" Line constructs. Each marker holds any quote markers before it.
syn match luccetQuote /^\s*>\%(\s\|$\)\@=[ \t>]*/

exe 'syn match luccetListMarker /' . s:Q . '\%([-*+]\|\d\{1,9}[.)]\)\%(\s\|$\)\@=/ contains=luccetQuote nextgroup=luccetTask skipwhite'
syn match luccetTask /\[[ xX]\]\%(\s\|$\)\@=/ contained
exe 'syn match luccetRule /' . s:Q . '\%(-\s*-\s*-[-[:space:]]*\|\*\s*\*\s*\*[*[:space:]]*\|_\s*_\s*_[_[:space:]]*\)$/ contains=luccetQuote'

exe 'syn match luccetFootnoteDef /' . s:Q . '\[\^' . s:LABEL . '\]:\%(\s\|$\)\@=/ contains=luccetQuote'

exe 'syn match luccetTableRow /' . s:Q . '|.*$/ contains=luccetQuote,luccetTablePipe,@luccetInline'
syn match luccetTablePipe /|/ contained
exe 'syn match luccetTableSep /' . s:Q . '|[-:| \t]*-[-:| \t]*$/ contains=luccetQuote'

" {#id .class key=value} alone on a line; one of # . = makes it strong.
exe 'syn match luccetAttrLine /' . s:Q . '\%([^}]*[#.=]\)\@=\%(' . s:GROUP . '\s*\)\+$/ contains=luccetQuote,luccetAttr'

" ## Heading {#id}: the text runs to a trailing group, if any.
exe 'syn match luccetHeading /' . s:Q . '#\{1,6}\%(\s.*\)\=$/ contains=luccetHeadingDelim'
exe 'syn match luccetHeadingDelim /' . s:Q . '#\{1,6}/ contained contains=luccetQuote nextgroup=luccetHeadingText'
exe 'syn match luccetHeadingText /.\{-}\ze\%(\s*' . s:GROUP . '\)\=\s*$/ contained transparent'
      \ . ' contains=@luccetInline nextgroup=luccetAttr skipwhite'

" :::name[Title]{attrs}, ::name[content]{attrs}, ::: and :::/name, +++ {attrs}
exe 'syn match luccetBlockDelim /' . s:Q . ':\{3,}\ze' . s:L . '/ contains=luccetQuote nextgroup=luccetBlockName'
exe 'syn match luccetBlockName /' . s:NAME . '/ contained nextgroup=luccetBlockTitle,luccetAttr skipwhite'
exe 'syn region luccetBlockTitle matchgroup=luccetTitleDelim start=/\[/ end=/\]/ oneline contained'
      \ . ' contains=@luccetInline,luccetBracket nextgroup=luccetAttr skipwhite'
exe 'syn match luccetLeafDelim /' . s:Q . '::\ze' . s:L . '/ contains=luccetQuote nextgroup=luccetLeafName'
exe 'syn match luccetLeafName /' . s:NAME . '/ contained nextgroup=luccetLeafContent,luccetAttr skipwhite'
exe 'syn region luccetLeafContent matchgroup=luccetTitleDelim start=/\[/ end=/\]/ oneline contained transparent'
      \ . ' contains=@luccetInline,luccetBracket nextgroup=luccetAttr skipwhite'
exe 'syn match luccetCloser /' . s:Q . ':\{3,}\%(\/' . s:NAME . '\)\=\s*$/ contains=luccetQuote,luccetCloserName'
exe 'syn match luccetCloserName /\/\zs' . s:NAME . '/ contained'
exe 'syn match luccetCellSep /' . s:Q . '+\{3,}\ze\s*\%(' . s:GROUP . '\)\=\s*$/ contains=luccetQuote nextgroup=luccetAttr skipwhite'

" $$ display math $$ {#eq}: to the next unescaped $$, or up to a line that
" terminates it (blank, heading, fence, ::: or +++), which stays outside.
" A line with $$ … $$ and more text after it is no display math.
for [s:pre, s:quoted] in s:VARIANTS
  exe 'syn region luccetMathBlock matchgroup=luccetMathDelim start=/' . s:pre . '\$\$\%(\%([^\\$]\|\\.\|\$\$\@!\)\{,'
        \ . s:MAX . '}\$\$\%(\s*\%(' . s:GROUP . '\)\=\s*$\)\@!\)\@!/ skip=/\\./ end=/\$\$/' . s:quoted
        \ . ' end=/^\ze[ \t>]*\%($\|#\{1,6}\%(\s\|$\)\|```\|\~\~\~\|:::\|+++\)/ keepend nextgroup=luccetAttr skipwhite'
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
      exe 'syn region luccetFence start=/' . l:pre . '\z(' . l:run . '\)' . l:info . l:rest . '/'
            \ . ' matchgroup=luccetFenceDelim end=/' . (l:quoted ==# '' ? '^\s*' : l:pre) . l:close . '/' . l:quoted
            \ . ' keepend contains=luccetFenceOpen' . a:suffix
    endfor
  endfor
  exe 'syn match luccetFenceOpen' . a:suffix . ' /.*$/ contained contains=luccetFenceDelim nextgroup=luccetFenceCode' . a:suffix . ' skipnl'
  exe 'syn region luccetFenceCode' . a:suffix . ' start=/^/ end=/\%$/ contained' . (a:cluster ==# '' ? '' : ' contains=' . a:cluster)
endfunction

exe 'syn match luccetFenceDelim /' . s:Q . '\%(' . s:ITEM . '\)\=\%(`\{3,}\|\~\{3,}\)/ contained contains=luccetQuote,luccetListMarker'
      \ . ' nextgroup=luccetFenceLang,luccetBlockTitle,luccetAttr skipwhite'
syn match luccetFenceLang /[^[:space:][\]{}`]\+/ contained nextgroup=luccetBlockTitle,luccetAttr skipwhite
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
let s:free = {'html': '@luccetHtml', 'javascript': '@htmlJavaScript', 'css': '@htmlCss'}
let s:langs = get(b:, 'luccet_fence_languages', get(g:, 'luccet_fence_languages', ['javascript', 'css', 'html']))
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
    let s:cluster = '@luccetLang_' . s:name
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
  exe 'syn region luccetHtmlComment start=/' . s:pre . '<!\ze--/ end=/-->.*$/' . s:quoted . ' keepend contains=luccetQuote'
  exe 'syn region luccetHtmlBlock start=/\c' . s:pre . '<\z(' . s:RAWTEXT . '\)' . s:TB . '/ end=/\c<\/\z1\s*>.*\zs$/' . s:quoted
        \ . ' keepend contains=luccetQuote,@luccetHtml'
endfor
" A generic block is its first element (luccetHtmlNest, which extends it to
" that element's end tag, counting nested elements) and the rest of the line
" where that ends; another element still open on that line extends it again.
for [s:names, s:case] in [[s:BLOCK, '\c'], [s:CUSTOM, '']]
  for [s:pre, s:quoted] in s:VARIANTS
    exe 'syn region luccetHtmlBlock start=/' . s:case . s:pre . '<\%(' . s:names . '\)' . s:TB . '/'
          \ . ' end=/^\ze[ \t>]*:::/' . s:quoted . ' end=/.*\zs$/ keepend contains=luccetHtmlNest,luccetQuote,@luccetHtml'
  endfor
  exe 'syn region luccetHtmlNest start=/' . s:case . '<\z(' . s:names . '\)' . s:TB . '\%([^>]*\/>\)\@!/'
        \ . ' end=/' . s:case . '<\/\z1\s*>/ end=/^\ze[ \t>]*:::/ contained keepend extend transparent contains=luccetHtmlNest,luccetQuote,@luccetHtml'
endfor
exe 'syn match luccetHtmlBlock /\c' . s:Q . '\%(<\/\%(' . s:BLOCK . '\|' . s:RAWTEXT . '\|' . s:ONELINE . '\|' . s:VOID . '\)' . s:TB
      \ . '\|<\%(' . s:VOID . '\|' . s:ONELINE . '\)' . s:TB . '\|<\%(' . s:BLOCK . '\)' . s:TB . '[^>]*\/>\).*$/ contains=luccetQuote,@luccetHtml'
exe 'syn match luccetHtmlBlock /' . s:Q . '\%(<\/' . s:CUSTOM . s:TB . '\|<' . s:CUSTOM . s:TB . '[^>]*\/>\).*$/ contains=luccetQuote,@luccetHtml'

" Raw-body containers: :::meta, :::macros, :::script/style/html (reserved)
" and :::name{raw}, to a bare closer or their own named closer.
function! s:Raw(group, name, rest, body, contains) abort
  exe 'syn region ' . a:group . ' start=/' . s:Q . ':\{3,}\z(' . a:name . '\)' . a:rest . '.*$/'
        \ . ' matchgroup=luccetCloser end=/' . s:Q . ':\{3,}\%(\/\z1\)\=\s*$/ keepend contains=' . a:group . 'Open'
  exe 'syn match ' . a:group . 'Open /.*$/ contained contains=luccetBlockDelim nextgroup=' . a:body . ' skipnl'
  exe 'syn region ' . a:body . ' start=/^/ end=/\%$/ contained' . (a:contains ==# '' ? '' : ' contains=' . a:contains)
endfunction
call s:Raw('luccetRaw', s:NAME, '[^{]*{\%([^}]*\s\)\=raw[[:space:]}=]', 'luccetRawText', '')
call s:Raw('luccetReserved', 'script\|style\|html', s:NB, 'luccetRawText', '')
call s:Raw('luccetMacros', 'macros', s:NB, 'luccetMacrosBody', '')
call s:Raw('luccetMeta', 'meta', s:NB, 'luccetMetaBody', 'luccetMetaKey')
syn match luccetMetaKey /^\s*[^:[:space:]][^:]*\ze:/ contained

" The head: everything up to and including the luccet.js line, as HTML. It is
" found by its text, the first <script …luccet.js…> tag (a looser match than
" luccet.detect, so it never ends after the real one), and follows edits.
syn region luccetHead start=/\%^/ end=/\c<script\>[^>]*luccet\.js[^>]*>.*\zs$/ keepend contains=@luccetHtml

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
hi def link luccetHeading Title
hi def link luccetHeadingDelim Delimiter
hi def link luccetBlockDelim Delimiter
hi def link luccetBlockName Statement
hi def link luccetBlockTitle Title
hi def link luccetTitleDelim Delimiter
hi def link luccetLeafDelim Delimiter
hi def link luccetLeafName luccetBlockName
hi def link luccetCloser Delimiter
hi def link luccetCloserName Statement
hi def link luccetCellSep Delimiter
hi def link luccetRule Delimiter
hi def link luccetQuote Delimiter
hi def link luccetListMarker Delimiter
hi def link luccetTask Special
hi def link luccetFootnoteDef Identifier
hi def link luccetTablePipe Delimiter
hi def link luccetTableSep Delimiter
hi def link luccetAttr Delimiter
hi def link luccetAttrId Identifier
hi def link luccetAttrClass Type
hi def link luccetAttrKey Special
hi def link luccetAttrValue String
hi def link luccetFenceDelim Delimiter
hi def link luccetFenceLang Type
hi def link luccetFenceCode String
hi def link luccetMathBlock luccetMath
hi def link luccetMathDelim Delimiter
hi def link luccetHtmlComment Comment
hi def link luccetMetaKey Identifier
hi def link luccetMetaBody String
hi def link luccetMacrosBody luccetMath
hi def link luccetRawText String
hi def link luccetEscape Special
hi def link luccetHardBreak Special
hi def link luccetCode String
hi def link luccetMath Special
hi def luccetEmphasis term=italic cterm=italic gui=italic
hi def luccetStrong term=bold cterm=bold gui=bold
hi def luccetStrongEmphasis term=bold,italic cterm=bold,italic gui=bold,italic
hi def link luccetEmphasisDelim Delimiter
hi def luccetStrike term=strikethrough cterm=strikethrough gui=strikethrough
hi def link luccetMark Search
hi def link luccetLink Underlined
hi def link luccetLinkDelim Delimiter
hi def link luccetLinkDest String
hi def link luccetLinkTitle String
hi def link luccetSpanDelim Delimiter
hi def link luccetElement Statement
hi def link luccetElementDelim Delimiter
hi def link luccetRef Identifier
hi def link luccetFootnoteRef Identifier
hi def link luccetAutolink Underlined
hi def link luccetEntity Special

delfunction s:Fence
delfunction s:Raw
let b:current_syntax = 'luccet'
if main_syntax ==# 'luccet'
  unlet main_syntax
endif
let &regexpengine = s:re_save
let &cpo = s:cpo_save
unlet s:cpo_save s:re_save
