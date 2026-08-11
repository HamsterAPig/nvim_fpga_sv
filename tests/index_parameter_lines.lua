vim.opt.runtimepath:prepend(vim.fn.getcwd())

local defaults = require("fpga_sv.defaults")
local features = require("fpga_sv.features")
local indexer = require("fpga_sv.index")
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

local function find_symbol(parsed, name, kind)
  for _, symbol in ipairs(parsed.symbols or {}) do
    if symbol.name == name and symbol.kind == kind then
      return symbol
    end
  end
  error(("未找到 %s %s"):format(kind, name))
end

local function assert_port_lines(text, name, kind, expected, message)
  local parsed = indexer.parse_text(text, name .. ".sv")
  local symbol = find_symbol(parsed, name, kind)
  local actual = {}
  for _, port in ipairs(symbol.ports or {}) do
    actual[#actual + 1] = port.line
  end
  assert_equal(expected, actual, message)
  return parsed, symbol
end

local multi_parameter = [[module multi_parameter #(
  parameter int WIDTH = 8,
  parameter bit ENABLE = 1
) (
  input logic clk,
  output logic done
);
endmodule
]]

local single_parameter = [[module single_parameter #(parameter int WIDTH = 8) (
  input logic clk,
  output logic done
);
endmodule
]]

local without_parameter = [[module without_parameter (
  input logic clk,
  output logic done
);
endmodule
]]

local parameter_interface = [[interface parameter_interface #(
  parameter int WIDTH = 8
) (
  input logic clk,
  output logic ready
);
endinterface
]]

local parsed_multi = assert_port_lines(
  multi_parameter,
  "multi_parameter",
  "module",
  { 5, 6 },
  "多行 parameter 后的端口应保留原始模块头行号"
)
assert_port_lines(
  single_parameter,
  "single_parameter",
  "module",
  { 2, 3 },
  "单行 parameter 的端口行号应保持正确"
)
assert_port_lines(
  without_parameter,
  "without_parameter",
  "module",
  { 2, 3 },
  "无 parameter 的端口行号不应变化"
)
assert_port_lines(
  parameter_interface,
  "parameter_interface",
  "interface",
  { 4, 5 },
  "interface 的多行 parameter 不应影响端口行号"
)

-- 端到端检查虚拟文字，确保提示落在端口行而不是 parameter 行。
local hint_path = vim.fs.normalize(vim.fn.tempname() .. ".sv")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, hint_path)
vim.api.nvim_buf_set_lines(
  bufnr,
  0,
  -1,
  false,
  vim.split(multi_parameter, "\n", { plain = true })
)
local workspace = {
  active_profile = "default",
  config = {
    effective = {
      hints = defaults.get().hints,
    },
  },
  index = {
    files = {
      [util.path_key(hint_path)] = parsed_multi,
    },
    definitions = {},
    symbols = parsed_multi.symbols,
    profile = "default",
  },
}
features.refresh_hints(workspace, bufnr)

local hint_namespace = vim.api.nvim_get_namespaces().fpga_sv_hints
assert_true(hint_namespace ~= nil, "应创建端口提示命名空间")
local hint_rows = {}
for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(
  bufnr,
  hint_namespace,
  0,
  -1,
  { details = true }
)) do
  local details = extmark[4]
  local text = details.virt_text and details.virt_text[1]
    and details.virt_text[1][1]
  if text == "← IN" or text == "→ OUT" then
    hint_rows[text] = extmark[2] + 1
  end
end
assert_equal(5, hint_rows["← IN"], "输入提示应位于 input 端口行")
assert_equal(6, hint_rows["→ OUT"], "输出提示应位于 output 端口行")
assert_true(hint_rows["← IN"] ~= 2, "输入提示不得落在 parameter 行")
assert_true(hint_rows["→ OUT"] ~= 3, "输出提示不得落在 parameter 行")
vim.api.nvim_buf_delete(bufnr, { force = true })

-- 旧缓存没有版本号，即使文件签名一致，也必须重新解析并写入新版缓存。
local root = vim.fs.normalize(vim.fn.tempname())
local state_dir = vim.fs.joinpath(root, "state")
local source_path = vim.fs.joinpath(root, "cached.sv")
assert_true(util.atomic_write(source_path, multi_parameter), "应创建缓存回归测试文件")
local stat = assert((vim.uv or vim.loop).fs_stat(source_path))
local signature = "disk:" .. stat.mtime.sec .. ":" .. stat.size
local cache_file = vim.fs.joinpath(
  state_dir,
  "projects",
  util.root_hash(root),
  "index.json"
)
local source_key = util.path_key(source_path)
local old_cache = {
  _owner = "nvim_fpga_sv",
  files = {
    [source_key] = {
      signature = signature,
      parsed = {
        path = source_path,
        parser = "fallback",
        symbols = {
          {
            kind = "module",
            name = "multi_parameter",
            file = source_path,
            line = 1,
            end_line = 8,
            parser = "fallback",
            parameters = {},
            ports = {
              { name = "clk", direction = "input", line = 2 },
              { name = "done", direction = "output", line = 3 },
            },
          },
        },
      },
    },
  },
}
assert_true(
  util.atomic_write(cache_file, vim.json.encode(old_cache) .. "\n"),
  "应写入旧版索引缓存"
)

local cached_workspace = {
  root = root,
  active_profile = "default",
  config = {
    effective = {
      state_dir = state_dir,
    },
  },
}
local rebuilt = assert(indexer.build(cached_workspace, {
  files = { source_path },
}))
local rebuilt_symbol = find_symbol(rebuilt.files[source_key], "multi_parameter", "module")
assert_equal(
  { 5, 6 },
  { rebuilt_symbol.ports[1].line, rebuilt_symbol.ports[2].line },
  "旧版缓存应失效并重新解析端口行号"
)
local rewritten_cache = vim.json.decode(assert(util.read_file(cache_file)))
assert_equal(1, rewritten_cache._version, "新版缓存应写入内部版本号")

print("[OK] parameter port line regression")
