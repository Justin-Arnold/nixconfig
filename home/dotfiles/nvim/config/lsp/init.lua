-- Ensure LSP servers are installed
local mason_registry = require('mason-registry')
local lsp_servers = { }

for _, server in ipairs(lsp_servers) do
  if not mason_registry.is_installed(server) then
    vim.cmd('MasonInstall ' .. server)
  end
end

local capabilities = require('blink.cmp').get_lsp_capabilities()

require('config.lsp.lua')(capabilities)
