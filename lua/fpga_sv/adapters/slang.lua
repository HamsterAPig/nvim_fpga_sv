local util = require("fpga_sv.util")
local M = {}

local config_name = "fpga_sv_slang"

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
    root_markers = { ".nvim-fpga.lua", ".git" },
    settings = options.settings,
  }
  local ok = pcall(vim.lsp.config, config_name, lsp_config)
  if ok then
    pcall(vim.lsp.enable, config_name)
  end
  return ok
end

local function workspace_clients(workspace)
  return vim.tbl_filter(function(client)
    local root = client.config and client.config.root_dir
    return client.name == config_name
      and (not root or util.path_key(root) == util.path_key(workspace.root))
  end, vim.lsp.get_clients())
end

function M.apply_profile(workspace)
  local artifacts = workspace.models
    and workspace.models[workspace.active_profile]
    and workspace.models[workspace.active_profile].artifacts
  if not artifacts then
    return false
  end
  local model = workspace.models[workspace.active_profile].full
  local changed = false
  for _, client in ipairs(workspace_clients(workspace)) do
    local restarted = false
    local function restart_on_error(err)
      if not err or restarted then
        return
      end
      restarted = true
      client:stop(true)
      vim.schedule(function()
        pcall(vim.lsp.enable, config_name)
      end)
    end
    local build_ok = pcall(client.exec_cmd, client, {
      command = "slang.setBuildFile",
      arguments = { artifacts.local_filelist },
    }, { bufnr = 0 }, restart_on_error)
    local top_ok = true
    if model.top then
      top_ok = pcall(client.exec_cmd, client, {
        command = "slang.setTopLevel",
        arguments = { model.top },
      }, { bufnr = 0 }, restart_on_error)
    end
    if build_ok and top_ok then
      changed = true
    else
      restart_on_error("命令发送失败")
    end
  end
  return changed
end

function M.set_build(workspace, path)
  for _, client in ipairs(workspace_clients(workspace)) do
    pcall(client.exec_cmd, client, {
      command = "slang.setBuildFile",
      arguments = { path },
    }, { bufnr = 0 })
  end
end

function M.set_top(workspace, top)
  for _, client in ipairs(workspace_clients(workspace)) do
    pcall(client.exec_cmd, client, {
      command = "slang.setTopLevel",
      arguments = { top },
    }, { bufnr = 0 })
  end
end

return M
