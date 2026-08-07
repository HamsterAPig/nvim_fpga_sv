local util = require("fpga_sv.util")
local M = {}

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
