local config_loader = require("fpga_sv.config")
local features = require("fpga_sv.features")
local generate = require("fpga_sv.generate")
local indexer = require("fpga_sv.index")
local util = require("fpga_sv.util")
local workspace_manager = require("fpga_sv.workspace")
local M = {}

local function current()
  return workspace_manager.current()
end

local function complete_profiles()
  return vim.tbl_keys(current().config.effective.profiles)
end

local function complete_templates()
  return vim.tbl_keys(features.snippets)
end

local function ensure_generated(workspace)
  if workspace.models then
    return true
  end
  if not workspace.config.valid then
    util.notify(table.concat(workspace.config.errors, "\n"), vim.log.levels.ERROR)
    return false
  end
  local result, errors = generate.run(workspace)
  if not result then
    util.notify(table.concat(errors, "\n"), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function open_info(workspace)
  local lines = {
    "fpga_sv 工程信息",
    string.rep("=", 60),
    "Root: " .. workspace.root,
    "Profile: " .. workspace.active_profile,
    "Generation: " .. workspace.generation,
    "",
    "配置文件:",
    "  global:  " .. workspace.config.paths.global,
    "  devices: " .. workspace.config.paths.device_catalog,
    "  project: " .. workspace.config.paths.project,
    "  local:   " .. workspace.config.paths.local_config,
    "",
  }
  if #workspace.errors > 0 then
    lines[#lines + 1] = "错误:"
    for _, err in ipairs(workspace.errors) do
      lines[#lines + 1] = "  - " .. err
    end
    lines[#lines + 1] = ""
  end
  if #(workspace.config.warnings or {}) > 0 then
    lines[#lines + 1] = "警告:"
    for _, warning in ipairs(workspace.config.warnings) do
      lines[#lines + 1] = "  - " .. warning
    end
    lines[#lines + 1] = ""
  end
  local entry = workspace.models and workspace.models[workspace.active_profile]
  if entry then
    local model = entry.full
    local device = model.device or {}
    local status_names = {
      loaded = "已加载",
      skipped = "已跳过",
      not_configured = "未配置",
    }
    vim.list_extend(lines, {
      "器件模型:",
      "  id: " .. tostring(device.id or "<未配置>"),
      "  status: " .. tostring(status_names[device.status] or device.status),
      "  dependencies: " .. (#(device.order or {}) > 0 and table.concat(device.order, " -> ") or "<无>"),
      "  catalog: " .. tostring(device.catalog_path or workspace.config.paths.device_catalog),
    })
    for _, warning in ipairs(device.warnings or {}) do
      lines[#lines + 1] = "  warning: " .. warning
    end
    lines[#lines + 1] = "  matched module_files:"
    if #(device.module_files or {}) == 0 then
      lines[#lines + 1] = "    <无>"
    else
      for _, mapping in ipairs(device.module_files) do
        lines[#lines + 1] = "    " .. mapping.module .. " -> " .. mapping.path
          .. " (" .. mapping.device .. ")"
      end
    end
    lines[#lines + 1] = "  module_files overrides:"
    if #(device.module_file_overrides or {}) == 0 then
      lines[#lines + 1] = "    <无>"
    else
      for _, override in ipairs(device.module_file_overrides) do
        lines[#lines + 1] = "    " .. override.module .. ": "
          .. override.previous_device .. " (" .. override.previous_path .. ")"
          .. " -> " .. override.device .. " (" .. override.path .. ")"
      end
    end
    lines[#lines + 1] = "  matched library files:"
    if #(model.library_files or {}) == 0 then
      lines[#lines + 1] = "    <无>"
    else
      for _, matched in ipairs(model.library_files) do
        local source = matched.device
          and ("device: " .. matched.device)
          or "project"
        lines[#lines + 1] = "    " .. matched.module .. " -> "
          .. matched.path .. " [" .. matched.library_dir .. "]"
          .. " (" .. source .. ")"
      end
    end
    vim.list_extend(lines, {
      "",
      "工程模型:",
      "  top: " .. tostring(model.top or "<未设置>"),
      "  files: " .. #model.files,
      "  include_dirs: " .. #model.include_dirs,
      "  defines: " .. vim.tbl_count(model.defines),
      "  source_sets: " .. table.concat(model.source_sets, ", "),
      "",
      "生成产物:",
      "  project .f: " .. entry.artifacts.project_filelist,
      "  local .f:   " .. entry.artifacts.local_filelist,
      "  Slang JSON: " .. entry.artifacts.local_slang,
    })
  else
    local profile = workspace.config.effective.profiles[workspace.active_profile] or {}
    vim.list_extend(lines, {
      "器件模型:",
      "  id: " .. tostring(profile.device or "<未配置>"),
      "  status: 尚未生成",
      "  dependencies: <尚未展开>",
      "  catalog: " .. workspace.config.paths.device_catalog,
      "",
    })
    lines[#lines + 1] = "工程尚未生成。"
  end
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "fpga_sv_info"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function edit_template(path, ensure)
  local created, err = ensure(path)
  if not created then
    util.notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(created))
end

function M.setup()
  vim.api.nvim_create_user_command("FpgaSvProfile", function(args)
    local workspace = current()
    local profile = args.args
    if profile == "" then
      vim.ui.select(complete_profiles(), { prompt = "选择 FPGA Profile" }, function(choice)
        if choice then
          require("fpga_sv").switch_profile(choice)
        end
      end)
    else
      require("fpga_sv").switch_profile(profile)
    end
  end, { nargs = "?", complete = complete_profiles })

  vim.api.nvim_create_user_command("FpgaSvGenerate", function()
    require("fpga_sv").generate()
  end, {})

  vim.api.nvim_create_user_command("FpgaSvProjectInfo", function()
    open_info(current())
  end, {})

  vim.api.nvim_create_user_command("FpgaSvDefinition", function()
    local workspace = current()
    require("fpga_sv.adapters.slang").definition(
      workspace,
      vim.api.nvim_get_current_buf()
    )
  end, {})

  vim.api.nvim_create_user_command("FpgaSvEditGlobalConfig", function()
    local workspace = current()
    edit_template(workspace.config.paths.global, config_loader.ensure_global_template)
  end, {})

  vim.api.nvim_create_user_command("FpgaSvEditDeviceCatalog", function()
    local workspace = current()
    edit_template(
      workspace.config.paths.device_catalog,
      config_loader.ensure_device_catalog_template
    )
  end, {})

  vim.api.nvim_create_user_command("FpgaSvEditProjectConfig", function()
    local workspace = current()
    edit_template(workspace.config.paths.project, config_loader.ensure_project_template)
  end, {})

  vim.api.nvim_create_user_command("FpgaSvEditLocalConfig", function()
    local workspace = current()
    local path, err = config_loader.ensure_local_template(
      workspace.root,
      workspace.config.effective
    )
    if not path then
      util.notify(tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
  end, {})

  vim.api.nvim_create_user_command("FpgaSvInstantiate", function(args)
    local workspace = current()
    if ensure_generated(workspace) then
      indexer.build(workspace, workspace.models[workspace.active_profile].full)
      features.instantiate(workspace, args.args)
    end
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("FpgaSvExpand", function()
    local workspace = current()
    if ensure_generated(workspace) then
      indexer.build(workspace, workspace.models[workspace.active_profile].full)
      features.expand_instance(workspace)
    end
  end, {})

  vim.api.nvim_create_user_command("FpgaSvHints", function()
    local enabled = features.toggle_hints(current())
    util.notify("端口提示已" .. (enabled and "启用" or "关闭"))
  end, {})

  vim.api.nvim_create_user_command("FpgaSvRefresh", function()
    local workspace = workspace_manager.refresh()
    if workspace.config.valid then
      require("fpga_sv").generate(workspace.root)
    else
      util.notify(table.concat(workspace.errors, "\n"), vim.log.levels.ERROR)
    end
  end, {})

  vim.api.nvim_create_user_command("FpgaSvTop", function(args)
    local workspace = current()
    if ensure_generated(workspace) then
      local top = args.args ~= "" and args.args
        or workspace.models[workspace.active_profile].full.top
      if top then
        require("fpga_sv.adapters.slang").set_top(workspace, top)
      else
        util.notify("活动 Profile 未设置 top", vim.log.levels.WARN)
      end
    end
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("FpgaSvLint", function()
    local workspace = current()
    if ensure_generated(workspace) then
      require("fpga_sv.adapters.svlint").current(workspace, 0)
    end
  end, {})

  vim.api.nvim_create_user_command("FpgaSvLintProject", function()
    local workspace = current()
    if ensure_generated(workspace) then
      require("fpga_sv.adapters.svlint").project(workspace)
    end
  end, {})

  vim.api.nvim_create_user_command("FpgaSvTemplate", function(args)
    features.template(args.args)
  end, { nargs = 1, complete = complete_templates })

  vim.api.nvim_create_user_command("FpgaSvNext", function(args)
    features.navigate(current(), 1, args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("FpgaSvPrev", function(args)
    features.navigate(current(), -1, args.args ~= "" and args.args or nil)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("FpgaSvSelect", function(args)
    features.select_object(current(), args.args)
  end, {
    nargs = 1,
    complete = function()
      return {
        "module",
        "interface",
        "package",
        "class",
        "function",
        "task",
        "sequence",
        "property",
        "covergroup",
      }
    end,
  })

  -- 兼容旧命令名称。
  vim.api.nvim_create_user_command("SVInstantiate", "FpgaSvInstantiate <args>", { nargs = "?" })
  vim.api.nvim_create_user_command("SVProjectInfo", "FpgaSvProjectInfo", {})
  vim.api.nvim_create_user_command("SVSlangSetBuild", function(args)
    local workspace = current()
    local path = args.args
    if path == "" and ensure_generated(workspace) then
      path = workspace.models[workspace.active_profile].artifacts.local_filelist
    end
    if path ~= "" then
      require("fpga_sv.adapters.slang").set_build(workspace, path)
    end
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("SVSlangSetTop", "FpgaSvTop <args>", { nargs = "?" })
  vim.api.nvim_create_user_command("SVPortDirectionsToggle", "FpgaSvHints", {})
end

function M.setup_buffer(workspace, bufnr)
  local maps = workspace.config.effective.keymaps
  local definitions = {
    definition = { "<cmd>FpgaSvDefinition<cr>", "FPGA: 跳转到定义" },
    profile = { "<cmd>FpgaSvProfile<cr>", "FPGA: 切换 Profile" },
    generate = { "<cmd>FpgaSvGenerate<cr>", "FPGA: 生成工程" },
    instantiate = { "<cmd>FpgaSvInstantiate<cr>", "FPGA: 新建例化" },
    expand = { "<cmd>FpgaSvExpand<cr>", "FPGA: 展开连接" },
    refresh = { "<cmd>FpgaSvRefresh<cr>", "FPGA: 刷新工程" },
    hints = { "<cmd>FpgaSvHints<cr>", "FPGA: 端口提示" },
    lint = { "<cmd>FpgaSvLint<cr>", "FPGA: lint 当前文件" },
  }
  for name, mapping in pairs(maps) do
    if mapping and definitions[name] then
      local exists = name == "definition"
        and vim.api.nvim_buf_call(bufnr, function()
          local current_mapping = vim.fn.maparg(mapping, "n", false, true)
          return type(current_mapping) == "table" and next(current_mapping) ~= nil
        end)
      if not exists then
        vim.keymap.set("n", mapping, definitions[name][1], {
          buffer = bufnr,
          silent = true,
          desc = definitions[name][2],
        })
      end
    end
  end
end

return M
