local core = require "core"
local style = require "core.style"
local Widget = require "widget"
local Dialog = require "widget.dialog"
local ListBox = require "widget.listbox"
local Button = require "widget.button"
local MessageBox = require "widget.messagebox"

---@class plugins.scm.ui.RewriteDialog : widget.dialog
local RewriteDialog = Dialog:extend()

function RewriteDialog:new(directory, backend, history, finished)
  RewriteDialog.super.new(self, "Rewrite Local History")
  self.plan, self.finished = {}, finished
  self.directory, self.backend = directory, backend
  self.close.on_click = function()
    self:on_close()
  end
  for i = #history, 1, -1 do
    self.plan[#self.plan + 1] = {
      hash = history[i].hash,
      action = "pick",
      summary = history[i].summary,
    }
  end
  self.container = Widget(self.panel)
  self.list = ListBox(self.container)
  self.list:enable_expand(true)
  self.buttons = {}
  local function button(label, fn)
    local control = Button(self.panel, label)
    control.on_click = fn
    self.buttons[#self.buttons + 1] = control
  end
  for _, action in ipairs({ "pick", "squash", "drop" }) do
    button(action, function()
      local i = self.list:get_selected()
      if self.plan[i] then
        self.plan[i].action = action
        self:reload(i)
      end
    end)
  end
  for _, direction in ipairs({ -1, 1 }) do
    button(direction < 0 and "Up" or "Down", function()
      local i = self.list:get_selected()
      if not i or not self.plan[i + direction] then
        return
      end
      self.plan[i], self.plan[i + direction] =
        self.plan[i + direction], self.plan[i]
      self:reload(i + direction)
    end)
  end
  button("Rewrite...", function()
    if self.busy then
      return
    end
    MessageBox.warning(
      "SCM Rewrite History",
      "Rewrite these local commits? A scm-backup branch will preserve "
        .. "the original tip. Shared commits and merges are rejected.",
      function(_, id)
        if id ~= 1 then
          return
        end
        self.busy = true
        backend:rewrite_history(
          directory,
          self.plan,
          function(ok, errmsg, backup)
            self.busy = false
            if backup then
              core.log("SCM: history backup: %s", backup)
            end
            if not ok then
              MessageBox.error("SCM Rewrite", errmsg)
            end
            if finished then
              finished(ok)
            end
            require("plugins.scm").open_workbench(directory)
            self:on_close()
          end
        )
      end,
      MessageBox.BUTTONS_YES_NO
    )
  end)
  button("Cancel", function()
    self:on_close()
  end)
  self:reload(1)
end

function RewriteDialog:reload(selected)
  self.list:clear()
  self.list.columns = {}
  self.list:add_column "Action"
  self.list:add_column "Commit"
  self.list:add_column "Message"
  for _, item in ipairs(self.plan) do
    self.list:add_row({
      item.action,
      ListBox.COLEND,
      item.hash:sub(1, 10),
      ListBox.COLEND,
      item.summary,
    })
  end
  self.list:set_selected(selected)
  core.redraw = true
end

function RewriteDialog:on_close()
  if not self.busy then
    RewriteDialog.super.on_close(self)
  end
end

function RewriteDialog:update_size_position()
  RewriteDialog.super.update_size_position(self)
  local gap = style.padding.x
  local width = math.min(760 * SCALE, core.root_view.size.x - gap * 3)
  local height = math.min(420 * SCALE, core.root_view.size.y - gap * 5)
  self.container:set_position(gap / 2, 0)
  self.container:set_size(width - gap, height - 100 * SCALE)
  self.list:resize_to_parent()
  local x, y = gap / 2, self.container:get_height() + gap
  for _, button in ipairs(self.buttons) do
    if x + button:get_width() > width - gap then
      x, y = gap / 2, y + button:get_height() + gap / 2
    end
    button:set_position(x, y)
    x = x + button:get_width() + gap / 2
  end
  self.panel:set_size(width, y + 50 * SCALE)
  self.size.x, self.size.y = width, self.panel.size.y + 40 * SCALE
  self.close:set_position(width - self.close:get_width() - gap / 2, gap / 2)
end

return RewriteDialog
