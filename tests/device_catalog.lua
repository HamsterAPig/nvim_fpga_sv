vim.opt.runtimepath:prepend(vim.fn.getcwd())

local generate = require("fpga_sv.generate")
local config_loader = require("fpga_sv.config")
local project = require("fpga_sv.project")
local util = require("fpga_sv.util")

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

local function assert_contains(text, expected, message)
  assert_true(text:find(expected, 1, true) ~= nil, message .. ": " .. text)
end

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root, "p")
local rtl = vim.fs.joinpath(root, "rtl")
local devices = vim.fs.joinpath(root, "devices")
vim.fn.mkdir(rtl, "p")
vim.fn.mkdir(devices, "p")

local paths = {}
for _, name in ipairs({ "shared", "left", "right", "final" }) do
  paths[name] = vim.fs.joinpath(devices, name .. ".v")
  assert_true(util.atomic_write(paths[name], "module " .. name .. "; endmodule\n"), "应创建器件模型")
end
paths.project = vim.fs.joinpath(rtl, "top.sv")
assert_true(util.atomic_write(paths.project, "module top; endmodule\n"), "应创建项目 RTL")

local effective = {
  source_sets = {
    rtl = {
      files = { paths.project },
      defines = {
        ORDER = "project",
        PROJECT_WINS = "project",
        PROJECT = true,
      },
    },
  },
  profiles = {
    default = {
      source_sets = { "rtl" },
      device = "final",
      top = "top",
      defines = {
        ORDER = "profile",
        PROFILE = true,
      },
    },
  },
  default_profile = "default",
}

local catalog = {
  path = vim.fs.joinpath(root, "fpga-sv-devices.lua"),
  valid = true,
  errors = {},
  entries = {
    shared = {
      files = { paths.shared },
      defines = { ORDER = "shared", SHARED = true },
    },
    left = {
      depends_on = { "shared" },
      files = { paths.left },
      defines = { ORDER = "left", LEFT = true },
    },
    right = {
      depends_on = { "shared" },
      files = { paths.right },
      defines = { RIGHT = true },
    },
    final = {
      depends_on = { "left", "right" },
      roots = { devices },
      defines = {
        ORDER = "device",
        PROJECT_WINS = "device",
        DEVICE = true,
      },
      library_dirs = { devices },
      library_extensions = { ".v", ".sv" },
      flags = { "--device-flag", "--device-flag" },
    },
  },
}

local model, errors = project.build(root, effective, "default", catalog)
assert_equal(nil, errors, "合法器件不应产生构建错误")
assert_equal("loaded", model.device.status, "器件应成功加载")
assert_equal(
  { "shared", "left", "right", "final" },
  model.device.order,
  "多父级依赖应稳定展开且共享依赖只出现一次"
)
assert_equal(
  { paths.shared, paths.left, paths.right, paths.final, paths.project },
  model.files,
  "器件依赖、当前器件和项目源码顺序应固定"
)
assert_equal("profile", model.defines.ORDER, "Profile defines 应覆盖项目和器件")
assert_equal("project", model.defines.PROJECT_WINS, "项目 defines 应覆盖器件")
for _, name in ipairs({ "SHARED", "LEFT", "RIGHT", "DEVICE", "PROJECT", "PROFILE" }) do
  assert_equal(true, model.defines[name], "应保留各层宏: " .. name)
end
assert_equal({ "--device-flag" }, model.flags, "器件 flags 应稳定去重")

local function assert_skipped(entries, expected_warning, message)
  local broken_catalog = vim.tbl_extend("force", vim.deepcopy(catalog), {
    entries = entries,
  })
  local broken, build_errors = project.build(root, effective, "default", broken_catalog)
  assert_equal(nil, build_errors, message .. "不应阻断项目 RTL")
  assert_equal("skipped", broken.device.status, message .. "应跳过器件模型")
  assert_equal({ paths.project }, broken.files, message .. "必须原子移除全部器件内容")
  assert_contains(
    table.concat(broken.device.warnings, "\n"),
    expected_warning,
    message .. "应给出明确警告"
  )
  assert_contains(
    table.concat(broken.device.warnings, "\n"),
    "unknown module",
    message .. "应说明 Slang 后续诊断原因"
  )
