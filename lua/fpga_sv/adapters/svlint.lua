local util = require("fpga_sv.util")
local M = {}

local namespace = vim.api.nvim_create_namespace("fpga_sv_svlint")

local function command(options)
  local result = type(options.cmd) == "table" and vim.deepcopy(options.cmd) or { options.cmd }
  vim.list_extend(result, options.args or {})
  return result
end

local function profile_args(workspace, options)
  local model = workspace.models
    and workspace.models[workspace.active_profile]
    and workspace.models[workspace.active_profile].full
  local args = {}
  if not model then
    return args
  end
  for _, dir in ipairs(model.include_dirs or {}) do
    vim.list_extend(args, { options.include_arg, dir })
  end
  local names = vim.tbl_keys(model.defines or {})
  table.sort(names)
  for _, name in ipairs(names) do
    local value = model.defines[name]
    local define = name .. (value == true and "" or "=" .. tostring(value))
    vim.list_extend(args, { options.define_arg, define })
  end
  return args
end

local function parse(output, root)
  local diagnostics, quickfix = {}, {}
  for line in output:gmatch("[^\r\n]+") do
    local file, lnum, col, message = line:match("^%a+%s+(.+):(%d+):(%d+)%s+(.+)$")
    if not file then
      file, lnum, col, message = line:match("^(.+):(%d+):(%d+):%s*(.+)$")
    end
    if file then
      file = util.path(file, root)
      local diagnostic = {
        lnum = math.max(0, tonumber(lnum) - 1),
        col = math.max(0, tonumber(col) - 1),
        message = message,
        severity = vim.diagnostic.severity.WARN,
        source = "svlint",
      }
      local key = util.path_key(file)
      diagnostics[key] = diagnostics[key] or {}
      diagnostics[key][#diagnostics[key] + 1] = diagnostic
      quickfix[#quickfix + 1] = {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = message,
        type = "W",
      }
    end
  end
  return diagnostics, quickfix
end

local function run(workspace, args, callback)
  local options = workspace.config.effective.tools.svlint
  if not util.executable(options.cmd) then
    util.notify("svlint 不可用；请配置 tools.svlint.cmd", vim.log.levels.WARN)
    return
  end
  local cmd = command(options)
  vim.list_extend(cmd, profile_args(workspace, options))
  vim.list_extend(cmd, args)
  local env = vim.fn.environ()
  local model = workspace.models
    and workspace.models[workspace.active_profile]
    and workspace.models[workspace.active_profile].full
  if model and model.lint and model.lint.config then
    env.SVLINT_CONFIG = util.path(model.lint.config, workspace.root)
  end
  vim.system(cmd, { cwd = workspace.root, text = true, env = env }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

function M.current(workspace, bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  run(workspace, { path }, function(result)
    local diagnostics = parse((result.stdout or "") .. "\n" .. (result.stderr or ""), workspace.root)
    vim.diagnostic.set(namespace, bufnr, diagnostics[util.path_key(path)] or {}, {})
    if result.code ~= 0 and not next(diagnostics) then
      util.notify("svlint 执行失败: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end
  end)
end

function M.project(workspace)
  local options = workspace.config.effective.tools.svlint
  local artifacts = workspace.models
    and workspace.models[workspace.active_profile]
    and workspace.models[workspace.active_profile].artifacts
  if not artifacts then
    util.notify("工程尚未生成", vim.log.levels.ERROR)
    return
  end
  run(workspace, { options.filelist_arg, artifacts.local_filelist }, function(result)
    local _, quickfix = parse((result.stdout or "") .. "\n" .. (result.stderr or ""), workspace.root)
    vim.fn.setqflist({}, "r", {
      title = "FpgaSvLintProject [" .. workspace.active_profile .. "]",
      items = quickfix,
    })
    vim.cmd("copen")
  end)
end

return M
