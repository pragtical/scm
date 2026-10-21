local core = require "core"
local style = require "core.style"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local TextBox = require "widget.textbox"
local CheckBox = require "widget.checkbox"
local SelectBox = require "widget.selectbox"
local FilePicker = require "widget.filepicker"
local NumberBox = require "widget.numberbox"
local Button = require "widget.button"
local MessageBox = require "widget.messagebox"

---@class plugins.scm.ui.FormDialog : widget.dialog
local FormDialog = Dialog:extend()

---Small repository operation form. The submit callback receives named values.
---@param title string
---@param fields table[]
---@param submit fun(values:table, done:fun(success:boolean,errmsg?:string))
---@param action? string
function FormDialog:new(title, fields, submit, action)
  FormDialog.super.new(self, title)
  self.fields, self.controls, self.labels = fields, {}, {}
  for _, field in ipairs(fields) do
    local control
    if field.kind == "check" then
      control = CheckBox(self.panel, field.label)
      control:set_checked(field.value == true)
    elseif field.kind == "directory" or field.kind == "file" then
      self.labels[field.id] = Label(self.panel, field.label)
      control = FilePicker(self.panel, field.value or "")
      control:set_mode(field.kind)
      control:set_editable(true)
    elseif field.kind == "number" then
      self.labels[field.id] = Label(self.panel, field.label)
      control = NumberBox(
        self.panel,
        field.value or field.min or 0,
        field.min,
        field.max,
        field.step or 1
      )
    elseif field.options then
      self.labels[field.id] = Label(self.panel, field.label)
      control = SelectBox(self.panel, field.label)
      local selected = field.value == nil and 1 or 0
      for i, option in ipairs(field.options) do
        local value = option.value
        if value == nil then value = option[2] end
        control:add_option(option.label or option[1], value)
        if field.value == value then
          selected = i
        end
      end
      control:set_selected(selected)
    else
      self.labels[field.id] = Label(self.panel, field.label)
      control = TextBox(self.panel, field.value or "", field.placeholder or "")
    end
    self.controls[field.id] = control
    if field.tooltip then
      control:set_tooltip(field.tooltip)
    end
  end
  self.accept = Button(self.panel, action or "Apply")
  self.close.on_click = function()
    self:on_close()
  end
  self.accept:set_icon ">"
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon "C"
  self.cancel.on_click = function()
    if not self.busy then
      self:on_close()
    end
  end
  self.accept.on_click = function()
    if self.busy then
      return
    end
    local values = {}
    for _, field in ipairs(fields) do
      local control = self.controls[field.id]
      if field.kind == "check" then
        values[field.id] = control:is_checked()
      elseif field.kind == "directory" or field.kind == "file" then
        values[field.id] = control:get_path()
      elseif field.kind == "number" then
        values[field.id] = control:get_value()
      elseif field.options then
        values[field.id] = control:get_selected_data()
      else
        values[field.id] = control:get_text()
      end
      if
        field.required
        and (values[field.id] == nil or values[field.id] == "")
      then
        MessageBox.error(title, field.label .. " is required.")
        return
      end
      if
        field.kind == "number"
        and (
          field.min and values[field.id] < field.min
          or field.max and values[field.id] > field.max
          or field.integer and values[field.id] % 1 ~= 0
        )
      then
        MessageBox.error(title, field.label .. " is out of range.")
        return
      end
    end
    self.busy = true
    submit(values, function(ok, errmsg)
      self.busy = false
      if ok then
        self:on_close()
      else
        MessageBox.error(title, errmsg or "Operation failed.")
      end
    end)
  end
end

function FormDialog:on_close()
  if not self.busy then
    FormDialog.super.on_close(self)
  end
end

function FormDialog:update_size_position()
  local width = math.min(560 * SCALE, core.root_view.size.x - 40 * SCALE)
  local pad, y = style.padding.x, style.padding.y
  self:set_size(width, self.size.y)
  FormDialog.super.update_size_position(self)
  for _, field in ipairs(self.fields) do
    local label, control = self.labels[field.id], self.controls[field.id]
    if field.kind == "check" then
      control:set_wrap_width(width - pad)
    end
    if label then
      label:set_position(pad / 2, y)
      y = y + label:get_height() + style.padding.y / 2
    end
    control:set_position(pad / 2, y)
    if field.kind ~= "check" then
      control:set_size(width - pad, control:get_height())
    end
    y = y + control:get_height() + style.padding.y
  end
  self.accept:set_position(pad / 2, y)
  self.cancel:set_position(self.accept:get_right() + pad, y)
  local height = y + self.accept:get_height() + style.padding.y
  local panel_height = math.min(height, core.root_view.size.y - 100 * SCALE)
  self.panel:set_size(width, panel_height)
  self.size.x, self.size.y =
    width, panel_height + self.title:get_height() + style.padding.y * 2
  self.close:set_position(
    width - self.close:get_width() - pad / 2,
    style.padding.y / 2
  )
end

return FormDialog
