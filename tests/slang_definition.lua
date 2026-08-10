vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(("%s: 期望 %s，实际 %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local commands = require("fpga_sv.commands")
local bufnr = vim.api.nvim_get_current_buf()
local keymap_workspace = {
  config = {
    effective = {
      keymaps = { definition = "gd" },
    },
  },
}

commands.setup_buffer(keymap_workspace, bufnr)
assert_equal(
  "<cmd>FpgaSvDefinition<cr>",
  vim.fn.maparg("gd", "n", false, true).rhs,
  "无现有映射时应设置 gd"
)
vim.keymap.set("n", "gd", "<cmd>echo 'existing'<cr>", { buffer = bufnr })
commands.setup_buffer(keymap_workspace, bufnr)
assert_equal(
  "<cmd>echo 'existing'<cr>",
  vim.fn.maparg("gd", "n", false, true).rhs,
  "不得覆盖现有 gd"
)

local original_get_clients = vim.lsp.get_clients
local calls, callbacks = {}, {}
local client = {
  id = 1,
  name = "slang_server",
  attached_buffers = { [bufnr] = true },
}
function client:exec_cmd(command, _, callback)
  calls[#calls + 1] = command
  callbacks[#callbacks + 1] = callback
end
vim.lsp.get_clients = function()
  return { client }
end

local ok, err = xpcall(function()
  local root = vim.fs.normalize(vim.fn.getcwd())
  vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(root, "top.sv"))
  package.loaded["fpga_sv.adapters.slang"] = nil
  local slang = require("fpga_sv.adapters.slang")
  local top_path = vim.fs.joinpath(root, "top.sv")
  local workspace = {
    root = root,
    active_profile = "default",
    index = {
      profile = "default",
      definitions = {
        top = {
          { kind = "module", name = "top", file = top_path },
        },
      },
    },
    models = {
      default = {
        artifacts = { local_filelist = vim.fs.joinpath(root, "default.f") },
        full = { top = "top" },
      },
    },
  }

  slang.attach(workspace, bufnr, client.id)
  assert_equal(1, #calls, "setTopLevel 必须等待 setBuildFile")
  assert_equal("slang.setBuildFile", calls[1].command, "首个请求应设置 build file")
  callbacks[1](nil)
  assert_equal("slang.setTopLevel", calls[2].command, "第二个请求应设置 top")
  assert_equal(top_path, calls[2].arguments[1], "top 参数应为唯一源码路径")
end, debug.traceback)

vim.lsp.get_clients = original_get_clients
package.loaded["fpga_sv.adapters.slang"] = nil
if not ok then
  error(err)
end

print("[OK] slang definition regression")
