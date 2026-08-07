if vim.g.loaded_fpga_sv == 1 then
  return
end
vim.g.loaded_fpga_sv = 1

if vim.fn.has("nvim-0.11") == 0 then
  vim.schedule(function()
    vim.notify("nvim_fpga_sv 需要 Neovim 0.11+", vim.log.levels.ERROR)
  end)
end
