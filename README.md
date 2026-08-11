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

## 配置放在哪里

插件把配置分成四个边界。先按“是否需要提交、是否依赖当前机器”判断，
不要把所有选项都塞进 `.nvim-fpga.lua`：

```text
插件全局配置
├── <stdpath("config")>/fpga-sv.lua
└── require("fpga_sv").setup({...})
    工具路径、提示、按键、适配器等跨项目选项

本机器件目录
└── <stdpath("config")>/fpga-sv-devices.lua
    多工程共享的厂商模型绝对路径和器件依赖

项目共享配置
└── <project>/.nvim-fpga.lua
    可提交的 RTL、stub、Source Set、Profile 和项目级编译参数

项目本机配置
└── :FpgaSvEditLocalConfig
    当前工程独有的本机工具路径和私有覆盖
```

最终配置按以下顺序合并，右侧覆盖左侧；列表默认追加并稳定去重：

```text
内置默认值 < 全局文件 < setup() < 项目共享配置 < 项目本机配置
```

### 插件全局配置

全局文件固定为 `<stdpath("config")>/fpga-sv.lua`。它必须返回 table，
适合保存所有项目通用的工具程序路径：

```lua
return {
  tools = {
    slang = { cmd = "slang-server" },
    svlint = { cmd = "svlint" },
    verible = { cmd = "verible-verilog-format" },
  },
}
```

插件管理器中的 `setup()` 也是全局层，适合提示、按键和适配器：

```lua
require("fpga_sv").setup({
  hints = {
    enabled = true,
    delay = 120,
  },
  keymaps = {
    generate = "<leader>vg",
    refresh = "<leader>vr",
  },
})
```

若工具路径只在某台机器成立，也可以把 `tools` 写进项目本机配置；不要把
个人绝对路径提交到项目共享配置。

### 本机器件目录

执行 `:FpgaSvEditDeviceCatalog` 打开器件目录。默认路径是
`<stdpath("config")>/fpga-sv-devices.lua`，可用
`device_catalog_file` 自定义。目录独立加载，不参与项目配置合并：

```lua
-- 更换厂商工具版本或安装位置时，只修改这一行。
local vendor_root =
  [[D:\FPGA\Vendor\Toolchain_Release]]

local family_root = vim.fs.joinpath(
  vendor_root,
  "simulation",
  "family_a"
)

return {
  vendor_family_a = {
    module_files = {
      VENDOR_CLOCK_BUFFER =
        vim.fs.joinpath(family_root, "clock_models.v"),
    },
    library_dirs = {
      family_root,
    },
    library_extensions = { ".v", ".sv" },
  },
}
```

`depends_on` 是有序器件 ID 列表，支持多级、多父级和共享依赖去重。
`module_files` 将模块名映射到合并模型文件；只有活动 Profile 实际例化
对应模块时才加入本地 `.f`，并递归加载已映射的模型依赖。同一映射文件
稳定去重，循环实例关系会安全终止。

推荐在目录顶部定义厂商 Root，再派生版本/系列 Root，最后编写器件条目。
一个目录可以定义多个 Root；厂商升级时只需修改对应的顶部变量，不需要
新增插件级 `root`/`roots` 配置。

所有器件路径必须是绝对路径。任一依赖缺失、字段无效或路径不可用时，
插件会原子跳过整套器件模型并继续生成项目 RTL；此时 Slang 仍可能报告
`unknown module`。

### 项目共享配置

`<project>/.nvim-fpga.lua` 由 `vim.secure.read()` 加载，可以提交到
仓库。最小示例：

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
      device = "amd_7series",
      top = "demo_top",
    },
  },
  default_profile = "default",
}
```

RTL、可提交的 stub、团队 Source Set/Profile，以及项目统一的宏、
include 目录、flags 和 timescale 相关编译参数，都应放在这一层。

### 项目本机配置

执行 `:FpgaSvEditLocalConfig` 打开当前项目的本机配置。文件实际位于
`<state>/fpga_sv/projects/<project-id>/config.lua`，不应提交到仓库。
器件安装路径应放入共享器件目录；本地配置保留给当前工程独有的本机工具
路径或私有覆盖。

修改任一层后执行 `:FpgaSvRefresh` 重新加载，或执行
`:FpgaSvGenerate` 重新生成全部 Profile 产物。

`.slang/server.json` 是 Slang 自身的配置文件，不属于插件项目配置，也
不能替代活动 Profile 生成的 `.f`。插件不会创建、覆盖或迁移它。

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

真实原语库和同名 stub 应由互斥 Profile 选择，不能同时进入活动构建。
配置边界和合并顺序见[配置放在哪里](#配置放在哪里)。

## 如何选择文件接入方式

先根据源码的组织方式选择字段：

```text
普通 RTL 源码目录
└── roots / files

