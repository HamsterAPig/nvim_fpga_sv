vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%s: 期望 %s，实际 %s")
        :format(message, vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function assert_same(expected, actual, message)
  if expected ~= actual then
    error(message)
  end
end

local diagnostics = require("fpga_sv.adapters.slang_diagnostics")

local base = {
  range = {
    start = { line = 2, character = 4 },
    ["end"] = { line = 2, character = 9 },
  },
  severity = 2,
  code = "case-enum-explicit",
  codeDescription = { href = "https://example.test/case-enum-explicit" },
  source = "slang",
  message = "case statement does not explicitly handle all enum values",
  tags = { 1 },
  relatedInformation = {
    {
      location = {
        uri = "file:///workspace/pkg.sv",
        range = {
          start = { line = 1, character = 0 },
          ["end"] = { line = 1, character = 3 },
        },
      },
      message = "enum declared here",
    },
  },
  data = { symbol = "state_t", values = { "IDLE", "RUN" } },
}

local duplicate = vim.deepcopy(base)
local different_position = vim.deepcopy(base)
different_position.range.start.character = 5
local different_severity = vim.deepcopy(base)
different_severity.severity = 1
local different_code = vim.deepcopy(base)
different_code.code = "different-code"
local different_related = vim.deepcopy(base)
different_related.relatedInformation[1].message = "different related message"
local different_data = vim.deepcopy(base)
different_data.data.values[2] = "STOP"

local filtered = diagnostics.deduplicate({
  base,
  different_position,
  duplicate,
  different_severity,
  different_code,
  different_related,
  different_data,
})
assert_equal(6, #filtered, "精确重复应只保留第一条")
assert_same(base, filtered[1], "第一条诊断及顺序必须保留")
assert_same(
  different_position,
  filtered[2],
  "位置不同的诊断必须保留原始顺序"
)
assert_same(
  different_severity,
  filtered[3],
  "级别不同的诊断必须保留"
)
assert_same(different_code, filtered[4], "代码不同的诊断必须保留")
assert_same(
  different_related,
  filtered[5],
  "相关信息不同的诊断必须保留"
)
assert_same(
  different_data,
  filtered[6],
  "完整属性不同的诊断必须保留"
)

local empty = {}
assert_same(empty, diagnostics.deduplicate(empty), "空诊断列表必须原样透传")

local original_encode = vim.json.encode
local encode_calls = 0
vim.json.encode = function(value)
  encode_calls = encode_calls + 1
  if encode_calls == 2 then
    error("模拟 JSON 编码失败")
  end
  return original_encode(value)
end
local failed_fingerprint = diagnostics.deduplicate({
  vim.deepcopy(base),
  vim.deepcopy(base),
})
vim.json.encode = original_encode
assert_equal(2, #failed_fingerprint, "JSON 指纹失败时必须保留原诊断")

local calls = {}
local downstream_result = {}
local handler = diagnostics.wrap(function(err, result, ctx, config)
  calls[#calls + 1] = {
    err = err,
    result = result,
    ctx = ctx,
    config = config,
  }
  return downstream_result
end)
local params = {
  uri = "file:///workspace/top.sv",
  version = 7,
  diagnostics = { base, duplicate },
}
local ctx = { client_id = 12, method = "textDocument/publishDiagnostics" }
local config = { virtual_text = false }
local returned = handler(nil, params, ctx, config)

assert_same(downstream_result, returned, "应返回下游 handler 的结果")
assert_equal(1, #calls, "下游 handler 只能调用一次")
assert_equal(1, #calls[1].result.diagnostics, "下游只应收到去重结果")
assert_same(params.uri, calls[1].result.uri, "必须保留发布 URI")
assert_same(params.version, calls[1].result.version, "必须保留发布版本")
assert_same(ctx, calls[1].ctx, "必须原样传递 handler 上下文")
assert_same(config, calls[1].config, "必须原样传递 handler 配置")
assert_equal(2, #params.diagnostics, "不得修改服务端原始发布对象")

local empty_calls = 0
local empty_handler = diagnostics.wrap(function(_, result)
  empty_calls = empty_calls + 1
  assert_same(empty, result.diagnostics, "空诊断数组引用必须原样传递")
end)
empty_handler(nil, { uri = params.uri, diagnostics = empty }, ctx, config)
assert_equal(1, empty_calls, "空诊断发布也必须调用下游一次")

local custom_calls = 0
local custom = function()
  custom_calls = custom_calls + 1
end
local configured = diagnostics.handler({
  handlers = {
    ["textDocument/publishDiagnostics"] = custom,
  },
})
configured(nil, { diagnostics = {} }, ctx, config)
assert_equal(1, custom_calls, "必须继续调用已有的自定义 handler")

local method = "textDocument/publishDiagnostics"
local original_default = vim.lsp.handlers[method]
local default_calls = 0
vim.lsp.handlers[method] = function()
  default_calls = default_calls + 1
end
local default_handler = diagnostics.handler(nil)
default_handler(nil, { diagnostics = {} }, ctx, config)
vim.lsp.handlers[method] = original_default
assert_equal(1, default_calls, "没有自定义 handler 时必须调用 Neovim 默认 handler")

local setup_calls = 0
vim.lsp.config("slang_server", {
  handlers = {
    [method] = function(_, result)
      setup_calls = setup_calls + 1
      assert_equal(1, #result.diagnostics, "注册后的 handler 应过滤精确重复")
    end,
  },
})
package.loaded["fpga_sv.adapters.slang"] = nil
local slang = require("fpga_sv.adapters.slang")
assert_equal(
  true,
  slang.setup({
    enabled = true,
    cmd = "nvim",
    settings = {},
  }),
  "Slang 适配器应成功注册诊断 handler"
)
vim.lsp.config.slang_server.handlers[method](
  nil,
  { uri = params.uri, diagnostics = { base, duplicate } },
  ctx,
  config
)
assert_equal(1, setup_calls, "适配器必须包装并调用已有配置 handler 一次")

print("[OK] slang diagnostics deduplication")
