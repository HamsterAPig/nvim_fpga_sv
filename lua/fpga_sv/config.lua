local defaults = require("fpga_sv.defaults")
local util = require("fpga_sv.util")
local M = {}

local function eval_lua(text, path)
  local chunk, err = load(text, "@" .. path, "t", setmetatable({ vim = vim }, { __index = _G }))
  if not chunk then
    return nil, err
  end
  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    return nil, path .. " 必须返回 table"
  end
  return value
end

local function read_layer(path, secure)
  if not path or not util.exists(path) then
    return {}, nil
  end
  local text, err
  if secure then
    local ok
    ok, text = pcall(vim.secure.read, path)
    if not ok or not text then
      return nil, "项目配置未受信任或读取失败: " .. path
    end
  else
    text, err = util.read_file(path)
    if not text then
      return nil, "读取配置失败: " .. path .. ": " .. tostring(err)
    end
  end
  return eval_lua(text, path)
end

local function validate(config)
  local errors = {}
  if type(config.source_sets) ~= "table" then
    errors[#errors + 1] = "source_sets 必须是 table"
  end
  if type(config.profiles) ~= "table" then
    errors[#errors + 1] = "profiles 必须是 table"
  end
  if type(config.default_profile) ~= "string" then
    errors[#errors + 1] = "default_profile 必须是字符串"
  elseif config.profiles and not config.profiles[config.default_profile] then
    errors[#errors + 1] = "default_profile 不存在: " .. config.default_profile
  end
  for name, profile in pairs(config.profiles or {}) do
    if type(name) ~= "string" or type(profile) ~= "table" then
      errors[#errors + 1] = "profiles 的键和值必须分别为字符串和 table"
    elseif profile.source_sets ~= nil
      and not vim.islist(profile.source_sets)
      and not util.is_list_operation(profile.source_sets)
    then
      errors[#errors + 1] = "profile " .. name .. " 的 source_sets 必须是列表"
    elseif profile.device ~= nil
      and (type(profile.device) ~= "string" or profile.device == "")
    then
      errors[#errors + 1] = "profile " .. name .. " 的 device 必须是非空字符串"
    end
  end
  return #errors == 0, errors
end

function M.local_path(root, base)
  base = base or defaults.get()
  return vim.fs.joinpath(base.state_dir, "projects", util.root_hash(root), "config.lua")
end

function M.project_path(root, base)
  base = base or defaults.get()
  return vim.fs.joinpath(root, base.project_file)
end

function M.load(root, setup_options)
  local builtin = defaults.get()
  setup_options = setup_options or {}
  local global_path = util.path(setup_options.global_config or builtin.global_config)
  local global, global_err = read_layer(global_path, false)
  global = global or {}

  local preliminary = util.merge_many(builtin, global, setup_options)
  local device_catalog_path = util.path(preliminary.device_catalog_file)
  local device_catalog, device_catalog_err = read_layer(device_catalog_path, false)
  device_catalog = device_catalog or {}
  local project_path = M.project_path(root, preliminary)
  local project, project_err = read_layer(project_path, true)
  project = project or {}

  local local_path = M.local_path(root, preliminary)
  local local_config, local_err = read_layer(local_path, false)
  local_config = local_config or {}

  local machine = util.merge_many(global, setup_options, local_config)
  local effective = util.merge_many(builtin, global, setup_options, project, local_config)
  local ok, validation_errors = validate(effective)
  local errors = {}
  for _, err in ipairs({ global_err, project_err, local_err }) do
    if err then
      errors[#errors + 1] = err
    end
  end
  vim.list_extend(errors, validation_errors)
  local warnings = {}
  if device_catalog_err then
    warnings[#warnings + 1] = "器件目录加载失败: " .. tostring(device_catalog_err)
  end

  return {
    effective = effective,
    portable = project,
    machine = machine,
    device_catalog = {
      path = device_catalog_path,
      entries = device_catalog,
      exists = util.exists(device_catalog_path),
      valid = device_catalog_err == nil,
      errors = device_catalog_err and { tostring(device_catalog_err) } or {},
    },
    paths = {
      global = global_path,
      device_catalog = device_catalog_path,
      project = project_path,
      local_config = local_path,
    },
    valid = ok and #errors == 0,
    errors = errors,
    warnings = warnings,
  }
end

local function ensure_template(path, content)
  if util.exists(path) then
    return path
  end
  local ok, err = util.atomic_write(path, content)
  if not ok then
    return nil, err
  end
  return path
end

function M.ensure_global_template(path)
  return ensure_template(path, [[-- FPGA SystemVerilog 插件的本机全局配置。
-- 适合配置工具路径、提示、按键和器件目录位置。
return {
  -- tools = {
  --   slang = { cmd = "slang-server" },
  -- },
  -- device_catalog_file = vim.fs.joinpath(vim.fn.stdpath("config"), "fpga-sv-devices.lua"),
}
]])
end

function M.ensure_device_catalog_template(path)
  return ensure_template(path, [=[-- 本机共享器件目录；这里可以安全保存厂商模型的绝对路径。
-- 工程通过 profiles.<name>.device 引用器件 ID。
return {
  -- amd_common = {
  --   files = { [[D:\FPGA\AMD\common\glbl.v]] },
  -- },
  -- amd_7series = {
  --   depends_on = { "amd_common" },
  --   library_dirs = { [[D:\FPGA\AMD\7series]] },
  --   library_extensions = { ".v", ".sv" },
  -- },
}
]=])
end

function M.ensure_project_template(path)
  return ensure_template(path, [[-- 可提交到仓库的 FPGA SystemVerilog 工程配置。
return {
  source_sets = {
    rtl = {
      roots = { "rtl" },
    },
  },
  profiles = {
    default = {
      source_sets = { "rtl" },
      -- device = "amd_7series",
      -- top = "demo_top",
    },
  },
  default_profile = "default",
}
]])
end

function M.ensure_local_template(root, options)
  local path = M.local_path(root, options)
  return ensure_template(path, [[-- 此文件位于 Neovim state 目录，不应提交到项目仓库。
return {
  -- tools = { svlint = { cmd = "svlint" } },
  -- profiles = {
  --   default = { device = "amd_7series" },
  -- },
}
]])
end

return M
