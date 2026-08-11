local util = require("fpga_sv.util")
local M = {}

local lsp_arbitration_enabled = false
local lsp_client_name = "verible"
local disabled_capabilities = {
  "definitionProvider",
  "referencesProvider",
  "documentHighlightProvider",
  "diagnosticProvider",
}

local function clear_pull_diagnostics(client)
  local prefix = ("nvim.lsp.%s.%d."):format(client.name, client.id)
  for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
    -- push namespace 到客户端 ID 结束；只有 pull namespace 带额外标识符。
    if name:sub(1, #prefix) == prefix then
      vim.diagnostic.reset(namespace)
    end
  end
end

function M.configure_lsp_arbitration(enabled)
  lsp_arbitration_enabled = enabled == true
end

function M.arbitrate_client(client)
  if
    not lsp_arbitration_enabled
    or not client
    or client.name ~= lsp_client_name
    or type(client.server_capabilities) ~= "table"
  then
    return false
  end

  -- Slang 负责语义导航；Verible 只退出重叠能力，保留 push diagnostics 等能力。
  for _, capability in ipairs(disabled_capabilities) do
    client.server_capabilities[capability] = nil
  end
  clear_pull_diagnostics(client)
  return true
end

function M.arbitrate_buffer(bufnr)
  if not lsp_arbitration_enabled then
    return 0
  end
  local count = 0
  for _, client in ipairs(vim.lsp.get_clients({
    bufnr = bufnr,
    name = lsp_client_name,
  })) do
    if M.arbitrate_client(client) then
      count = count + 1
    end
  end
  return count
end

function M.setup(options)
  if not options.enabled or not util.executable(options.cmd) then
    return false
  end
  local ok, conform = pcall(require, "conform")
  if not ok then
    return false
  end
  conform.setup({
    formatters_by_ft = {
      systemverilog = { "fpga_sv_verible" },
      verilog = { "fpga_sv_verible" },
    },
    formatters = {
      fpga_sv_verible = {
        command = type(options.cmd) == "table" and options.cmd[1] or options.cmd,
        args = options.args,
        stdin = true,
      },
    },
  })
  return true
end

return M
