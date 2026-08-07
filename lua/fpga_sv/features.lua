local indexer = require("fpga_sv.index")
local util = require("fpga_sv.util")
local M = {}

local hint_ns = vim.api.nvim_create_namespace("fpga_sv_hints")
local timers = {}

local snippets = {
  module = "module ${1:name} (\n  ${2:/* ports */}\n);\n  ${0}\nendmodule : ${1:name}",
  interface = "interface ${1:name} (\n  ${2:/* ports */}\n);\n  ${0}\nendinterface : ${1:name}",
  package = "package ${1:name};\n  ${0}\nendpackage : ${1:name}",
  ["function"] = "function automatic ${1:logic} ${2:name}(${3});\n  ${0}\nendfunction : ${2:name}",
  task = "task automatic ${1:name}(${2});\n  ${0}\nendtask : ${1:name}",
  always_ff = "always_ff @(posedge ${1:clk}) begin\n  ${0}\nend",
  always_comb = "always_comb begin\n  ${0}\nend",
  sequence = "sequence ${1:name};\n  ${0}\nendsequence : ${1:name}",
  property = "property ${1:name};\n  ${0}\nendproperty : ${1:name}",
  assert = "${1:label}: assert property (${2:property});",
  covergroup = "covergroup ${1:name} @(posedge ${2:clk});\n  ${0}\nendgroup : ${1:name}",
  testbench = "module ${1:tb_name};\n  timeunit 1ns;\n  timeprecision 1ps;\n\n  ${0}\nendmodule : ${1:tb_name}",
}

local function ensure_index(workspace)
  if not workspace.index or workspace.index.profile ~= workspace.active_profile then
    local model = workspace.models and workspace.models[workspace.active_profile].full
    if model then
      indexer.build(workspace, model)
    end
  end
  return workspace.index
end

local function hint_text(port, options)
  local text = options.text[port.direction] or port.direction:upper()
  if options.dimensions then
    if port.packed then
      text = text .. " " .. port.packed
    end
    if port.unpacked then
      text = text .. " " .. port.unpacked
    end
  end
  if options.interfaces and port.interface then
    text = text .. " " .. port.interface .. (port.modport and "." .. port.modport or "")
  end
  return text
end

function M.refresh_hints(workspace, bufnr)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
  local options = workspace.config.effective.hints
  if not options.enabled then
    return
  end
  ensure_index(workspace)
  local parsed = indexer.current_file(workspace, bufnr)
  if not parsed then
    return
  end
  for _, symbol in ipairs(parsed.symbols or {}) do
    local counts = { input = 0, output = 0, inout = 0, ref = 0, interface = 0 }
    for _, port in ipairs(symbol.ports or {}) do
      counts[port.direction] = (counts[port.direction] or 0) + 1
      if options.directions and port.line then
        vim.api.nvim_buf_set_extmark(bufnr, hint_ns, math.max(0, port.line - 1), 0, {
          virt_text = {
            {
              hint_text(port, options),
              options.highlights[port.direction] or "Comment",
            },
          },
          virt_text_pos = options.position,
          priority = options.priority,
          hl_mode = "combine",
        })
      end
    end
    if options.summary and symbol.line then
      local summary = ("  I:%d O:%d IO:%d REF:%d IF:%d"):format(
        counts.input,
        counts.output,
        counts.inout,
        counts.ref,
        counts.interface
      )
      vim.api.nvim_buf_set_extmark(bufnr, hint_ns, symbol.line - 1, 0, {
        virt_text = { { summary, options.highlights.summary } },
        virt_text_pos = "eol",
        priority = options.priority,
      })
    end
  end

  -- 实例首行补充数组与自动连接提示；复杂多行实例仍由索引和展开命令处理。
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local compact = line:gsub("#%s*%b()", "")
    for name, definitions in pairs(workspace.index.definitions or {}) do
      if #definitions == 1 and definitions[1].kind == "module" then
        local escaped = vim.pesc(name)
        local instance, rest = compact:match("^%s*" .. escaped .. "%s+([%a_$][%w_$]*)%s*(.-)%(")
        if instance then
          local array = rest:match("(%b[])") or ""
          local automatic = line:find("%.%*") and " AUTO:*" or ""
          vim.api.nvim_buf_set_extmark(bufnr, hint_ns, row - 1, 0, {
            virt_text = {
              {
                "INST " .. instance .. array .. automatic,
                options.highlights.summary,
              },
            },
            virt_text_pos = "eol",
            priority = options.priority - 1,
          })
          break
        end
      end
    end
  end
