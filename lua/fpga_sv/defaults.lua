local M = {}

function M.get()
  local state = vim.fn.stdpath("state")
  local config = vim.fn.stdpath("config")

  return {
    global_config = vim.fs.joinpath(config, "fpga-sv.lua"),
    project_file = ".nvim-fpga.lua",
    state_dir = vim.fs.joinpath(state, "fpga_sv"),
    project_output_dir = vim.fs.joinpath(".nvim", "fpga-sv"),
    default_profile = "default",
    source_sets = {},
    profiles = {
      default = {
        source_sets = {},
        defines = {},
        include_dirs = {},
        flags = {},
      },
    },
    tools = {
      slang = {
        enabled = true,
        cmd = "slang-server",
        settings = {
          slang = {
            diagnostics = true,
            portTypes = false,
          },
        },
      },
      svlint = {
        enabled = true,
        cmd = "svlint",
        args = { "--oneline" },
        include_arg = "-I",
        define_arg = "-D",
        filelist_arg = "-f",
      },
      verible = {
        enabled = true,
        cmd = "verible-verilog-format",
        args = { "-" },
      },
    },
    hints = {
      enabled = true,
      directions = true,
      dimensions = true,
      interfaces = true,
      summary = true,
      automatic = true,
      position = "eol",
      priority = 120,
      delay = 120,
      text = {
        input = "IN ←",
        output = "OUT →",
        inout = "INOUT ↔",
        ref = "REF ↕",
        interface = "IF ◇",
      },
      highlights = {
        input = "FpgaSvPortInput",
        output = "FpgaSvPortOutput",
        inout = "FpgaSvPortInout",
        ref = "FpgaSvPortRef",
        interface = "FpgaSvPortInterface",
        summary = "FpgaSvPortSummary",
      },
    },
    instantiate = {
      instance_name = "u_%s",
      connection = "same_name",
      parameter = "same_name",
      empty_connection = "",
      align = true,
    },
    indent = {
      module = 2,
      preprocessor = 0,
      width = 2,
    },
    scan = {
      batch_size = 200,
    },
    keymaps = {
      profile = "<leader>vp",
      generate = "<leader>vg",
      instantiate = "<leader>vi",
      expand = "<leader>ve",
      refresh = "<leader>vr",
      hints = "<leader>vd",
      lint = "<leader>vl",
    },
    adapters = {
      slang = true,
      svlint = true,
      verible = true,
      lazyvim = true,
    },
  }
end

return M
