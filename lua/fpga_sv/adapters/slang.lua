local util = require("fpga_sv.util")
local M = {}

local config_name = "slang_server"
local root_markers = { ".nvim-fpga.lua", ".git" }

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

local function send_profile(workspace, client, bufnr)
  local artifacts = workspace.models
    and workspace.models[workspace.active_profile]
    and workspace.models[workspace.active_profile].artifacts
  if not artifacts then
    return false
  end
  local model = workspace.models[workspace.active_profile].full
  local build_ok = pcall(client.exec_cmd, client, {
    command = "slang.setBuildFile",
    arguments = { artifacts.local_filelist },
  }, { bufnr = bufnr })
  local top_ok = true
  if model.top then
    top_ok = pcall(client.exec_cmd, client, {
      command = "slang.setTopLevel",
      arguments = { model.top },
    }, { bufnr = bufnr })
  end
  return build_ok and top_ok
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
    pcall(item.client.exec_cmd, item.client, {
      command = "slang.setBuildFile",
      arguments = { path },
    }, { bufnr = item.bufnr })
  end
end

function M.set_top(workspace, top)
  for _, item in ipairs(workspace_clients(workspace)) do
    pcall(item.client.exec_cmd, item.client, {
      command = "slang.setTopLevel",
      arguments = { top },
    }, { bufnr = item.bufnr })
  end
end

return M
