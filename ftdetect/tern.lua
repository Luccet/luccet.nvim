-- SPDX-License-Identifier: MIT
-- An .html file is a Tern note when one of its lines loads tern.js
-- (tern.detect); it then gets the filetype `tern` instead of `html`.
vim.filetype.add({
  pattern = {
    ['.*%.html?'] = {
      function(_, buf)
        if require('tern.detect').buffer(buf) then
          return 'tern'
        end
      end,
      { priority = 10 },
    },
  },
})
