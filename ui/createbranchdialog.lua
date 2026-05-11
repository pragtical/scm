--
-- CreateBranchDialog Widget.
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
local ListBox = require "widget.listbox"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"
local Widget = require "widget"

---@class plugins.scm.ui.CreateBranchDialog : widget.dialog
---@field public project_dir string
---@field public branches plugins.scm.backend.branch[]
---@field private branch_label widget.label
---@field private branch_textbox widget.textbox
---@field private base_label widget.label
---@field private filter_textbox widget.textbox
---@field private list_container widget
---@field private list widget.listbox
---@field private checkout widget.checkbox
---@field private line widget.line
---@field private create widget.button
---@field private cancel widget.button
---@overload fun(project_dir:string,branches:plugins.scm.backend.branch[]):plugins.scm.ui.CreateBranchDialog
local CreateBranchDialog = Dialog:extend()

---Constructor
---@param project_dir string
---@param branches plugins.scm.backend.branch[]
function CreateBranchDialog:new(project_dir, branches)
  CreateBranchDialog.super.new(self, "Create Branch")

  self.type_name = "plugins.scm.ui.CreateBranchDialog"
  self.project_dir = project_dir
  self.branches = branches or {}

  self.branch_label = Label(self.panel, "Branch name")
  self.branch_textbox = TextBox(self.panel, "", "new branch name...")
  self.base_label = Label(self.panel, "Base branch")
  self.filter_textbox = TextBox(self.panel, "", "filter base branches...")

  self.list_container = Widget(self.panel)
  self.list_container.border.width = 0
  self.list_container:set_size(500 * SCALE, 220 * SCALE)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Branch")
  self.list:add_column("Remote Origin")
  self.list:add_column("Last Modified")
  self.list:add_column("Last Commit")
  self.list:add_column("Message")

  self.checkout = CheckBox(self.panel, "Checkout after creation")
  self.line = Line(self.panel, 1, style.padding.x)
  self.create = Button(self.panel, "Create")
  self.create:set_icon("+")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  for _, branch in ipairs(self.branches) do
    self:add_branch(branch)
  end
  if #self.branches > 0 then
    self.list:set_selected(1)
  end

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

  function self.create:on_click()
    this:submit()
  end

  function self.cancel:on_click()
    this:on_close()
  end
end

---Add a branch row to the base-branch list.
---@param branch plugins.scm.backend.branch
function CreateBranchDialog:add_branch(branch)
  local remote = branch.remote or ""
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

---@return plugins.scm.backend.branch?
function CreateBranchDialog:get_selected_branch()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

function CreateBranchDialog:submit()
  local branch = self.branch_textbox:get_text():match("^%s*(.-)%s*$")
  local base_branch = self:get_selected_branch()
  if not branch or branch == "" then
    MessageBox.error("SCM Create Branch", "Enter a branch name.")
    return
  end
  if not base_branch then
    MessageBox.error("SCM Create Branch", "Select a base branch.")
    return
  end

  self:on_create(branch, base_branch.name, self.checkout:is_checked())
  self:on_close()
end

---Called when the user clicks Create.
---@param branch string
---@param base_branch string
---@param checkout boolean
function CreateBranchDialog:on_create(branch, base_branch, checkout) end

function CreateBranchDialog:on_close()
  CreateBranchDialog.super.on_close(self)
  self:destroy()
end

function CreateBranchDialog:update_size_position()
  CreateBranchDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.max(600 * SCALE, core.root_view.size.x * 0.45)
  local height = math.max(420 * SCALE, core.root_view.size.y * 0.5)
  self:set_size(width, height)
  local panel_height = self.panel:get_height()

  self.branch_label:set_position(padding, 0)
  self.branch_textbox:set_position(padding, self.branch_label:get_bottom() + style.padding.y / 2)
  self.branch_textbox:set_size(width - style.padding.x, self.branch_textbox:get_real_height())

  self.base_label:set_position(padding, self.branch_textbox:get_bottom() + style.padding.y)
  self.filter_textbox:set_position(padding, self.base_label:get_bottom() + style.padding.y / 2)
  self.filter_textbox:set_size(width - style.padding.x, self.filter_textbox:get_real_height())

  local buttons_y = panel_height - self.create:get_height() - (style.padding.y / 2)

  self.checkout:set_position(
    padding,
    buttons_y - self.checkout:get_height() - style.padding.y
  )

  self.line:set_position(0, self.checkout:get_position().y - style.padding.y)

  self.list_container:set_position(padding, self.filter_textbox:get_bottom() + style.padding.y)
  self.list_container:set_size(
    width - style.padding.x,
    math.max(120 * SCALE, self.line.position.y - self.list_container.position.y - style.padding.y)
  )
  self.list:resize_to_parent()

  self.create:set_position(padding, buttons_y)
  self.cancel:set_position(self.create:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return CreateBranchDialog
