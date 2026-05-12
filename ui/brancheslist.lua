--
-- BranchesList Widget/View.
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

---@class plugins.scm.ui.BranchesList : widget
---@field public searching boolean
---@field public project_dir string
---@field public path string
---@field private backend plugins.scm.backend
---@field public list widget.listbox
---@field private title widget.label
---@field private line widget.line
---@field private textbox widget.textbox
---@field private list_container widget
---@overload fun(project_dir:string,backend:plugins.scm.backend):plugins.scm.ui.BranchesList
local BranchesList = Widget:extend()

---@type core.contextmenu
BranchesList.menu = ContextMenu()

---Constructor
---@param project_dir string
---@param backend plugins.scm.backend
function BranchesList:new(project_dir, backend)
  BranchesList.super.new(self)

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
  self.backend = backend
  self.path = common.basename(project_dir)
  self.searching = true

  self.name = self.path .. " - Branches"
  self.title = Label(self, "Branches for: " .. self.path)
  self.line = Line(self, 2, style.padding.x)
  self.textbox = TextBox(self, "", "filter branches...")

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0

  self.list:enable_expand(true)
  self.list:add_column("Branch")
  self.list:add_column("Remote Origin")
  self.list:add_column("Last Modified")
  self.list:add_column("Last Commit")
  self.list:add_column("Message")

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(this, button, x, y, clicks)
    ---@cast this widget.listbox
    list_on_mouse_pressed(this, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      command.perform "scm-branches:checkout"
    end
  end

  self.textbox.on_change = function(this, value)
    self.list:filter(value)
  end

  self.border.width = 0
  self:set_size(200, 200)
  self:show()
end

---@return plugins.scm.backend.branch? branch_data
function BranchesList:get_selected_data()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
  return nil
end

function BranchesList:on_mouse_pressed(button, x, y, clicks)
  if BranchesList.menu.show_context_menu then
    return BranchesList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  local processed = BranchesList.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.list:mouse_on_top(x, y) then
    handled = BranchesList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

function BranchesList:on_mouse_moved(x, y, dx, dy)
  if BranchesList.menu:on_mouse_moved(x, y) then return true end
  return BranchesList.super.on_mouse_moved(self, x, y, dx, dy)
end

---Add a new branch element to the list.
---@param branch plugins.scm.backend.branch
function BranchesList:add_branch(branch)
  local remote = branch.remote or ""
  if branch.remote_only then
    remote = remote ~= "" and remote or branch.name
  end
  local date = branch.date or ""
  local commit = branch.commit or ""
  local message = branch.message or ""
  local row = {
    style.syntax.keyword, branch.name,
    ListBox.COLEND,
    style.syntax.literal, remote,
    ListBox.COLEND,
    style.syntax.literal, date,
    ListBox.COLEND,
    style.syntax.string, commit:sub(1, 12),
    ListBox.COLEND,
    style.text, message
  }

  self.list:add_row(row, branch)
  core.redraw = true
end

function BranchesList:clear_branches()
  self.searching = true
  self.list:filter(nil)
  self.list:clear()
  self.list.rows_original = {}
  self.list.row_data_original = {}
  self.list.rows_idx_original = {}
  self.list:resize_to_parent()
end

---@param branches plugins.scm.backend.branch[]
---@param backend plugins.scm.backend
function BranchesList:populate(branches, backend)
  table.sort(branches, function(a, b)
    return (a.date or "") > (b.date or "")
  end)
  for idx, branch in ipairs(branches) do
    self:add_branch(branch)
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

function BranchesList:refresh()
  if self.backend then
    self:clear_branches()
    self.backend:get_branches(self.project_dir, function(branches)
      if branches and type(branches) == "table" and #branches > 0 then
        self:populate(branches, self.backend)
      else
        self:stop_searching()
        core.warn("SCM: no branches for '%s'.", self.path)
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

function BranchesList:stop_searching()
  self.searching = false
end

function BranchesList:draw()
  if BranchesList.super.draw(self) then
    BranchesList.menu:draw()
  end
end

function BranchesList:update()
  if not BranchesList.super.update(self) then return end
  -- update the positions and sizes
  self.background_color = style.background
  self.title:set_position(style.padding.x, style.padding.y)
  if not self.searching or #self.list.rows > 0 then
    BranchesList.menu:update()
    local label = "Branches: "
    if self.searching then
      label = "Loading Branches: "
    end
    self.title:set_label(
      label
        .. #self.list.rows
        .. ", "
        .. "Project: "
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

---@param bl plugins.scm.ui.BranchesList
---@param force boolean
local function confirm_delete_branch(bl, force)
  local data = bl:get_selected_data()
  if not data or data.remote_only then return end
  local action = force and "Force Delete Branch" or "Delete Branch"
  local details = force
    and "Git will force delete the local branch even if it is unmerged.\n"
      .. "Fossil will close the branch."
    or "Git will refuse to delete an unmerged branch.\n"
      .. "Fossil will close the branch."
  MessageBox.warning(
    "SCM " .. action,
    {
      details .. "\n\n",
      "Branch: " .. data.name,
      Widget.NEWLINE,
      "Project: " .. bl.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        scm.delete_branch(data.name, bl.project_dir, force, function(deleted)
          if deleted then
            bl:refresh()
          end
        end)
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---@param bl plugins.scm.ui.BranchesList
local function refresh_from_remote(bl)
  local function fetch(prune)
    scm.fetch(bl.project_dir, function(success)
      if success then
        bl:refresh()
      end
    end, prune)
  end

  if bl.backend:supports_fetch_prune() then
    MessageBox.warning(
      "SCM Refresh From Remote",
      {
        "Also delete locally cached remote branches and tags that were deleted upstream?",
        Widget.NEWLINE,
        "Git may also update changed local tags to match the remote.",
        Widget.NEWLINE,
        Widget.NEWLINE,
        "Project: " .. bl.project_dir
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


-- register branches list commands
command.add(
  function()
    return core.active_view:is(BranchesList)
      and not core.active_view.searching,
      core.active_view
  end, {
  ["scm-branches:checkout"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    local data = bl:get_selected_data()
    if data then
      scm.checkout(data.name, bl.project_dir)
    end
  end,

  ["scm-branches:view-history"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    local data = bl:get_selected_data()
    if data then
      scm.open_commit_history(bl.project_dir, data.name)
    end
  end,

  ["scm-branches:view-diff"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    local data = bl:get_selected_data()
    if data then
      scm.open_branch_diff(data.name, nil, bl.project_dir)
    end
  end,

  ["scm-branches:copy-commit-hash"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    local data = bl:get_selected_data()
    if data then
      system.set_clipboard(data.commit)
      core.log("Copied hash: %s", data.commit or "nothing")
    end
  end,

  ["scm-branches:create"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    scm.create_branch(bl.project_dir, function(created)
      if created then
        bl:refresh()
      end
    end)
  end,

  ["scm-branches:rebase"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    local data = bl:get_selected_data()
    if data and not data.remote_only then
      scm.open_rebase_branch_dialog(data, bl.project_dir, function(rebased)
        if rebased then
          bl:refresh()
        end
      end)
    end
  end,

  ["scm-branches:refresh-from-remote"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    refresh_from_remote(bl)
  end,

  ["scm-branches:refresh"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    bl:refresh()
  end,

  ["scm-branches:delete"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    confirm_delete_branch(bl, false)
  end,

  ["scm-branches:force-delete"] = function(bl)
    ---@cast bl plugins.scm.ui.BranchesList
    confirm_delete_branch(bl, true)
  end
})

--- register context menu entries
BranchesList.menu:register(
  function()
    return core.active_view:is(BranchesList)
      and not core.active_view.searching
      and core.active_view:get_selected_data()
  end, {
    { text = "View Changes Diff", command = "scm-branches:view-diff" },
    { text = "View Branch History", command = "scm-branches:view-history" },
    { text = "Copy Commit Hash", command = "scm-branches:copy-commit-hash" },
    { text = "Checkout Branch", command = "scm-branches:checkout" },
    ContextMenu.DIVIDER
})

BranchesList.menu:register(
  function()
    return core.active_view:is(BranchesList)
      and not core.active_view.searching
      and core.active_view:get_selected_data()
      and not core.active_view:get_selected_data().remote_only
      and core.active_view.backend:supports_rebase_branch()
  end, {
    { text = "Rebase Branch...", command = "scm-branches:rebase" },
    ContextMenu.DIVIDER
})

BranchesList.menu:register(
  function()
    return core.active_view:is(BranchesList)
      and not core.active_view.searching
  end, {
    { text = "Refresh", command = "scm-branches:refresh" },
    { text = "Refresh From Remote", command = "scm-branches:refresh-from-remote" },
    { text = "Create Branch", command = "scm-branches:create" }
})

BranchesList.menu:register(
  function()
    return core.active_view:is(BranchesList)
      and not core.active_view.searching
      and core.active_view:get_selected_data()
      and not core.active_view:get_selected_data().remote_only
  end, {
    ContextMenu.DIVIDER,
    { text = "Delete Branch", command = "scm-branches:delete" },
    { text = "Force Delete Branch", command = "scm-branches:force-delete" }
})


return BranchesList
