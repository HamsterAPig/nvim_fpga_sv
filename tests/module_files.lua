vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config_loader = require("fpga_sv.config")
local commands = require("fpga_sv.commands")
local defaults = require("fpga_sv.defaults")
local generate = require("fpga_sv.generate")
local health = require("fpga_sv.health")
local project = require("fpga_sv.project")
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

local function assert_contains(text, expected, message)
  assert_true(text:find(expected, 1, true) ~= nil, message .. ": " .. text)
end

local function write(path, content)
  assert_true(util.atomic_write(path, content), "应创建测试文件: " .. path)
  return path
end

local root = vim.fs.normalize(vim.fn.tempname())
local rtl = vim.fs.joinpath(root, "rtl")
local common_root = vim.fs.joinpath(root, "common")
local vendor_root = vim.fs.joinpath(root, "vendor")
local family_root = vim.fs.joinpath(vendor_root, "simulation", "family_a")
local secondary_library_root = vim.fs.joinpath(
  vendor_root,
  "simulation",
  "secondary"
)
vim.fn.mkdir(rtl, "p")
vim.fn.mkdir(common_root, "p")
vim.fn.mkdir(family_root, "p")
vim.fn.mkdir(secondary_library_root, "p")

local paths = {
  top = write(
    vim.fs.joinpath(rtl, "top.sv"),
    [[module top;
  VENDOR_CLOCK_BUFFER u_clk();
  SHARED_OVERRIDE u_override();
  AUTO_LIBRARY u_auto0();
  AUTO_LIBRARY u_auto1();
  PROJECT_DEFINED u_project();
  DIR_ORDER u_dir_order();
  EXT_ORDER u_ext_order();
  MISSING_LIBRARY u_missing();
endmodule

module PROJECT_DEFINED;
endmodule
]]
  ),
  clock = write(
    vim.fs.joinpath(family_root, "clock_models.v"),
    [[module VENDOR_CLOCK_BUFFER;
  VENDOR_CLOCK_DEP u_dep0();
  VENDOR_CLOCK_DEP u_dep1();
  ALIAS_DEP u_alias();
  CYCLE_A u_cycle();
endmodule
]]
  ),
  dependency = write(
    vim.fs.joinpath(family_root, "clock_dependency.v"),
    [[module VENDOR_CLOCK_DEP;
  CYCLE_B u_cycle();
endmodule
]]
  ),
  cycle_a = write(
    vim.fs.joinpath(family_root, "cycle_a.v"),
    [[module CYCLE_A;
  CYCLE_B u_cycle();
endmodule
]]
  ),
  cycle_b = write(
    vim.fs.joinpath(family_root, "cycle_b.v"),
    [[module CYCLE_B;
  CYCLE_A u_cycle();
endmodule
]]
  ),
  common_override = write(
    vim.fs.joinpath(common_root, "shared_override.v"),
    "module SHARED_OVERRIDE; endmodule\n"
  ),
  device_override = write(
    vim.fs.joinpath(family_root, "shared_override.v"),
    "module SHARED_OVERRIDE; endmodule\n"
  ),
  unused = write(
    vim.fs.joinpath(family_root, "unused.v"),
    "module UNUSED_VENDOR_MODULE; endmodule\n"
  ),
  auto_library = write(
    vim.fs.joinpath(family_root, "AUTO_LIBRARY.v"),
    [[module AUTO_LIBRARY;
  AUTO_DEP u_dep();
endmodule
]]
  ),
  auto_dependency = write(
    vim.fs.joinpath(family_root, "AUTO_DEP.sv"),
    "module AUTO_DEP; endmodule\n"
  ),
  project_defined_library = write(
    vim.fs.joinpath(family_root, "PROJECT_DEFINED.v"),
    "module PROJECT_DEFINED; endmodule\n"
  ),
  mapped_shadow = write(
    vim.fs.joinpath(family_root, "VENDOR_CLOCK_BUFFER.v"),
    "module VENDOR_CLOCK_BUFFER; endmodule\n"
  ),
  directory_first = write(
    vim.fs.joinpath(family_root, "DIR_ORDER.sv"),
    "module DIR_ORDER; endmodule\n"
  ),
  directory_second = write(
    vim.fs.joinpath(secondary_library_root, "DIR_ORDER.v"),
    "module DIR_ORDER; endmodule\n"
  ),
  extension_first = write(
    vim.fs.joinpath(family_root, "EXT_ORDER.v"),
    "module EXT_ORDER; endmodule\n"
  ),
  extension_second = write(
    vim.fs.joinpath(family_root, "EXT_ORDER.sv"),
    "module EXT_ORDER; endmodule\n"
  ),
}

