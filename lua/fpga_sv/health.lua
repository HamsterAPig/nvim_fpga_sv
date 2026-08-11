local util = require("fpga_sv.util")
local project = require("fpga_sv.project")
local workspace_manager = require("fpga_sv.workspace")
local M = {}

local function inside(path, root)
  local path_key = util.path_key(path)
  local root_key = util.path_key(root)
  return path_key == root_key
    or path_key:sub(1, #root_key + 1) == root_key .. "/"
end

function M.check()
  vim.health.start("nvim_fpga_sv")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim >= 0.11")
  else
    vim.health.error("需要 Neovim 0.11+")
  end

  local workspace = workspace_manager.current()
  if workspace.config.valid then
    vim.health.ok("配置有效，活动 Profile: " .. workspace.active_profile)
  else
    for _, err in ipairs(workspace.config.errors) do
      vim.health.error(err)
    end
  end

  local catalog = workspace.config.device_catalog
  if catalog.exists and catalog.valid then
    local schema_ok, schema_errors = project.validate_device_catalog(catalog.entries)
    if schema_ok then
      vim.health.ok("器件目录语法和字段有效: " .. catalog.path)
    else
      for _, err in ipairs(schema_errors) do
        vim.health.warn("器件目录字段无效: " .. err)
      end
    end
  elseif catalog.exists then
    for _, err in ipairs(catalog.errors) do
      vim.health.error("器件目录无效: " .. err)
    end
  else
    vim.health.warn("器件目录尚未创建: " .. catalog.path)
  end

  local profile = workspace.config.effective.profiles[workspace.active_profile]
  if profile and profile.device then
    local entry = workspace.models and workspace.models[workspace.active_profile]
    local model = entry and entry.full
    if not model then
      model = project.build(
        workspace.root,
        workspace.config.effective,
        workspace.active_profile,
        catalog
      )
    end
    local device = model and model.device
    if device and device.status == "loaded" then
      vim.health.ok(
        "活动器件已加载: "
          .. profile.device
          .. "；依赖顺序: "
          .. table.concat(device.order, " -> ")
      )
    else
      local warnings = device and device.warnings or { "无法构建活动器件状态" }
      for _, warning in ipairs(warnings) do
        vim.health.warn(warning)
      end
    end
  else
    vim.health.ok("活动 Profile 未配置器件，保持原有工程行为")
  end

  for _, name in ipairs({ "slang", "svlint", "verible" }) do
    local options = workspace.config.effective.tools[name]
    if options and util.executable(options.cmd) then
      vim.health.ok(name .. " 可执行: " .. tostring(type(options.cmd) == "table" and options.cmd[1] or options.cmd))
    else
      vim.health.warn(name .. " 不可用；仅禁用该适配器，可通过 tools." .. name .. ".cmd 显式配置")
    end
  end

  local ok_ts = pcall(vim.treesitter.language.add, "systemverilog")
  if not ok_ts then
    ok_ts = pcall(vim.treesitter.language.add, "verilog")
  end
  if ok_ts then
    vim.health.ok("SystemVerilog Tree-sitter parser 可用")
  else
    vim.health.warn("SystemVerilog Tree-sitter parser 不可用，将使用容错扫描")
  end

  local local_path = workspace.config.paths.local_config
  if inside(local_path, workspace.root) then
    vim.health.warn("local 配置位于仓库内，可能被意外提交: " .. local_path)
  else
    vim.health.ok("local 配置位于仓库外")
  end
  for _, artifacts in pairs(workspace.models or {}) do
    local path = artifacts.artifacts and artifacts.artifacts.local_filelist
    if path and inside(path, workspace.root) then
      vim.health.warn("local 产物位于仓库内，可能被意外提交: " .. path)
    end
  end
end

return M
