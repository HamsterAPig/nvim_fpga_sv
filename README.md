# nvim_fpga_sv

面向 Neovim 0.11+ 的通用 SystemVerilog 编辑插件。插件负责建立编辑分析
工程、驱动标准 `slang_server`、生成端口虚拟提示，并集成 Verible、
svlint 与 Tree-sitter。生成的 filelist 用于编辑分析，不承诺可以直接替代
仿真、综合或其他工具链的工程文件。

## 安装

Lazy.nvim 示例：

```lua
return {
  {
    "<plugin-owner>/nvim_fpga_sv",
    ft = { "systemverilog", "verilog" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/conform.nvim",
    },
    config = function()
      require("fpga_sv").setup()
    end,
  },
}
```

本地调试可将插件声明改为：

```lua
{
  dir = "/path/to/tool",
  name = "nvim_fpga_sv",
}
```

插件不会在线安装工具。`slang-server`、`svlint` 和
`verible-verilog-format` 默认从 `PATH` 查找，也可以显式配置：

```lua
require("fpga_sv").setup({
  tools = {
    slang = { cmd = "/path/to/tool/slang-server" },
    svlint = { cmd = "/path/to/tool/svlint" },
    verible = { cmd = "/path/to/tool/verible-verilog-format" },
  },
})
```

安装后执行：

```vim
:TSInstall verilog
:checkhealth fpga_sv
```

`systemverilog` 文件类型使用的 Tree-sitter parser 名称是 `verilog`。

## 快速开始

示例工程完全使用虚构名称：

```text
demo_project
├── .nvim-fpga.lua
├── rtl
│   ├── demo_top.sv
│   └── counter.sv
└── vendor
    └── clock_core.v
```

在 `<project>/.nvim-fpga.lua` 写入最小配置：

```lua
return {
  source_sets = {
    rtl = {
      roots = { "rtl" },
    },
  },
  profiles = {
    default = {
      source_sets = { "rtl" },
      top = "demo_top",
    },
  },
  default_profile = "default",
}
```

首次使用流程：

1. 创建 `.nvim-fpga.lua`。
2. 接受 Neovim 对项目配置的信任请求。
3. 执行 `:FpgaSvGenerate`。
4. 执行 `:FpgaSvProjectInfo`。
5. 确认活动 Profile、Source Set 和文件数量正确。

项目配置由 `vim.secure.read()` 加载。首次读取或内容变化后，Neovim 会
重新请求信任。

## 工程模型

```text
Source Set 定义文件集合
        ↓
Profile 选择 Source Set
        ↓
生成活动 Profile 的 .f
        ↓
同步活动 Profile 源码到 Slang 工作区索引
        ↓
发送 slang.setBuildFile
        ↓
Slang 分析完整工程
```

必须区分“定义”与“启用”：

- 定义 Source Set 不等于启用 Source Set。
- `profile.source_sets` 决定哪些集合参与当前构建。
- `top` 只指定顶层模块，不会自动收集依赖文件。
- 当前打开的文件可以由 Slang 单独分析，但同目录文件不会自动进入工程。
- 是否属于工程以活动 Profile 生成的 `.f` 为准。

配置分为三层：

```text
全局配置
<project>/.nvim-fpga.lua
<state>/fpga_sv/projects/<project-id>/config.lua
```

合并顺序：

```text
内置默认值 < 全局文件 < setup() < 项目文件 < local 文件
```

## Source Set 字段参考

### `roots`

相对 `<project>` 解析，扫描目录中的 Verilog/SystemVerilog 源文件。
默认扫描 `.sv`、`.svh`、`.v` 和 `.vh`。

```lua
roots = { "rtl", "vendor" }
```

目录也可以设为可选：

```lua
roots = {
  "rtl",
  { path = "generated", optional = true },
}
```

### `globs`

控制每个 `roots` 目录中的文件类型和递归范围。

```lua
-- 只匹配目录直属文件
globs = { "*.sv", "*.v" }

-- 递归匹配子目录
globs = { "**/*.sv" }

-- 同时覆盖直属文件、递归目录和混合扩展名
globs = { "*.sv", "*.v", "**/*.sv", "**/*.v" }
```

### `files`

显式加入指定文件，适合少量模型或不规则目录。

```lua
files = {
  "vendor/clock_core.v",
  "vendor/memory_model.sv",
}
```

### `filelists`

导入已有 `.f`。嵌套 `-f` 或 `-F` 相对于当前 filelist 所在目录解析。

```lua
filelists = { "config/project.f" }
```

### `include_dirs`

生成 `-I`，只用于头文件搜索。把源码目录写入 `include_dirs` 不会编译
其中的模块。

