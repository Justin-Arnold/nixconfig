vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client:supports_method('textDocument/foldingRange') then
            local win = vim.api.nvim_get_current_win()
            vim.wo[win].foldmethod = 'expr'
            vim.wo[win].foldexpr = 'v:lua.vim.lsp.foldexpr()'
        end
    end,
})
vim.opt.foldlevel = 99  -- Don't auto-fold anything
vim.api.nvim_create_autocmd('LspDetach', { command = 'setl foldexpr<' })


