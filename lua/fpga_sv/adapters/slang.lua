local util = require("fpga_sv.util")
local indexer = require("fpga_sv.index")
local M = {}

local config_name = "slang_server"
local root_markers = { ".nvim-fpga.lua", ".git" }
local definition_method = "textDocument/definition"

local function command(cmd)
  return type(cmd) == "table" and cmd or { cmd }
end

function M.setup(options)
  if not options.enabled or not util.executable(options.cmd) then
    return false
  end
  local lsp_config = {
    cmd = command(options.cmd),
    filetypes = { "systemverilog", "verilog" },
    root_markers = root_markers,
    settings = options.settings,
  }
  local ok = pcall(vim.lsp.config, config_name, lsp_config)
  if ok then
    pcall(vim.lsp.enable, config_name)
  end
  return ok
end

local function buffer_workspace_root(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local start = vim.fs.dirname(name)
  return vim.fs.root(start, root_markers) or vim.fs.normalize(start)
end

local function belongs_to(workspace, bufnr)
  local root = buffer_workspace_root(bufnr)
  return root and util.path_key(root) == util.path_key(workspace.root)
end

local function attached_buffers(client)
  local buffers = {}
  for bufnr in pairs(client.attached_buffers or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      buffers[#buffers + 1] = bufnr
    end
  end
  table.sort(buffers)
  return buffers
end

local function workspace_clients(workspace)
  local result = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = config_name })) do
    for _, bufnr in ipairs(attached_buffers(client)) do
      if belongs_to(workspace, bufnr) then
        result[#result + 1] = { client = client, bufnr = bufnr }
        break
      end
    end
  end
  return result
end

local function error_message(err)
  if type(err) == "table" and err.message then
    return err.message
  end
  return tostring(err)
end

local function exec_command(client, bufnr, name, arguments, callback)
  local ok, err = pcall(client.exec_cmd, client, {
    command = name,
    arguments = arguments,
  }, { bufnr = bufnr }, function(request_err)
    if request_err then
      util.notify(
        ("Slang 执行 %s 失败: %s"):format(name, error_message(request_err)),
        vim.log.levels.ERROR
      )
      if callback then
        callback(false)
      end
      return
    end
    if callback then
      callback(true)
    end
  end)
  if not ok then
    util.notify(
      ("Slang 执行 %s 失败: %s"):format(name, error_message(err)),
      vim.log.levels.ERROR
    )
    if callback then
      callback(false)
    end
    return false
  end
  return true
end

local function ensure_index(workspace)
  if workspace.index and workspace.index.profile == workspace.active_profile then
    return workspace.index
  end
  local entry = workspace.models and workspace.models[workspace.active_profile]
  if not entry then
    return nil, "工程尚未生成"
  end
  return indexer.build(workspace, entry.full)
end

function M.resolve_top(workspace, top)
  local _, build_err = ensure_index(workspace)
  if build_err then
    return nil, build_err
  end
  local definitions = indexer.lookup(workspace, top, "module")
  if #definitions == 0 then
    return nil, (
      '活动 Profile "%s" 中未找到顶层模块 "%s"；'
      .. "已保留 build file，未发送 slang.setTopLevel"
    ):format(workspace.active_profile, top)
  end
  if #definitions > 1 then
    return nil, (
      '活动 Profile "%s" 中顶层模块 "%s" 存在 %d 个定义；'
      .. "已保留 build file，未发送 slang.setTopLevel"
    ):format(workspace.active_profile, top, #definitions)
  end
  return definitions[1].file
end

local function send_top(workspace, client, bufnr, top)
  local path, err = M.resolve_top(workspace, top)
  if not path then
    util.notify(err, vim.log.levels.WARN)
    return false
  end
  return exec_command(client, bufnr, "slang.setTopLevel", { path })
end

local function send_profile(workspace, client, bufnr)
  local profile = workspace.active_profile
  local entry = workspace.models and workspace.models[profile]
  if not entry or not entry.artifacts then
    return false
  end
  return exec_command(
    client,
    bufnr,
    "slang.setBuildFile",
    { entry.artifacts.local_filelist },
    function(ok)
      -- Profile 切换期间旧请求可能稍晚返回，不能覆盖新 Profile。
      if not ok or workspace.active_profile ~= profile then
        return
      end
      if entry.full.top then
        send_top(workspace, client, bufnr, entry.full.top)
      end
    end
  )
end

function M.attach(workspace, bufnr, client_id)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = config_name })
  if #clients == 0 then
    return false
  end

  -- 同一缓冲区只保留一个标准 Slang 客户端，避免重复诊断。
  table.sort(clients, function(a, b)
    if a.id == client_id then
      return true
    elseif b.id == client_id then
      return false
    end
    return a.id < b.id
  end)
  local selected = clients[1]
  for i = 2, #clients do
    pcall(vim.lsp.buf_detach_client, bufnr, clients[i].id)
  end
  return send_profile(workspace, selected, bufnr)
