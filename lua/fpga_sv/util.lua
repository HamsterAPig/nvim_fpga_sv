local uv = vim.uv or vim.loop
local M = {}

local function value_key(value)
  if type(value) == "table" then
    if value.path then
      return "path:" .. vim.fs.normalize(tostring(value.path)):gsub("\\", "/")
    end
    local ok, encoded = pcall(vim.json.encode, value)
    return ok and encoded or tostring(value)
  end
  if type(value) == "string" then
    return "string:" .. vim.fs.normalize(value):gsub("\\", "/")
  end
  return type(value) .. ":" .. tostring(value)
end

function M.deepcopy(value)
  return vim.deepcopy(value)
end

function M.is_list_operation(value)
  return type(value) == "table"
    and not vim.islist(value)
    and (value.add ~= nil or value.remove ~= nil or value.replace ~= nil)
end

function M.merge_list(base, overlay)
  local result = {}
  local seen = {}

  local function append(values)
    for _, value in ipairs(values or {}) do
      local key = value_key(value)
      if not seen[key] then
        seen[key] = true
        result[#result + 1] = M.deepcopy(value)
      end
    end
  end

  if M.is_list_operation(overlay) then
    append(overlay.replace or base or {})
    local removed = {}
    for _, value in ipairs(overlay.remove or {}) do
      removed[value_key(value)] = true
    end
    if next(removed) then
      local kept = {}
      for _, value in ipairs(result) do
        if not removed[value_key(value)] then
          kept[#kept + 1] = value
        end
      end
      result = kept
      seen = {}
      for _, value in ipairs(result) do
        seen[value_key(value)] = true
      end
    end
    append(overlay.add or {})
    return result
  end

  append(base or {})
  append(overlay or {})
  return result
end

function M.merge(base, overlay)
  if overlay == nil then
    return M.deepcopy(base)
  end
  if base == nil then
    return M.deepcopy(overlay)
  end
  local overlay_is_list = vim.islist(overlay)
    and (next(overlay) ~= nil or vim.islist(base))
  if overlay_is_list or M.is_list_operation(overlay) then
    return M.merge_list(vim.islist(base) and base or {}, overlay)
  end
  if type(base) ~= "table" or type(overlay) ~= "table" then
    return M.deepcopy(overlay)
  end

  local result = M.deepcopy(base)
  for key, value in pairs(overlay) do
    result[key] = M.merge(result[key], value)
  end
  return result
end

function M.merge_many(...)
  local result
  for i = 1, select("#", ...) do
    result = M.merge(result, select(i, ...))
  end
  return result or {}
end

function M.path(value, base)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  value = vim.fn.expand(value)
  local absolute = value:match("^/") ~= nil
    or value:match("^%a:[/\\]") ~= nil
    or value:match("^[/\\][/\\]") ~= nil
  if not absolute then
    value = vim.fs.joinpath(base or uv.cwd(), value)
  end
  return vim.fs.normalize(value)
end

function M.is_absolute(path)
  return type(path) == "string"
    and (
      path:match("^/") ~= nil
      or path:match("^%a:[/\\]") ~= nil
      or path:match("^[/\\][/\\]") ~= nil
    )
end

function M.path_key(path)
  path = vim.fs.normalize(path)
  return jit and jit.os == "Windows" and path:lower() or path
end

function M.relative(path, base)
  path = vim.fs.normalize(path)
  base = vim.fs.normalize(base)
  if vim.fs.relpath then
    local relative = vim.fs.relpath(base, path)
    if relative then
      return relative
    end
  end
  local key_path = M.path_key(path)
  local key_base = M.path_key(base)
  if key_path == key_base then
    return "."
  end
  local path_parts = vim.split(path:gsub("\\", "/"), "/", { plain = true, trimempty = true })
  local base_parts = vim.split(base:gsub("\\", "/"), "/", { plain = true, trimempty = true })
  local common = 0
  while path_parts[common + 1]
    and base_parts[common + 1]
    and M.path_key(path_parts[common + 1]) == M.path_key(base_parts[common + 1])
  do
    common = common + 1
  end
  local same_unix_root = path:sub(1, 1) == "/" and base:sub(1, 1) == "/"
  if common > 0 or same_unix_root then
    local relative = {}
    for _ = common + 1, #base_parts do
      relative[#relative + 1] = ".."
    end
    for i = common + 1, #path_parts do
      relative[#relative + 1] = path_parts[i]
    end
    return #relative > 0 and table.concat(relative, "/") or "."
  end
  return path
end

function M.item(value, base)
  if type(value) == "string" then
    return M.path(value, base), false
  end
  if type(value) == "table" and type(value.path) == "string" then
    return M.path(value.path, base), value.optional == true
  end
  return nil, false
end

function M.exists(path)
  return path and uv.fs_stat(path) ~= nil
end

function M.read_file(path)
  local fd, err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err
  end
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

function M.mkdir(path)
  vim.fn.mkdir(path, "p")
end

function M.atomic_write(path, content)
  M.mkdir(vim.fs.dirname(path))
  local tmp = path .. ".tmp." .. tostring(uv.hrtime())
  local fd, err = uv.fs_open(tmp, "w", 420)
  if not fd then
    return nil, err
  end
  local ok, write_err = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  if not ok then
    pcall(uv.fs_unlink, tmp)
    return nil, write_err
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    -- Windows 不允许直接覆盖目标，先删除插件拥有的旧临时产物。
    pcall(uv.fs_unlink, path)
    renamed, rename_err = uv.fs_rename(tmp, path)
  end
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return nil, rename_err
  end
  return true
end

function M.hash(value)
  return vim.fn.sha256(type(value) == "string" and value or vim.json.encode(value))
end

function M.root_hash(root)
  return M.hash(vim.fs.normalize(root)):sub(1, 16)
end

function M.unique(values, key_fn)
  local result, seen = {}, {}
  for _, value in ipairs(values or {}) do
    local key = key_fn and key_fn(value) or value_key(value)
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = value
    end
  end
  return result
end

function M.emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "fpga_sv" })
end

function M.executable(cmd)
  if type(cmd) == "table" then
    cmd = cmd[1]
  end
  return type(cmd) == "string" and vim.fn.executable(cmd) == 1
end

return M
