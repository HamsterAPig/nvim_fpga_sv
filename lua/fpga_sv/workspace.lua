local config_loader = require("fpga_sv.config")
local util = require("fpga_sv.util")
local M = {}

local workspaces = {}
local setup_options = {}
local state_cache = {}

local function state_path(options)
  return vim.fs.joinpath(options.state_dir, "profiles.json")
end

local function read_state(options)
  local path = state_path(options)
  if state_cache[path] then
    return state_cache[path]
  end
  local text = util.read_file(path)
  if not text then
    state_cache[path] = {}
    return state_cache[path]
  end
  local ok, value = pcall(vim.json.decode, text)
  state_cache[path] = ok and type(value) == "table" and value or {}
  return state_cache[path]
end

local function write_state(options)
  local path = state_path(options)
  util.atomic_write(path, vim.json.encode(state_cache[path] or {}))
end

function M.setup(options)
  setup_options = options or {}
end

function M.root(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and vim.fs.dirname(name) or (vim.uv or vim.loop).cwd()
  return vim.fs.root(start, { ".nvim-fpga.lua", ".git" }) or vim.fs.normalize(start)
end

function M.get(root)
  root = vim.fs.normalize(root or M.root())
  local current = workspaces[root]
  if current then
    return current
  end
  local loaded = config_loader.load(root, setup_options)
  local profiles = read_state(loaded.effective)
  local active = profiles[util.path_key(root)] or loaded.effective.default_profile
  if not loaded.effective.profiles[active] then
    active = loaded.effective.default_profile
  end
  current = {
    root = root,
    config = loaded,
    active_profile = active,
    generation = 0,
    scan_generation = 0,
    errors = vim.deepcopy(loaded.errors),
    warnings = vim.deepcopy(loaded.warnings),
    artifacts = {},
    index = nil,
  }
  workspaces[root] = current
  return current
end

function M.current()
  return M.get(M.root())
end

function M.refresh(root)
  root = vim.fs.normalize(root or M.root())
  local old = workspaces[root]
  workspaces[root] = nil
  local current = M.get(root)
  if old and current.config.effective.profiles[old.active_profile] then
    current.active_profile = old.active_profile
  end
  return current
end

function M.switch(profile, root)
  local workspace = M.get(root or M.root())
  if not workspace.config.effective.profiles[profile] then
    return nil, "未知 Profile: " .. tostring(profile)
  end
  workspace.active_profile = profile
  local profiles = read_state(workspace.config.effective)
  profiles[util.path_key(workspace.root)] = profile
  write_state(workspace.config.effective)
  util.emit("FpgaSvProfileChanged", {
    root = workspace.root,
    profile = profile,
  })
  return workspace
end

function M.each()
  return pairs(workspaces)
end

function M.config_change_roots(path)
  local changed = util.path_key(vim.fs.normalize(path))
  local loaded = {}
  local refresh_all = false
  for root, workspace in pairs(workspaces) do
    loaded[#loaded + 1] = { root = root, paths = workspace.config.paths }
    if changed == util.path_key(workspace.config.paths.global)
      or changed == util.path_key(workspace.config.paths.device_catalog)
    then
      refresh_all = true
    end
  end
  local roots = {}
  for _, item in ipairs(loaded) do
    if refresh_all
      or changed == util.path_key(item.paths.project)
      or changed == util.path_key(item.paths.local_config)
    then
      roots[#roots + 1] = item.root
    end
  end
  table.sort(roots)
  return roots
end

return M