end

function M.apply_profile(workspace)
  local changed = false
  for _, item in ipairs(workspace_clients(workspace)) do
    changed = send_profile(workspace, item.client, item.bufnr) or changed
  end
  return changed
end

function M.set_build(workspace, path)
  for _, item in ipairs(workspace_clients(workspace)) do
    exec_command(item.client, item.bufnr, "slang.setBuildFile", { path })
  end
end

function M.set_top(workspace, top)
  local path, err = M.resolve_top(workspace, top)
  if not path then
    util.notify(err, vim.log.levels.WARN)
    return false
  end
  local sent = false
  for _, item in ipairs(workspace_clients(workspace)) do
    sent = exec_command(
      item.client,
      item.bufnr,
      "slang.setTopLevel",
      { path }
    ) or sent
  end
  return sent
end

local function definition_failure(workspace, detail)
  util.notify(
    ("%s（活动 Profile: %s）。请检查生成的 .f 是否包含目标源码。")
      :format(detail, workspace.active_profile),
    vim.log.levels.WARN
  )
end

function M.definition(workspace, bufnr)
  bufnr = bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = config_name })
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  local client = clients[1]
  if not client then
    definition_failure(workspace, "当前缓冲区未附着 slang_server")
    return false
  end

  if client.supports_method then
    local ok, supported = pcall(
      client.supports_method,
      client,
      definition_method,
      bufnr
    )
    if ok and not supported then
      definition_failure(workspace, "slang_server 不支持 definition")
      return false
    end
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    winid = 0
  end
  local params = vim.lsp.util.make_position_params(
    winid,
    client.offset_encoding
  )
  local ok, requested = pcall(
    client.request,
    client,
    definition_method,
    params,
    function(err, result)
      if err then
        definition_failure(
          workspace,
          "slang_server definition 请求失败: " .. error_message(err)
        )
        return
      end
      if not result or vim.tbl_isempty(result) then
        definition_failure(workspace, "slang_server 未返回定义")
        return
      end
      local locations = vim.islist(result) and result or { result }
      if #locations == 1 then
        if not vim.lsp.util.show_document(
          locations[1],
          client.offset_encoding,
          { reuse_win = true, focus = true }
        ) then
          definition_failure(workspace, "slang_server 返回了无效定义位置")
        end
        return
      end
      local items = vim.lsp.util.locations_to_items(
        locations,
        client.offset_encoding
      )
      vim.fn.setqflist({}, " ", {
        title = "Slang definitions",
        items = items,
      })
      vim.cmd("botright copen")
    end,
    bufnr
  )
  if not ok or requested == false then
    definition_failure(
      workspace,
      "无法发送 slang_server definition 请求"
        .. (ok and "" or ": " .. error_message(requested))
    )
    return false
  end
  return true
end

return M
