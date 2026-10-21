local core = require "core"
local config = require "core.config"

-- Delay loading of TreeView changes to properly check if the plugin is enabled.
core.add_thread(function()

-- Load treeview if enabled to add menu entries
---@module 'plugins.treeview'
local TreeView
---@module 'core.contextmenu'
local TreeViewMenu

if config.plugins.treeview ~= false then
  TreeView = require "plugins.treeview"
  TreeViewMenu = TreeView.contextmenu
else
  return
end

local scm = require "plugins.scm"
local command = require "core.command"

local function context_item()
  return TreeView:get_context_item()
end

local function context_status()
  local item = context_item()
  if item then return scm.get_cached_path_status(item.abs_filename) end
end

local treeview_menu_show = TreeViewMenu.show
function TreeViewMenu:show(x, y)
  local opening = {}
  self.scm_status_opening = opening
  local shown = treeview_menu_show(self, x, y)
  local item = context_item()
  if shown and item and not scm.get_cached_path_status(item.abs_filename) then
    scm.get_cached_path_status(item.abs_filename, function(status)
      if not status or not self.show_context_menu
        or self.scm_status_opening ~= opening or context_item() ~= item
      then
        return
      end
      local selected = self.items and self.items[self.selected]
      self.items = self:build_items(self.source_items, self.application_menu)
      self.size.x, self.size.y = self.items.width, self.items.height
      self.selected = -1
      for i, row in ipairs(self.items) do
        if selected and row.command and row.command == selected.command then
          self.selected = i
          break
        end
      end
      core.redraw = true
    end)
  end
  return shown
end

local function can_initialize()
  local item = TreeView.hovered_item
  return item and item.type == "dir"
    and scm.can_initialize_repository(item.abs_filename)
end

TreeViewMenu:register(can_initialize, {
  TreeViewMenu.DIVIDER,
  { text = "Initialize Repository...", command = "treeview:scm-initialize" }
})
command.add(can_initialize, {
  ["treeview:scm-initialize"] = function()
    scm.initialize_repository(TreeView.hovered_item.abs_filename)
  end
})

local function can_manage_remotes()
  local item = TreeView.hovered_item
  local backend = item and scm.get_path_backend(item.abs_filename)
  return backend and scm.is_scm_project(item.abs_filename)
    and backend:get_capabilities().remotes
end
TreeViewMenu:register(can_manage_remotes, {
  { text = "Manage Remotes", command = "treeview:scm-remotes" }
})
command.add(can_manage_remotes, {
  ["treeview:scm-remotes"] = function()
    scm.open_repository_tools(TreeView.hovered_item.abs_filename, "remotes")
  end
})

--------------------------------------------------------------------------------
-- Override treeview to change color of files depending on status
--------------------------------------------------------------------------------
local treeview_get_item_text = TreeView.get_item_text
function TreeView:get_item_text(item, active, hovered)
  local text, font, color = treeview_get_item_text(self, item, active, hovered)
  local path = item.abs_filename
  local status = scm.get_path_changes(path)
  if status then
    if status.text then text = status.text end
    color = status.color
  end
  return text, font, color
end

local treeview_toggle_expand = TreeView.toggle_expand
function TreeView:toggle_expand(toggle, item)
  item = item or self.selected_item
  local was_expanded = item and item.expanded
  local result = treeview_toggle_expand(self, toggle, item)
  if item and item.type == "dir" and item.expanded and not was_expanded
    and scm.get_path_backend(item.abs_filename)
  then
    scm.request_update()
  end
  return result
end

--------------------------------------------------------------------------------
-- Add entries to treeview contextmenu
--------------------------------------------------------------------------------

-- Entries when right clicking project root
TreeViewMenu:register(
  function()
    return TreeView.hovered_item
      and scm.is_scm_project(TreeView.hovered_item.abs_filename)
  end,
  {
    TreeViewMenu.DIVIDER,
    { text = "Repository Workbench", command = "treeview:scm-workbench" },
    { text = "Pull From Remote", command = "treeview:scm-pull" },
    { text = "Push To Remote", command = "treeview:scm-push" },
    { text = "View Changes Diff", command = "treeview:scm-global-diff" },
    { text = "View Project Status", command = "treeview:scm-project-status" },
    { text = "View Branches", command = "treeview:scm-view-branches" },
    { text = "View Tags", command = "treeview:scm-view-tags" },
    { text = "View Commits History", command = "treeview:scm-commits-history" }
  }
)

TreeViewMenu:register(function()
    return TreeView.hovered_item
      and scm.get_path_backend(TreeView.hovered_item.abs_filename)
    end, {
    TreeViewMenu.DIVIDER,
    { text = "Add to Repo", command = "treeview:scm-path-add" },
    { text = "Remove from Repo", command = "treeview:scm-path-remove" },
    { text = "Add to Staging", command = "treeview:scm-staging-add" },
    { text = "Remove from Staging", command = "treeview:scm-staging-remove" },
    { text = "Revert Changes", command = "treeview:scm-file-revert" },
    { text = "Compare With Head", command = "treeview:scm-compare-with-head" },
    { text = "View Changes Diff", command = "treeview:scm-file-diff" },
    { text = "View Commits History", command = "treeview:scm-commits-history" }
})

--------------------------------------------------------------------------------
-- Register treeview commands
--------------------------------------------------------------------------------
command.add(
  function()
    return TreeView.hovered_item
      and scm.is_scm_project(TreeView.hovered_item.abs_filename)
  end, {

  ["treeview:scm-pull"] = function()
    scm.pull(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-workbench"] = function()
    scm.open_workbench(TreeView.hovered_item.abs_filename)
  end,


  ["treeview:scm-push"] = function()
    scm.push(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-global-diff"] = function()
    scm.open_diff(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-project-status"] = function()
    scm.open_project_status(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-view-branches"] = function()
    scm.open_branches_list(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-view-tags"] = function()
    scm.open_tags_list(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-commits-history"] = function()
    scm.open_commit_history(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    return TreeView.hovered_item
      and (
        scm.is_scm_project(TreeView.hovered_item.abs_filename)
        or
        (scm.get_path_backend(TreeView.hovered_item.abs_filename)
          and context_status() and context_status() ~= "untracked")
      )
  end, {

  ["treeview:scm-commits-history"] = function()
    scm.open_commit_history(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    return TreeView.hovered_item
      and scm.get_path_backend(TreeView.hovered_item.abs_filename)
      and context_status() == "untracked"
  end, {

  ["treeview:scm-path-add"] = function()
    scm.add_path(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    return TreeView.hovered_item
      and context_status() == "unchanged"
  end, {

  ["treeview:scm-path-remove"] = function()
    scm.remove_path(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    if TreeView.hovered_item then
      local path = TreeView.hovered_item.abs_filename
      local status, staged = context_status()
      if status == "edited" and not staged then
        local backend = scm.get_path_backend(path)
        if backend and backend:has_staging() then
          return true
        end
      end
    end
    return false
  end, {

  ["treeview:scm-staging-add"] = function()
    scm.stage_file(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    if TreeView.hovered_item then
      local backend = scm.get_path_backend(TreeView.hovered_item.abs_filename)
      if backend and backend:has_staging() then
        local _, staged = context_status()
        if staged then
          return true
        end
      end
    end
    return false
  end, {

  ["treeview:scm-staging-remove"] = function()
    scm.unstage_file(TreeView.hovered_item.abs_filename)
  end
})

command.add(
  function()
    if TreeView.hovered_item then
      local path = TreeView.hovered_item.abs_filename
      local status, staged = context_status()
      local backend = scm.get_path_backend(path)
      if backend and backend:has_staging() then
        if status == "edited" and not staged then
          return true
        end
      elseif backend then
        return scm.get_path_backend(
          TreeView.hovered_item.abs_filename, true, true
        )
      end
    end
    return false
  end, {

  ["treeview:scm-file-revert"] = function()
    scm.revert_file(TreeView.hovered_item.abs_filename)
  end,
})

command.add(
  function()
    local status, staged = context_status()
    return TreeView.hovered_item and status == "edited" and not staged
  end, {

  ["treeview:scm-file-diff"] = function()
    scm.open_path_diff(TreeView.hovered_item.abs_filename)
  end,

  ["treeview:scm-compare-with-head"] = function()
    scm.open_commit_file(nil, TreeView.hovered_item.abs_filename)
  end
})

end) -- end initialization coroutine
