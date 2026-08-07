local util = require("fpga_sv.util")
local M = {}

local source_extensions = {
  sv = true,
  svh = true,
  v = true,
  vh = true,
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
    _seen = {
      files = {},
      include_dirs = {},
      library_dirs = {},
    },
  }
end

function M.build(root, config, profile_name)
  local profile = config.profiles and config.profiles[profile_name]
  if not profile then
    return nil, { "未知 Profile: " .. tostring(profile_name) }
  end
  local order, errors = topological_sets(config, profile)
  local model = empty_model(root, profile_name, profile)

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
      workspace.active_profile
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