已有工程文件清单
└── filelists

只有宏、类型、头文件
└── include_dirs

每个模块一个文件的原语库
└── library_dirs + library_extensions

多个模块合并在单个模型文件
└── files / filelists

模型缺失、加密或不便引入
└── 手写 stub + 独立 Profile
```

相对路径统一以工程根目录为基准。绝对路径受支持，但机器相关的厂商安装
路径不应写入共享的 `.nvim-fpga.lua`；请放入本地配置，并优先通过环境
变量传入。完整原语库示例见[FPGA 原语库配置](#fpga-原语库配置)，缺失
模型的处理见[手写 Stub 模块](#手写-stub-模块)。

## Source Set 字段参考

字段用于描述源码如何进入活动 Profile。若模块仍报告未知，按
[原语仍然 `unknown`](#原语仍然-unknown)的顺序检查。

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

### `module_files`（仅器件目录）

把模块名映射到包含该模块的绝对模型文件。插件复用实例解析器，仅在活动
Profile 实际例化模块时加入文件；已选模型中的映射依赖会继续递归解析。

```lua
module_files = {
  VENDOR_CLOCK_BUFFER =
    vim.fs.joinpath(family_root, "clock_models.v"),
}
```

键必须是合法模块名，值必须是存在的绝对文件路径。器件依赖先合并，后加载
器件的同名映射覆盖前面的公共依赖。映射文件只写入本地 `.f`，不会进入
可提交的项目 `.f`。

### `filelists`

导入已有 `.f`。嵌套 `-f` 或 `-F` 相对于当前 filelist 所在目录解析。

```lua
filelists = { "config/project.f" }
```

当前明确支持以下内容：

- Verilog/SystemVerilog 源文件路径。
- `-I`、`-D`、`-y`，以及它们与参数连写的形式。
- `+incdir`、`+define`、`+libext`。
- 嵌套 `-f`、`-F`，以及它们与路径连写的形式。

未知的 `-`/`+` 选项会作为 `flags` 保留，但“选项与参数分成两个 token”
的厂商专用语法不能可靠推断。遇到这类 `.f`，应把选项转换为
`include_dirs`、`defines`、`library_dirs`、`library_extensions`、
`flags` 等插件字段，或制作只保留编辑分析所需内容的 wrapper `.f`。

### `include_dirs`

生成 `-I`，只用于头文件搜索。把源码目录写入 `include_dirs` 不会编译
其中的模块。

```lua
include_dirs = { "include", "rtl/include" }
```

### `library_dirs`

生成 `-y`，配合 `library_extensions` 按模块名搜索库模块。它适合
“每个模块一个文件”的库目录，不适合多个模块合并在单个文件中的模型库。

```lua
library_dirs = { "vendor" }
```

厂商原语库的本地配置方式见[FPGA 原语库配置](#fpga-原语库配置)。

### `library_extensions`

生成 `+libext+...`。扩展名必须带点，例如 `.v`、`.sv`。

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

`--ignore-unknown-modules` 只能临时压制诊断，不能检查未知模块的参数和
端口；原语接入不应默认依赖它。

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

`replaces` 只作用于已经由 `roots`、`files` 或 `filelists` 收集到
`model.files` 的准确路径，不能移除仅通过 `library_dirs` 提供的模块。
详细顺序和限制见[高级用法：使用 `replaces` 替换具体模型文件](#高级用法使用-replaces-替换具体模型文件)。

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

### `device`

引用本机器件目录中的一个最终器件。Profile 不支持继承；器件公共部分通过
器件条目的 `depends_on` 组合：

```lua
device = "amd_7series"
```

合并顺序为“器件公共依赖 → 当前器件 → 项目 Source Set → Profile”。
后加载的同名 `defines` 覆盖前一层。

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

## FPGA 原语库配置

看到 `unknown module: device_pll` 时，先确认缺少的是模块定义，而不是
头文件。厂商原语库通常安装在每台机器不同的位置，应写入
`:FpgaSvEditDeviceCatalog` 打开的共享器件目录。项目配置只通过
`profile.device` 引用稳定器件 ID，不包含个人绝对路径。

路径规则：

- 器件目录中的 `files`、`filelists`、`roots`、`include_dirs` 和
  `library_dirs` 必须使用绝对路径；`module_files` 的值必须是存在的
  绝对文件路径。
- 绝对路径不应写入共享的 `.nvim-fpga.lua`。
- 推荐在器件目录顶部定义厂商 Root，再通过 `vim.fs.joinpath()` 派生
  版本 Root、系列 Root 和器件路径。

从未知模块到可分析工程的操作流程：

1. 在厂商安装目录中找到 Slang 能解析的 Verilog/SystemVerilog 仿真
   模型；加密网表或只供专用仿真器使用的格式通常不能直接使用。
2. 判断模型组织方式：每模块一文件、多模块合并文件，或厂商 `.f`。
3. 执行 `:FpgaSvEditDeviceCatalog`，建立 `device_primitives` 器件条目。
4. 在项目 Profile 中设置 `device = "device_primitives"`。
5. 执行 `:FpgaSvGenerate`，再用 `:FpgaSvProfile edit_vendor` 切换。
6. 执行 `:FpgaSvProjectInfo`，检查活动 Profile、Source Set、诊断和本地
   `.f`；本地 `.f` 中必须出现预期模型文件，或 `-y` 与 `+libext`。

下面的模型只用于 Slang 编辑分析。插件生成的 `.f` 不承诺可以直接用于
厂商仿真、综合或实现流程。

下面四种接入模式覆盖常见的原语库组织方式。

### 按模块选择合并模型文件

厂商把多个模块合并在少量大文件中，但工程只用其中一部分时，优先使用
`module_files`。它不会扫描整个厂商目录，也不会读取未命中的映射文件：

```lua
local vendor_root =
  [[D:\FPGA\Vendor\Toolchain_Release]]
