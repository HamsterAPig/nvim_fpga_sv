local M = {}

local publish_diagnostics_method = "textDocument/publishDiagnostics"
local wrapped_handlers = setmetatable({}, { __mode = "k" })

local function canonicalize(value, visiting)
  if type(value) ~= "table" then
    return value
  end
  if visiting[value] then
    error("诊断对象包含循环引用")
  end
  visiting[value] = true

  local result
  if vim.islist(value) then
    result = { "array" }
    for index, item in ipairs(value) do
      result[index + 1] = canonicalize(item, visiting)
    end
  else
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "string" then
        error("诊断对象包含非字符串属性名")
      end
      keys[#keys + 1] = key
    end
    table.sort(keys)

    result = { "object" }
    for _, key in ipairs(keys) do
      result[#result + 1] = {
        key,
        canonicalize(value[key], visiting),
      }
    end
  end

  visiting[value] = nil
  return result
end

local function fingerprint(diagnostic)
  local ok, encoded = pcall(function()
    return vim.json.encode(canonicalize(diagnostic, {}))
  end)
  if not ok or type(encoded) ~= "string" then
    return nil
  end
  return encoded
end

function M.deduplicate(diagnostics)
  if type(diagnostics) ~= "table" or #diagnostics < 2 then
    return diagnostics
  end

  local seen = {}
  local filtered = {}
  local changed = false
  for _, diagnostic in ipairs(diagnostics) do
    local key = fingerprint(diagnostic)
    if key and seen[key] then
      changed = true
    else
      if key then
        seen[key] = true
      end
      filtered[#filtered + 1] = diagnostic
    end
  end

  return changed and filtered or diagnostics
end

function M.wrap(handler)
  assert(type(handler) == "function", "诊断 handler 必须是函数")
  if wrapped_handlers[handler] then
    return handler
  end

  local wrapped = function(err, result, ctx, config)
    if type(result) ~= "table" or type(result.diagnostics) ~= "table" then
      return handler(err, result, ctx, config)
    end

    local diagnostics = M.deduplicate(result.diagnostics)
    if diagnostics == result.diagnostics then
      return handler(err, result, ctx, config)
    end

    -- 仅替换当前 Slang 发布包的诊断列表，保留 URI、版本等原始字段。
    local filtered_result = {}
    for key, value in pairs(result) do
      filtered_result[key] = value
    end
    filtered_result.diagnostics = diagnostics
    return handler(err, filtered_result, ctx, config)
  end

  wrapped_handlers[wrapped] = true
  return wrapped
end

function M.handler(existing_config)
  local configured = existing_config
    and existing_config.handlers
    and existing_config.handlers[publish_diagnostics_method]
  local downstream = configured
    or vim.lsp.handlers[publish_diagnostics_method]
  return M.wrap(downstream)
end

return M