```lua
include_dirs = { "include", "rtl/include" }
```

### `library_dirs`

生成 `-y`，配合 `library_extensions` 搜索库模块。

```lua
library_dirs = { "vendor" }
```

### `library_extensions`

生成 `+libext+...`。

```lua
library_extensions = { ".sv", ".v" }
```

### `defines`

支持无值宏和带值宏：

```lua
defines = {
  DEMO_BUILD = true,
  DATA_WIDTH = 32,
}
```

也可以使用列表形式：

```lua
defines = { "DEMO_BUILD", "DATA_WIDTH=32" }
```

### `flags`

原样传递额外编译参数：

```lua
flags = { "--ignore-unknown-modules" }
```

### `depends_on`

定义 Source Set 之间的依赖和生成顺序：

```lua
simulation = {
  roots = { "tb" },
  depends_on = { "rtl" },
}
```

### `replaces`

从已收集文件中移除指定源文件，再由当前 Source Set 加入 stub：

```lua
counter_stub = {
  files = { "stubs/counter.sv" },
  replaces = { "rtl/counter.sv" },
  depends_on = { "rtl" },
}
```

### `exclude`

排除生成目录、输出目录或指定文件：

```lua
exclude = {
  "build",
  "output",
  "rtl/unused_block.sv",
}
```

### `optional`

文件和目录都支持 `{ path = "...", optional = true }`：

```lua
files = {
  "rtl/demo_top.sv",
  { path = "generated/registers.sv", optional = true },
}
```

## Profile 字段参考

### `source_sets`

必须显式列出启用的 Source Set。空列表会生成空文件集合。

```lua
source_sets = { "rtl", "vendor_models" }
```

### `top`

指定 Slang 顶层模块，但不会自动收集模块依赖：

```lua
top = "demo_top"
```

插件会在活动 Profile 的索引中查找同名 `module`。只有定义唯一时，才将
对应源码路径发送给 `slang.setTopLevel`。发送前，插件会先把活动 Profile
的全部源码同步到 Slang 工作区索引，再等待 build file 加载成功。模块缺失
或存在同名定义时，插件保留已加载的 build file，并提示检查 Profile 与
文件集合。

### `defines`

添加当前 Profile 专用宏：

```lua
defines = { SIMULATION = true }
```

### `include_dirs`

添加当前 Profile 专用头文件目录：

```lua
include_dirs = { "tb/include" }
```

### `flags`

添加当前 Profile 专用参数：

```lua
flags = { "--compat vcs" }
```

### `lint`

指定当前 Profile 使用的 lint 配置：

```lua
lint = { config = ".svlint.toml" }
```

### `default_profile`

`default_profile` 决定首次加载时的默认 Profile。使用
`:FpgaSvProfile [name]` 切换后，插件会在 `<state>/fpga_sv` 保存当前
选择，并重新激活对应 `.f`。

## 通用配置用例

### 1. 单一 RTL 目录

```lua
source_sets = {
  rtl = {
    roots = { "rtl" },
  },
}
```

### 2. RTL 与模型分离

```lua
source_sets = {
  rtl = {
    roots = { "rtl" },
  },
  vendor_models = {
    roots = { "vendor" },
    globs = { "**/*.sv", "**/*.v" },
  },
},
profiles = {
  default = {
    source_sets = { "rtl", "vendor_models" },
    top = "demo_top",
  },
},
```

### 3. 只加入指定模型

```lua
vendor_models = {
  files = {
    "vendor/clock_core.v",
    "vendor/memory_model.sv",
  },
}
```

### 4. 综合与仿真 Profile

```lua
source_sets = {
  rtl = {
    roots = { "rtl" },
  },
  simulation = {
    roots = { "tb" },
    depends_on = { "rtl" },
  },
},
profiles = {
  synth = {
    source_sets = { "rtl" },
    top = "demo_top",
  },
  sim = {
    source_sets = { "simulation" },
    top = "demo_top_tb",
  },
},
default_profile = "synth",
```

### 5. 已有 filelist

```lua
source_sets = {
  existing_build = {
    filelists = { "config/project.f" },
  },
},
profiles = {
  default = {
    source_sets = { "existing_build" },
  },
},
```

### 6. 可选生成文件

```lua
files = {
  "rtl/demo_top.sv",
  { path = "generated/registers.sv", optional = true },
}
```

### 7. 列表覆盖操作

列表默认追加并稳定去重，也支持 `add`、`remove` 和 `replace`：

```lua
include_dirs = {
  add = { "include/common" },
  remove = { "include/obsolete" },
}
```

## 生成产物

活动 Profile 会生成三类信息：