local family_root = vim.fs.joinpath(
  vendor_root,
  "simulation",
  "family_a"
)

return {
  device_primitives = {
    module_files = {
      VENDOR_CLOCK_BUFFER =
        vim.fs.joinpath(family_root, "clock_models.v"),
    },
    library_dirs = { family_root },
    library_extensions = { ".v", ".sv" },
  },
}
```

如果 `clock_models.v` 又例化了另一个存在映射的模块，对应文件会递归加入。
`:FpgaSvProjectInfo` 显示本次实际命中的映射和依赖覆盖关系。

### 每个模块一个文件的库目录

当库目录按模块名拆分文件时，使用 `library_dirs` 和
`library_extensions`：

```lua
local primitive_root = assert(
  vim.env.FPGA_PRIMITIVE_LIB,
  "请设置 FPGA_PRIMITIVE_LIB"
)

return {
  device_primitives = {
    library_dirs = { primitive_root },
    library_extensions = { ".v", ".sv" },
  },
}
```

执行 `:FpgaSvGenerate` 后，本地 `.f` 中应出现类似内容：

```text
-y <primitive-library>
+libext+.v+.sv
```

`library_dirs` 适合 Slang 按模块名按需解析的库，不需要为了消除
`unknown module` 把整个库扫描进 `model.files`。

### 单个或少量合并模型文件

如果多个模块合并在一个模型文件中，不能依赖 `-y` 按模块名查找，必须用
`files` 显式加入：

```lua
local primitive_root = assert(
  vim.env.FPGA_PRIMITIVE_LIB,
  "请设置 FPGA_PRIMITIVE_LIB"
)

