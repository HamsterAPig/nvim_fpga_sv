local util = require("fpga_sv.util")
local M = {}

local source_extensions = {
  sv = true,
  svh = true,
  v = true,
  vh = true,
}

local device_fields = {
  depends_on = true,
  files = true,
  filelists = true,
  roots = true,
  include_dirs = true,
  library_dirs = true,
  library_extensions = true,
  defines = true,
  flags = true,
}

local function add_path(list, seen, path)
  local key = util.path_key(path)
  if not seen[key] then
    seen[key] = true
    list[#list + 1] = path
  end
end

local function resolve_required(value, base, kind, errors)
  local path, optional = util.item(value, base)
  if not path then
    errors[#errors + 1] = kind .. " 项格式无效"
    return nil
  end
  if not util.exists(path) then
    if not optional then
      errors[#errors + 1] = kind .. " 不存在: " .. path
    end
    return nil
  end
  return path
end

local function tokenize(text)
  local tokens, current, quote = {}, {}, nil
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    if quote then
      if ch == quote then
        quote = nil
      elseif ch == "\\" and i < #text then
        i = i + 1
        current[#current + 1] = text:sub(i, i)
      else
        current[#current + 1] = ch
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "/" and text:sub(i, i + 1) == "//" then
      while i <= #text and text:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif ch == "#" and #current == 0 then
      while i <= #text and text:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif ch:match("%s") then
      if #current > 0 then
        tokens[#tokens + 1] = table.concat(current)
        current = {}
      end
    else
      current[#current + 1] = ch
    end
    i = i + 1
  end
  if #current > 0 then
    tokens[#tokens + 1] = table.concat(current)
  end
  return tokens
end

local function parse_define(value)
  local name, definition = value:match("^([^=]+)=(.*)$")
  return name or value, definition or true
end

local function parse_filelist(path, model, visited, errors)
  local key = util.path_key(path)
  if visited[key] == "active" then
    errors[#errors + 1] = "filelist 循环引用: " .. path
    return
  elseif visited[key] then
    return
  end
  visited[key] = "active"
  local text, err = util.read_file(path)
  if not text then
    errors[#errors + 1] = "无法读取 filelist: " .. path .. ": " .. tostring(err)
    visited[key] = true
    return
  end

  local base = vim.fs.dirname(path)
  local tokens = tokenize(text)
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    if token == "-f" or token == "-F" then
      i = i + 1
      local nested = tokens[i] and util.path(tokens[i], base)
      if nested and util.exists(nested) then
        parse_filelist(nested, model, visited, errors)
      else
        errors[#errors + 1] = "嵌套 filelist 不存在: " .. tostring(nested or tokens[i])
      end
    elseif token:match("^%-[fF].+") then
      local nested = util.path(token:sub(3), base)
      if util.exists(nested) then
        parse_filelist(nested, model, visited, errors)
      else
        errors[#errors + 1] = "嵌套 filelist 不存在: " .. nested
      end
    elseif token == "-I" then
      i = i + 1
      if tokens[i] then
        add_path(model.include_dirs, model._seen.include_dirs, util.path(tokens[i], base))
      end
    elseif token:match("^%-I.+") then
      add_path(model.include_dirs, model._seen.include_dirs, util.path(token:sub(3), base))
    elseif token:match("^%+incdir%+") then
      for dir in token:gmatch("%+incdir%+([^+]+)") do
        add_path(model.include_dirs, model._seen.include_dirs, util.path(dir, base))
      end
    elseif token == "-D" then
      i = i + 1
      if tokens[i] then
        local name, value = parse_define(tokens[i])
        model.defines[name] = value
      end
    elseif token:match("^%-D.+") then
      local name, value = parse_define(token:sub(3))
      model.defines[name] = value
    elseif token:match("^%+define%+") then
      for define in token:gmatch("%+define%+([^+]+)") do
        local name, value = parse_define(define)
        model.defines[name] = value
      end
    elseif token == "-y" then
      i = i + 1
      if tokens[i] then
        add_path(model.library_dirs, model._seen.library_dirs, util.path(tokens[i], base))
      end
    elseif token:match("^%-y.+") then
      add_path(model.library_dirs, model._seen.library_dirs, util.path(token:sub(3), base))
    elseif token:match("^%+libext%+") then
      for extension in token:gmatch("%+libext%+([^+]+)") do
        if extension:sub(1, 1) ~= "." then
          extension = "." .. extension
        end
        model.library_extensions[#model.library_extensions + 1] = extension
      end
    elseif token:sub(1, 1) == "-" or token:sub(1, 1) == "+" then
      model.flags[#model.flags + 1] = token
    else
      local file = util.path(token, base)
      if util.exists(file) then
        add_path(model.files, model._seen.files, file)
      else
        errors[#errors + 1] = "filelist 源文件不存在: " .. file
      end
    end
    i = i + 1
  end
  visited[key] = true
end

local function topological_sets(config, profile)
  local result, state, errors = {}, {}, {}
  local requested = profile.source_sets or {}
  if util.is_list_operation(requested) then
    requested = util.merge_list({}, requested)
  end

  local function visit(name, chain)
    if state[name] == "done" then
      return
    end
    if state[name] == "active" then
      errors[#errors + 1] = "Source Set 依赖循环: " .. table.concat(chain, " -> ") .. " -> " .. name
      return
    end
    local set = config.source_sets and config.source_sets[name]
    if not set then
      errors[#errors + 1] = "缺失 Source Set: " .. tostring(name)
      return
    end
    state[name] = "active"
    local next_chain = vim.list_extend(vim.deepcopy(chain), { name })
    for _, dependency in ipairs(set.depends_on or {}) do
      visit(dependency, next_chain)
    end
    state[name] = "done"
    result[#result + 1] = name
  end

  for _, name in ipairs(requested) do
    visit(name, {})
  end
  return result, errors
end

local function excluded(path, root, excludes)
  local relative = util.relative(path, root):gsub("\\", "/")
  for _, value in ipairs(excludes or {}) do
    local pattern = type(value) == "table" and value.path or value
    if pattern then
      pattern = pattern:gsub("\\", "/"):gsub("^%./", "")
      if relative == pattern
        or relative:sub(1, #pattern + 1) == pattern .. "/"
        or relative:match(pattern)
      then
        return true
      end
    end
  end
  return false
end

local function add_defines(target, values)
  values = values or {}
  if vim.islist(values) then
    for _, value in ipairs(values) do
      if type(value) == "string" then
        local name, definition = parse_define(value)
        target[name] = definition
      end
    end
  else
    for name, value in pairs(values or {}) do
      if value ~= false and value ~= nil then
        target[name] = value
      else
        target[name] = nil
      end
    end
  end
end

local function validate_device_entry(id, entry)
  local errors = {}
  if type(entry) ~= "table" or (vim.islist(entry) and next(entry) ~= nil) then
    return nil, { "器件条目 " .. tostring(id) .. " 必须是 table" }
  end
  local function list(field)
    return vim.islist(entry[field]) and entry[field] or {}
  end
  for field in pairs(entry) do
    if not device_fields[field] then
      errors[#errors + 1] = "器件 " .. id .. " 包含不支持的字段: " .. tostring(field)
    end
  end
  for _, field in ipairs({
    "depends_on",
    "files",
    "filelists",
    "roots",
    "include_dirs",
    "library_dirs",
    "library_extensions",
    "flags",
  }) do
    if entry[field] ~= nil and not vim.islist(entry[field]) then
      errors[#errors + 1] = "器件 " .. id .. " 的 " .. field .. " 必须是列表"
    end
  end
  for _, dependency in ipairs(list("depends_on")) do
    if type(dependency) ~= "string" or dependency == "" then
      errors[#errors + 1] = "器件 " .. id .. " 的 depends_on 只能包含非空器件 ID"
    end
  end
  for _, field in ipairs({ "files", "filelists", "roots", "include_dirs", "library_dirs" }) do
    for _, value in ipairs(list(field)) do
      local path = type(value) == "table" and value.path or value
      if type(path) ~= "string" or path == "" then
        errors[#errors + 1] = "器件 " .. id .. " 的 " .. field .. " 包含无效路径"
      elseif not util.is_absolute(path) then
        errors[#errors + 1] = "器件 " .. id .. " 的路径必须是绝对路径: " .. path
      end
    end
  end
  for _, extension in ipairs(list("library_extensions")) do
    if type(extension) ~= "string" or extension:sub(1, 1) ~= "." then
      errors[#errors + 1] = "器件 " .. id .. " 的 library_extensions 必须是带点扩展名"
    end
  end
  for _, flag in ipairs(list("flags")) do
    if type(flag) ~= "string" then
      errors[#errors + 1] = "器件 " .. id .. " 的 flags 只能包含字符串"
    end
  end
  if entry.defines ~= nil and type(entry.defines) ~= "table" then
    errors[#errors + 1] = "器件 " .. id .. " 的 defines 必须是 table"
  elseif vim.islist(entry.defines or {}) then
    for _, define in ipairs(entry.defines or {}) do
      if type(define) ~= "string" then
        errors[#errors + 1] = "器件 " .. id .. " 的 defines 列表只能包含字符串"
      end
    end
  end
  return #errors == 0, errors
end

local function device_order(catalog, requested)
  local entries = catalog.entries
  local order, state, errors = {}, {}, {}
  if type(entries) ~= "table" or (vim.islist(entries) and next(entries) ~= nil) then
    return nil, { "器件目录必须返回以器件 ID 为键的 table" }
  end

  local function visit(id, chain)
    if state[id] == "done" then
      return
    end
    if state[id] == "active" then
      errors[#errors + 1] = "器件依赖循环: " .. table.concat(chain, " -> ") .. " -> " .. id
      return
    end
    local entry = entries[id]
    if entry == nil then
      errors[#errors + 1] = (#chain == 0 and "缺失器件: " or "缺失器件依赖: ")
        .. tostring(id)
      return
    end
    local valid, validation_errors = validate_device_entry(id, entry)
    if not valid then
      vim.list_extend(errors, validation_errors)
      return
    end
    state[id] = "active"
    local next_chain = vim.list_extend(vim.deepcopy(chain), { id })
    for _, dependency in ipairs(entry.depends_on or {}) do
      visit(dependency, next_chain)
    end
    state[id] = "done"
    order[#order + 1] = id
  end

  visit(requested, {})
  if #errors > 0 then
    return nil, errors
  end
  return order
end

function M.validate_device_catalog(entries)
  local errors = {}
  if type(entries) ~= "table" or (vim.islist(entries) and next(entries) ~= nil) then
    return false, { "器件目录必须返回以器件 ID 为键的 table" }
  end
  for id, entry in pairs(entries) do
    if type(id) ~= "string" or id == "" then
      errors[#errors + 1] = "器件 ID 必须是非空字符串: " .. tostring(id)
    else
      local valid, entry_errors = validate_device_entry(id, entry)
      if not valid then
        vim.list_extend(errors, entry_errors)
      end
    end
  end
  return #errors == 0, errors
end

local function remove_replaced(model, replacements, root)
  local remove = {}
  for _, value in ipairs(replacements or {}) do
    local path = type(value) == "table" and value.path or value
    if path then
      remove[util.path_key(util.path(path, root))] = true
    end
  end
  if not next(remove) then
    return
  end
  local kept = {}
  for _, file in ipairs(model.files) do
    if not remove[util.path_key(file)] then
      kept[#kept + 1] = file
    else
      model._seen.files[util.path_key(file)] = nil
    end
  end
  model.files = kept
end

local function empty_model(root, name, profile)
  return {
    root = root,
    profile = name,
    top = profile.top,
    lint = vim.deepcopy(profile.lint or {}),
    files = {},
    include_dirs = {},
    defines = {},
    library_dirs = {},
    library_extensions = {},
    flags = {},
    source_sets = {},
    warnings = {},
    device = {
      id = profile.device,
      status = profile.device and "skipped" or "not_configured",
      order = {},
      warnings = {},
    },
    _seen = {
      files = {},
      include_dirs = {},
      library_dirs = {},
    },
  }
end

local function resolve_device_path(value, kind, errors)
  local raw = type(value) == "table" and value.path or value
  if type(raw) ~= "string" or not util.is_absolute(raw) then
    errors[#errors + 1] = kind .. " 必须是绝对路径: " .. tostring(raw)
    return nil
  end
  local path = util.path(raw)
  if not util.exists(path) then
    errors[#errors + 1] = kind .. " 不存在: " .. path
    return nil
  end
  return path
end

local function collect_device_entry(model, id, entry, errors)
  for _, value in ipairs(entry.files or {}) do
    local path = resolve_device_path(value, "器件 " .. id .. " 源文件", errors)
    if path then
      add_path(model.files, model._seen.files, path)
    end
  end
  for _, value in ipairs(entry.roots or {}) do
    local scan_root = resolve_device_path(value, "器件 " .. id .. " 源码目录", errors)
    if scan_root then
      local matched = {}
      for _, glob in ipairs({
        "*.sv",
        "*.svh",
        "*.v",
        "*.vh",
        "**/*.sv",
        "**/*.svh",
        "**/*.v",
        "**/*.vh",
      }) do
        vim.list_extend(matched, vim.fn.globpath(scan_root, glob, true, true))
      end
      table.sort(matched)
      for _, path in ipairs(matched) do
        path = vim.fs.normalize(path)
        local stat = (vim.uv or vim.loop).fs_stat(path)
        local extension = path:match("%.([^./\\]+)$")
        if stat and stat.type == "file" and source_extensions[extension] then
          add_path(model.files, model._seen.files, path)
        end
      end
    end
  end
  for _, value in ipairs(entry.filelists or {}) do
    local path = resolve_device_path(value, "器件 " .. id .. " filelist", errors)
    if path then
      parse_filelist(path, model, {}, errors)
    end
  end
  for _, value in ipairs(entry.include_dirs or {}) do
    local path = resolve_device_path(value, "器件 " .. id .. " Include 目录", errors)
    if path then
      add_path(model.include_dirs, model._seen.include_dirs, path)
    end
  end
  for _, value in ipairs(entry.library_dirs or {}) do
    local path = resolve_device_path(value, "器件 " .. id .. " 库目录", errors)
    if path then
      add_path(model.library_dirs, model._seen.library_dirs, path)
    end
  end
  add_defines(model.defines, entry.defines)
  vim.list_extend(model.library_extensions, entry.library_extensions or {})
  vim.list_extend(model.flags, entry.flags or {})
end

local function merge_model(target, source)
  for _, field in ipairs({ "files", "include_dirs", "library_dirs" }) do
    for _, path in ipairs(source[field] or {}) do
      add_path(target[field], target._seen[field], path)
    end
  end
  for name, value in pairs(source.defines or {}) do
    target.defines[name] = value
  end
  vim.list_extend(target.library_extensions, source.library_extensions or {})
  vim.list_extend(target.flags, source.flags or {})
end

local function build_device(root, profile_name, device_id, catalog)
  local info = {
    id = device_id,
    catalog_path = catalog and catalog.path or nil,
    status = device_id and "skipped" or "not_configured",
    order = {},
    warnings = {},
  }
  if not device_id then
    return nil, info
  end

  local errors = {}
  if not catalog or catalog.valid == false then
    vim.list_extend(errors, catalog and catalog.errors or { "器件目录不可用" })
  else
    local order, order_errors = device_order(catalog, device_id)
    if not order then
      vim.list_extend(errors, order_errors)
    else
      info.order = order
      local device_model = empty_model(root, profile_name, {})
      for _, id in ipairs(order) do
        collect_device_entry(device_model, id, catalog.entries[id], errors)
      end
      for _, field in ipairs({ "files", "include_dirs", "library_dirs" }) do
        for _, path in ipairs(device_model[field]) do
          if not util.exists(path) then
            errors[#errors + 1] = "器件 " .. device_id .. " 的 " .. field
              .. " 路径不存在: " .. path
          end
        end
      end
      if #errors == 0 then
        device_model.library_extensions = util.unique(device_model.library_extensions)
        device_model.flags = util.unique(device_model.flags)
        info.status = "loaded"
        info.model = device_model
        return device_model, info
      end
    end
  end

  local prefix = "器件 " .. tostring(device_id)
    .. " 加载失败，已原子跳过整套器件模型；Slang 可能报告 unknown module: "
  for _, err in ipairs(errors) do
    info.warnings[#info.warnings + 1] = prefix .. tostring(err)
  end
  return nil, info
end

function M.build(root, config, profile_name, device_catalog)
  local profile = config.profiles and config.profiles[profile_name]
  if not profile then
    return nil, { "未知 Profile: " .. tostring(profile_name) }
  end
  local order, errors = topological_sets(config, profile)
  local model = empty_model(root, profile_name, profile)
  if device_catalog ~= nil then
    local device_model, device_info = build_device(
      root,
      profile_name,
      profile.device,
      device_catalog
    )
    model.device = device_info
    vim.list_extend(model.warnings, device_info.warnings)
    if device_model then
      merge_model(model, device_model)
    end
  end

  for _, set_name in ipairs(order) do
    local set = config.source_sets[set_name]
    set.files = set.files or {}
    model.source_sets[#model.source_sets + 1] = set_name
    remove_replaced(model, set.replaces, root)

    for _, value in ipairs(set.files or {}) do
      local path = resolve_required(value, root, "源文件", errors)
      if path then
        add_path(model.files, model._seen.files, path)
      end
    end

    local roots = set.roots or {}
    for _, root_value in ipairs(roots) do
      local scan_root = resolve_required(root_value, root, "源码目录", errors)
      if scan_root then
        local globs = set.globs or { "**/*.sv", "**/*.svh", "**/*.v", "**/*.vh" }
        for _, glob in ipairs(globs) do
          for _, path in ipairs(vim.fn.globpath(scan_root, glob, true, true)) do
            path = vim.fs.normalize(path)
            local stat = (vim.uv or vim.loop).fs_stat(path)
            local extension = path:match("%.([^./\\]+)$")
            if stat and stat.type == "file" and source_extensions[extension] and not excluded(path, root, set.exclude) then
              add_path(model.files, model._seen.files, path)
            end
          end
        end
      end
    end

    for _, value in ipairs(set.filelists or {}) do
      local filelist = resolve_required(value, root, "filelist", errors)
      if filelist then
        parse_filelist(filelist, model, {}, errors)
      end
    end
    for _, value in ipairs(set.include_dirs or {}) do
      local path = resolve_required(value, root, "Include 目录", errors)
      if path then
        add_path(model.include_dirs, model._seen.include_dirs, path)
      end
    end
    for _, value in ipairs(set.library_dirs or {}) do
      local path = resolve_required(value, root, "库目录", errors)
      if path then
        add_path(model.library_dirs, model._seen.library_dirs, path)
      end
    end
    add_defines(model.defines, set.defines)
    vim.list_extend(model.library_extensions, set.library_extensions or {})
    vim.list_extend(model.flags, set.flags or {})
  end

  for _, value in ipairs(profile.include_dirs or {}) do
    local path = resolve_required(value, root, "Profile Include 目录", errors)
    if path then
      add_path(model.include_dirs, model._seen.include_dirs, path)
    end
  end
  add_defines(model.defines, profile.defines)
  vim.list_extend(model.flags, profile.flags or {})
  model.library_extensions = util.unique(model.library_extensions)
  model.flags = util.unique(model.flags)
  if model.device and model.device.model then
    model.device.model._seen = nil
  end
  model._seen = nil

  if #errors > 0 then
    return nil, errors
  end
  return model
end

function M.empty(root, profile_name)
  return empty_model(root, profile_name, {})
end

function M.scan_async(workspace, callback)
  workspace.scan_generation = workspace.scan_generation + 1
  local generation = workspace.scan_generation
  local config = vim.deepcopy(workspace.config.effective)
  local profile = config.profiles[workspace.active_profile]
  local order, errors = topological_sets(config, profile)
  local jobs = {}

  for _, set_name in ipairs(order) do
    local set = config.source_sets[set_name]
    set.files = set.files or {}
    for _, root_value in ipairs(set.roots or {}) do
      local scan_root = resolve_required(root_value, workspace.root, "源码目录", errors)
      if scan_root then
        jobs[#jobs + 1] = {
          set = set,
          root = scan_root,
          queue = { scan_root },
          globs = set.globs or { "**/*.sv", "**/*.svh", "**/*.v", "**/*.vh" },
        }
      end
    end
    set.roots = {}
  end
  if #errors > 0 then
    vim.schedule(function()
      if workspace.scan_generation == generation then
        callback(nil, errors)
      end
    end)
    return generation
  end

  local batch_size = math.max(1, workspace.config.effective.scan.batch_size or 200)
  local coroutine_handle
  coroutine_handle = coroutine.create(function()
    local processed = 0
    for _, job in ipairs(jobs) do
      local matched = {}
      local regexes = {}
      for _, glob in ipairs(job.globs) do
        local ok, regex = pcall(vim.regex, vim.fn.glob2regpat(glob))
        if ok then
          regexes[#regexes + 1] = regex
        end
      end
      while #job.queue > 0 do
        if workspace.scan_generation ~= generation then
          return
        end
        local directory = table.remove(job.queue, 1)
        local handle = (vim.uv or vim.loop).fs_scandir(directory)
        local entries = {}
        if handle then
          while true do
            local name, kind = (vim.uv or vim.loop).fs_scandir_next(handle)
            if not name then
              break
            end
            entries[#entries + 1] = { name = name, kind = kind }
          end
        end
        table.sort(entries, function(a, b)
          return a.name < b.name
        end)
        for _, entry in ipairs(entries) do
          local path = vim.fs.joinpath(directory, entry.name)
          if entry.kind == "directory" then
            if not excluded(path, workspace.root, job.set.exclude) then
              job.queue[#job.queue + 1] = path
            end
          elseif entry.kind == "file" and not excluded(path, workspace.root, job.set.exclude) then
            local relative = util.relative(path, job.root):gsub("\\", "/")
            for _, regex in ipairs(regexes) do
              if regex:match_str(relative) then
                matched[#matched + 1] = path
                break
              end
            end
          end
          processed = processed + 1
          if processed % batch_size == 0 then
            coroutine.yield()
          end
        end
      end
      table.sort(matched)
      vim.list_extend(job.set.files, matched)
    end
    local model, build_errors = M.build(
      workspace.root,
      config,
      workspace.active_profile,
      workspace.config.device_catalog
    )
    if workspace.scan_generation == generation then
      callback(model, build_errors)
    end
  end)

  local function resume()
    if workspace.scan_generation ~= generation
      or coroutine.status(coroutine_handle) == "dead"
    then
      return
    end
    local ok, err = coroutine.resume(coroutine_handle)
    if not ok then
      callback(nil, { tostring(err) })
      return
    end
    if coroutine.status(coroutine_handle) ~= "dead" then
      vim.schedule(resume)
    end
  end
  vim.schedule(resume)
  return generation
end

return M