- 项目 `.f`：`<project>/.nvim/fpga-sv/<profile>.f`，保存可移植配置。
- 本地 `.f`：`<state>/fpga_sv/projects/<project-id>/generated/<profile>.f`，
  保存机器相关增量，并通过 `-F` 引用项目 `.f`。
- `slang.json`：记录 Profile、build file 和 top，供插件恢复活动状态。

项目 `.f` 的正确示例：

```text
// generated by nvim_fpga_sv; DO NOT EDIT
-Iinclude
-DDEMO_BUILD
rtl/demo_top.sv
rtl/counter.sv
vendor/clock_core.v
```

本地 `.f` 至少包含：

```text
// generated by nvim_fpga_sv; DO NOT EDIT
-F <project>/.nvim/fpga-sv/default.f
```

空 `.f` 示例：

```text
// generated by nvim_fpga_sv; DO NOT EDIT
```

常见原因：

- Profile 未选择任何 Source Set。
- Source Set 名称拼写错误。
- `globs` 没有匹配文件。
- 路径被 `exclude` 排除。

插件不会创建、覆盖或迁移外部 `.slang/server.json`。该文件可以继续保存
索引、hover 等 Slang 设置；插件生成的活动 `.f` 决定实际编译文件。插件会
通过 LSP 通知把活动 Profile 的全部源码同步到 Slang 工作区索引，用户无需
在 `.slang/server.json` 中用 glob 重复覆盖同一份 filelist。

## Slang 生命周期

插件复用标准 `slang_server` 配置，不创建第二个自定义 Slang 客户端。

```text
slang_server 附着缓冲区
        ↓
识别缓冲区所属 <project>
        ↓
发送 workspace/didChangeWatchedFiles
同步活动 Profile 全部源码（Changed）
        ↓
发送 slang.setBuildFile
        ↓
等待服务器成功回调
        ↓
将 top 模块名解析为唯一源码路径
        ↓
发送 slang.setTopLevel
```

同一客户端、Profile、工程生成版本和 top 只激活一次，避免 `FileType` 与
`LspAttach` 重复发送。Profile 切换或重新生成后会重新同步。索引通知无法
发送时，插件只加载完整 build file，不自动设置 top，避免重新产生
`unknown module`。

当前现场验证基线为 Neovim `0.12.4` 与 slang-server `0.2.9`。

以下操作会重新发送活动构建信息：

- `slang_server` 完成 `LspAttach`。
- 执行 `:FpgaSvGenerate`。
- 执行 `:FpgaSvRefresh` 或保存已信任的配置。
- 使用 `:FpgaSvProfile` 切换 Profile。

插件初始化时也会补挂载已经打开的 Verilog/SystemVerilog 缓冲区。同一
缓冲区只保留一个标准 Slang 客户端，避免重复诊断。可用 `:LspInfo`
检查客户端数量。

SystemVerilog/Verilog 缓冲区默认使用 `gd` 执行
`:FpgaSvDefinition`，并将标准 `textDocument/definition` 请求发送给
当前附着的 `slang_server`。已有的用户或 LazyVim `gd` 映射不会被覆盖：

```lua
keymaps = {
  definition = "gd", -- 设为 false 可禁用
}
```

若当前缓冲区没有 Slang 客户端，或服务器没有返回定义，提示会包含活动
Profile，并引导检查生成的 `.f` 是否包含目标源码。

## 端口提示

提示使用 Neovim virtual text，不会写入源文件。模块声明提示的位置由
`hints.position` 控制；例化提示始终使用 inline virtual text。

模块声明显示效果：

```systemverilog
module counter (
  input  logic        clk,                ← IN
  input  logic [15:0] input_data,         ← IN [15:0]
  output logic [31:0] output_data [3:0],  → OUT [31:0] [3:0]
  stream_if.master    master_port         ◇ IF stream_if.master
);
```

普通命名连接：

```systemverilog
counter u_counter (
  .clk         (← IN system_clk),
  .input_data  (← IN [15:0] source_data),
  .output_data (→ OUT [31:0] [3:0] result_array),
  .master_port (◇ IF stream_if.master stream_bus)
);
```

modport 保留完整类型：

```systemverilog
.master_port (◇ IF stream_if.master master_bus),
.slave_port  (◇ IF stream_if.slave slave_bus)
```

参数化例化和实例数组同样支持：

```systemverilog
counter #(
  .WIDTH(16)
) u_counter [3:0] (
  .clk        (← IN system_clk),
  .input_data (← IN [15:0] source_data)
);
```

简写连接和位置连接会在对应表达式旁显示方向。自动连接只显示
`AUTO:*`，不会伪造逐端口方向：

