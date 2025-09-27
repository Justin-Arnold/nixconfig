return {
    {
        "williamboman/mason.nvim",
        config = function()
            require("mason").setup()
        end,
    },
    {
        "williamboman/mason-lspconfig.nvim",
        lazy = false,
        opts = {
            automatic_enable = false,
            auto_install = true,
        }
    },
    {
        "saghen/blink.cmp",
        lazy = false,
        dependencies = {
            'rafamadriz/friendly-snippets',
            {
                "L3MON4D3/LuaSnip",
                version = "v2.*",
                build = "make install_jsregexp",
                config = function()
                    require("luasnip.loaders.from_vscode").lazy_load()
                end,
            },
        },
        version = 'v0.*',
        config = function()
            require('blink.cmp').setup({
                keymap = { 
                    preset = 'default',
                    ['<Tab>'] = { 'select_and_accept' },
                    ['<C-space>'] = { 'show', 'show_documentation', 'hide_documentation' },

                },
                appearance = {
                    use_nvim_cmp_as_default = true,
                    nerd_font_variant = 'mono'
                },
                sources = {
                    default = { 'lsp', 'path', 'snippets', 'buffer' },
                    providers = {
                        snippets = {
                            min_keyword_length = 1,
                            score_offset = -3,
                        },
                    },
                },
                completion = {
                    accept = {
                        auto_brackets = {
                            enabled = true,
                        },
                    },
                    menu = {
                        draw = {
                            treesitter = { "lsp" },
                        },
                    },
                    documentation = {
                        auto_show = true,
                        auto_show_delay_ms = 200,
                    },
                },
                snippets = {
                    expand = function(snippet)
                        require('luasnip').lsp_expand(snippet)
                    end,
                    active = function(filter)
                        if filter and filter.direction then
                            return require('luasnip').jumpable(filter.direction)
                        end
                        return require('luasnip').in_snippet()
                    end,
                    jump = function(direction)
                        require('luasnip').jump(direction)
                    end,
                },
            })
        end,
    },
    {
        "neovim/nvim-lspconfig",
        lazy = false,
        config = function()
            local lspconfig = require("lspconfig")

            local vue_language_server_path = vim.fn.stdpath("data")
				.. "/mason/packages/vue-language-server/node_modules/@vue/language-server"
            
            lspconfig.ts_ls.setup {
                init_options = {
                    plugins = {
                        {
                            name =  "@vue/typescript-plugin",
                            location = vue_language_server_path,
                            languages = { "vue" },
                        }
                    },
                },
                filetypes = { "typescript", "javascript", "vue" },
            }
	    
	    lspconfig.nil_ls.setup {
              
	    }
        end,
    },  
}
