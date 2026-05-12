--
-- RebaseBranchDialog Widget.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
local core = require "core"
local style = require "core.style"
local Button = require "widget.button"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local Line = require "widget.line"
local ListBox = require "widget.listbox"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"
local Widget = require "widget"

---@class plugins.scm.ui.RebaseBranchDialog : widget.dialog
---@field public project_dir string
---@field public branch plugins.scm.backend.branch
---@field public branches plugins.scm.backend.branch[]
---@field private branch_label widget.label
---@field private base_label widget.label
---@field private filter_textbox widget.textbox
---@field private list_container widget
---@field private list widget.listbox
---@field private strategy_label widget.label
---@field private strategy_container widget
---@field private strategy_list widget.listbox
---@field private line widget.line
---@field private rebase widget.button
---@field private cancel widget.button
---@overload fun(project_dir:string,branch:plugins.scm.backend.branch,branches:plugins.scm.backend.branch[]):plugins.scm.ui.RebaseBranchDialog
local RebaseBranchDialog = Dialog:extend()

---Constructor
---@param project_dir string
---@param branch plugins.scm.backend.branch
---@param branches plugins.scm.backend.branch[]
function RebaseBranchDialog:new(project_dir, branch, branches)
  RebaseBranchDialog.super.new(self, "Rebase Branch")

  self.type_name = "plugins.scm.ui.RebaseBranchDialog"
  self.project_dir = project_dir
  self.branch = branch
  self.branches = branches or {}

  self.branch_label = Label(self.panel, "Branch: " .. branch.name)
  self.base_label = Label(self.panel, "Rebase onto")
  self.filter_textbox = TextBox(self.panel, "", "filter base branches...")

  self.list_container = Widget(self.panel)
  self.list_container.border.width = 0
  self.list_container:set_size(500 * SCALE, 180 * SCALE)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Branch")
  self.list:add_column("Remote Origin")
  self.list:add_column("Last Modified")
  self.list:add_column("Last Commit")
  self.list:add_column("Message")

  self.strategy_label = Label(self.panel, "Conflict strategy")
  self.strategy_container = Widget(self.panel)
  self.strategy_container.border.width = 0
  self.strategy_container:set_size(500 * SCALE, 92 * SCALE)

  self.strategy_list = ListBox(self.strategy_container)
  self.strategy_list.border.width = 0
  self.strategy_list:enable_expand(true)
  self.strategy_list:add_column("Strategy")
  self.strategy_list:add_column("Description")

  self.line = Line(self.panel, 1, style.padding.x)
  self.rebase = Button(self.panel, "Rebase")
  self.rebase:set_icon(">")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  for _, item in ipairs(self.branches) do
    if item.name ~= branch.name then
      self:add_branch(item)
    end
  end
  if #self.list.rows > 0 then
    self.list:set_selected(1)
  end

  self:add_strategy("normal", "Normal", "Stop and report conflicts")
  self:add_strategy("ours", "Prefer Base Changes", "Use the base side when possible")
  self:add_strategy("theirs", "Prefer Branch Changes", "Use this branch side when possible")
  self.strategy_list:set_selected(1)

  local this = self

  self.filter_textbox.on_change = function(_, value)
    this.list:filter(value)
    if #this.list.rows > 0 and not this.list:get_selected() then
      this.list:set_selected(1)
    end
  end

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(list, button, x, y, clicks)
    ---@cast list widget.listbox
    list_on_mouse_pressed(list, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      this:submit()
    end
  end

  function self.rebase:on_click()
    this:submit()
  end

  function self.cancel:on_click()
    this:on_close()
  end
end

---Add a branch row to the base-branch list.
---@param branch plugins.scm.backend.branch
function RebaseBranchDialog:add_branch(branch)
  local remote = branch.remote or ""
  if branch.remote_only then
    remote = remote ~= "" and remote or branch.name
  end
  local date = branch.date or ""
  local commit = branch.commit or ""
  local message = branch.message or ""
  self.list:add_row({
    style.syntax.keyword, branch.name,
    ListBox.COLEND,
    style.syntax.literal, remote,
    ListBox.COLEND,
    style.syntax.literal, date,
    ListBox.COLEND,
    style.syntax.string, commit:sub(1, 12),
    ListBox.COLEND,
    style.text, message
  }, branch)
end

---@param value plugins.scm.backend.rebasestrategy
---@param label string
---@param description string
function RebaseBranchDialog:add_strategy(value, label, description)
  self.strategy_list:add_row({
    style.syntax.keyword, label,
    ListBox.COLEND,
    style.text, description
  }, value)
end

---@return plugins.scm.backend.branch?
function RebaseBranchDialog:get_selected_branch()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

---@return plugins.scm.backend.rebasestrategy
function RebaseBranchDialog:get_selected_strategy()
  local idx = self.strategy_list:get_selected()
  if idx then
    return self.strategy_list:get_row_data(idx)
  end
  return "normal"
end

function RebaseBranchDialog:submit()
  local base_branch = self:get_selected_branch()
  if not base_branch then
    MessageBox.error("SCM Rebase Branch", "Select a base branch.")
    return
  end

  self:on_rebase(self.branch.name, base_branch.name, self:get_selected_strategy())
  self:on_close()
end

---Called when the user clicks Rebase.
---@param branch string
---@param base_branch string
---@param strategy plugins.scm.backend.rebasestrategy
function RebaseBranchDialog:on_rebase(branch, base_branch, strategy) end

function RebaseBranchDialog:on_close()
  RebaseBranchDialog.super.on_close(self)
  self:destroy()
end

function RebaseBranchDialog:update_size_position()
  RebaseBranchDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.max(640 * SCALE, core.root_view.size.x * 0.48)
  local height = math.max(520 * SCALE, core.root_view.size.y * 0.58)
  self:set_size(width, height)
  self.panel:set_size(
    width,
    height - self.title:get_height() - style.padding.y
  )
  local panel_height = self.panel:get_height()

  self.branch_label:set_position(padding, 0)

  self.base_label:set_position(padding, self.branch_label:get_bottom() + style.padding.y)
  self.filter_textbox:set_position(padding, self.base_label:get_bottom() + style.padding.y / 2)
  self.filter_textbox:set_size(width - style.padding.x, self.filter_textbox:get_real_height())

  local buttons_y = panel_height - self.rebase:get_height() - (style.padding.y / 2)
  self.line:set_position(0, buttons_y - style.padding.y)

  local strategy_height = 92 * SCALE
  local strategy_y = self.line:get_position().y - strategy_height - style.padding.y
  self.strategy_label:set_position(
    padding,
    strategy_y - self.strategy_label:get_height() - style.padding.y / 2
  )
  self.strategy_container:set_position(padding, strategy_y)
  self.strategy_container:set_size(width - style.padding.x, strategy_height)
  self.strategy_list:resize_to_parent()

  self.list_container:set_position(padding, self.filter_textbox:get_bottom() + style.padding.y)
  self.list_container:set_size(
    width - style.padding.x,
    math.max(
      120 * SCALE,
      self.strategy_label:get_position().y
        - self.list_container:get_position().y
        - style.padding.y
    )
  )
  self.list:resize_to_parent()

  self.rebase:set_position(padding, buttons_y)
  self.cancel:set_position(self.rebase:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return RebaseBranchDialog
