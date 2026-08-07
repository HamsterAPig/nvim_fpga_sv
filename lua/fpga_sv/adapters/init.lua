local M = {
  backends = {},
  installers = {},
}

function M.register_backend(name, backend)
  assert(type(name) == "string" and name ~= "", "backend 名称不能为空")
  assert(type(backend) == "table", "backend 必须是 table")
  M.backends[name] = backend
end

function M.register_installer(name, installer)
  assert(type(name) == "string" and name ~= "", "installer 名称不能为空")
  assert(type(installer) == "table", "installer 必须是 table")
  M.installers[name] = installer
end

function M.setup(config)
  local availability = {}
  if config.adapters.slang then
    availability.slang = require("fpga_sv.adapters.slang").setup(config.tools.slang)
  end
  if config.adapters.verible then
    availability.verible = require("fpga_sv.adapters.verible").setup(config.tools.verible)
  end
  availability.svlint = config.adapters.svlint
    and require("fpga_sv.util").executable(config.tools.svlint.cmd)
    or false
  availability.lazyvim = config.adapters.lazyvim
    and require("fpga_sv.adapters.lazyvim").detect()
    or false
  return availability
end

return M
