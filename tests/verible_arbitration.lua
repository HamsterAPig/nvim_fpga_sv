vim.opt.runtimepath:prepend(vim.fn.getcwd())

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

local function diagnostic(message)
  return {
    lnum = 0,
    col = 0,
    message = message,
    severity = vim.diagnostic.severity.WARN,
  }
end

local function new_client(id)
  return {
    id = id,
    name = "verible",
    server_capabilities = {
      definitionProvider = true,
      referencesProvider = true,
      documentHighlightProvider = true,
      diagnosticProvider = { identifier = "verible" },
      codeActionProvider = true,
      hoverProvider = true,
    },
  }
end

local verible = require("fpga_sv.adapters.verible")
local bufnr = vim.api.nvim_get_current_buf()
local original_get_clients = vim.lsp.get_clients

local ok, err = xpcall(function()
  do
    verible.configure_lsp_arbitration(false)
    local client = new_client(41001)

    assert_equal(
      false,
      verible.arbitrate_client(client),
      "Slang 禁用或不可用时不得仲裁 Verible"
    )
    assert_true(
      client.server_capabilities.definitionProvider,
      "后备 Verible 必须保留 definition"
    )
    assert_true(
      client.server_capabilities.diagnosticProvider,
      "后备 Verible 必须保留 pull diagnostics"
    )
  end

  do
    verible.configure_lsp_arbitration(true)
    local client = new_client(41002)
    local push = vim.api.nvim_create_namespace("nvim.lsp.verible.41002")
    local pull_nil = vim.api.nvim_create_namespace("nvim.lsp.verible.41002.nil")
    local pull_named =
      vim.api.nvim_create_namespace("nvim.lsp.verible.41002.verible")
    vim.diagnostic.set(push, bufnr, { diagnostic("push") })
    vim.diagnostic.set(pull_nil, bufnr, { diagnostic("pull nil") })
    vim.diagnostic.set(pull_named, bufnr, { diagnostic("pull named") })

    assert_true(
      verible.arbitrate_client(client),
      "Slang 可用时应仲裁新附着的 Verible"
    )
    for _, capability in ipairs({
      "definitionProvider",
      "referencesProvider",
      "documentHighlightProvider",
      "diagnosticProvider",
    }) do
      assert_equal(
        nil,
        client.server_capabilities[capability],
        "应关闭 Verible capability: " .. capability
      )
    end
    assert_true(
      client.server_capabilities.codeActionProvider,
      "Verible code action 必须保留"
    )
    assert_true(
      client.server_capabilities.hoverProvider,
      "未参与仲裁的 capability 必须保留"
    )
    assert_equal(
      1,
      #vim.diagnostic.get(bufnr, { namespace = push }),
      "Verible push namespace 必须保留"
    )
    assert_equal(
      0,
      #vim.diagnostic.get(bufnr, { namespace = pull_nil }),
      "无 identifier 的 pull namespace 必须清空"
    )
    assert_equal(
      0,
      #vim.diagnostic.get(bufnr, { namespace = pull_named }),
      "有 identifier 的 pull namespace 必须清空"
    )

    assert_true(
      verible.arbitrate_client(client),
      "重复仲裁必须保持幂等"
    )
    assert_equal(
      1,
      #vim.diagnostic.get(bufnr, { namespace = push }),
      "重复仲裁不得清空 push diagnostics"
    )
  end

  do
    local client = new_client(41003)
    vim.lsp.get_clients = function(filter)
      assert_equal(bufnr, filter.bufnr, "补挂载必须按缓冲区查找客户端")
      assert_equal("verible", filter.name, "补挂载必须只查找 Verible")
      return { client }
    end

    assert_equal(
      1,
      verible.arbitrate_buffer(bufnr),
      "补挂载应处理已经附着的 Verible"
    )
    assert_equal(
      nil,
      client.server_capabilities.referencesProvider,
      "已附着客户端也必须关闭 references"
    )
  end
end, debug.traceback)

vim.lsp.get_clients = original_get_clients
verible.configure_lsp_arbitration(false)
if not ok then
  error(err)
end

print("[OK] verible lsp arbitration")
