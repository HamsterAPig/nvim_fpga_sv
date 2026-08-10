vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(
      ("%s: 期望 %s，实际 %s")
        :format(message, vim.inspect(expected), vim.inspect(actual))
    )
  end
end

local function assert_true(actual, message)
  assert_equal(true, not not actual, message)
end

local function event_count(client, kind, name)
  local count = 0
  for _, event in ipairs(client.events) do
    if event.kind == kind and (not name or event.name == name) then
      count = count + 1
    end
  end
  return count
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

local root = vim.fs.normalize(vim.fn.getcwd())
vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(root, "top.sv"))

local original_get_clients = vim.lsp.get_clients
local original_notify = vim.notify
local active_clients = {}

vim.lsp.get_clients = function()
  return active_clients
end
vim.notify = function() end

local function new_client(id)
  local client = {
    id = id,
    name = "slang_server",
    attached_buffers = { [bufnr] = true },
    events = {},
    callbacks = {},
    notify_result = true,
  }

  function client:notify(method, params)
    self.events[#self.events + 1] = {
      kind = "notify",
      name = method,
      params = params,
    }
    if self.notify_error then
      error(self.notify_error)
    end
    return self.notify_result
  end

  function client:exec_cmd(command, _, callback)
    self.events[#self.events + 1] = {
      kind = "command",
      name = command.command,
      command = command,
    }
    self.callbacks[#self.callbacks + 1] = {
      name = command.command,
      callback = callback,
      completed = false,
    }
  end

  return client
end

local function complete(client, name, err)
  for _, pending in ipairs(client.callbacks) do
    if not pending.completed and pending.name == name then
      pending.completed = true
      pending.callback(err)
      return
    end
  end
  error("未找到待完成命令: " .. name)
end

local function new_workspace()
  local top_path = vim.fs.joinpath(root, "top.sv")
  local child_path = vim.fs.joinpath(root, "child.sv")
  local alt_path = vim.fs.joinpath(root, "alt.sv")
  local beta_path = vim.fs.joinpath(root, "beta.sv")
  return {
    root = root,
    active_profile = "default",
    generation = 1,
    index = {
      profile = "default",
      definitions = {
        top = {
          { kind = "module", name = "top", file = top_path },
        },
        alt = {
          { kind = "module", name = "alt", file = alt_path },
        },
        duplicate = {
          { kind = "module", name = "duplicate", file = top_path },
          { kind = "module", name = "duplicate", file = child_path },
        },
      },
    },
    models = {
      default = {
        artifacts = {
          local_filelist = vim.fs.joinpath(root, "default.f"),
        },
        full = {
          top = "top",
          files = { top_path, child_path },
        },
      },
      beta = {
        artifacts = {
          local_filelist = vim.fs.joinpath(root, "beta.f"),
        },
        full = {
          top = "beta",
          files = { beta_path },
        },
      },
    },
  }
end

local function load_slang(client)
  active_clients = { client }
  package.loaded["fpga_sv.adapters.slang"] = nil
  return require("fpga_sv.adapters.slang")
end

