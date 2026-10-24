-- SPDX-License-Identifier: MIT
-- An .html file is a Luccet note when one of its lines loads luccet.js
-- (luccet.detect); it then gets the filetype `luccet` instead of `html`.
vim.filetype.add({
  pattern = {
    ['.*%.html?'] = {
      function(_, buf)
        if require('luccet.detect').buffer(buf) then
          return 'luccet'
        end
      end,
      { priority = 10 },
    },
  },
})
