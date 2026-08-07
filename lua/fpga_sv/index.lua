local util = require("fpga_sv.util")
local M = {}

local function line_number(text, offset)
  local _, count = text:sub(1, offset):gsub("\n", "\n")
  return count + 1
end

local function split_top_level(text)
  local result, current = {}, {}
  local round, square, curly = 0, 0, 0
  local quote = nil
  for i = 1, #text do
    local ch = text:sub(i, i)
    if quote then
      current[#current + 1] = ch
      if ch == quote and text:sub(i - 1, i - 1) ~= "\\" then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
      current[#current + 1] = ch
    else
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
      end
      if ch == "," and round == 0 and square == 0 and curly == 0 then
        result[#result + 1] = vim.trim(table.concat(current))
        current = {}
      else
        current[#current + 1] = ch
      end
    end
  end
  if #current > 0 then
    result[#result + 1] = vim.trim(table.concat(current))
  end
  return result
end

local function balanced_at(text, start)
  local open = text:sub(start, start)
  local close = ({ ["("] = ")", ["["] = "]", ["{"] = "}" })[open]
  if not close then
    return nil
  end
  local depth, quote = 0, nil
  for i = start, #text do
    local ch = text:sub(i, i)
    if quote then
      if ch == quote and text:sub(i - 1, i - 1) ~= "\\" then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == open then
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

local function parse_ports(text, base_line)
  local ports, inherited = {}, {}
  for _, raw in ipairs(split_top_level(text)) do
    local value = raw:gsub("//[^\n]*", " "):gsub("/%*.-%*/", " ")
    local direction = value:match("^%s*(input)%f[%W]")
      or value:match("^%s*(output)%f[%W]")
      or value:match("^%s*(inout)%f[%W]")
      or value:match("^%s*(ref)%f[%W]")
    local explicit_direction = direction ~= nil
    if direction then
      inherited.direction = direction
    else
      direction = inherited.direction
    end

    local without_default = value:gsub("%s*=%s*.+$", "")
    local name = without_default:match("([%a_$][%w_$]*)%s*%b[]%s*$")
      or without_default:match("([%a_$][%w_$]*)%s*$")
    local prefix = name
        and without_default:sub(1, without_default:find(name, 1, true) - 1)
      or ""
    local interface, modport = prefix:match("([%a_$][%w_$]*)%.([%a_$][%w_$]*)")
    if not explicit_direction and interface then
      direction = "interface"
    end
    if name and direction then
      if direction ~= "interface" then
        prefix = prefix:gsub("^%s*" .. direction .. "%s*", "")
      end
      local packed = prefix:match("(%b[])")
      local unpacked = without_default:match(name .. "%s*(%b[])%s*$")
      interface, modport = prefix:match("([%a_$][%w_$]*)%.([%a_$][%w_$]*)")
      local data_type = vim.trim(prefix:gsub("%b[]", ""):gsub("%s+", " "))
      ports[#ports + 1] = {
        name = name,
        direction = direction,
        packed = packed,
        unpacked = unpacked,
        interface = interface,
        modport = modport,
        type = data_type ~= "" and data_type or nil,
        line = base_line + line_number(text, math.max(1, text:find(name, 1, true) or 1)) - 1,
      }
    end
  end
  return ports
end

local function parse_parameters(text, base_line)
  local result = {}
  for _, raw in ipairs(split_top_level(text)) do
    local name = raw:match("parameter%s+.-([%a_$][%w_$]*)%s*=")
      or raw:match("localparam%s+.-([%a_$][%w_$]*)%s*=")
    if name then
      result[#result + 1] = {
        name = name,
        default = raw:match("=%s*(.-)%s*$"),
        line = base_line + line_number(text, math.max(1, text:find(name, 1, true) or 1)) - 1,
      }
    end
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
        local header_end = text:find(";", name_end + 1, true)
        if header_end and header_end < finish then
          local header = text:sub(name_end + 1, header_end)
          local hash = header:find("#%s*%(")
          if hash then
            local open = header:find("%(", hash)
            local params, param_end = balanced_at(header, open)
            if params then
              symbol.parameters = parse_parameters(
                params:sub(2, -2),
                symbol.line + line_number(header, open) - 1
              )
              header = header:sub(param_end + 1)
            end
          end
          local open = header:find("%(")
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

  local excluded_instance_heads = {
    module = true,
    interface = true,
    package = true,
    class = true,
    ["function"] = true,
    task = true,
    ["if"] = true,
    ["for"] = true,
    ["while"] = true,
    case = true,
    assert = true,
    cover = true,
  }
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

    local compact = line:gsub("#%s*%b()", "")
    local instance_type, instance_name, rest = compact:match(
      "^%s*([%a_$][%w_$]*)%s+([%a_$][%w_$]*)%s*(.-)%("
    )
    if instance_type and not excluded_instance_heads[instance_type] then
      symbols[#symbols + 1] = {
        kind = "instance",
        name = instance_name,
        type = instance_type,
        array = rest:match("(%b[])"),
        automatic = line:find("%.%*") ~= nil,
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
  if ok and type(decoded) == "table" and decoded._owner == "nvim_fpga_sv" then
    return decoded
  end
  return { files = {} }
end

local function write_cache(workspace, cache)
  cache._owner = "nvim_fpga_sv"
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
M.parse_text = parse_declarations

return M
