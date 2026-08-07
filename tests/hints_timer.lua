vim.opt.runtimepath:prepend(vim.fn.getcwd())

local scheduled = {}
local created_timers = {}
local build_count = 0
local refresh_count = 0

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(("%s: 期望 %s，实际 %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function new_timer()
  local timer = {
    closing = false,
    stop_count = 0,
    close_count = 0,
  }

  function timer:start(_, _, callback)
    self.callback = callback
  end

  function timer:stop()
    self.stop_count = self.stop_count + 1
  end

  function timer:close()
    if self.closing then
      error("handle " .. tostring(self) .. " is already closing")
    end
    self.closing = true
    self.close_count = self.close_count + 1
  end

  function timer:is_closing()
    return self.closing
  end

  created_timers[#created_timers + 1] = timer
  return timer
end

local original_uv = vim.uv
local original_schedule_wrap = vim.schedule_wrap
local original_indexer = package.loaded["fpga_sv.index"]
local original_features = package.loaded["fpga_sv.features"]

local ok, err = xpcall(function()
  vim.uv = { new_timer = new_timer }
  vim.schedule_wrap = function(callback)
    return function()
      scheduled[#scheduled + 1] = callback
    end
  end

  package.loaded["fpga_sv.index"] = {
    build = function()
      build_count = build_count + 1
    end,
  }
  package.loaded["fpga_sv.features"] = nil

  local features = require("fpga_sv.features")
  features.refresh_hints = function()
    refresh_count = refresh_count + 1
  end

  local workspace = {
    active_profile = "default",
    config = {
      effective = {
        hints = {
          delay = 120,
        },
      },
    },
    models = {
      default = {
        full = {},
      },
    },
  }
  local bufnr = vim.api.nvim_get_current_buf()

  features.schedule_hints(workspace, bufnr)
  assert_equal(1, #created_timers, "应创建首个提示定时器")

  -- 模拟 uv 回调已触发，但 vim.schedule_wrap 包装的主线程回调仍在队列中。
  created_timers[1].callback()
  assert_equal(1, #scheduled, "旧定时器回调应进入调度队列")

  features.schedule_hints(workspace, bufnr)
  assert_equal(2, #created_timers, "新事件应创建替代定时器")
  assert_equal(1, created_timers[1].stop_count, "替换时应停止旧定时器")
  assert_equal(1, created_timers[1].close_count, "替换时应关闭旧定时器")

  table.remove(scheduled, 1)()
  assert_equal(1, created_timers[1].close_count, "过期回调不得重复关闭旧定时器")
  assert_equal(0, build_count, "过期回调不得重建索引")
  assert_equal(0, refresh_count, "过期回调不得刷新提示")

  created_timers[2].callback()
  assert_equal(1, #scheduled, "最新定时器回调应进入调度队列")
  table.remove(scheduled, 1)()

  assert_equal(1, created_timers[2].stop_count, "最新回调应停止自身定时器")
  assert_equal(1, created_timers[2].close_count, "最新回调应关闭自身定时器")
  assert_equal(1, build_count, "最新回调应仅重建一次索引")
  assert_equal(1, refresh_count, "最新回调应仅刷新一次提示")
end, debug.traceback)

vim.uv = original_uv
vim.schedule_wrap = original_schedule_wrap
package.loaded["fpga_sv.index"] = original_indexer
package.loaded["fpga_sv.features"] = original_features

if not ok then
  error(err)
end

print("[OK] hints timer debounce regression")