local effective = {
  source_sets = {
    rtl = {
      files = { paths.top },
    },
  },
  profiles = {
    default = {
      source_sets = { "rtl" },
      device = "vendor_family_a",
      top = "top",
    },
  },
  default_profile = "default",
}

local catalog = {
  path = vim.fs.joinpath(root, "fpga-sv-devices.lua"),
  exists = true,
  valid = true,
  errors = {},
  entries = {
    common = {
      module_files = {
        SHARED_OVERRIDE = paths.common_override,
      },
    },
    vendor_family_a = {
      depends_on = { "common" },
      module_files = {
        VENDOR_CLOCK_BUFFER = paths.clock,
        VENDOR_CLOCK_DEP = paths.dependency,
        ALIAS_DEP = paths.dependency,
        CYCLE_A = paths.cycle_a,
        CYCLE_B = paths.cycle_b,
        SHARED_OVERRIDE = paths.device_override,
        UNUSED_VENDOR_MODULE = paths.unused,
      },
      library_dirs = { family_root, secondary_library_root },
      library_extensions = { ".v", ".sv" },
    },
  },
}

local model, errors = project.build(root, effective, "default", catalog)
assert_equal(nil, errors, "合法 module_files 不应产生构建错误")
assert_equal("loaded", model.device.status, "器件映射应成功加载")
assert_equal(
  {
    paths.top,
    paths.clock,
    paths.device_override,
    paths.auto_library,
    paths.directory_first,
    paths.extension_first,
    paths.dependency,
    paths.cycle_a,
    paths.auto_dependency,
    paths.cycle_b,
  },
  model.files,
  "映射和库文件应按实例发现顺序递归加载并稳定去重"
)
assert_equal(
  {
    { module = "VENDOR_CLOCK_BUFFER", path = paths.clock, device = "vendor_family_a" },
    { module = "SHARED_OVERRIDE", path = paths.device_override, device = "vendor_family_a" },
    { module = "VENDOR_CLOCK_DEP", path = paths.dependency, device = "vendor_family_a" },
    { module = "ALIAS_DEP", path = paths.dependency, device = "vendor_family_a" },
    { module = "CYCLE_A", path = paths.cycle_a, device = "vendor_family_a" },
    { module = "CYCLE_B", path = paths.cycle_b, device = "vendor_family_a" },
  },
  model.device.module_files,
  "工程信息应保留本次实际命中的模块映射"
)
assert_equal(
  {
    {
      module = "AUTO_LIBRARY",
      path = paths.auto_library,
      library_dir = family_root,
      device = "vendor_family_a",
    },
    {
      module = "DIR_ORDER",
      path = paths.directory_first,
      library_dir = family_root,
      device = "vendor_family_a",
    },
    {
      module = "EXT_ORDER",
      path = paths.extension_first,
      library_dir = family_root,
      device = "vendor_family_a",
    },
    {
      module = "AUTO_DEP",
      path = paths.auto_dependency,
      library_dir = family_root,
      device = "vendor_family_a",
    },
  },
  model.library_files,
  "库模块应按目录再按扩展名顺序命中，并递归加载依赖"
)
assert_equal(
  {
    {
      module = "SHARED_OVERRIDE",
      previous_device = "common",
      previous_path = paths.common_override,
      device = "vendor_family_a",
      path = paths.device_override,
    },
  },
  model.device.module_file_overrides,
  "当前器件同名映射应覆盖公共依赖并保留诊断"
)
assert_true(
  not vim.tbl_contains(model.files, paths.unused),
  "未例化的映射不得进入工程模型"
)
assert_true(
  not vim.tbl_contains(model.files, paths.project_defined_library),
  "工程已有同名定义时不得加载库文件"
)
assert_true(
  not vim.tbl_contains(model.files, paths.mapped_shadow),
  "module_files 应优先于自动库搜索"
)
assert_true(
  not vim.tbl_contains(model.files, paths.directory_second),
  "库目录搜索应优先选择第一个命中目录"
)
assert_true(
  not vim.tbl_contains(model.files, paths.extension_second),
  "同一目录应优先选择第一个命中扩展名"
)

local function assert_skipped(entries, expected_warning, message)
  local broken_catalog = vim.tbl_extend("force", vim.deepcopy(catalog), {
    entries = entries,
  })
  local broken, build_errors = project.build(
    root,
    effective,
    "default",
    broken_catalog
  )
  assert_equal(nil, build_errors, message .. "不应阻断项目 RTL")
  assert_equal("skipped", broken.device.status, message .. "应原子跳过器件模型")
  assert_equal({ paths.top }, broken.files, message .. "不得留下部分器件模型")
  assert_contains(
    table.concat(broken.device.warnings, "\n"),
    expected_warning,
    message .. "应给出明确警告"
  )