return {
  device_primitives = {
    files = {
      vim.fs.joinpath(
        primitive_root,
        "primitive_models.v"
      ),
    },
  },
}
```

生成后，`primitive_models.v` 的路径应作为源码行直接出现在本地 `.f`。

### 厂商提供 `.f` 文件

如果厂商已经提供模型 filelist，使用 `filelists`：

```lua
local primitive_root = assert(
  vim.env.FPGA_PRIMITIVE_LIB,
  "请设置 FPGA_PRIMITIVE_LIB"
)

return {
  device_primitives = {
    filelists = {
      vim.fs.joinpath(
        primitive_root,
        "primitive_models.f"
      ),
    },
  },
}
```

插件会解析 `.f` 中的源码、`-I`、`-D`、`-y`、`+incdir`、`+define`、
`+libext` 及嵌套 `-f`/`-F`，并把结果合并到当前模型。

厂商 `.f` 常包含只对专用仿真器有效的选项。若某个选项另带独立参数，
解析器可能把后一个 token 当成源码路径。此时应把有效信息转换为插件字段，
或新建精简 wrapper `.f`，只引用编辑分析需要的源码和嵌套 filelist。

### 如何判断字段是否选对

- `module_files` 适合按模块选择合并模型文件，避免扫描大型厂商目录。
- `library_dirs` 适合按模块拆文件并按需搜索的库。
- 合并模型文件必须通过 `files` 或 `filelists` 显式加入。
- `include_dirs` 只搜索 `` `include `` 文件，不能解决
  `unknown module`。
- `library_extensions` 必须写成带点的扩展名，例如 `.v`、`.sv`。

Slang 可以通过 `library_dirs` 按需解析模块，但插件自己的端口提示、
`:FpgaSvInstantiate` 和 `:FpgaSvExpand` 主要索引 `model.files`。如果需要
对某个原语使用这些功能，请用 `files` 显式加入所需模型文件，或提供轻量
stub。不建议为了端口提示扫描整个大型厂商库。

## 手写 Stub 模块

以下情况适合提供 stub：

- 原语模型未安装。
- 模型被加密，Slang 无法读取。
- 团队不能提交厂商模型。
- 编辑阶段只需消除 `unknown module` 并检查调用接口。

stub 没有插件专用格式。它就是普通 `.sv`/`.v` 源文件，通过 Source Set
的 `files` 加入；一个文件可以包含一个或多个 stub 模块。下面可保存为
`stubs/device_primitives.sv`：

```systemverilog
// 仅用于编辑分析，不用于仿真、综合或器件行为验证。
module device_pll #(
  parameter int unsigned MULTIPLY = 8,
  parameter int unsigned DIVIDE   = 1,
  parameter string       STARTUP  = "WAIT_LOCK"
) (
  input  logic refclk,
  input  logic reset,
  output logic outclk,
  output logic locked
);
endmodule

// 仅用于编辑分析，不用于仿真、综合或器件行为验证。
module device_buf #(
  parameter string BUFFER_TYPE = "GLOBAL"
) (
  input  logic i,
  output logic o
);
endmodule
```

示例模块名和接口是虚构的。落地时必须按工程实际调用和厂商文档逐项匹配：

- 模块名必须与厂商原语完全一致。
- 参数名必须覆盖工程中出现的全部参数覆盖。
- 命名端口的名称必须一致。
- 位置端口的数量和声明顺序必须一致。
- 端口方向、packed/unpacked 位宽、数组维度和
  interface/modport 必须一致。
- 只保留接口；不要实现时钟生成、锁定过程、延迟或器件行为。

### 使用独立 Stub Profile

项目共享配置定义可提交的 `primitive_stubs`，并把 `edit_stub` 设为默认
Profile：

```lua
return {
  source_sets = {
    rtl = {
      roots = { "rtl" },
    },
    primitive_stubs = {
      files = {
        "stubs/device_primitives.sv",
      },
    },
  },

  profiles = {
    edit_stub = {
      source_sets = { "rtl", "primitive_stubs" },
      top = "demo_top",
    },
  },

  default_profile = "edit_stub",
}
```

共享项目配置可同时定义引用真实器件的 `edit_vendor`：

```lua
return {
  profiles = {
    edit_vendor = {
      source_sets = { "rtl" },
      device = "device_primitives",
      top = "demo_top",
    },
  },
}
```

