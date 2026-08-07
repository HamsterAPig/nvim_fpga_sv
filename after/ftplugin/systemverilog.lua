if vim.b.did_fpga_sv_ftplugin then
  return
end
vim.b.did_fpga_sv_ftplugin = true

-- 保留 Neovim 自带 SystemVerilog 缩进，只补充 Tree-sitter 折叠。
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
