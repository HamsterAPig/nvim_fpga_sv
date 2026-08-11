local util = require("fpga_sv.util")
local M = {}
local CACHE_VERSION = 1

local function line_number(text, offset)
  local _, count = text:sub(1, offset):gsub("\n", "\n")
  return count + 1
end

local function mask_ignored(text)
  local result = {}
  local state = "code"
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    local pair = text:sub(i, i + 1)
    if state == "line_comment" then
      if ch == "\n" then
        state = "code"
        result[#result + 1] = ch
      else
        result[#result + 1] = " "
      end
    elseif state == "block_comment" then
      if pair == "*/" then
        result[#result + 1] = " "
        result[#result + 1] = " "
        state = "code"
        i = i + 1
      elseif ch == "\n" then
        result[#result + 1] = ch
      else
        result[#result + 1] = " "
      end
    elseif state == "string" then
      if ch == "\\" and i < #text then
        result[#result + 1] = " "
        result[#result + 1] = " "
        i = i + 1
      elseif ch == '"' then
        result[#result + 1] = ch
        state = "code"
      elseif ch == "\n" then
        result[#result + 1] = ch
      else
        result[#result + 1] = " "
      end
    elseif pair == "//" then
      result[#result + 1] = " "
      result[#result + 1] = " "
      state = "line_comment"
      i = i + 1
    elseif pair == "/*" then
      result[#result + 1] = " "
      result[#result + 1] = " "
      state = "block_comment"
      i = i + 1
    elseif ch == '"' then
      result[#result + 1] = ch
      state = "string"
    else
      result[#result + 1] = ch
    end
    i = i + 1
  end
  return table.concat(result)
end

local function strip_comments(text)
  local masked = mask_ignored(text)
  local result = {}
  local in_string = false
  for i = 1, #text do
    local original = text:sub(i, i)
    local mask = masked:sub(i, i)
    if original == '"' and mask == '"' then
      in_string = not in_string
      result[#result + 1] = original
    elseif in_string or mask ~= " " or original:match("%s") then
      result[#result + 1] = original
    else
      result[#result + 1] = " "
    end
  end
  return table.concat(result)
end

local function split_top_level(text)
  local result = {}
  local masked = mask_ignored(text)
  local round, square, curly = 0, 0, 0
  local start = 1
  for i = 1, #masked do
    local ch = masked:sub(i, i)
    if ch == "(" then
      round = round + 1
    elseif ch == ")" then
      round = round - 1
    elseif ch == "[" then
      square = square + 1
    elseif ch == "]" then
      square = square - 1
    elseif ch == "{" then
      curly = curly + 1
    elseif ch == "}" then
      curly = curly - 1
    elseif ch == "," and round == 0 and square == 0 and curly == 0 then
      result[#result + 1] = vim.trim(text:sub(start, i - 1))
      start = i + 1
    end
  end
  local tail = vim.trim(text:sub(start))
  if tail ~= "" then
    result[#result + 1] = tail
  end
  return result
end

local function balanced_at(text, start)
  local open = text:sub(start, start)
  local close = ({ ["("] = ")", ["["] = "]", ["{"] = "}" })[open]
  if not close then
    return nil
  end
  local masked = mask_ignored(text)
  local depth = 0
  for i = start, #masked do
    local ch = masked:sub(i, i)
    if ch == open then
      depth = depth + 1
    elseif ch == close then
      depth = depth - 1
      if depth == 0 then
        return text:sub(start, i), i
      end
    end
  end
  return nil
end

local function top_level_equal(text)
  local masked = mask_ignored(text)
  local round, square, curly = 0, 0, 0
  for i = 1, #masked do
    local ch = masked:sub(i, i)
    if ch == "(" then
      round = round + 1
    elseif ch == ")" then
      round = round - 1
    elseif ch == "[" then
      square = square + 1
    elseif ch == "]" then
      square = square - 1
    elseif ch == "{" then
      curly = curly + 1
    elseif ch == "}" then
      curly = curly - 1
    elseif ch == "=" and round == 0 and square == 0 and curly == 0 then
      return i
    end
  end
end

local function declaration_parts(text)
  local equal = top_level_equal(text)
  local declaration = vim.trim(equal and text:sub(1, equal - 1) or text)
  local default = equal and vim.trim(text:sub(equal + 1)) or nil
  local unpacked = {}
  while true do
    local start, finish = declaration:find("%b[]%s*$")
    if not start then
      break
    end
    table.insert(unpacked, 1, vim.trim(declaration:sub(start, finish)))
    declaration = vim.trim(declaration:sub(1, start - 1))
  end
  local name_start, _, name = declaration:find("([%a_$][%w_$]*)%s*$")
  if not name then
    return nil
  end
  return {
    name = name,
    prefix = vim.trim(declaration:sub(1, name_start - 1)),
    unpacked = #unpacked > 0 and table.concat(unpacked, " ") or nil,
    default = default,
  }
end

local function packed_dimensions(prefix)
  local values = {}
  for dimension in prefix:gmatch("%b[]") do
    values[#values + 1] = vim.trim(dimension)
  end
  return #values > 0 and table.concat(values, " ") or nil
end

local function parse_ports(text, base_line)
  local ports, inherited = {}, {}
  local search = 1
  for _, raw in ipairs(split_top_level(text)) do
    local value = strip_comments(raw)
    local direction = value:match("^%s*(input)%f[%W]")
      or value:match("^%s*(output)%f[%W]")
      or value:match("^%s*(inout)%f[%W]")
      or value:match("^%s*(ref)%f[%W]")
    local explicit_direction = direction ~= nil
    local parts = declaration_parts(value)
    if not parts then
      goto continue
    end

    local prefix = parts.prefix
    if explicit_direction then
      prefix = vim.trim(prefix:gsub("^" .. direction .. "%f[%W]", "", 1))
    end
    local packed = packed_dimensions(prefix)
    local data_type = vim.trim(prefix:gsub("%b[]", " "):gsub("%s+", " "))
    local interface, modport = data_type:match(
      "^([%a_$][%w_$]*)%s*%.%s*([%a_$][%w_$]*)$"
    )

    if not explicit_direction then
      if interface then
        direction = "interface"
      elseif data_type:match("^[%a_$][%w_$]*$") and not inherited.direction then
        direction = "interface"
        interface = data_type
      else
        direction = inherited.direction
      end
    end

    if direction == "interface" and not interface then
      interface = inherited.interface
      modport = inherited.modport
      data_type = inherited.type or data_type
    end
    if not packed and not explicit_direction and prefix == "" then
      packed = inherited.packed
    end
    if data_type == "" and not explicit_direction then
      data_type = inherited.type or ""
    end

    if direction then
      local raw_offset = text:find(raw, search, true) or search
      local name_offset = value:find(parts.name, 1, true) or 1
      ports[#ports + 1] = {
        name = parts.name,
        direction = direction,
        packed = packed,
        unpacked = parts.unpacked,
        interface = interface,
        modport = modport,
        type = data_type ~= "" and data_type or nil,
        default = parts.default,
        line = base_line + line_number(text, raw_offset + name_offset - 1) - 1,
      }
      inherited = {
        direction = direction,
        packed = packed,
        interface = interface,
        modport = modport,
        type = data_type ~= "" and data_type or nil,
      }
    end
    search = math.max(search, (text:find(raw, search, true) or search) + #raw)
    ::continue::
  end
  return ports
end

local function parse_parameters(text, base_line)
  local result, inherited = {}, nil
  local search = 1
  for _, raw in ipairs(split_top_level(text)) do
    local value = strip_comments(raw)
    local kind = value:match("^%s*(parameter)%f[%W]")
      or value:match("^%s*(localparam)%f[%W]")
    if kind then
      inherited = kind
      value = vim.trim(value:gsub("^%s*" .. kind .. "%f[%W]", "", 1))
    end
    local parts = declaration_parts(value)
    if inherited and parts and parts.default ~= nil then
      local raw_offset = text:find(raw, search, true) or search
      local name_offset = value:find(parts.name, 1, true) or 1
      result[#result + 1] = {
        name = parts.name,
        default = parts.default,
        line = base_line + line_number(text, raw_offset + name_offset - 1) - 1,
      }
    end
    search = math.max(search, (text:find(raw, search, true) or search) + #raw)
  end
  return result
end

local function tree_root(text)
  local parser
  for _, language in ipairs({ "systemverilog", "verilog" }) do
    local ok, value = pcall(vim.treesitter.get_string_parser, text, language)
    if ok and value then
      parser = value
      break
    end
  end
  if not parser then
    return "missing", nil
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    return "missing", nil
  end
  return "ok", trees[1]:root()
end

local declaration_nodes = {
  module_declaration = "module",
  interface_declaration = "interface",
  package_declaration = "package",
  class_declaration = "class",
  function_declaration = "function",
  task_declaration = "task",
  sequence_declaration = "sequence",
  property_declaration = "property",
  covergroup_declaration = "covergroup",
}

local patterns = {
  { "module", "endmodule" },
  { "interface", "endinterface" },
  { "package", "endpackage" },
  { "class", "endclass" },
  { "function", "endfunction" },
  { "task", "endtask" },
  { "sequence", "endsequence" },
  { "property", "endproperty" },
  { "covergroup", "endgroup" },
}

local function header_end_at(text, start)
  local masked = mask_ignored(text)
  local round, square, curly = 0, 0, 0
  for i = start, #masked do
    local ch = masked:sub(i, i)
    if ch == "(" then
      round = round + 1
    elseif ch == ")" then
      round = round - 1
    elseif ch == "[" then
      square = square + 1
    elseif ch == "]" then
      square = square - 1
    elseif ch == "{" then
      curly = curly + 1
    elseif ch == "}" then
      curly = curly - 1
    elseif ch == ";" and round == 0 and square == 0 and curly == 0 then
      return i
    end
  end
end

local function scan_declarations(text, path, parser, line_offset, only_kind)
  local symbols = {}
  line_offset = line_offset or 0

  for _, spec in ipairs(patterns) do
    local kind, ending = spec[1], spec[2]
    if only_kind and only_kind ~= kind then
      goto continue
    end
    local search = 1
    while true do
      local start_pos, name_end, name = text:find("%f[%w_]" .. kind .. "%s+[%w%s:_#%(%)%[%]]-([%a_$][%w_$]*)", search)
      if not start_pos then
        break
      end
      local finish = text:find("%f[%w_]" .. ending .. "%f[%W]", name_end + 1) or name_end
      local symbol = {
        kind = kind,
        name = name,
        file = path,
        line = line_offset + line_number(text, start_pos),
        end_line = line_offset + line_number(text, finish),
        parser = parser,
        ports = {},
        parameters = {},
      }

      if kind == "module" or kind == "interface" then
        local header_end = header_end_at(text, name_end + 1)
        if header_end and header_end < finish then
          local header = text:sub(name_end + 1, header_end)
          local port_search = 1
          local hash = header:find("#%s*%(")
          if hash then
            local open = header:find("%(", hash)
            local params, param_end = balanced_at(header, open)
            if params then
              symbol.parameters = parse_parameters(
                params:sub(2, -2),
                symbol.line + line_number(header, open) - 1
              )
              -- 不能裁剪原始模块头，否则 parameter 占用的换行会让端口行号整体上移。
              port_search = param_end + 1
            end
          end
          local open = header:find("%(", port_search)
          if open then
            local ports = balanced_at(header, open)
            if ports then
              symbol.ports = parse_ports(
                ports:sub(2, -2),
                symbol.line + line_number(header, open) - 1
              )
            end
          end
        end
      end
      symbols[#symbols + 1] = symbol
      search = math.max(name_end + 1, finish + #ending)
    end
    ::continue::
  end
  return symbols
end

local excluded_instance_heads = {
  module = true,
  interface = true,
  package = true,
  class = true,
  ["function"] = true,
  task = true,
  sequence = true,
  property = true,
  covergroup = true,
  typedef = true,
  parameter = true,
  localparam = true,
  input = true,
  output = true,
  inout = true,
  ref = true,
  logic = true,
  bit = true,
  wire = true,
  reg = true,
  assign = true,
  always = true,
  always_ff = true,
  always_comb = true,
  always_latch = true,
  initial = true,
  final = true,
  ["if"] = true,
  ["else"] = true,
  ["for"] = true,
  foreach = true,
  ["while"] = true,
  ["repeat"] = true,
  forever = true,
  case = true,
  casex = true,
  casez = true,
  assert = true,
  assume = true,
  cover = true,
  ["return"] = true,
}

local function skip_space(text, position)
  while position <= #text and text:sub(position, position):match("%s") do
    position = position + 1
  end
  return position
end

local function identifier_at(text, position)
  local start, finish, name = text:find("([%a_$][%w_$]*)", position)
  if start ~= position then
    return nil
  end
  return name, finish + 1, finish
end

local function top_level_ranges(text, start, finish)
  local masked = mask_ignored(text)
  local result = {}
  local round, square, curly = 0, 0, 0
  local item_start = start
  for i = start, finish do
    local ch = masked:sub(i, i)
    if ch == "(" then
      round = round + 1
    elseif ch == ")" then
      round = round - 1
    elseif ch == "[" then
      square = square + 1
    elseif ch == "]" then
      square = square - 1
    elseif ch == "{" then
      curly = curly + 1
    elseif ch == "}" then
      curly = curly - 1
    elseif ch == "," and round == 0 and square == 0 and curly == 0 then
      result[#result + 1] = { item_start, i - 1 }
      item_start = i + 1
    end
  end
  result[#result + 1] = { item_start, finish }
  return result, masked
end

local function trim_range(masked, start, finish)
  while start <= finish and masked:sub(start, start):match("%s") do
    start = start + 1
  end
  while finish >= start and masked:sub(finish, finish):match("%s") do
    finish = finish - 1
  end
  return start, finish
end

local function parse_connections(text, start, finish)
  local connections = {}
  local ranges, masked = top_level_ranges(text, start, finish)
  local positional = 0
  for _, range in ipairs(ranges) do
    local first, last = trim_range(masked, range[1], range[2])
    if first <= last then
      if masked:sub(first, first) == "." then
        local position = skip_space(masked, first + 1)
        if masked:sub(position, position) == "*" then
          connections[#connections + 1] = {
            kind = "automatic",
            hint_offset = position + 1,
          }
        else
          local name, after_name, name_end = identifier_at(masked, position)
          if name then
            local after = skip_space(masked, after_name)
            if masked:sub(after, after) == "(" then
              connections[#connections + 1] = {
                kind = "named",
                name = name,
                hint_offset = after + 1,
              }
            else
              connections[#connections + 1] = {
                kind = "shorthand",
                name = name,
                hint_offset = name_end + 1,
              }
            end
          end
        end
      else
        positional = positional + 1
        connections[#connections + 1] = {
          kind = "positional",
          position = positional,
          hint_offset = first,
        }
      end
    end
  end
  return connections
end

local function parse_instances(text)
  local masked = mask_ignored(text)
  local instances = {}
  local search = 1
  while search <= #masked do
    local module_start, module_end, module_name = masked:find(
      "([%a_$][%w_$]*)",
      search
    )
    if not module_start then
      break
    end
    search = module_end + 1
    local previous = module_start > 1 and masked:sub(module_start - 1, module_start - 1) or ""
    if previous:match("[%w_$]") or excluded_instance_heads[module_name] then
      goto continue
    end

    local position = skip_space(masked, module_end + 1)
    if masked:sub(position, position) == "#" then
      position = skip_space(masked, position + 1)
      if masked:sub(position, position) ~= "(" then
        goto continue
      end
      local _, parameter_end = balanced_at(masked, position)
      if not parameter_end then
        goto continue
      end
      position = skip_space(masked, parameter_end + 1)
    end

    local instance_name, after_instance = identifier_at(masked, position)
    if not instance_name then
      goto continue
    end
    position = skip_space(masked, after_instance)
    local arrays = {}
    while masked:sub(position, position) == "[" do
      local array, array_end = balanced_at(masked, position)
      if not array then
        goto continue
      end
      arrays[#arrays + 1] = text:sub(position, array_end)
      position = skip_space(masked, array_end + 1)
    end
    if masked:sub(position, position) ~= "(" then
      goto continue
    end
    local _, connection_end = balanced_at(masked, position)
    if not connection_end then
      goto continue
    end
    local tail = skip_space(masked, connection_end + 1)
    local tail_char = masked:sub(tail, tail)
    if tail_char ~= ";" and tail_char ~= "," and tail <= #masked then
      goto continue
    end

    local connections = parse_connections(text, position + 1, connection_end - 1)
    local automatic = false
    for _, connection in ipairs(connections) do
      automatic = automatic or connection.kind == "automatic"
    end
    instances[#instances + 1] = {
      kind = "instance",
      name = instance_name,
      type = module_name,
      array = #arrays > 0 and table.concat(arrays, " ") or nil,
      automatic = automatic,
      connections = connections,
      line = line_number(text, module_start),
      end_line = line_number(text, connection_end),
    }
    search = connection_end + 1
    ::continue::
  end
  return instances
end

local function parse_declarations(text, path)
  local state, root = tree_root(text)
  local symbols = {}
  if root then
    local has_error = false
    local function walk(node)
      local node_type = node:type()
      if node_type == "ERROR" then
        has_error = true
        local start_row = node:range()
        local segment = vim.treesitter.get_node_text(node, text)
        vim.list_extend(
          symbols,
          scan_declarations(segment, path, "fallback", start_row, nil)
        )
        return
      end
      local kind = declaration_nodes[node_type]
      if kind then
        local start_row = node:range()
        local segment = vim.treesitter.get_node_text(node, text)
        local parsed = scan_declarations(segment, path, "treesitter", start_row, kind)
        if parsed[1] then
          symbols[#symbols + 1] = parsed[1]
        end
      end
      for child in node:iter_children() do
        walk(child)
      end
    end
    walk(root)
    state = has_error and "error" or "ok"
  else
    symbols = scan_declarations(text, path, "fallback", 0, nil)
  end

  for row, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local modport = line:match("%f[%w_]modport%s+([%a_$][%w_$]*)")
    if modport then
      symbols[#symbols + 1] = {
        kind = "modport",
        name = modport,
        file = path,
        line = row,
        end_line = row,
        parser = state == "missing" and "fallback" or "treesitter",
      }
    end

    local assertion = line:match(
      "^%s*([%a_$][%w_$]*)%s*:%s*assert%s+property"
    )
    if assertion then
      symbols[#symbols + 1] = {
        kind = "assertion",
        name = assertion,
        file = path,
        line = row,
        end_line = row,
        parser = state == "missing" and "fallback" or "treesitter",
      }
    end
  end
  for _, instance in ipairs(parse_instances(text)) do
    instance.file = path
    instance.parser = state == "missing" and "fallback" or "treesitter"
    symbols[#symbols + 1] = instance
  end

  local deduplicated, seen = {}, {}
  table.sort(symbols, function(a, b)
    if a.line == b.line then
      return a.kind < b.kind
    end
    return a.line < b.line
  end)
  for _, symbol in ipairs(symbols) do
    local key = symbol.kind .. ":" .. symbol.name .. ":" .. symbol.line
    if not seen[key] then
      seen[key] = true
      deduplicated[#deduplicated + 1] = symbol
    end
  end
  return {
    path = path,
    parser = state,
    symbols = deduplicated,
  }
end

local function buffer_text(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
      and util.path_key(vim.api.nvim_buf_get_name(bufnr)) == util.path_key(path)
    then
      return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
        vim.api.nvim_buf_get_changedtick(bufnr)
    end
  end
end

local function cache_path(workspace)
  return vim.fs.joinpath(
    workspace.config.effective.state_dir,
    "projects",
    util.root_hash(workspace.root),
    "index.json"
  )
end

local function read_cache(workspace)
  local text = util.read_file(cache_path(workspace))
  if not text then
    return { files = {} }
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if ok
    and type(decoded) == "table"
    and decoded._owner == "nvim_fpga_sv"
    and decoded._version == CACHE_VERSION
  then
    return decoded
  end
  return { files = {} }
end

local function write_cache(workspace, cache)
  cache._owner = "nvim_fpga_sv"
  cache._version = CACHE_VERSION
  util.atomic_write(cache_path(workspace), vim.json.encode(cache) .. "\n")
end

function M.build(workspace, model)
  model = model or (workspace.models and workspace.models[workspace.active_profile].full)
  if not model then
    return nil, "工程尚未生成"
  end
  local cache = read_cache(workspace)
  local files, definitions, all_symbols = {}, {}, {}

  for _, path in ipairs(model.files) do
    local stat = (vim.uv or vim.loop).fs_stat(path)
    if stat then
      local text, changedtick = buffer_text(path)
      local signature = changedtick and ("buffer:" .. changedtick)
        or ("disk:" .. stat.mtime.sec .. ":" .. stat.size)
      local key = util.path_key(path)
      local entry = cache.files[key]
      if not entry or entry.signature ~= signature then
        text = text or util.read_file(path) or ""
        entry = {
          signature = signature,
          parsed = parse_declarations(text, path),
        }
        cache.files[key] = entry
      end
      files[key] = entry.parsed
      for _, symbol in ipairs(entry.parsed.symbols or {}) do
        all_symbols[#all_symbols + 1] = symbol
        definitions[symbol.name] = definitions[symbol.name] or {}
        definitions[symbol.name][#definitions[symbol.name] + 1] = symbol
      end
    end
  end

  local retained = {}
  for key, value in pairs(cache.files) do
    if files[key] then
      retained[key] = value
    end
  end
  cache.files = retained
  write_cache(workspace, cache)

  workspace.index = {
    files = files,
    definitions = definitions,
    symbols = all_symbols,
    profile = workspace.active_profile,
  }
  util.emit("FpgaSvIndexUpdated", {
    root = workspace.root,
    profile = workspace.active_profile,
    files = vim.tbl_count(files),
  })
  return workspace.index
end

function M.lookup(workspace, name, kind)
  local values = workspace.index and workspace.index.definitions[name] or {}
  if not kind then
    return values
  end
  return vim.tbl_filter(function(value)
    return value.kind == kind
  end, values)
end

function M.current_file(workspace, bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr or 0)
  return workspace.index and workspace.index.files[util.path_key(path)]
end

M.split_top_level = split_top_level
M.balanced_at = balanced_at
M.parse_instances = parse_instances
M.parse_text = parse_declarations

return M