合并后的两个 Profile 结构如下：

```text
edit_stub
├── rtl
└── primitive_stubs

edit_vendor
├── rtl
└── device: device_primitives
```

同一 Profile 中不得同时启用真实原语库和同名 stub，否则 Slang 或插件索引
可能遇到重复模块定义。使用 `:FpgaSvProfile edit_stub` 或
`:FpgaSvProfile edit_vendor` 明确选择其中一种。

验证清单：

1. 用 `:FpgaSvProfile edit_stub` 和 `:FpgaSvProfile edit_vendor`
   分别切换，确认二者都能独立加载。
2. 执行 `:FpgaSvGenerate`，检查活动本地 `.f` 包含 stub 文件或真实库
   配置，不能同时包含二者。
3. 用 `:FpgaSvProjectInfo` 核对活动 Profile、Source Set 和文件数量。
4. 搜索同名 `module device_pll`、`module device_buf`，排除重复定义。
5. 对照 RTL 参数覆盖和端口连接，核对参数名、端口名、方向、位宽、数组
   以及位置端口顺序。
6. 重新检查诊断；stub 消除 `unknown module` 后，参数或端口错误仍应由
   Slang 报出。

### 高级用法：使用 `replaces` 替换具体模型文件

只有当真实模型已经由 `roots`、`files` 或 `filelists` 收集时，才使用
`replaces`：

```lua
primitive_stubs = {
  depends_on = { "vendor_models" },
  replaces = {
    "vendor/models/device_pll.v",
  },
  files = {
    "stubs/device_pll.sv",
  },
}
```

必须同时满足以下条件：

- stub Source Set 排在原 Source Set 之后，通常通过 `depends_on` 保证。
- `replaces` 填写被替换文件相对于工程根目录的准确路径。
- 被替换文件必须已经进入 `model.files`。
- 仅通过 `library_dirs` 提供的模块无法用 `replaces` 移除；这种情况必须
  使用互斥 Profile。

### 最后兜底：忽略未知模块

`flags = { "--ignore-unknown-modules" }` 可以暂时压制未知模块诊断，但
Slang 无法继续检查该模块的参数和端口名称。它只适合短期排查，不应作为
原语库或 stub 的常规替代方案。

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
- `:FpgaSvRefresh`：重新加载配置、生成产物并刷新活动工程。
- `:FpgaSvProjectInfo`：显示工程、实际命中的模块映射、文件数量与产物。
- `:FpgaSvEditGlobalConfig`：编辑插件全局配置。
- `:FpgaSvEditDeviceCatalog`：编辑本机共享器件目录。
- `:FpgaSvEditProjectConfig`：编辑可提交的项目配置。
- `:FpgaSvEditLocalConfig`：编辑不提交到仓库的机器本地配置。
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

### 原语仍然 `unknown`

1. 执行 `:FpgaSvProfile`，确认当前选择了真实库或 stub Profile。
2. 执行 `:FpgaSvGenerate`。
3. 用 `:FpgaSvProjectInfo` 检查 Source Set、文件数量和生成产物。
4. 检查实际命中的 `module_files`，以及本地 `.f` 中预期的 `-y`、
   `+libext`、模型文件或 stub 文件。
5. 确认没有把模块源码目录误放到 `include_dirs`。
6. 确认合并模型文件使用的是 `files` 或 `filelists`。
7. 搜索同名模块，排除真实模型与 stub 同时启用。
8. 检查 stub 的参数名、端口名和位置端口顺序。

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

先执行 `:LspInfo` 区分重复来源：

- 若当前缓冲区附着多个 `slang_server`，请检查重复的 LSP 配置或自动启用逻辑。
- 同时附着一个 `slang_server` 和一个 `verible` 属于正常情况；插件不会跨客户端合并诊断。
- 若只有一个 `slang_server`，旧版 Slang 可能在一次
  `textDocument/publishDiagnostics` 中发布精确重复项。插件会在该 Slang
  发布包内按完整 LSP Diagnostic 对象去重；位置、级别、代码、相关信息或
  `data` 不同的诊断仍会保留。

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