end

assert_skipped({
  vendor_family_a = {
    module_files = {
      ["bad-module-name"] = paths.clock,
    },
  },
}, "模块名无效", "无效模块名")

assert_skipped({
  vendor_family_a = {
    module_files = {
      VENDOR_CLOCK_BUFFER = "relative/clock_models.v",
    },
  },
}, "必须是绝对路径", "相对映射路径")

assert_skipped({
  vendor_family_a = {
    module_files = {
      VENDOR_CLOCK_BUFFER = vim.fs.joinpath(family_root, "missing.v"),
    },
  },
}, "不存在", "不存在映射路径")

local workspace = {
  root = root,
  active_profile = "default",
  generation = 0,
  errors = {},
  config = {
    effective = vim.tbl_extend("force", vim.deepcopy(effective), {
      state_dir = vim.fs.joinpath(root, "state"),
      project_output_dir = ".nvim/fpga-sv",
      tools = defaults.get().tools,
    }),
    portable = {
      source_sets = effective.source_sets,
      profiles = effective.profiles,
      default_profile = "default",
    },
    device_catalog = catalog,
    paths = {
      global = vim.fs.joinpath(root, "global.lua"),
      device_catalog = catalog.path,
      project = vim.fs.joinpath(root, ".nvim-fpga.lua"),
      local_config = vim.fs.joinpath(root, "local.lua"),
    },
    warnings = {},
    valid = true,
    errors = {},
  },
}
local original_notify = vim.notify
vim.notify = function() end
local built, generate_errors = generate.run(workspace)
vim.notify = original_notify
assert_true(built ~= nil, "module_files 应成功生成本地产物")
assert_equal(nil, generate_errors, "生成不应返回错误")

local project_f = assert(util.read_file(built.default.artifacts.project_filelist))
local local_f = assert(util.read_file(built.default.artifacts.local_filelist))
assert_true(
  project_f:find(paths.clock, 1, true) == nil,
  "映射文件不得进入可提交的项目 .f"
)
assert_contains(
  local_f,
  paths.clock:gsub("\\", "/"),
  "已命中的映射文件应进入本地 .f"
)
assert_contains(
  local_f,
  paths.auto_library:gsub("\\", "/"),
  "器件库自动命中文件应进入本地 .f"
)
assert_contains(
  local_f,
  "-y " .. family_root:gsub("\\", "/"),
  "本地 .f 应继续保留器件库 -y"
)
assert_contains(
  local_f,
  "+libext+.v+.sv",
  "本地 .f 应继续保留器件库 +libext"
)
assert_true(
  project_f:find(paths.auto_library, 1, true) == nil,
  "器件库自动命中文件不得进入可提交的项目 .f"
)
assert_true(
  local_f:find(paths.unused:gsub("\\", "/"), 1, true) == nil,
  "未命中的映射文件不得进入本地 .f"
)

local original_current = workspace_manager.current
workspace_manager.current = function()
  return workspace
end
commands.setup()
vim.cmd("FpgaSvProjectInfo")
workspace_manager.current = original_current
local info = table.concat(
  vim.api.nvim_buf_get_lines(0, 0, -1, false),
  "\n"
)
assert_contains(
  info,
  "VENDOR_CLOCK_BUFFER -> " .. paths.clock,
  "工程信息应显示实际命中的映射和文件"
)
assert_contains(
  info,
  "SHARED_OVERRIDE: common",
  "工程信息应显示器件依赖映射覆盖"
)
assert_contains(
  info,
  "AUTO_LIBRARY -> " .. paths.auto_library,
  "工程信息应区分显示自动命中的库文件"
)

