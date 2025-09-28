local mason_registry = require('mason-registry')
local linters = { 
	'luacheck'
}

for _, linter in ipairs(linters) do
  if not mason_registry.is_installed(linter) then
    vim.cmd('MasonInstall ' .. linter)
  end
end

require('lint').linters_by_ft = {
  lua = { 'luacheck' }
}

-- Auto-lint on save and text change
vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufReadPost', 'InsertLeave' }, {
  callback = function()
    require('lint').try_lint()
  end,
})
