# tern.nvim

Neovim support for [Tern](https://github.com/OscarAC/tern) notes.

A Tern note is an HTML file. Its first line loads `tern.js`, and everything after that line is the note, written in Tern's markdown-like syntax. Opened in a browser, tern.js renders the note in place.

tern.nvim is a client of `tern lsp`, Tern's language server. It has no grammar of its own: positions, structure, diagnostics and folds come from the server, which runs the engine the browser runs. The one exception is syntax highlighting, which is lexical so that it is fast and works without Node.

## Features

- **Detection.** An `.html` file that loads `tern.js` gets the filetype `tern`. This is the engine's own rule, written in Lua, so it needs no Node.
- **Language server.** Diagnostics as you type, completion of element names, closers and ids, go to definition, references, rename, hover, document symbols and folding. They work through Neovim's own LSP mappings (`grr`, `grn`, `K`, `gO`, `CTRL-]`, `]d` …).
- **Virtual text** drawn from the server's outline. It shows a numbered block's label ("Theorem 1"), what each `@reference` reads as, equation numbers, and simple TeX as Unicode. Math reads as Unicode in place of its source (`$\mathbb{R}^n$` → ℝⁿ), inline and display, with the note's `:::macros` expanded, `$$` hidden, and `align`, `cases` and matrices shown row by row. A block's opener reads as its label and title (`:::theorem[Main]{#t1 .big}` → Theorem 1 Main {#t1}), and its closer is hidden; an inline element reads as its content (`:kbd[Ctrl]` → Ctrl). The head (doctype, scripts, styles) folds into one line saying what it holds. The source shows again while the cursor is on it.
- **Live preview.** `:TernPreview` serves the note's project from inside Neovim and refreshes the browser each time you write. The note re-renders in place and keeps its scroll position. The server listens on 127.0.0.1 and refuses requests from other sites.
- **Commands.** `:TernInit` writes a note's first line, `:TernCheck` sends `tern check` to the quickfix list, and `:TernBuild` runs `tern build`.
- **Highlighting** for the whole syntax, with fenced code highlighted in its language.
- **`:checkhealth tern`** shows what the plugin found and why.
- **Without Node**, detection, highlighting, folding by headings, `:TernInit` and the preview still work. The plugin says once why the server cannot start.

## Requirements

- Neovim 0.11 or later
- Node 22 or later
- The Tern CLI, `tern-cli.js` from a checkout of [Tern](https://github.com/OscarAC/tern)

Node and the CLI are needed for the language server, the virtual text, `:TernCheck` and `:TernBuild`.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'OscarAC/tern.nvim',
  opts = {}, -- passed to require('tern').setup()
}
```

With packer.nvim:

```lua
use({
  'OscarAC/tern.nvim',
  config = function()
    require('tern').setup({})
  end,
})
```

With Neovim's native packages:

```sh
git clone https://github.com/OscarAC/tern.nvim \
  ~/.local/share/nvim/site/pack/tern/start/tern.nvim
```

You do not need to lazy-load it: the modules load when the first note opens or a command runs.

Then get Tern and make its CLI findable:

```sh
git clone https://github.com/OscarAC/tern
cd tern && npm link     # puts `tern` on PATH
```

The plugin looks for the CLI in this order. It uses `cmd` from `setup()` first, then `$TERN_CLI` (the path of `tern-cli.js`). Next it looks for `tern-cli.js` in the note's directory or above, then next to the `tern.js` the note loads, with symbolic links followed. Last, it tries `tern` on PATH, when that is Tern's `tern-cli.js` or a script that runs it. See `:help tern-cli-lookup`.

## Quick start

1. Open or create an `.html` file: `:edit notes/maps.html`.
2. `:TernInit` writes the first line, `<!doctype html><meta charset="utf-8"><script src="tern.js"></script>`, with the path of the nearest `tern.js`. The buffer is now a note.
3. Write the note below that line, then `:write`. Diagnostics, completion and the virtual text follow as you type.
4. `:TernPreview` opens the note in your browser. Each `:write` refreshes it.

## Configuration

`setup()` is optional. These are the defaults:

```lua
require('tern').setup({
  -- The language server command, e.g. { 'node', '/path/to/tern-cli.js', 'lsp' }.
  -- nil: found for each note.
  cmd = nil,
  -- Start `tern lsp` for notes.
  lsp = true,
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
  -- :TernPreview, a local server that refreshes the browser on save.
  preview = {
    host = '127.0.0.1',
    port = 0, -- 0: any free port
    open = true, -- open the page in a browser
    browser = nil, -- the command to open it with; nil: vim.ui.open
  },
})
```

Fenced code is highlighted in its language for the syntaxes in `g:tern_fence_languages`. The default is `{ 'javascript', 'css', 'html' }`, which costs nothing because the HTML syntax brings them in.

## Commands

| Command | What it does |
|---|---|
| `:TernInit [SRC]` | Writes the canonical first line, which loads `tern.js` from SRC or from the nearest `tern.js`, at the top of the buffer. |
| `:TernCheck [PATH…]` | Runs `tern check` on the paths, or on the buffer's file, and puts the diagnostics in the quickfix list. |
| `:TernBuild [OUT]` | Runs `tern build` on the buffer's file. OUT defaults to `NAME.built.html` beside the note. |
| `:TernPreview` | Serves the note and opens it in a browser. The page refreshes on each write. |
| `:TernPreviewStop` | Stops the preview server. |
| `:TernRender [on\|off\|toggle]` | Shows or hides the virtual text in the buffer. |

## Documentation

`:help tern` covers every option, command and highlight group, as well as the outline API, the preview's security model and troubleshooting.

## Development

Run the tests headless, without your config:

```sh
nvim --headless -u NONE -l test/run.lua            # every test
nvim --headless -u NONE -l test/run.lua preview    # those whose "file: name" contains "preview"
```

Each `test/*_test.lua` returns a list of `{ name, fn }`. The tests of the language server, the commands and the syntax against Tern's documentation need Node and a Tern checkout. The runner uses `$TERN_ROOT`, or else a checkout next to this one (`../tern`). Without one, those tests are skipped and say so. The preview's browser test uses Playwright when it finds it, from `$NODE_PATH` or npx's cache.

`lua/tern/detect.lua` implements the engine's detection rule. `test/fixtures/detect.json` is a copy of the Tern repository's `test/fixtures/detect.json`, and the tests fail when the two differ. When Tern's rule changes, copy the file over and make the tests pass again.

## License

MIT. See [LICENSE](LICENSE).
