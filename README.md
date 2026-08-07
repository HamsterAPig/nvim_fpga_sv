# nvim_fpga_sv

面向 Neovim 0.11+ 的通用 SystemVerilog 编辑插件，优先适配
LazyVim。插件只负责编辑分析工程，不保证生成的 filelist 能直接用于仿真、
综合或厂商工程。

固定编辑链路：

- Slang language server：LSP、工程 build file 与 top。
- Verible：通过 Conform 格式化。
- svlint：当前文件诊断与完整 Profile quickfix。
- Tree-sitter：语法着色、折叠、文本对象；parser 缺失或局部错误时使用
  容错索引。

插件不会在线安装任何工具。`slang-server`、`svlint`、
`verible-verilog-format` 默认从 `PATH` 查找，也可以显式配置命令。

## 安装

Lazy.nvim / LazyVim：

```lua
{
  dir = "/path/to/nvim_fpga_sv",
  ft = { "systemverilog", "verilog" },
  config = function()
    require("fpga_sv").setup()
  end,
}
```

最小配置：

```lua
require("fpga_sv").setup({
  tools = {
    svlint = {
      cmd = "D:/tools/svlint.exe",
    },
  },
})
```

## 工程配置

物理配置分为三层：

1. 全局：`stdpath("config")/fpga-sv.lua`
2. 项目：项目根目录 `.nvim-fpga.lua`
3. local：`stdpath("state")/fpga_sv/projects/<root-hash>/config.lua`

行为优先级：

```text
内置默认值 < 全局文件 < setup() < 项目文件 < local 文件
```

项目配置通过 `vim.secure.read()` 加载。首次读取或文件内容变化后，
Neovim 会重新请求信任。可用 `:FpgaSvEditProjectConfig` 和
`:FpgaSvEditLocalConfig` 创建或编辑配置。

完整示例：

```lua
return {
  source_sets = {
    common = {
      roots = { "rtl" },
      files = {},
      globs = { "**/*.sv", "**/*.svh", "**/*.v", "**/*.vh" },
      exclude = { "build", "output" },
      filelists = {},
      include_dirs = { { path = "include", optional = true } },
      defines = { FPGA = true, WIDTH = 32 },
      library_dirs = {},
      library_extensions = { ".sv", ".v" },
      flags = {},
      depends_on = {},
    },
    vendor_stub = {
      files = { "stubs/vendor_ip.sv" },
      replaces = { "../vendor/encrypted_ip.sv" },
      depends_on = { "common" },
    },
  },
  profiles = {
    default = {
      source_sets = { "common", "vendor_stub" },
      top = "fpga_top",
      defines = {},
      include_dirs = {},
      flags = {},
      lint = { config = ".svlint.toml" },
    },
  },
  default_profile = "default",
}
```

所有列表默认追加并稳定去重，也支持显式操作：

```lua
include_dirs = {
  add = { "local/include" },
  remove = { "obsolete/include" },
  replace = { "only/this/include" },
}
```

文件与目录可以标记为可选：

```lua
files = {
  "rtl/required.sv",
  { path = "generated/optional.sv", optional = true },
}
```

缺失必需项、Source Set 依赖循环、缺失依赖或生成所有权冲突都会阻止
覆盖上一份有效产物。

## 生成产物

项目层生成：

```text
<root>/.nvim/fpga-sv/<profile>.f
<root>/.nvim/fpga-sv/<profile>.slang.json
```

项目层只包含项目 Lua 声明的可移植内容，路径优先相对项目根目录。
机器相关内容生成在 Neovim state 目录，通过 `-F` 引用项目 `.f`。
插件不会自动修改 `.gitignore`。

## 命令

- `:FpgaSvProfile [name]`：切换活动 Profile。
- `:FpgaSvGenerate`：生成全部 Profile。
- `:FpgaSvProjectInfo`：显示工程、错误与产物。
- `:FpgaSvInstantiate [module]`：生成命名端口例化。
- `:FpgaSvExpand`：展开位置连接、`.port` 与 `.*`。
- `:FpgaSvHints`：开关端口虚拟提示。
- `:FpgaSvTop [module]`：通知 Slang top。
- `:FpgaSvLint`：lint 当前文件。
- `:FpgaSvLintProject`：lint 活动 Profile，结果写入 quickfix。
- `:FpgaSvTemplate <name>`：用原生 `vim.snippet` 展开模板。
- `:FpgaSvNext [kind]` / `:FpgaSvPrev [kind]`：结构导航。
- `:FpgaSvSelect <kind>`：选择当前结构。
- `:checkhealth fpga_sv`：检查 parser、工具与 local 产物位置。

兼容别名包括 `SVInstantiate`、`SVProjectInfo`、`SVSlangSetBuild`、
`SVSlangSetTop` 和 `SVPortDirectionsToggle`。

默认 buffer-local 键位：

```text
<leader>vp  Profile       <leader>vg  Generate
<leader>vi  Instantiate   <leader>ve  Expand
<leader>vr  Refresh       <leader>vd  Hints
<leader>vl  Lint
```

每个键位都可以覆盖，设置为 `false` 即禁用。

## 公共 API

```lua
local fpga = require("fpga_sv")

fpga.setup({})
fpga.project()
fpga.generate()
fpga.switch_profile("default")
fpga.register_backend("name", backend)
fpga.register_installer("name", installer)
fpga.statusline()
```

插件发布 `FpgaSvProfileChanged`、`FpgaSvProjectGenerated` 和
`FpgaSvIndexUpdated` 三个 `User` 事件。

## v1 边界

- 不在线安装工具，只保留 backend / installer provider 注册接口。
- 不包含 UVM query、UVM 模板或 UVM 专用导航。
- Conform 不存在时不实现第二套格式化器。
- `.f` 是编辑分析产物，不承诺工具链工程兼容性。
