local mason_registery = require('mason-registery')
local formatters = {
  'stylua'
}

for _, formatter in ipairs(formatters) do
	if not mason_registery.is_installed(formatter) then
		vim.cmd('MasonInstall ' .. formatter)
	end
end

require('conform').setup({
  formatters_by_ft = {
    lua = { 'stylua' }
  },
  format_on_save = {
    timeout_ms = 500,
    lsp_fallback = true,
  },
})