local health_report = {}
local original_health = {}
for _, name in ipairs({ "start", "ok", "warn", "error" }) do
  original_health[name] = vim.health[name]
  vim.health[name] = function(message)
    health_report[#health_report + 1] = name .. ": " .. message
  end
end
workspace_manager.current = function()
  return workspace
end
health.check()
workspace_manager.current = original_current
for name, callback in pairs(original_health) do
  vim.health[name] = callback
end
local health_text = table.concat(health_report, "\n")
assert_contains(
  health_text,
  "模块映射: VENDOR_CLOCK_BUFFER -> " .. paths.clock,
  "checkhealth 应检查实际命中的模块映射"
)
assert_contains(
  health_text,
  "模块映射覆盖: SHARED_OVERRIDE；common",
  "checkhealth 应检查依赖映射覆盖"
)
assert_contains(
  health_text,
  "库模块: AUTO_LIBRARY -> " .. paths.auto_library,
  "checkhealth 应检查自动命中的库文件"
)

-- 项目自身的 library_dirs 同样应物化命中文件，但不带器件 ID。
local project_library_root = vim.fs.joinpath(root, "project-library")
vim.fn.mkdir(project_library_root, "p")
local project_library_top = write(
  vim.fs.joinpath(rtl, "project_library_top.sv"),
  "module project_library_top; PROJECT_AUTO u_auto(); endmodule\n"
)
local project_library_file = write(
  vim.fs.joinpath(project_library_root, "PROJECT_AUTO.sv"),
  "module PROJECT_AUTO; endmodule\n"
)
local project_library_model, project_library_errors = project.build(root, {
  source_sets = {
    project_library = {
      files = { project_library_top },
      library_dirs = { project_library_root },
      library_extensions = { ".sv" },
    },
  },
  profiles = {
    default = {
      source_sets = { "project_library" },
      top = "project_library_top",
    },
  },
}, "default")
assert_equal(nil, project_library_errors, "项目库自动解析不应产生错误")
assert_equal(
  { project_library_top, project_library_file },
  project_library_model.files,
  "项目 library_dirs 命中文件应加入工程模型"
)
assert_equal(
  {
    {
      module = "PROJECT_AUTO",
      path = project_library_file,
      library_dir = project_library_root,
    },
  },
  project_library_model.library_files,
  "项目库命中记录不应携带器件 ID"
)
local project_library_config = {
  source_sets = {
    project_library = {
      files = { project_library_top },
      library_dirs = { project_library_root },
      library_extensions = { ".sv" },
    },
  },
  profiles = {
    default = {
      source_sets = { "project_library" },
      top = "project_library_top",
    },
  },
  default_profile = "default",
  state_dir = vim.fs.joinpath(root, "project-library-state"),
  project_output_dir = ".project-library-generated",
}
local project_library_workspace = {
  root = root,
  active_profile = "default",
  generation = 0,
  errors = {},
  config = {
    effective = project_library_config,
    portable = project_library_config,
  },
}
local project_library_built, project_library_generate_errors =
  generate.run(project_library_workspace)
assert_equal(
  nil,
  project_library_generate_errors,
  "项目库物化后应成功生成产物"
)
local project_library_f = assert(util.read_file(
  project_library_built.default.artifacts.project_filelist
))
assert_contains(
  project_library_f,
  "PROJECT_AUTO.sv",
  "项目库命中文件应写入可提交项目 .f"
)

local alternate_root = vim.fs.joinpath(root, "vendor-alternate")
local alternate_family = vim.fs.joinpath(
  alternate_root,
  "simulation",
  "family_a"
)
vim.fn.mkdir(alternate_family, "p")
local alternate_clock = write(
  vim.fs.joinpath(alternate_family, "clock_models.v"),
  "module VENDOR_CLOCK_BUFFER; endmodule\n"
)
local catalog_path = vim.fs.joinpath(root, "root-derived-devices.lua")

local function write_root_catalog(root_path)
  write(
    catalog_path,
    ([=[local vendor_root = [[%s]]
local family_root = vim.fs.joinpath(vendor_root, "simulation", "family_a")

return {
  vendor_family_a = {
    module_files = {
      VENDOR_CLOCK_BUFFER = vim.fs.joinpath(family_root, "clock_models.v"),
    },
    library_dirs = { family_root },
    library_extensions = { ".v", ".sv" },
  },
}
]=]):format(root_path)
  )
end

local function load_root_catalog()
  return config_loader.load(root, {
    global_config = vim.fs.joinpath(root, "missing-global.lua"),
    device_catalog_file = catalog_path,
    state_dir = vim.fs.joinpath(root, "root-state"),
    project_file = ".missing-project.lua",
  }).device_catalog.entries
end

write_root_catalog(vendor_root)
assert_equal(
  paths.clock,
  load_root_catalog().vendor_family_a.module_files.VENDOR_CLOCK_BUFFER,
  "顶部 vendor_root 应派生全部系列路径"
)
write_root_catalog(alternate_root)
assert_equal(
  alternate_clock,
  load_root_catalog().vendor_family_a.module_files.VENDOR_CLOCK_BUFFER,
  "更换顶部 vendor_root 后映射路径应自动更新"
)

print("[OK] module files regression")
