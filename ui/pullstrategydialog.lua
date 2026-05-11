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
  local width = math.max(560 * SCALE, core.root_view.size.x * 0.42)
  local height = math.max(270 * SCALE, core.root_view.size.y * 0.28)
  self:set_size(width, height)
  self.panel:set_size(
    width,
    height - self.title:get_height() - style.padding.y
  )
  local panel_height = self.panel:get_height()
  local buttons_y = panel_height - self.merge:get_height() - (style.padding.y / 2)
  local remember_y = buttons_y - self.remember:get_height() - style.padding.y
  local line_y = remember_y - style.padding.y

  self.message:set_position(padding, 0)
  self.message:set_size(
    width - style.padding.x,
    math.max(self.message:get_font():get_height(), line_y - style.padding.y)
  )

  self.remember:set_position(padding, remember_y)
  self.line:set_position(0, line_y)

  self.merge:set_position(padding, buttons_y)
  self.rebase:set_position(self.merge:get_right() + style.padding.x, buttons_y)
  self.ff_only:set_position(self.rebase:get_right() + style.padding.x, buttons_y)
  self.cancel:set_position(self.ff_only:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return PullStrategyDialog
