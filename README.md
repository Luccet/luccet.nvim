# luccet.nvim

Neovim support for [Luccet](https://github.com/Luccet/luccet) notes.

A Luccet note is an HTML file. Its first line loads `luccet.js`, and everything after that line is the note, written in Luccet's markdown-like syntax. Opened in a browser, luccet.js renders the note in place.

luccet.nvim is a client of `luccet lsp`, Luccet's language server. It has no grammar of its own: positions, structure, diagnostics and folds come from the server, which runs the engine the browser runs. The one exception is syntax highlighting, which is lexical so that it is fast and works without Node.

## Features

- **Detection.** An `.html` file that loads `luccet.js` gets the filetype `luccet`. This is the engine's own rule, written in Lua, so it needs no Node.
- **Language server.** Diagnostics as you type, completion of element names, closers and ids, go to definition, references, rename, hover, document symbols, folding, and quick fixes for the diagnostics that have one. A link `page.html#id` is a reference too: definition, references and rename follow it into the other note. They work through Neovim's own LSP mappings (`grr`, `grn`, `gra`, `K`, `gO`, `CTRL-]`, `]d` …), and `vim.lsp.buf.workspace_symbol()` searches the headings and blocks of every note under the root.
- **Virtual text** drawn from the server's outline. It shows a numbered block's label ("Theorem 1"), what each `@reference` reads as, equation numbers, and simple TeX as Unicode. Math reads as Unicode in place of its source (`$\mathbb{R}^n$` → ℝⁿ), inline and display, with the note's `:::macros` expanded, `$$` hidden, and `align`, `cases` and matrices shown row by row. A block's opener reads as its label and title (`:::theorem[Main]{#t1 .big}` → Theorem 1 Main {#t1}), and its closer is hidden; an inline element reads as its content (`:kbd[Ctrl]` → Ctrl). The head (doctype, scripts, styles) folds into one line saying what it holds. The source shows again while the cursor is on it.
- **Live preview.** `:LuccetPreview` serves the note's project from inside Neovim and refreshes the browser as you type, before you write. The note re-renders in place and keeps its scroll position. The server listens on 127.0.0.1 and refuses requests from other sites.
- **Commands.** `:LuccetInit` writes a note's first line, `:LuccetCheck` sends `luccet check` to the quickfix list, `:LuccetSearch` searches the notes by word into it, `:LuccetBuild` runs `luccet build`, and `:LuccetMove` moves a file and fixes the links to it and in it.
- **Highlighting** for the whole syntax, with fenced code highlighted in its language.
- **`:checkhealth luccet`** shows what the plugin found and why.
- **Formatting with Neovim's own operators.** `=` lines up a list item's lines with its text, and `gq` wraps paragraphs only, never joining one with a heading or block opener above it and never touching code, math or raw HTML.
- **Without Node**, detection, highlighting, formatting, folding by headings, `:LuccetInit` and the preview still work. The plugin says once why the server cannot start.

## Requirements

- Neovim 0.11 or later
- Node 22 or later
- The Luccet CLI, `luccet-cli.js` from a checkout of [Luccet](https://github.com/Luccet/luccet)

Node and the CLI are needed for the language server, the virtual text, `:LuccetCheck` and `:LuccetBuild`.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'Luccet/luccet.nvim',
  opts = {}, -- passed to require('luccet').setup()
}
```

With packer.nvim:

```lua
use({
  'Luccet/luccet.nvim',
  config = function()
    require('luccet').setup({})
  end,
})
```

With Neovim's native packages:

```sh
git clone https://github.com/Luccet/luccet.nvim \
  ~/.local/share/nvim/site/pack/luccet/start/luccet.nvim
```

You do not need to lazy-load it: the modules load when the first note opens or a command runs.

Then get Luccet and make its CLI findable:

```sh
git clone https://github.com/Luccet/luccet
cd luccet && npm link     # puts `luccet` on PATH
```

The plugin looks for the CLI in this order. It uses `cmd` from `setup()` first, then `$LUCCET_CLI` (the path of `luccet-cli.js`). Next it looks for `luccet-cli.js` in the note's directory or above, then next to the `luccet.js` the note loads, with symbolic links followed. Last, it tries `luccet` on PATH, when that is Luccet's `luccet-cli.js` or a script that runs it. See `:help luccet-cli-lookup`.

## Quick start

1. Open or create an `.html` file: `:edit notes/maps.html`.
2. `:LuccetInit` writes the first line, `<!doctype html><meta charset="utf-8"><script src="luccet.js"></script>`, with the path of the nearest `luccet.js`. The buffer is now a note.
3. Write the note below that line, then `:write`. Diagnostics, completion and the virtual text follow as you type.
4. `:LuccetPreview` opens the note in your browser, which follows your edits as you type.

## Configuration

`setup()` is optional. These are the defaults:

```lua
require('luccet').setup({
  -- The language server command, e.g. { 'node', '/path/to/luccet-cli.js', 'lsp' }.
  -- nil: found for each note.
  cmd = nil,
  -- Start `luccet lsp` for notes.
  lsp = true,
  -- Let the server watch the root's files for changes made outside Neovim.
  watch = false,
  -- Fold from the language server; without it, by headings.
  fold = true,
  -- Virtual text drawn from the server's outline.
  render = {
    enabled = true,
    labels = true, -- "Theorem 1" beside a numbered block's opener
    refs = true, -- what an @reference will read as
    math = true, -- simple TeX as Unicode, and equation numbers
    conceal = true, -- math, block and inline element syntax drawn in place of the source, but under the cursor
  },
  -- :LuccetPreview, a local server that refreshes the browser as you type.
  preview = {
    host = '127.0.0.1',
    port = 0, -- 0: any free port
    open = true, -- open the page in a browser
    browser = nil, -- the command to open it with; nil: vim.ui.open
    update = 'change', -- 'change': the page follows the note's buffer, written or not; 'write': on each write
  },
})
```

Fenced code is highlighted in its language for the syntaxes in `g:luccet_fence_languages`. The default is `{ 'javascript', 'css', 'html' }`, which costs nothing because the HTML syntax brings them in.

## Commands

| Command | What it does |
|---|---|
| `:LuccetInit [SRC]` | Writes the canonical first line, which loads `luccet.js` from SRC or from the nearest `luccet.js`, at the top of the buffer. |
| `:LuccetCheck [PATH…]` | Runs `luccet check` on the paths, or on the buffer's file, and puts the diagnostics in the quickfix list. |
| `:LuccetSearch WORD… [PATH…]` | Runs `luccet search` on the paths, or on the working directory, and puts the hits, each at its heading or block, in the quickfix list. An argument starting with `--` is passed on: `--index=search.json` searches the index `luccet index` wrote. |
| `:LuccetBuild [OUT]` | Runs `luccet build` on the buffer's file. OUT defaults to `NAME.built.html` beside the note. |
| `:LuccetMove [FROM] TO` | Moves the buffer's file, or FROM (a file or a folder), to TO, and fixes the links to it and in it, as `luccet mv` does. Unsaved changes count. Needs the language server. |
| `:LuccetPreview` | Serves the note and opens it in a browser. The page refreshes as you type. |
| `:LuccetPreviewStop` | Stops the preview server. |
| `:LuccetRender [on\|off\|toggle]` | Shows or hides the virtual text in the buffer. |

## Documentation

`:help luccet` covers every option, command and highlight group, as well as the outline API, the preview's security model and troubleshooting.

## Development

Run the tests headless, without your config:

```sh
nvim --headless -u NONE -l test/run.lua            # every test
nvim --headless -u NONE -l test/run.lua preview    # those whose "file: name" contains "preview"
```

Each `test/*_test.lua` returns a list of `{ name, fn }`. The tests of the language server, the commands and the syntax against Luccet's documentation need Node and a Luccet checkout. The runner uses `$LUCCET_ROOT`, or else a checkout next to this one (`../luccet`). Without one, those tests are skipped and say so. The preview's browser test uses Playwright when it finds it, from `$NODE_PATH` or npx's cache.

`lua/luccet/detect.lua` implements the engine's detection rule. `test/fixtures/detect.json` is a copy of the Luccet repository's `test/fixtures/detect.json`, and the tests fail when the two differ. When Luccet's rule changes, copy the file over and make the tests pass again.

## License

MIT. See [LICENSE](LICENSE).
