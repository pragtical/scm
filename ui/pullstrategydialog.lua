--
-- PullStrategyDialog Widget.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
local core = require "core"
local style = require "core.style"
local Button = require "widget.button"
local CheckBox = require "widget.checkbox"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local Line = require "widget.line"
local Widget = require "widget"

---@class plugins.scm.ui.PullStrategyDialog : widget.dialog
---@field public project_dir string
---@field private message widget.label
---@field private remember widget.checkbox
---@field private line widget.line
---@field private merge widget.button
---@field private rebase widget.button
---@field private ff_only widget.button
---@field private cancel widget.button
---@field private submitted boolean
---@overload fun(project_dir:string,message?:string|widget.styledtext):plugins.scm.ui.PullStrategyDialog
local PullStrategyDialog = Dialog:extend()

---@param project_dir string
---@param message? string|widget.styledtext
function PullStrategyDialog:new(project_dir, message)
  PullStrategyDialog.super.new(self, "SCM Pull Strategy")

  self.type_name = "plugins.scm.ui.PullStrategyDialog"
  self.project_dir = project_dir
  self.submitted = false

  self.message = Label(self.panel, message)
  self.message.scrollable = true
  self.remember = CheckBox(self.panel, "Remember for this repository")
  self.line = Line(self.panel, 1, style.padding.x)
  self.merge = Button(self.panel, "Merge")
  self.rebase = Button(self.panel, "Rebase")
  self.ff_only = Button(self.panel, "Fast-forward Only")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  local this = self

  function self.merge:on_click()
    this:submit("merge")
  end

  function self.rebase:on_click()
    this:submit("rebase")
  end

  function self.ff_only:on_click()
    this:submit("ff-only")
  end

  function self.cancel:on_click()
    this:on_close()
  end
end

---@param strategy "merge"|"rebase"|"ff-only"
function PullStrategyDialog:submit(strategy)
  self.submitted = true
  self:on_select(strategy, self.remember:is_checked())
  self:on_close()
end

---@param strategy "merge"|"rebase"|"ff-only"
---@param remember boolean
function PullStrategyDialog:on_select(strategy, remember) end

function PullStrategyDialog:on_cancel() end

function PullStrategyDialog:on_close()
  if not self.submitted then
    self:on_cancel()
  end
  PullStrategyDialog.super.on_close(self)
  self:destroy()
end

function PullStrategyDialog:update_size_position()
  PullStrategyDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.min(
    core.root_view.size.x - 40 * SCALE,
    math.max(560 * SCALE, core.root_view.size.x * 0.42)
  )
  local height = math.min(
    core.root_view.size.y - 60 * SCALE,
    math.max(300 * SCALE, core.root_view.size.y * 0.28)
  )
  self:set_size(width, height)
  self.panel:set_size(width, height - self.title:get_height() - style.padding.y)
  local panel_height = self.panel:get_height()
  self.remember:set_wrap_width(width - style.padding.x)
  local controls = { self.merge, self.rebase, self.ff_only, self.cancel }
  local x, rows = padding, 1
  for _, control in ipairs(controls) do
    if x + control:get_width() > width - padding then
      x, rows = padding, rows + 1
    end
    control.layout_x, control.layout_row = x, rows
    x = x + control:get_width() + style.padding.x
  end
  local buttons_y = math.max(panel_height, 240 * SCALE)
    - rows * (self.merge:get_height() + style.padding.y)
  local remember_y = buttons_y - self.remember:get_height() - style.padding.y
  local line_y = remember_y - style.padding.y

  self.message:set_position(padding, 0)
  self.message:set_size(
    width - style.padding.x,
    math.max(self.message:get_font():get_height(), line_y - style.padding.y)
  )

  self.remember:set_position(padding, remember_y)
  self.line:set_position(0, line_y)

  for _, control in ipairs(controls) do
    control:set_position(
      control.layout_x,
      buttons_y
        + (control.layout_row - 1)
          * (self.merge:get_height() + style.padding.y)
    )
  end

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return PullStrategyDialog
