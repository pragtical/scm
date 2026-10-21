local core = require "core"
local style = require "core.style"
local common = require "core.common"
local Widget = require "widget"
local Button = require "widget.button"
local Label = require "widget.label"
local ListBox = require "widget.listbox"
local SelectBox = require "widget.selectbox"
local TextBox = require "widget.textbox"
local MessageBox = require "widget.messagebox"
local DiffPreview = require "plugins.scm.ui.diffpreview"
local CommitDetails = require "plugins.scm.ui.commitdetails"
local FormDialog = require "plugins.scm.ui.formdialog"
local actions = require "plugins.scm.ui.repositoryactions"

---@class plugins.scm.ui.RepositoryTools : widget
local RepositoryTools = Widget:extend()

local function identity(entry)
  return entry and (entry.hash or entry.path or entry.name)
end

function RepositoryTools:new(directory, backend, mode)
  RepositoryTools.super.new(self, nil, false)
  self.defer_draw, self.border.width = false, 0
  self.directory, self.backend, self.generation = directory, backend, 0
  self.name = common.basename(directory) .. " - Repository Tools"
  self.project_dir = directory
  local scm = require "plugins.scm"
  if scm.register_workbench then
    scm.register_workbench(self)
  end
  self.capabilities = backend:get_capabilities()
  self.mode = mode or "incoming"
  self.selector = SelectBox(self, "View")
  local modes = {
    { "Incoming", "incoming" },
    { "Outgoing", "outgoing" },
    { "Remotes", "remotes", "remotes" },
    { "Worktrees", "worktrees", "worktrees" },
    { "Submodules", "submodules", "submodules" },
    { "Git LFS", "lfs", "lfs" },
    { "Search Results", "search" },
  }
  for _, item in ipairs(modes) do
    if not item[3] or self.capabilities[item[3]] then
      self.selector:add_option(item[1], item[2])
    end
  end
  self.selector:set_selected(1)
  self.selector.on_selected = function(_, _, mode)
    self.mode = mode
    self:refresh()
  end
  self.commands = SelectBox(self, "Repository Actions")
  self.commands:add_option("Fetch from remote", "fetch")
  self.commands:add_option("Search history...", "search")
  if self.capabilities.merge then
    self.commands:add_option("Merge branches...", "merge")
  end
  if self.capabilities.remote_refs then
    for _, kind in ipairs({ "branch", "tag" }) do
      self.commands:add_option("Push " .. kind .. "...", "push-" .. kind)
      self.commands:add_option(
        "Delete remote " .. kind .. "...",
        "delete-" .. kind
      )
    end
  end
  if self.capabilities.remotes then
    self.commands:add_option("Manage remotes...", "remotes")
    self.commands:add_option("Add remote...", "add-remote")
  end
  if self.capabilities.rewrite then
    self.commands:add_option("Rewrite local history...", "rewrite")
  end
  if self.capabilities.worktrees then
    self.commands:add_option("Add worktree...", "worktree")
  end
  self.commands.on_selected = function(_, _, action)
    self:perform(action)
  end
  self.refresh_button = Button(self, "Refresh")
  self.refresh_button.on_click = function()
    self:refresh()
  end
  self.search = TextBox(self, "", "Filter...")
  self.search.on_change = function(_, value)
    local selected = identity(self.selected)
    self.list:filter(value)
    self:restore_selection(selected)
    core.redraw = true
  end
  self.container = Widget(self)
  self.list = ListBox(self.container)
  self.list:enable_expand(true)
  self.list.on_row_click = function(_, _, entry)
    self:select(entry)
  end
  self.preview = DiffPreview(self)
  self.commit_details = CommitDetails(self)
  self.remote_details = Label(self, "")
  self.remote_details.scrollable, self.remote_details.clickable = true, true
  self.status = Label(self, "")
  self.status.scrollable = true
  self.open = Button(self, "Open")
  self.open.on_click = function()
    self:open_selected()
  end
  self.copy = Button(self, "Copy Hash")
  self.copy.on_click = function()
    if self.selected and self.selected.hash then
      system.set_clipboard(self.selected.hash)
    end
  end
  self.remove = Button(self, "Remove Worktree...")
  self.remove.on_click = function()
    local entry = self.selected
    if not entry then
      return
    end
    local remote = self.mode == "remotes"
    local name = remote and entry.name or entry.path
    MessageBox.warning(
      remote and "SCM Remove Remote" or "SCM Worktree",
      "Remove '"
        .. name
        .. "'?"
        .. (
          remote
            and (entry.is_default and "\nThis disables Fossil autosync." or "\nOnly local configuration and tracking refs are removed.")
          or ""
        ),
      function(_, id)
        if id == 1 then
          local remove = remote and backend.remove_remote
            or backend.remove_worktree
          remove(backend, directory, name, function(ok, errmsg)
            if not ok then
              MessageBox.error("SCM Remove", errmsg)
            end
            self:refresh()
          end)
        end
      end,
      MessageBox.BUTTONS_YES_NO
    )
  end
  self.add = Button(self, "Add Remote...")
  self.add.on_click = function()
    actions.edit_remote(backend, directory, nil, function()
      self:refresh()
    end)
  end
  self.edit = Button(self, "Edit...")
  self.edit.on_click = function()
    if self.mode == "remotes" and self.selected then
      actions.edit_remote(backend, directory, self.selected, function()
        self:refresh()
      end)
    end
  end
  self.rename = Button(self, "Rename...")
  self.rename.on_click = function()
    if self.mode == "remotes" and self.selected then
      actions.rename_remote(backend, directory, self.selected, function()
        self:refresh()
      end)
    end
  end
  self.default_remote = Button(self, "Set Default")
  self.default_remote.on_click = function()
    local entry = self.mode == "remotes" and self.selected
    if entry then
      backend:set_default_remote(directory, entry.name, function(ok, errmsg)
        if not ok then
          MessageBox.error("SCM Remote", errmsg)
        end
        self:refresh()
      end)
    end
  end
  self.download = Button(self, "Update / Download")
  self.download.on_click = function()
    local function done(ok, errmsg)
      if not ok then
        MessageBox.error("SCM Download", errmsg)
      end
      self:refresh()
    end
    if self.mode == "lfs" then
      backend:fetch_lfs(directory, done)
    elseif self.selected then
      backend:update_submodule(directory, self.selected.path, done)
    end
  end
  self:show()
  self:refresh()
