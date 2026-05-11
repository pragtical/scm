--
-- CredentialsDialog Widget.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
local core = require "core"
local style = require "core.style"
local Button = require "widget.button"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local Line = require "widget.line"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"

---@class plugins.scm.ui.CredentialsDialog : widget.dialog
---@field public project_dir string
---@field private username_label widget.label
---@field private username_textbox widget.textbox
---@field private password_label widget.label
---@field private password_textbox widget.textbox
---@field private line widget.line
---@field private connect widget.button
---@field private cancel widget.button
---@overload fun(project_dir:string,username?:string):plugins.scm.ui.CredentialsDialog
local CredentialsDialog = Dialog:extend()

---@param project_dir string
---@param username? string
function CredentialsDialog:new(project_dir, username)
  CredentialsDialog.super.new(self, "SCM Credentials")

  self.type_name = "plugins.scm.ui.CredentialsDialog"
  self.project_dir = project_dir
  self.submitted = false

  self.username_label = Label(self.panel, "Username")
  self.username_textbox = TextBox(self.panel, username or "", "username...")
  self.password_label = Label(self.panel, "Password")
  self.password_textbox = TextBox(self.panel, "", "password...", {
    password = true
  })
  self.line = Line(self.panel, 1, style.padding.x)
  self.connect = Button(self.panel, "Connect")
  self.connect:set_icon(">")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  local this = self

  function self.connect:on_click()
    this:submit()
  end

  function self.cancel:on_click()
    this:on_close()
  end
end

function CredentialsDialog:submit()
  local username = self.username_textbox:get_text():match("^%s*(.-)%s*$")
  local password = self.password_textbox:get_text()
  if not username or username == "" then
    MessageBox.error("SCM Credentials", "Enter a username.")
    return
  end
  if not password or password == "" then
    MessageBox.error("SCM Credentials", "Enter a password.")
    return
  end

  self.submitted = true
  self:on_submit(username, password)
  self:on_close()
end

---@param username string
---@param password string
function CredentialsDialog:on_submit(username, password) end

---Called when the dialog is closed without submitting credentials.
function CredentialsDialog:on_cancel() end

function CredentialsDialog:on_close()
  if not self.submitted then
    self:on_cancel()
  end
  CredentialsDialog.super.on_close(self)
  self:destroy()
end

function CredentialsDialog:update_size_position()
  CredentialsDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.max(420 * SCALE, core.root_view.size.x * 0.32)
  local height = math.max(220 * SCALE, core.root_view.size.y * 0.24)
  self:set_size(width, height)
  local panel_height = self.panel:get_height()

  self.username_label:set_position(padding, 0)
  self.username_textbox:set_position(
    padding,
    self.username_label:get_bottom() + style.padding.y / 2
  )
  self.username_textbox:set_size(width - style.padding.x, self.username_textbox:get_real_height())

  self.password_label:set_position(padding, self.username_textbox:get_bottom() + style.padding.y)
  self.password_textbox:set_position(
    padding,
    self.password_label:get_bottom() + style.padding.y / 2
  )
  self.password_textbox:set_size(width - style.padding.x, self.password_textbox:get_real_height())

  local buttons_y = panel_height - self.connect:get_height() - (style.padding.y / 2)
  self.line:set_position(0, buttons_y - style.padding.y)

  self.connect:set_position(padding, buttons_y)
  self.cancel:set_position(self.connect:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return CredentialsDialog