end

function M.schedule_hints(workspace, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr]:close()
  end
  local timer = (vim.uv or vim.loop).new_timer()
  timers[bufnr] = timer
  timer:start(workspace.config.effective.hints.delay, 0, vim.schedule_wrap(function()
    if timers[bufnr] == timer then
      timers[bufnr] = nil
    end
    timer:close()
    if vim.api.nvim_buf_is_valid(bufnr) then
      local model = workspace.models and workspace.models[workspace.active_profile].full
      if model then
        indexer.build(workspace, model)
      end
      M.refresh_hints(workspace, bufnr)
    end
  end))
end

function M.toggle_hints(workspace)
  local options = workspace.config.effective.hints
  options.enabled = not options.enabled
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_hints(workspace, bufnr)
    end
  end
  return options.enabled
end

local function module_choices(workspace)
  ensure_index(workspace)
  local result = {}
  for _, symbol in ipairs(workspace.index and workspace.index.symbols or {}) do
    if symbol.kind == "module" then
      result[#result + 1] = symbol.name
    end
  end
  table.sort(result)
  return util.unique(result)
end

local function unique_module(workspace, name)
  ensure_index(workspace)
  local definitions = indexer.lookup(workspace, name, "module")
  if #definitions == 0 then
    return nil, "未找到模块: " .. name
  elseif #definitions > 1 then
    return nil, "模块定义不唯一，拒绝修改: " .. name
  end
  local seen = {}
  for _, port in ipairs(definitions[1].ports or {}) do
    if seen[port.name] then
      return nil, "模块存在重复端口，拒绝修改: " .. port.name
    end
    seen[port.name] = true
  end
  return definitions[1]
end

local function connection_lines(module, options, indent)
  local width = 0
  for _, port in ipairs(module.ports or {}) do
    width = math.max(width, #port.name)
  end
  local lines = {}
  for i, port in ipairs(module.ports or {}) do
    local name = options.align and (port.name .. string.rep(" ", width - #port.name)) or port.name
    local expression = options.connection == "same_name" and port.name or options.empty_connection
    lines[#lines + 1] = ("%s.%s (%s)%s"):format(
      indent,
      name,
      expression,
      i < #module.ports and "," or ""
    )
  end
  return lines
end

local function insert_instance(workspace, module_name, instance_name, array)
  local module, err = unique_module(workspace, module_name)
  if not module then
    util.notify(err, vim.log.levels.ERROR)
    return
  end
  local options = workspace.config.effective.instantiate
  instance_name = instance_name ~= "" and instance_name
    or options.instance_name:format(module_name:lower())
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local indent = line:match("^%s*") or ""
  local lines = {}
  if #(module.parameters or {}) > 0 then
    lines[#lines + 1] = ("%s%s #("):format(indent, module_name)
    local width = 0
    for _, parameter in ipairs(module.parameters) do
      width = math.max(width, #parameter.name)
    end
    for i, parameter in ipairs(module.parameters) do
      local name = options.align
          and parameter.name .. string.rep(" ", width - #parameter.name)
        or parameter.name
      local expression = options.parameter == "same_name"
          and parameter.name
        or options.empty_connection
      lines[#lines + 1] = ("%s  .%s (%s)%s"):format(
        indent,
        name,
        expression,
        i < #module.parameters and "," or ""
      )
    end
    lines[#lines + 1] = ("%s) %s%s ("):format(indent, instance_name, array or "")
  else
    lines[#lines + 1] = ("%s%s %s%s ("):format(
      indent,
      module_name,
      instance_name,
      array or ""
    )
  end
  vim.list_extend(lines, connection_lines(module, options, indent .. "  "))
  lines[#lines + 1] = indent .. ");"
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)
end

function M.instantiate(workspace, module_name)
  local function ask_instance(name)
    vim.ui.input({
      prompt = "实例名: ",
      default = workspace.config.effective.instantiate.instance_name:format(name:lower()),
    }, function(instance)
      if not instance then
        return
      end
      vim.ui.input({ prompt = "实例数组（可空，如 [3:0]）: " }, function(array)
        if array ~= nil then
          insert_instance(workspace, name, instance, array)
        end
      end)
    end)
  end
  if module_name and module_name ~= "" then
    ask_instance(module_name)
    return
  end
  vim.ui.select(module_choices(workspace), { prompt = "选择模块" }, function(choice)
    if choice then
      ask_instance(choice)
    end
  end)
end

local function statement_at_cursor()
  local bufnr = 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local start_line, end_line = row, row
  while start_line > 1 and not lines[start_line - 1]:find(";") do
    start_line = start_line - 1
  end
  while end_line <= #lines and not lines[end_line]:find(";") do
    end_line = end_line + 1
  end
  if end_line > #lines then
    return nil
  end
  return table.concat(vim.list_slice(lines, start_line, end_line), "\n"), start_line, end_line
end

local function parse_instance(statement)
  local clean = statement:gsub("//[^\n]*", " ")
  local module, pos = clean:match("^%s*([%a_$][%w_$]*)%s*()")
  if not module then
    return nil
  end
  local parameter = ""
  if clean:sub(pos):match("^#%s*%(") then
    local hash_start = clean:find("#", pos, true)
    local open = clean:find("%(", hash_start)
    local value, finish = indexer.balanced_at(clean, open)
    if not value then
      return nil
    end
    parameter = clean:sub(hash_start, finish)
    pos = finish + 1
  end
  local instance, relative_after = clean:sub(pos):match("^%s*([%a_$][%w_$]*)%s*()")
  if not instance then
    return nil
  end
  pos = pos + relative_after - 1
  local array = clean:sub(pos):match("^%s*(%b[])%s*") or ""
  if array ~= "" then
    local _, array_end = clean:find("%b[]", pos)
    pos = array_end + 1
  end
  local open = clean:find("%(", pos)
  if not open then
    return nil
  end
  local connections, finish = indexer.balanced_at(clean, open)
  if not connections then
    return nil
  end
  local tail = statement:sub(finish + 1):match(";%s*(//.*)$") or ""
  return {
    module = module,
    parameter = vim.trim(parameter),
    instance = instance,
    array = array,
    connections = connections:sub(2, -2),
    tail = tail,
  }
end

function M.expand_instance(workspace)
  local statement, start_line, end_line = statement_at_cursor()
  if not statement then
    util.notify("光标附近没有完整实例语句", vim.log.levels.ERROR)
    return
  end
  local parsed = parse_instance(statement)
  if not parsed then
    util.notify("无法解析当前实例", vim.log.levels.ERROR)
    return
  end
  local module, err = unique_module(workspace, parsed.module)
  if not module then
    util.notify(err, vim.log.levels.ERROR)
    return
  end

  local raw = indexer.split_top_level(parsed.connections)
  local values, named, has_star = {}, {}, false
  for _, connection in ipairs(raw) do
    if connection == ".*" then
      has_star = true
    else
      local name, expression = connection:match("^%.([%a_$][%w_$]*)%s*%((.*)%)$")
      local shorthand = connection:match("^%.([%a_$][%w_$]*)$")
      if name then
        if named[name] then
          util.notify("实例存在重复连接，拒绝修改: " .. name, vim.log.levels.ERROR)
          return
        end
        named[name] = expression
      elseif shorthand then
        if named[shorthand] then
          util.notify("实例存在重复连接，拒绝修改: " .. shorthand, vim.log.levels.ERROR)
          return
        end
        named[shorthand] = shorthand
      elseif connection ~= "" then
        values[#values + 1] = connection
      end
    end
  end
  if #values > 0 and (#values ~= #module.ports or next(named) or has_star) then
    util.notify("位置连接数量与端口数量不匹配，拒绝修改", vim.log.levels.ERROR)
    return
  end

  local options = workspace.config.effective.instantiate
  local expressions = {}
  for i, port in ipairs(module.ports) do
    expressions[port.name] = named[port.name]
      or values[i]
      or (has_star and port.name)
      or (options.connection == "same_name" and port.name or options.empty_connection)
  end
  local indent = statement:match("^%s*") or ""
  local header = ("%s%s%s %s%s ("):format(
    indent,
    parsed.module,
    parsed.parameter ~= "" and " " .. parsed.parameter or "",
    parsed.instance,
    parsed.array
  )
  local width = 0
  for _, port in ipairs(module.ports) do
    width = math.max(width, #port.name)
  end
  local lines = { header }
  for i, port in ipairs(module.ports) do
    local name = options.align and port.name .. string.rep(" ", width - #port.name) or port.name
    lines[#lines + 1] = ("%s  .%s (%s)%s"):format(
      indent,
      name,
      expressions[port.name],
      i < #module.ports and "," or ""
    )
  end
  lines[#lines + 1] = indent .. ");" .. (parsed.tail ~= "" and " " .. parsed.tail or "")
  -- 单次缓冲区替换，确保一次 u 可以整体撤销。
  vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, lines)
end

function M.template(name)
  if not snippets[name] then
    util.notify("未知模板: " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  vim.snippet.expand(snippets[name])
end

function M.navigate(workspace, direction, kind)
  ensure_index(workspace)
  local parsed = indexer.current_file(workspace, 0)
  if not parsed then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local candidates = vim.tbl_filter(function(symbol)
    return not kind or symbol.kind == kind
  end, parsed.symbols)
  if kind == "port" or kind == "parameter" then
    candidates = {}
    for _, symbol in ipairs(parsed.symbols) do
      local values = kind == "port" and symbol.ports or symbol.parameters
      for _, value in ipairs(values or {}) do
        candidates[#candidates + 1] = value
      end
    end
  elseif vim.tbl_contains({ "process", "block", "instance", "assertion", "comment" }, kind) then
    candidates = {}
    local patterns = {
      process = "%f[%w_]always[_%w]*%f[%W]",
      block = "%f[%w_]begin%f[%W]",
      assertion = "%f[%w_]assert%s+property%f[%W]",
      comment = "^%s*//",
    }
    for line_number_value, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local matched = patterns[kind] and line:match(patterns[kind])
      if kind == "instance" then
        for name, definitions in pairs(workspace.index.definitions or {}) do
          if #definitions == 1
            and definitions[1].kind == "module"
            and line:match("^%s*" .. vim.pesc(name) .. "%s+")
          then
            matched = true
            break
          end
        end
      end
      if matched then
        candidates[#candidates + 1] = { line = line_number_value }
      end
    end
  end
  table.sort(candidates, function(a, b)
    return a.line < b.line
  end)
  if direction > 0 then
    for _, symbol in ipairs(candidates) do
      if symbol.line > row then
        vim.api.nvim_win_set_cursor(0, { symbol.line, 0 })
        return
      end
    end
  else
    for i = #candidates, 1, -1 do
      if candidates[i].line < row then
        vim.api.nvim_win_set_cursor(0, { candidates[i].line, 0 })
        return
      end
    end
  end
end

function M.select_object(workspace, kind)
  ensure_index(workspace)
  local parsed = indexer.current_file(workspace, 0)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, symbol in ipairs(parsed and parsed.symbols or {}) do
    if symbol.kind == kind and row >= symbol.line and row <= symbol.end_line then
      vim.api.nvim_win_set_cursor(0, { symbol.line, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { symbol.end_line, 0 })
      return
    end
  end
end

function M.setup_buffer(workspace, bufnr)
  local indent = workspace.config.effective.indent
  local filetype = vim.bo[bufnr].filetype
  vim.bo[bufnr].shiftwidth = indent.width
  vim.bo[bufnr].softtabstop = indent.width
  if filetype == "systemverilog" then
    vim.b[bufnr].systemverilog_indent_width = indent.width
    vim.b[bufnr].systemverilog_indent_modules = indent.module > 0 and 1 or nil
    vim.b[bufnr].systemverilog_indent_ifdef_off = indent.preprocessor == 0 and 1 or nil
  elseif filetype == "verilog" then
    vim.b[bufnr].verilog_indent_width = indent.width
    vim.b[bufnr].verilog_indent_modules = indent.module > 0 and 1 or nil
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
  end)
  local group = vim.api.nvim_create_augroup("FpgaSvBuffer" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    buffer = bufnr,
    callback = function(args)
      M.schedule_hints(workspace, bufnr)
      if args.event == "BufWritePost" and workspace.models then
        local lint = workspace.config.effective.tools.svlint
        if workspace.config.effective.adapters.svlint
          and lint.enabled
          and util.executable(lint.cmd)
        then
          require("fpga_sv.adapters.svlint").current(workspace, bufnr)
        end
        local path = vim.api.nvim_buf_get_name(bufnr)
        local model = workspace.models[workspace.active_profile].full
        local known = false
        for _, file in ipairs(model.files) do
          if util.path_key(file) == util.path_key(path) then
            known = true
            break
          end
        end
        if not known then
          -- 新源码可能命中 glob；重新生成模型，旧产物仅在成功后替换。
          vim.schedule(function()
            require("fpga_sv").generate(workspace.root)
          end)
        end
      end
    end,
  })
  M.schedule_hints(workspace, bufnr)
end

M.snippets = snippets
return M