end

function RepositoryTools:reset_list(mode)
  self.list:filter(nil)
  self.list:clear()
  self.list.columns = {}
  self.list:add_column(mode == "remotes" and "Remote" or "Name / Message")
  self.list:add_column(mode == "remotes" and "Fetch URL" or "Details")
  if mode == "remotes" then
    self.list:add_column "Push URL"
  end
end

function RepositoryTools:restore_selection(key)
  local selected = #self.list.rows > 0 and 1 or nil
  for i = 1, #self.list.rows do
    if key and identity(self.list:get_row_data(i)) == key then
      selected = i
      break
    end
  end
  self.list:set_selected(selected)
  self:select(self.list:get_row_data(selected or 0))
end

function RepositoryTools:refresh()
  self.refreshing = true
  self.loading = self.snapshot_mode ~= self.mode
  self.generation = self.generation + 1
  self.preview_request = (self.preview_request or 0) + 1
  local generation, mode = self.generation, self.mode
  for i = 2, #self.selector.list.rows do
    if self.selector.list:get_row_data(i) == mode then
      self.selector:set_selected(i - 1)
      break
    end
  end
  if self.loading then
    self.commit_details:clear()
    self.remote_details:set_label ""
    self.status:set_label "Loading..."
    self.preview:set_message "Loading..."
    self.selected = nil
    self:reset_list(mode)
  end
  local backend, directory = self.backend, self.directory
  local function fill(entries, errmsg)
    if self.generation ~= generation then
      return
    end
    if not entries then
      self.loading, self.refreshing = false, false
      self.snapshot_key, self.snapshot_mode = nil, nil
      self.entries = {}
      self:reset_list(mode)
      self:select(nil)
      self.remote_details:set_label ""
      self.preview:set_message "Repository query failed"
      self.commit_details:clear()
      self.status:set_label(errmsg or "Could not load repository state")
      core.redraw = true
      return
    end
    local parts = {}
    for i, entry in ipairs(entries) do
      parts[i] = common.serialize(entry, { sort = true })
      if i % 100 == 0 then backend:yield() end
      if self.generation ~= generation then return end
    end
    local signature = table.concat(parts, "\n")
    if self.snapshot_key == signature and self.snapshot_mode == mode then
      self.loading, self.refreshing = false, false
      if self.selected and self.selected.hash then
        self:select(self.selected)
      end
      local status = errmsg or (#entries .. " items")
      if self.status.label ~= status then
        self.status:set_label(status)
        core.redraw = true
      end
      return
    end
    local selected = identity(self.selected)
    self:reset_list(mode)
    self.entries = entries
    for i, entry in ipairs(self.entries) do
      local row = {
        entry.summary or entry.name or entry.path,
        ListBox.COLEND,
        entry.url
          or entry.author
          or entry.message
          or entry.branch
          or entry.commit
          or "",
      }
      if mode == "remotes" then
        row[#row + 1], row[#row + 2] = ListBox.COLEND, entry.push_url or ""
      end
      self.list:add_row(row, entry)
      core.redraw = true
      if i % 100 == 0 then
        backend:yield()
      end
      if self.generation ~= generation then
        return
      end
    end
    self.list:filter(self.search:get_text())
    self:restore_selection(selected)
    self.snapshot_key, self.snapshot_mode = signature, mode
    self.loading, self.refreshing = false, false
    self.status:set_label(errmsg or (#self.entries .. " items"))
  end
  if mode == "incoming" or mode == "outgoing" then
    backend:get_sync_history(directory, function(status, errmsg)
      fill(status and status[mode], errmsg or status and status.note)
    end, 200)
  elseif mode == "worktrees" then
    backend:get_worktrees(directory, fill)
  elseif mode == "remotes" then
    backend:get_remotes(directory, fill)
  elseif mode == "submodules" then
    backend:get_submodules(directory, fill)
  elseif mode == "lfs" then
    backend:get_lfs_files(directory, fill)
  elseif mode == "search" then
    fill(self.search_results or {})
  end
end

function RepositoryTools:select(entry)
  local same = self.selected_mode == self.mode
    and identity(entry) == identity(self.selected)
  self.selected = entry
  self.selected_mode = self.mode
  self.preview_request = (self.preview_request or 0) + 1
  local request = self.preview_request
  if not same then
    self.preview:set_message(entry and "Loading..." or "No selection")
  end
  if entry and entry.hash then
    self.commit_details:load(self.backend, self.directory, entry.hash, entry)
    self.backend:get_commit_diff(entry.hash, self.directory,
      function(diff, _, err)
        if request == self.preview_request then
          if diff then self.preview:set_diff(diff)
          else self.preview:set_message(err or "Diff unavailable") end
        end
      end)
  else
    self.commit_details:clear()
  end
  if entry and self.mode == "remotes" then
    local text = { entry.name, "", "Fetch URLs:" }
    for _, url in ipairs(entry.fetch_urls or { entry.url }) do
      text[#text + 1] = url
    end
    text[#text + 1] = ""
    text[#text + 1] = "Push URLs:"
    local urls = entry.push_explicit and entry.push_urls
      or entry.fetch_urls
      or { entry.push_url }
    for _, url in ipairs(urls) do
      text[#text + 1] = url
    end
    local styled = {}
    for _, line in ipairs(text) do
      styled[#styled + 1], styled[#styled + 2] = line, Widget.NEWLINE
    end
    self.remote_details:set_label(styled)
  elseif entry and not entry.hash then
    self.preview:set_message(entry.path or entry.message or "")
  elseif self.mode == "remotes" then
    self.remote_details:set_label ""
  end
  core.redraw = true
end

function RepositoryTools:perform(action)
  local backend, directory = self.backend, self.directory
  local finished = function()
    self:refresh()
  end
  if action == "fetch" then
    require("plugins.scm").fetch(directory, function(ok)
      if ok then
        self:refresh()
      end
    end)
  elseif action == "merge" then
    actions.merge(backend, directory, finished)
  elseif action == "search" then
    actions.search(backend, directory, function(history)
      self.search_results, self.mode = history, "search"
      self:refresh()
    end)
  elseif action == "worktree" then
    actions.worktree(backend, directory, finished)
  elseif action == "remotes" or action == "add-remote" then
    self.mode = "remotes"
    self:refresh()
    if action == "add-remote" then
      actions.edit_remote(backend, directory, nil, finished)
    end
  elseif action == "rewrite" then
    FormDialog("SCM Rewrite Range", {
      {
        id = "count",
        label = "Number of latest local commits",
        value = 3,
        kind = "number",
        min = 1,
        max = 100,
        integer = true,
      },
    }, function(values, done)
      local count = tonumber(values.count)
      if not count or count < 1 or count > 100 or count % 1 ~= 0 then
        done(false, "Choose an integer from 1 to 100.")
        return
      end
      backend:get_review_history(directory, function(history, errmsg)
        if not history then
          done(false, errmsg)
          return
        end
        done(true)
        local RewriteDialog = require "plugins.scm.ui.rewritedialog"
        RewriteDialog(directory, backend, history, finished):show()
      end, "HEAD", count)
    end, "Review Plan"):show()
  elseif action:match "^push%-%a+$" or action:match "^delete%-%a+$" then
    actions.remote(
      backend,
      directory,
      action:match "%-(%a+)$",
      action:match "^delete" ~= nil,
      finished
    )
  end
end

function RepositoryTools:open_selected()
  local entry = self.selected
  if not entry or not entry.path then
    return
  end
  local info = system.get_file_info(entry.path)
  if info and info.type == "dir" then
    core.add_project(entry.path)
    require("plugins.scm").open_workbench(entry.path)
  elseif info then
    core.root_view:open_doc(core.open_doc(entry.path))
  end
end

function RepositoryTools:update()
  if not RepositoryTools.super.update(self) then
    return false
  end
  local gap, row = style.padding.x, style.font:get_height() + 14 * SCALE
  local width, height = self.size.x, self.size.y
  self.selector:set_position(gap / 2, gap / 2)
  self.selector:set_size(width * 0.35 - gap, row)
  self.commands:set_position(width * 0.35, gap / 2)
  self.commands:set_size(width * 0.65 - gap, row)
  self.refresh_button:set_position(gap / 2, gap + row)
  self.search:set_position(self.refresh_button:get_right() + gap, gap + row)
  self.search:set_size(
    math.max(40, width - self.refresh_button:get_width() - gap * 3),
    row
  )
  local bottom = height - row * 1.6
  local controls = {
    self.open,
    self.copy,
    self.remove,
    self.download,
    self.add,
    self.edit,
    self.rename,
    self.default_remote,
  }
  local x, rows = gap / 2, 1
  self.remove:set_label(
    self.mode == "remotes" and "Remove Remote..." or "Remove Worktree..."
  )
  for _, control in ipairs(controls) do
    local remote = self.mode == "remotes"
    control.visible = self.selected ~= nil
    if control == self.open then
      control.visible = self.selected and self.selected.path ~= nil
    elseif control == self.copy then
      control.visible = self.selected and self.selected.hash ~= nil
    elseif control == self.remove then
      control.visible = self.selected and (remote or self.mode == "worktrees")
    elseif control == self.download then
      control.visible = self.mode == "lfs"
        or self.selected and self.mode == "submodules"
    elseif control == self.add then
      control.visible = remote
    elseif control == self.edit then
      control.visible = remote and self.selected ~= nil
    elseif control == self.rename then
      control.visible = remote
        and self.selected
        and self.capabilities.remote_rename
    elseif control == self.default_remote then
      control.visible = remote
        and self.selected
        and not self.selected.is_default
        and self.capabilities.default_remote
    end
    if control.visible then
      if x + control:get_width() > width - gap / 2 then
        x, rows = gap / 2, rows + 1
      end
      control.layout_x, control.layout_row = x, rows
      x = x + control:get_width() + gap / 2
    end
  end
  local actions_top = bottom - rows * row
  for _, control in ipairs(controls) do
    if control.visible then
      control:set_position(
        control.layout_x,
        actions_top + (control.layout_row - 1) * row
      )
    end
  end
  local top, stacked = self.search:get_bottom() + gap / 2, width < 700 * SCALE
  local list_width = stacked and width - gap or width * 0.45 - gap
  local list_height = stacked and (actions_top - top) * 0.4
    or actions_top - top - gap
  self.container:set_position(gap / 2, top)
  self.container:set_size(list_width, math.max(1, list_height))
  self.list:resize_to_parent()
  self.preview:set_position(
    stacked and gap / 2 or width * 0.45,
    stacked and top + list_height + gap / 2 or top
  )
  local header = self.commit_details:layout(
    self.preview.position.rx, self.preview.position.ry,
    stacked and width - gap or width * 0.55 - gap,
    math.min(220 * SCALE,
      math.max(0, actions_top - self.preview.position.ry) * 0.3)
  )
  if header > 0 then
    self.preview:set_position(
      self.preview.position.rx, self.preview.position.ry + header + gap / 2
    )
  end
  self.preview:set_size(
    stacked and width - gap or width * 0.55 - gap,
    math.max(1, actions_top - self.preview.position.ry - gap)
  )
  self.preview.visible = self.mode ~= "remotes"
  self.remote_details.visible = self.mode == "remotes"
  self.remote_details:set_position(
    self.preview.position.rx,
    self.preview.position.ry
  )
  self.remote_details:set_size(self.preview.size.x, self.preview.size.y)
  self.status:set_position(gap / 2, height - row * 1.3)
  self.status:set_size(width - gap, row)
  return true
end

function RepositoryTools:try_close(close)
  self.commit_details:clear()
  self.generation = self.generation + 1
  self.preview_request = (self.preview_request or 0) + 1
  if self.preview then
    core.threads[self.preview.parse_key] = nil
  end
  close()
end

return RepositoryTools
