if vim.b.did_fpga_sv_ftplugin then
  return
end
vim.b.did_fpga_sv_ftplugin = true

vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
