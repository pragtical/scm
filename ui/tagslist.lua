--
-- TagsList Widget/View.
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
local MessageBox = require "widget.messagebox"

---@type plugins.scm
local scm

---@class plugins.scm.ui.TagsList : widget
---@field public searching boolean
---@field public project_dir string
---@field public path string
---@field private backend plugins.scm.backend
---@field public list widget.listbox
---@field private title widget.label
---@field private line widget.line
---@field private textbox widget.textbox
---@field private list_container widget
---@overload fun(project_dir:string,backend:plugins.scm.backend):plugins.scm.ui.TagsList
local TagsList = Widget:extend()

---@type core.contextmenu
TagsList.menu = ContextMenu()

---@param project_dir string
---@param backend plugins.scm.backend
function TagsList:new(project_dir, backend)
  TagsList.super.new(self)

  if not project_dir then
    core.add_thread(function()
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
  self.backend = backend
  self.path = common.basename(project_dir)
  self.searching = true

  self.name = self.path .. " - Tags"
  self.title = Label(self, "Tags for: " .. self.path)
  self.line = Line(self, 2, style.padding.x)
  self.textbox = TextBox(self, "", "filter tags...")

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Tag")
  self.list:add_column("Type")
  self.list:add_column("Last Modified")
  self.list:add_column("Last Commit")
  self.list:add_column("Message")

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(this, button, x, y, clicks)
    ---@cast this widget.listbox
    list_on_mouse_pressed(this, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      command.perform "scm-tags:checkout"
    elseif button == "right" and this.hovered_row > 0 then
      this:set_selected(this.hovered_row)
    end
  end

  self.textbox.on_change = function(_, value)
    self.list:filter(value)
  end

  self.border.width = 0
  self:set_size(200, 200)
  self:show()
end

---@return plugins.scm.backend.tag?
function TagsList:get_selected_data()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

function TagsList:on_mouse_pressed(button, x, y, clicks)
  local processed = TagsList.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.list:mouse_on_top(x, y) then
    handled = TagsList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

function TagsList:on_mouse_moved(x, y, dx, dy)
  if TagsList.menu:on_mouse_moved(x, y) then return true end
  return TagsList.super.on_mouse_moved(self, x, y, dx, dy)
end

---@param tag plugins.scm.backend.tag
function TagsList:add_tag(tag)
  local date = tag.date or ""
  local commit = tag.commit or ""
  local message = tag.message or ""
  local tag_type = tag.annotated and "annotated" or "simple"
  self.list:add_row({
    style.syntax.keyword, tag.name,
    ListBox.COLEND,
    style.syntax.literal, tag_type,
    ListBox.COLEND,
    style.syntax.literal, date,
    ListBox.COLEND,
    style.syntax.string, commit:sub(1, 12),
    ListBox.COLEND,
    style.text, message
  }, tag)
end

function TagsList:clear_tags()
  self.searching = true
  self.list:filter(nil)
  self.list:clear()
  self.list.rows_original = {}
  self.list.row_data_original = {}
  self.list.rows_idx_original = {}
  self.list:resize_to_parent()
end

---@param tags plugins.scm.backend.tag[]
---@param backend plugins.scm.backend
function TagsList:populate(tags, backend)
  table.sort(tags, function(a, b)
    return (a.date or "") > (b.date or "")
  end)
  for idx, tag in ipairs(tags) do
    self:add_tag(tag)
    if idx % 100 == 0 then
      core.redraw = true
      self.list:resize_to_parent()
      backend:yield()
    end
  end
  core.redraw = true
  self.list:resize_to_parent()
  self:stop_searching()
end

function TagsList:refresh()
  if self.backend then
    self:clear_tags()
    self.backend:get_tags(self.project_dir, function(tags)
      if tags and type(tags) == "table" and #tags > 0 then
        self:populate(tags, self.backend)
      else
        self:stop_searching()
        core.warn("SCM: no tags for '%s'.", self.path)
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

function TagsList:stop_searching()
  self.searching = false
end

function TagsList:draw()
  if TagsList.super.draw(self) then
    TagsList.menu:draw()
  end
end

function TagsList:update()
  if not TagsList.super.update(self) then return end
  self.background_color = style.background
  self.title:set_position(style.padding.x, style.padding.y)
  if not self.searching or #self.list.rows > 0 then
    TagsList.menu:update()
    local label = self.searching and "Loading Tags: " or "Tags: "
    self.title:set_label(
      label
        .. #self.list.rows
        .. ", Project: \""
        .. self.path
        .. "\""
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

---@param tl plugins.scm.ui.TagsList
local function confirm_delete_tag(tl)
  local data = tl:get_selected_data()
  if not data then return end
  MessageBox.warning(
    "SCM Delete Tag",
    {
      "Do you really want to delete this tag?",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Tag: " .. data.name,
      Widget.NEWLINE,
      "Project: " .. tl.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        scm.delete_tag(data.name, data.commit, tl.project_dir, function(deleted)
          if deleted then
            tl:refresh()
          end
        end)
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---@param tl plugins.scm.ui.TagsList
local function confirm_edit_tag(tl)
  local data = tl:get_selected_data()
  if not data then return end
  MessageBox.warning(
    "SCM Edit Tag",
    {
      "Editing a tag replaces its target.",
      Widget.NEWLINE,
      "Git users may need to force-push the tag if it was already shared.",
      Widget.NEWLINE,
      "Fossil records this as cancel/add tag operations.",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Tag: " .. data.name,
      Widget.NEWLINE,
      "Project: " .. tl.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        scm.update_tag(data, tl.project_dir, function(updated)
          if updated then
            tl:refresh()
          end
        end)
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---@param tl plugins.scm.ui.TagsList
local function refresh_from_remote(tl)
  local function fetch(prune)
    scm.fetch(tl.project_dir, function(success)
      if success then
        tl:refresh()
      end
    end, prune)
  end

  if tl.backend:supports_fetch_prune() then
    MessageBox.warning(
      "SCM Refresh From Remote",
      {
        "Also delete locally cached remote branches and tags that were deleted upstream?",
        Widget.NEWLINE,
        "Git may also update changed local tags to match the remote.",
        Widget.NEWLINE,
        Widget.NEWLINE,
        "Project: " .. tl.project_dir
      },
      function(_, button_id)
        fetch(button_id == 1)
      end,
      MessageBox.BUTTONS_YES_NO
    )
  else
    fetch(false)
  end
end

command.add(
  function()
    return core.active_view:is(TagsList)
      and not core.active_view.searching,
      core.active_view
  end, {
  ["scm-tags:checkout"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    local data = tl:get_selected_data()
    if data then
      scm.checkout(data.name, tl.project_dir)
    end
  end,

  ["scm-tags:view-history"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    local data = tl:get_selected_data()
    if data then
      scm.open_commit_history(tl.project_dir, data.name, "tag")
    end
  end,

  ["scm-tags:view-diff"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    local data = tl:get_selected_data()
    if data then
      scm.open_tag_diff(data.name, nil, tl.project_dir)
    end
  end,

  ["scm-tags:copy-commit-hash"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    local data = tl:get_selected_data()
    if data then
      system.set_clipboard(data.commit)
      core.log("Copied hash: %s", data.commit or "nothing")
    end
  end,

  ["scm-tags:create"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    scm.create_tag(tl.project_dir, function(created)
      if created then
        tl:refresh()
      end
    end)
  end,

  ["scm-tags:refresh-from-remote"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    refresh_from_remote(tl)
  end,

  ["scm-tags:edit"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    confirm_edit_tag(tl)
  end,

  ["scm-tags:delete"] = function(tl)
    ---@cast tl plugins.scm.ui.TagsList
    confirm_delete_tag(tl)
  end
})

TagsList.menu:register(
  function()
    return core.active_view:is(TagsList)
      and not core.active_view.searching
      and core.active_view:get_selected_data()
  end, {
    { text = "View Changes Diff", command = "scm-tags:view-diff" },
    { text = "View Tag History", command = "scm-tags:view-history" },
    { text = "Copy Commit Hash", command = "scm-tags:copy-commit-hash" },
    { text = "Checkout Tag", command = "scm-tags:checkout" },
    ContextMenu.DIVIDER
})

TagsList.menu:register(
  function()
    return core.active_view:is(TagsList)
      and not core.active_view.searching
  end, {
    { text = "Refresh From Remote", command = "scm-tags:refresh-from-remote" },
    { text = "Create Tag", command = "scm-tags:create" }
})

TagsList.menu:register(
  function()
    return core.active_view:is(TagsList)
      and not core.active_view.searching
      and core.active_view:get_selected_data()
  end, {
    ContextMenu.DIVIDER,
    { text = "Edit Tag", command = "scm-tags:edit" },
    { text = "Delete Tag", command = "scm-tags:delete" }
})

return TagsList
