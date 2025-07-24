--
-- HistoryResults Widget/View.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Widget = require "widget"
local Label = require "widget.label"
local Line = require "widget.line"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"
local ContextMenu = require "core.contextmenu"

---@type plugins.scm
local scm

---@class plugins.scm.HistoryResults : widget
---@field public searching boolean
---@field public symbol string
---@field private title widget.label
---@field private line widget.line
---@field private list_container widget
---@field private list widget.listbox
---@overload fun(project_dir:string,path?:string):plugins.scm.HistoryResults
local HistoryResults = Widget:extend()

---@type core.contextmenu
HistoryResults.menu = ContextMenu()

---Constructor
---@param project_dir string
---@param path? string
function HistoryResults:new(project_dir, path)
  HistoryResults.super.new(self)

  -- close when automatically loaded from workspace plugin
  if not project_dir then
    core.add_thread(function()
      -- core should offer a function to easily close a view...
      local parent = core.root_view.root_node:get_node_for_view(self)
      if parent then
        parent:close_view(core.root_view.root_node, self)
      end
    end)
    return
  end

  if not scm then
    scm = require "plugins.scm"
    ---@cast scm plugins.scm
  end

  self.defer_draw = false
  self.project_dir = project_dir
  self.is_file = false

  self.searching = true
  if path then
    self.path = common.relative_path(project_dir, path)
    self.abs_path = path
    self.is_file = true
  else
    self.path = common.basename(project_dir)
  end

  self.name = self.path .. " - Commits History"
  self.title = Label(self, "History for: " .. self.path)
  self.line = Line(self, 2, style.padding.x)
  self.textbox = TextBox(self, "", "filter commits...")

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0

  self.list:enable_expand(true)
  self.list:add_column("Commit")
  self.list:add_column("Author")
  self.list:add_column("Date")
  self.list:add_column("Summary")

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(this, button, x, y, clicks)
    ---@cast this widget.listbox
    list_on_mouse_pressed(this, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      local idx = this:get_selected()
      if idx then
        self:on_selected(idx, this:get_row_data(idx))
      end
    elseif button == "right" and this.hovered_row > 0 then
      this:set_selected(this.hovered_row)
    end
  end

  self.textbox.on_change = function(this, value)
    self.list:filter(value)
  end

  self.border.width = 0
  self:set_size(200, 200)
  self:show()
end

---@return plugins.scm.backend.commit? commit_data
function HistoryResults:get_selected_data()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

function HistoryResults:on_mouse_pressed(button, x, y, clicks)
  local processed = HistoryResults.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.list:mouse_on_top(x, y) then
    handled = HistoryResults.menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

function HistoryResults:on_mouse_moved(x, y, dx, dy)
  if HistoryResults.menu:on_mouse_moved(x, y) then return true end
  return HistoryResults.super.on_mouse_moved(self, x, y, dx, dy)
end

---Add a new commit element to the history.
---@param commit plugins.scm.backend.commit
function HistoryResults:add_commit(commit)
  local row = {
    style.syntax.string, commit.hash:sub(1, 8),
    ListBox.COLEND,
    style.syntax.keyword, commit.author,
    ListBox.COLEND,
    style.syntax.literal, commit.date,
    ListBox.COLEND,
    style.text, commit.summary
  }

  self.list:add_row(row, commit)
end

function HistoryResults:stop_searching()
  self.searching = false
end

---@param idx integer
---@param data plugins.scm.backend.commit
function HistoryResults:on_selected(idx, data)
  scm.open_commit_diff(data.hash, self.project_dir)
end

function HistoryResults:draw()
  if HistoryResults.super.draw(self) then
    HistoryResults.menu:draw()
  end
end

function HistoryResults:update()
  if not HistoryResults.super.update(self) then return end
  -- update the positions and sizes
  self.background_color = style.background
  self.title:set_position(style.padding.x, style.padding.y)
  if not self.searching or #self.list.rows > 0 then
    HistoryResults.menu:update()
    local label = "Commits: "
    if self.searching then
      label = "Loading Commits: "
    end
    self.title:set_label(
      label
        .. #self.list.rows
        .. ", "
        .. "Path: "
        .. '"'
        .. self.path
        .. '"'
    )
  end
  self.line:set_position(0, self.title:get_bottom() + 10)
  self.textbox:set_position(style.padding.x, self.line:get_bottom() + 5)
  self.textbox:set_size(self:get_width() - style.padding.x * 2)
  self.list_container:set_position(style.padding.x, self.textbox:get_bottom() + 10)
  self.list_container:set_size(
    self.size.x - (style.padding.x * 2),
    self.size.y - self.textbox:get_bottom()
  )
end


-- register history commands
command.add(
  function()
    return core.active_view:is(HistoryResults)
      and not core.active_view.searching,
      core.active_view
  end, {
  ["scm-history:copy-commit-hash"] = function(hr)
    ---@cast hr plugins.scm.HistoryResults
    local data = hr:get_selected_data()
    if data then
      system.set_clipboard(data.hash)
      core.log("Copied hash: %s", data.hash or "nothing")
    end
  end,

  ["scm-history:view-diff"] = function(hr)
    ---@cast hr plugins.scm.HistoryResults
    local data = hr:get_selected_data()
    if data then
      scm.open_commit_diff(data.hash, hr.project_dir)
    end
  end
})

command.add(
  function()
    return core.active_view:is(HistoryResults)
      and not core.active_view.searching and core.active_view.is_file,
      core.active_view
  end, {
  ["scm-history:compare-with-current"] = function(hr)
    ---@cast hr plugins.scm.HistoryResults
    local data = hr:get_selected_data()
    if data then
      scm.open_commit_file(data.hash, hr.abs_path)
    end
  end
})


--- register context menu entries
HistoryResults.menu:register(
  function()
    return core.active_view:is(HistoryResults)
      and not core.active_view.searching
  end, {
    { text = "View Diff", command = "scm-history:view-diff" },
    { text = "Copy Commit Hash", command = "scm-history:copy-commit-hash" }
})

HistoryResults.menu:register(
  function()
    return core.active_view:is(HistoryResults)
      and not core.active_view.searching and core.active_view.is_file
  end, {
    ContextMenu.DIVIDER,
    { text = "Compare With Current", command = "scm-history:compare-with-current" }
})


return HistoryResults
