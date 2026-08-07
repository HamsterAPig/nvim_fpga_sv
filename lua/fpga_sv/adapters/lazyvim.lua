local M = {}

function M.detect()
  return package.loaded["lazyvim"] ~= nil or vim.g.lazyvim_version ~= nil
end

return M