```systemverilog
counter u_counter (
  .clk (← IN),
  .* AUTO:*
);
```

模块定义缺失或定义不唯一时，插件不会显示推测结果。

配置项：

- `hints.enabled`：总开关。
- `hints.directions`：显示 input/output/inout/ref 方向。
- `hints.dimensions`：显示 packed/unpacked 数组维度。
- `hints.interfaces`：显示 interface 与 modport。
- `hints.summary`：显示模块声明端口统计。
- `hints.automatic`：为 `.*` 显示 `AUTO:*`。
- `hints.text`：覆盖默认方向文字。
- `hints.highlights`：覆盖高亮组。
- `hints.position`：仅控制模块声明提示位置。

自定义文字：

```lua
hints = {
  text = {
    input = "< IN",
    output = "> OUT",
    inout = "<> INOUT",
    ref = "REF",
    interface = "IF",
  },
}
```

默认文字为：

```text
← IN
→ OUT
↔ INOUT
↕ REF
◇ IF
```

## 命令

- `:FpgaSvProfile [name]`：切换活动 Profile。
- `:FpgaSvGenerate`：生成全部 Profile，并重新通知 Slang。
- `:FpgaSvProjectInfo`：显示工程、错误、文件数量与产物。
- `:FpgaSvDefinition`：通过当前 `slang_server` 跳转到定义。
- `:FpgaSvInstantiate [module]`：生成命名端口例化。
- `:FpgaSvExpand`：展开位置连接、`.port` 与 `.*`。
- `:FpgaSvHints`：开关并刷新端口提示。
- `:FpgaSvTop [module]`：将模块名解析为唯一源码路径后通知 Slang。
- `:FpgaSvLint`：lint 当前文件。
- `:FpgaSvLintProject`：lint 活动 Profile，结果写入 quickfix。
- `:FpgaSvTemplate <name>`：展开原生 `vim.snippet` 模板。
- `:FpgaSvNext [kind]` / `:FpgaSvPrev [kind]`：结构导航。
- `:FpgaSvSelect <kind>`：选择当前结构。
- `:checkhealth fpga_sv`：检查 parser、工具与本地产物。

兼容别名包括 `SVInstantiate`、`SVProjectInfo`、`SVSlangSetBuild`、
`SVSlangSetTop` 和 `SVPortDirectionsToggle`。

## 排错指南

### 文件存在但模块未知

1. 检查活动 Profile。
2. 检查 Profile 是否选择对应 Source Set。
3. 检查 `:FpgaSvProjectInfo` 中的文件数量。
4. 检查生成 `.f` 是否包含目标文件。
5. 确认没有误把源码目录写入 `include_dirs`。

`unknown module` 通常属于文件集合问题；`timescale`、implicit net、
unused signal 等通常属于真实 HDL 源码问题。

### `gd` 没有跳转

1. 执行 `:LspInfo`，确认当前缓冲区附着 `slang_server`。
2. 检查活动 Profile 是否包含目标模块。
3. 检查生成的 `.f` 是否包含目标源码。
4. 若 `gd` 已由用户或 LazyVim 定义，可直接执行
   `:FpgaSvDefinition` 验证 Slang definition。

### 子目录模块能识别，直属文件不能识别

- 检查 Source Set 的 `globs` 是否包含 `*.sv`、`*.v` 等直属文件规则。
- 检查 `:FpgaSvProjectInfo` 的文件数量是否已包含直属文件。
- 插件会同步活动 Profile 全部源码到 Slang 索引，无需再为
  `.slang/server.json` 添加重复 glob。

### 每条诊断出现两次

执行 `:LspInfo`，确认当前缓冲区只有一个 `slang_server`。

### 没有端口方向提示

- 检查 `hints.enabled`。
- 检查当前文件是否属于活动 Profile。
- 检查模块端口是否成功索引。
- 执行 `:FpgaSvHints` 关闭后再次执行以刷新。

### 修改配置后未生效

- 执行 `:FpgaSvGenerate` 或 `:FpgaSvRefresh`。
- 检查项目配置是否已被信任。
- 检查 `:FpgaSvProjectInfo` 中的错误。

## 公共 API 与事件

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

公开 Lua API 与必填配置字段保持不变。

插件发布 `FpgaSvProfileChanged`、`FpgaSvProjectGenerated` 和
`FpgaSvIndexUpdated` 三个 `User` 事件。

## 边界

- 不在线安装外部工具。
- 不修改用户 HDL 工程源码。
- 不修改外部 Slang 配置。
- Conform 不存在时不实现第二套格式化器。
- `.f` 是编辑分析产物，不承诺工具链工程兼容性。