end

assert_skipped({
  final = { depends_on = { "missing" }, files = { paths.final } },
}, "缺失器件依赖: missing", "缺失依赖")

assert_skipped({
  final = { depends_on = { "left" }, files = { paths.final } },
  left = { depends_on = { "final" }, files = { paths.left } },
}, "final -> left -> final", "循环依赖")

assert_skipped({
  final = { files = { paths.final }, unsupported = true },
}, "包含不支持的字段", "无效字段")

assert_skipped({
  final = { files = "not-a-list" },
}, "files 必须是列表", "无效列表类型")

assert_skipped({
  final = { files = { "relative/model.v" } },
}, "路径必须是绝对路径", "相对路径")

assert_skipped({
  final = { files = { vim.fs.joinpath(devices, "missing.v") } },
}, "不存在", "不存在路径")

local invalid_filelist = vim.fs.joinpath(devices, "invalid.f")
assert_true(
  util.atomic_write(invalid_filelist, "-I missing-include\n" .. paths.final .. "\n"),
  "应创建包含无效路径的器件 filelist"
)
assert_skipped({
  final = { filelists = { invalid_filelist } },
}, "include_dirs 路径不存在", "filelist 内不存在路径")

local portable = {
  source_sets = effective.source_sets,
  profiles = effective.profiles,
  default_profile = "default",
}
local workspace = {
  root = root,
  active_profile = "default",
  generation = 0,
  errors = {},
  config = {
    effective = vim.tbl_extend("force", vim.deepcopy(effective), {
      state_dir = vim.fs.joinpath(root, "state"),
      project_output_dir = ".nvim/fpga-sv",
    }),
    portable = portable,
    device_catalog = catalog,
  },
}
local original_notify = vim.notify
vim.notify = function() end
local built, generate_errors = generate.run(workspace)
vim.notify = original_notify
assert_true(built ~= nil, "包含器件时应成功生成")
assert_equal(nil, generate_errors, "生成不应返回错误")

local artifacts = built.default.artifacts
local project_f = assert(util.read_file(artifacts.project_filelist))
local local_f = assert(util.read_file(artifacts.local_filelist))
assert_true(project_f:find(paths.shared, 1, true) == nil, "项目 .f 不得泄漏器件绝对路径")
assert_true(project_f:find("DEVICE", 1, true) == nil, "项目 .f 不得泄漏器件宏")
assert_contains(local_f, paths.shared:gsub("\\", "/"), "本地 .f 应包含器件模型")
assert_true(
  local_f:find("-DORDER=device", 1, true) < local_f:find("-F ", 1, true),
  "器件参数必须位于项目 .f 之前，确保项目定义后覆盖"
)

local invalid_catalog_path = vim.fs.joinpath(root, "invalid-devices.lua")
assert_true(util.atomic_write(invalid_catalog_path, "return {\n"), "应创建语法错误器件目录")
local loaded = config_loader.load(root, {
  global_config = vim.fs.joinpath(root, "missing-global.lua"),
  device_catalog_file = invalid_catalog_path,
  state_dir = vim.fs.joinpath(root, "syntax-state"),
  project_file = ".missing-project.lua",
})
assert_equal(true, loaded.valid, "器件目录语法错误不应阻断项目配置")
assert_equal(false, loaded.device_catalog.valid, "应记录器件目录语法错误")
assert_contains(
  table.concat(loaded.warnings, "\n"),
  "器件目录加载失败",
  "应把器件目录语法错误记录为警告"
)
assert_equal(true, project.validate_device_catalog({}), "空器件目录应是合法目录")

print("[OK] device catalog regression")
