--
-- CreateTagDialog Widget.
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

---@class plugins.scm.ui.CreateTagDialog : widget.dialog
---@field public project_dir string
---@field public targets plugins.scm.backend.commit[]
---@field public tag_data plugins.scm.backend.tag?
---@field public editing boolean
---@field private tag_label widget.label
---@field private tag_textbox widget.textbox
---@field private target_label widget.label
---@field private filter_textbox widget.textbox
---@field private list_container widget
---@field private list widget.listbox
---@field private annotated widget.checkbox
---@field private message_label widget.label
---@field private message_textbox widget.textbox
---@field private line widget.line
---@field private create widget.button
---@field private cancel widget.button
---@overload fun(project_dir:string,targets:plugins.scm.backend.commit[],tag_data?:plugins.scm.backend.tag):plugins.scm.ui.CreateTagDialog
local CreateTagDialog = Dialog:extend()

---@param project_dir string
---@param targets plugins.scm.backend.commit[]
---@param tag_data? plugins.scm.backend.tag
function CreateTagDialog:new(project_dir, targets, tag_data)
  CreateTagDialog.super.new(self, tag_data and "Edit Tag" or "Create Tag")

  self.type_name = "plugins.scm.ui.CreateTagDialog"
  self.project_dir = project_dir
  self.targets = targets or {}
  self.tag_data = tag_data
  self.editing = tag_data ~= nil

  self.tag_label = Label(self.panel, "Tag name")
  self.tag_textbox = TextBox(self.panel, tag_data and tag_data.name or "", "new tag name...")
  self.target_label = Label(self.panel, "Target commit")
  self.filter_textbox = TextBox(self.panel, "", "filter commits...")

  self.list_container = Widget(self.panel)
  self.list_container.border.width = 0
  self.list_container:set_size(500 * SCALE, 180 * SCALE)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Commit")
  self.list:add_column("Author")
  self.list:add_column("Date")
  self.list:add_column("Summary")

  self.annotated = CheckBox(self.panel, "Annotated tag")
  if tag_data and tag_data.annotated then
    self.annotated:set_checked(true)
  end
  self.message_label = Label(self.panel, "Message")
  self.message_textbox = TextBox(self.panel, tag_data and tag_data.message or "", "tag message...")
  self.line = Line(self.panel, 1, style.padding.x)
  self.create = Button(self.panel, tag_data and "Update" or "Create")
  self.create:set_icon("+")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  for _, target in ipairs(self.targets) do
    self:add_target(target)
  end
  if #self.targets > 0 then
    self.list:set_selected(1)
    if tag_data and tag_data.commit then
      for idx, target in ipairs(self.targets) do
        if target.hash == tag_data.commit then
          self.list:set_selected(idx)
          break
        end
      end
    end
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

---@param target plugins.scm.backend.commit
function CreateTagDialog:add_target(target)
  local hash = target.hash or ""
  local author = target.author or ""
  local date = target.date or ""
  local summary = target.summary or ""
  self.list:add_row({
    style.syntax.string, hash:sub(1, 12),
    ListBox.COLEND,
    style.syntax.keyword, author,
    ListBox.COLEND,
    style.syntax.literal, date,
    ListBox.COLEND,
    style.text, summary
  }, target)
end

---@return plugins.scm.backend.commit?
function CreateTagDialog:get_selected_target()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

function CreateTagDialog:submit()
  local tag = self.tag_textbox:get_text():match("^%s*(.-)%s*$")
  local target = self:get_selected_target()
  local annotated = self.annotated:is_checked()
  local message = self.message_textbox:get_text():match("^%s*(.-)%s*$")
  if not tag or tag == "" then
    MessageBox.error("SCM Create Tag", "Enter a tag name.")
    return
  end
  if self.editing and self.tag_data and tag ~= self.tag_data.name then
    MessageBox.error("SCM Edit Tag", "Renaming tags is not supported.")
    return
  end
  if not target then
    MessageBox.error("SCM Create Tag", "Select a target.")
    return
  end
  if annotated and message == "" then
    MessageBox.error("SCM Create Tag", "Enter a message for the annotated tag.")
    return
  end

  self:on_create(tag, target.hash, annotated, message)
  self:on_close()
end

---@param tag string
---@param target string
---@param annotated boolean
---@param message string
function CreateTagDialog:on_create(tag, target, annotated, message) end

function CreateTagDialog:on_close()
  CreateTagDialog.super.on_close(self)
  self:destroy()
end

function CreateTagDialog:update_size_position()
  CreateTagDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.max(600 * SCALE, core.root_view.size.x * 0.45)
  local height = math.max(500 * SCALE, core.root_view.size.y * 0.58)
  self:set_size(width, height)
  local panel_height = self.panel:get_height()

  self.tag_label:set_position(padding, 0)
  self.tag_textbox:set_position(padding, self.tag_label:get_bottom() + style.padding.y / 2)
  self.tag_textbox:set_size(width - style.padding.x, self.tag_textbox:get_real_height())

  self.target_label:set_position(padding, self.tag_textbox:get_bottom() + style.padding.y)
  self.filter_textbox:set_position(padding, self.target_label:get_bottom() + style.padding.y / 2)
  self.filter_textbox:set_size(width - style.padding.x, self.filter_textbox:get_real_height())

  local buttons_y = panel_height - self.create:get_height() - (style.padding.y / 2)
  self.message_textbox:set_size(width - style.padding.x, self.message_textbox:get_real_height())
  self.message_textbox:set_position(
    padding,
    buttons_y - self.message_textbox:get_height() - style.padding.y
  )
  self.message_label:set_position(
    padding,
    self.message_textbox:get_position().y - self.message_label:get_height() - style.padding.y / 2
  )
  self.annotated:set_position(
    padding,
    self.message_label:get_position().y - self.annotated:get_height() - style.padding.y
  )
  self.line:set_position(0, self.annotated:get_position().y - style.padding.y)

  self.list_container:set_position(padding, self.filter_textbox:get_bottom() + style.padding.y)
  self.list_container:set_size(
    width - style.padding.x,
    math.max(120 * SCALE, self.line:get_position().y - self.list_container:get_position().y - style.padding.y)
  )
  self.list:resize_to_parent()

  self.create:set_position(padding, buttons_y)
  self.cancel:set_position(self.create:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return CreateTagDialog
