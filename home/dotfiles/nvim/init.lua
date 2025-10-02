vim.g.mapleader = " "

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable", -- latest stable release
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

local opts = {
	install = {
		colorscheme = { "nord" },
	},
	ui = {
		border = "shadow",
	},
}

require("lazy").setup("plugins", opts)

require("mason").setup()
require("config.folding")
require("config.lsp")
require("config.formatting")
require("config.linting")

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", builtin.find_files, {})
vim.keymap.set("n", "<leader>ft", ":Neotree filesystem toggle left<CR>")

vim.o.termguicolors = true
vim.cmd.colorscheme("nord")

vim.o.clipboard = "unnamedplus"
vim.opt.shell = "/bin/zsh"
vim.opt.number = true
vim.opt.wrap = false

-- Natural horizontal scrolling
vim.keymap.set("n", "<ScrollWheelLeft>", "3zl", { silent = true })
vim.keymap.set("n", "<ScrollWheelRight>", "3zh", { silent = true })

vim.api.nvim_create_autocmd("FileType", {
	pattern = "go",
	callback = function()
		vim.bo.tabstop = 4
		vim.bo.shiftwidth = 4
		vim.bo.softtabstop = 4
	end,
})

require("telescope").setup({
	extensions = {},
})
