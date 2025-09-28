return function(capabilities)
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'lua',
    callback = function()
      vim.lsp.start({
        name = 'lua-language-server',
        cmd = { 'lua-language-server' },
        root_dir = vim.fs.root(0, { '.git', '.luarc.json' }),
        capabilities = capabilities,
        settings = {
          Lua = {
            runtime = { version = 'LuaJIT' },
            diagnostics = { globals = { 'vim' } },
            workspace = {
              library = vim.api.nvim_get_runtime_file('', true),
              checkThirdParty = false,
            },
          },
        },
      })
    end,
  })
end
