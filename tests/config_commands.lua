vim.opt.runtimepath:prepend(vim.fn.getcwd())

local commands = require("fpga_sv.commands")
local util = require("fpga_sv.util")
local workspace_manager = require("fpga_sv.workspace")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%s: 期望 %s，实际 %s")
        :format(message, vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function assert_true(actual, message)
  assert_equal(true, not not actual, message)
end

local root = vim.fs.normalize(vim.fn.tempname())
local second_root = vim.fs.normalize(vim.fn.tempname())
local config_dir = vim.fs.joinpath(root, "config")
local state_dir = vim.fs.joinpath(root, "state")
local global_path = vim.fs.joinpath(config_dir, "custom-global.lua")
local device_path = vim.fs.joinpath(config_dir, "custom-devices.lua")
vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")
vim.fn.mkdir(vim.fs.joinpath(second_root, ".git"), "p")
assert_true(util.atomic_write(global_path, "-- keep-global\nreturn {}\n"), "应创建自定义全局配置")

workspace_manager.setup({
  global_config = global_path,
  device_catalog_file = device_path,
  state_dir = state_dir,
})
commands.setup()

local buffer_index = 0
local function enter_project(project_root)
  buffer_index = buffer_index + 1
  vim.cmd.enew()
  vim.api.nvim_buf_set_name(
    0,
    vim.fs.joinpath(project_root, "top-" .. buffer_index .. ".sv")
  )
end

local function run_and_check(command, expected)
  enter_project(root)
  vim.cmd(command)
  assert_equal(
    util.path_key(expected),
    util.path_key(vim.api.nvim_buf_get_name(0)),
    command .. " 应打开实际配置路径"
  )
end

run_and_check("FpgaSvEditGlobalConfig", global_path)
assert_equal("-- keep-global\nreturn {}\n", util.read_file(global_path), "已有全局配置不得覆盖")

run_and_check("FpgaSvEditDeviceCatalog", device_path)
local device_template = assert(util.read_file(device_path))
assert_true(device_template:find("本机共享器件目录", 1, true) ~= nil, "器件模板应含简体中文注释")
assert_true(device_template:find("local vendor_root", 1, true) ~= nil, "器件模板应集中定义厂商 Root")
assert_true(device_template:find("module_files", 1, true) ~= nil, "器件模板应展示按需模块映射")
run_and_check("FpgaSvEditDeviceCatalog", device_path)
assert_equal(device_template, util.read_file(device_path), "已有器件目录不得覆盖")

local workspace = workspace_manager.get(root)
run_and_check("FpgaSvEditProjectConfig", workspace.config.paths.project)
local project_template = assert(util.read_file(workspace.config.paths.project))
assert_true(project_template:find("可提交到仓库", 1, true) ~= nil, "项目模板应含简体中文注释")
run_and_check("FpgaSvEditProjectConfig", workspace.config.paths.project)
assert_equal(project_template, util.read_file(workspace.config.paths.project), "已有项目配置不得覆盖")

run_and_check("FpgaSvEditLocalConfig", workspace.config.paths.local_config)
local local_template = assert(util.read_file(workspace.config.paths.local_config))
assert_true(local_template:find("不应提交", 1, true) ~= nil, "本地模板应含简体中文注释")
run_and_check("FpgaSvEditLocalConfig", workspace.config.paths.local_config)
assert_equal(local_template, util.read_file(workspace.config.paths.local_config), "已有本地配置不得覆盖")

local second = workspace_manager.get(second_root)
local function sorted_keys(values)
  local result = vim.tbl_map(util.path_key, values)
  table.sort(result)
  return result
end
assert_equal(
  sorted_keys({ root, second_root }),
  sorted_keys(workspace_manager.config_change_roots(global_path)),
  "保存全局配置应刷新全部已加载工程"
)
assert_equal(
  sorted_keys({ root, second_root }),
  sorted_keys(workspace_manager.config_change_roots(device_path)),
  "保存器件目录应刷新全部已加载工程"
)
assert_equal(
  { util.path_key(root) },
  sorted_keys(workspace_manager.config_change_roots(workspace.config.paths.project)),
  "保存项目配置只应刷新所属工程"
)
assert_equal(
  { util.path_key(second_root) },
  sorted_keys(workspace_manager.config_change_roots(second.config.paths.local_config)),
  "保存本地配置只应刷新所属工程"
)

print("[OK] config commands regression")
