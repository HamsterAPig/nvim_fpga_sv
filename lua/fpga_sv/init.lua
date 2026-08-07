local adapters = require("fpga_sv.adapters")
local commands = require("fpga_sv.commands")
local features = require("fpga_sv.features")
local generate = require("fpga_sv.generate")
local indexer = require("fpga_sv.index")
local util = require("fpga_sv.util")
local workspace_manager = require("fpga_sv.workspace")
local M = {}

local initialized = false
local availability = {}

local function is_hdl_buffer(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return filetype == "systemverilog" or filetype == "verilog"
end

local function setup_highlights()
  local links = {
    FpgaSvPortInput = "DiagnosticHint",
    FpgaSvPortOutput = "DiagnosticInfo",
    FpgaSvPortInout = "DiagnosticWarn",
    FpgaSvPortRef = "Special",
    FpgaSvPortInterface = "Type",
    FpgaSvPortSummary = "Comment",
    ["@fpga_sv.interface"] = "@type",
    ["@fpga_sv.modport"] = "@property",
    ["@fpga_sv.instance"] = "@variable",
    ["@fpga_sv.macro_parameter"] = "@constant",
    ["@fpga_sv.assertion"] = "@keyword",
    ["@fpga_sv.sequence"] = "@function",
    ["@fpga_sv.property"] = "@function",
    ["@fpga_sv.coverage"] = "@keyword",
    ["@fpga_sv.hierarchy"] = "@variable.member",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local function attach_buffer(bufnr)
  local workspace = workspace_manager.get(workspace_manager.root(bufnr))
  if workspace.config.valid and not workspace.models then
    local built, errors = generate.run(workspace)
    if not built then
      util.notify(table.concat(errors, "\n"), vim.log.levels.ERROR)
    end
  end
  if workspace.models then
    indexer.build(workspace, workspace.models[workspace.active_profile].full)
  end
  features.setup_buffer(workspace, bufnr)
  commands.setup_buffer(workspace, bufnr)
  require("fpga_sv.adapters.slang").attach(workspace, bufnr)
end

function M.setup(options)
  options = options or {}
  workspace_manager.setup(options)
  if initialized then
    for root in workspace_manager.each() do
      workspace_manager.refresh(root)
    end
    return M
  end
  initialized = true
  commands.setup()
  setup_highlights()

  local workspace = workspace_manager.current()
  availability = adapters.setup(workspace.config.effective)

  local group = vim.api.nvim_create_augroup("FpgaSv", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "systemverilog", "verilog" },
    callback = function(args)
      attach_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "slang_server" or not is_hdl_buffer(args.buf) then
        return
      end
      local workspace_item = workspace_manager.get(workspace_manager.root(args.buf))
      if workspace_item.config.valid and not workspace_item.models then
        local built, errors = generate.run(workspace_item)
        if not built then
          util.notify(table.concat(errors, "\n"), vim.log.levels.ERROR)
          return
        end
        indexer.build(
          workspace_item,
          workspace_item.models[workspace_item.active_profile].full
        )
      end
      require("fpga_sv.adapters.slang").attach(
        workspace_item,
        args.buf,
        args.data.client_id
      )
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { ".nvim-fpga.lua", "fpga-sv.lua", "config.lua" },
    callback = function(args)
      vim.schedule(function()
        local changed = vim.fs.normalize(args.file)
        local roots = {}
        for root, workspace_item in workspace_manager.each() do
          local paths = workspace_item.config.paths
          if util.path_key(changed) == util.path_key(paths.global)
            or util.path_key(changed) == util.path_key(paths.project)
            or util.path_key(changed) == util.path_key(paths.local_config)
          then
            roots[#roots + 1] = root
          end
        end
        for _, root in ipairs(roots) do
          local refreshed = workspace_manager.refresh(root)
          if refreshed.config.valid then
            M.generate(refreshed.root)
          else
            util.notify(table.concat(refreshed.errors, "\n"), vim.log.levels.ERROR)
          end
        end
      end)
    end,
  })
  -- setup() 可能在 FileType 之后执行，补挂载已经打开的 HDL 缓冲区。
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and is_hdl_buffer(bufnr) then
        attach_buffer(bufnr)
      end
    end
  end)
  return M
end

function M.project(root)
  local workspace = workspace_manager.get(root or workspace_manager.root())
  if not workspace.models then
    local built, errors = generate.run(workspace)
    if not built then
      return nil, errors
    end
  end
  return workspace.models[workspace.active_profile].full
end

function M.generate(root)
  local workspace = workspace_manager.get(root or workspace_manager.root())
  if not workspace.config.valid then
    workspace.errors = vim.deepcopy(workspace.config.errors)
    return nil, workspace.errors
  end
  local built, errors = generate.run(workspace)
  if not built then
    return nil, errors
  end
  indexer.build(workspace, built[workspace.active_profile].full)
  require("fpga_sv.adapters.slang").apply_profile(workspace)
  return built
end

function M.switch_profile(profile, root)
  local workspace, err = workspace_manager.switch(profile, root)
  if not workspace then
    return nil, err
  end
  if not workspace.models then
    local built, errors = M.generate(workspace.root)
    if not built then
      return nil, table.concat(errors, "\n")
    end
  end
  workspace.artifacts = workspace.models[profile].artifacts
  local _, activate_err = generate.activate(workspace)
  if activate_err then
    return nil, activate_err
  end
  indexer.build(workspace, workspace.models[profile].full)
  require("fpga_sv.adapters.slang").apply_profile(workspace)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      features.schedule_hints(workspace, bufnr)
    end
  end
  return workspace
end

function M.register_backend(name, backend)
  adapters.register_backend(name, backend)
end

function M.register_installer(name, installer)
  adapters.register_installer(name, installer)
end

function M.statusline(root)
  local workspace = workspace_manager.get(root or workspace_manager.root())
  return "FPGA:" .. workspace.active_profile
end

function M.availability()
  return vim.deepcopy(availability)
end

return M