local ok, err = xpcall(function()
  do
    local client = new_client(1)
    local slang = load_slang(client)
    local workspace = new_workspace()

    assert_true(
      slang.attach(workspace, bufnr, client.id),
      "首次附着应开始激活"
    )
    assert_equal("notify", client.events[1].kind, "索引通知必须最先发送")
    assert_equal(
      "workspace/didChangeWatchedFiles",
      client.events[1].name,
      "应发送 Slang 工作区索引通知"
    )
    assert_equal("slang.setBuildFile", client.events[2].name, "通知后应设置 build file")
    assert_equal(0, event_count(client, "command", "slang.setTopLevel"), "top 必须等待 build 成功")

    local changes = client.events[1].params.changes
    assert_equal(2, #changes, "通知应包含活动 Profile 全部源码")
    for index, file in ipairs(workspace.models.default.full.files) do
      assert_equal(vim.uri_from_fname(file), changes[index].uri, "源码 URI 应正确")
      assert_equal(
        vim.lsp.protocol.FileChangeType.Changed,
        changes[index].type,
        "源码通知类型应为 Changed"
      )
    end

    complete(client, "slang.setBuildFile", nil)
    assert_equal("slang.setTopLevel", client.events[3].name, "build 成功后应设置 top")
    assert_equal(
      workspace.index.definitions.top[1].file,
      client.events[3].command.arguments[1],
      "top 参数应为唯一源码路径"
    )
    complete(client, "slang.setTopLevel", nil)

    slang.attach(workspace, bufnr, client.id)
    assert_equal(3, #client.events, "同一生成版本不得重复激活")

    workspace.generation = workspace.generation + 1
    slang.attach(workspace, bufnr, client.id)
    assert_equal("notify", client.events[4].kind, "generation 增加后应重新同步")
    complete(client, "slang.setBuildFile", nil)
    complete(client, "slang.setTopLevel", nil)

    workspace.active_profile = "beta"
    workspace.index = {
      profile = "beta",
      definitions = {
        beta = {
          {
            kind = "module",
            name = "beta",
            file = workspace.models.beta.full.files[1],
          },
        },
      },
    }
    local before_switch = #client.events
    slang.attach(workspace, bufnr, client.id)
    assert_equal(
      before_switch + 2,
      #client.events,
      "切换 Profile 后应重新同步并设置 build"
    )
    assert_equal(
      vim.uri_from_fname(workspace.models.beta.full.files[1]),
      client.events[before_switch + 1].params.changes[1].uri,
      "切换后应同步新 Profile 源码"
    )
  end

  do
    local client = new_client(2)
    local slang = load_slang(client)
    local workspace = new_workspace()

    assert_true(slang.set_top(workspace, "alt"), "FpgaSvTop 流程应开始激活")
    assert_equal("notify", client.events[1].kind, "手动 top 也必须先同步索引")
    assert_equal("slang.setBuildFile", client.events[2].name, "手动 top 必须重新加载 build")
    complete(client, "slang.setBuildFile", nil)
    assert_equal("slang.setTopLevel", client.events[3].name, "手动 top 应等待 build 成功")
    assert_equal(
      workspace.index.definitions.alt[1].file,
      client.events[3].command.arguments[1],
      "手动 top 应解析为唯一源码路径"
    )
  end

  do
    local client = new_client(3)
    client.notify_result = false
    local slang = load_slang(client)
    local workspace = new_workspace()

    slang.attach(workspace, bufnr, client.id)
    assert_equal("notify", client.events[1].kind, "通知失败也应先尝试同步")
    assert_equal("slang.setBuildFile", client.events[2].name, "通知失败时仍应加载完整 build")
    complete(client, "slang.setBuildFile", nil)
    assert_equal(
      0,
      event_count(client, "command", "slang.setTopLevel"),
      "通知失败时不得自动设置 top"
    )

    client.notify_result = true
    slang.attach(workspace, bufnr, client.id)
    assert_equal(2, event_count(client, "notify"), "通知失败后应允许重试")
    complete(client, "slang.setBuildFile", nil)
    assert_equal(1, event_count(client, "command", "slang.setTopLevel"), "重试成功后应设置 top")
  end

  do
    local client = new_client(4)
    local slang = load_slang(client)
    local workspace = new_workspace()

    slang.attach(workspace, bufnr, client.id)
    complete(client, "slang.setBuildFile", { message = "build failed" })
    assert_equal(0, event_count(client, "command", "slang.setTopLevel"), "build 失败不得设置 top")
    slang.attach(workspace, bufnr, client.id)
    assert_equal(2, event_count(client, "notify"), "build 失败后应允许重试")
    complete(client, "slang.setBuildFile", nil)
    complete(client, "slang.setTopLevel", { message = "top failed" })
    slang.attach(workspace, bufnr, client.id)
    assert_equal(3, event_count(client, "notify"), "top 失败后应允许重试")
  end

  do
    local client = new_client(5)
    local slang = load_slang(client)
    local workspace = new_workspace()

    slang.attach(workspace, bufnr, client.id)
    workspace.active_profile = "beta"
    complete(client, "slang.setBuildFile", nil)
    assert_equal(
      0,
      event_count(client, "command", "slang.setTopLevel"),
      "Profile 中途切换时旧回调不得设置 top"
    )
  end

  do
    local client = new_client(6)
    local slang = load_slang(client)
    local workspace = new_workspace()
    workspace.models.default.full.top = nil

    slang.attach(workspace, bufnr, client.id)
    complete(client, "slang.setBuildFile", nil)
    assert_equal(0, event_count(client, "command", "slang.setTopLevel"), "缺失 top 时不得发送 top")
    slang.attach(workspace, bufnr, client.id)
    assert_equal(2, #client.events, "缺失 top 的成功 build 不应重复激活")
  end

  do
    local client = new_client(7)
    local slang = load_slang(client)
    local workspace = new_workspace()
    workspace.models.default.full.top = "duplicate"

    slang.attach(workspace, bufnr, client.id)
    complete(client, "slang.setBuildFile", nil)
    assert_equal(0, event_count(client, "command", "slang.setTopLevel"), "重复 top 定义不得发送 top")
    slang.attach(workspace, bufnr, client.id)
    assert_equal(2, #client.events, "重复 top 定义不应反复激活")
  end
end, debug.traceback)

vim.lsp.get_clients = original_get_clients
vim.notify = original_notify
package.loaded["fpga_sv.adapters.slang"] = nil
if not ok then
  error(err)
end

print("[OK] slang definition regression")
