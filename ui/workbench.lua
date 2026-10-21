local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local Widget = require "widget"
local Button = require "widget.button"
local Label = require "widget.label"
local ListBox = require "widget.listbox"
local TextBox = require "widget.textbox"
local SelectBox = require "widget.selectbox"
local CheckBox = require "widget.checkbox"
local MessageBox = require "widget.messagebox"
local DiffPreview = require "plugins.scm.ui.diffpreview"
local CommitDetails = require "plugins.scm.ui.commitdetails"
local review = require "plugins.scm.review"
local repository_actions = require "plugins.scm.ui.repositoryactions"
local FormDialog = require "plugins.scm.ui.formdialog"

---Repository review surface. Backend operations remain asynchronous.
---@class plugins.scm.ui.Workbench : widget
local Workbench = Widget:extend()

local function button(parent, label, tooltip, action)
  local control = Button(parent, label)
  control.tooltip = tooltip
  control.border.width = 0
  control.padding.x, control.padding.y = 8 * SCALE, 4 * SCALE
  control:set_label(label)
  control.on_click = action
  return control
end

local function reset_list(list)
  list:filter(nil)
  list:clear()
  list.rows_original, list.row_data_original, list.rows_idx_original =
    {}, {}, {}
end

local function identity(entry)
  return entry and (entry.hash or entry.new_path or entry.path or entry.name)
end

local function graph_cell(graph)
  return function(_, _, x, y, font, _, only_calc)
    local step, height = 12 * SCALE, font:get_height() * 2
    if not only_calc then
      local colors = { style.accent, style.good, style.warn, style.text }
      local function edge(a, b, top, bottom)
        if not b then
          return
        end
        local ax, bx = x + (a - 0.5) * step, x + (b - 0.5) * step
        local mid, color = (top + bottom) / 2, colors[(a - 1) % #colors + 1]
        renderer.draw_rect(ax, top, 2 * SCALE, mid - top, color)
        renderer.draw_rect(
          math.min(ax, bx),
          mid,
          math.abs(bx - ax) + 2 * SCALE,
          2 * SCALE,
          color
        )
        renderer.draw_rect(bx, mid, 2 * SCALE, bottom - mid, color)
      end
      for _, item in ipairs(graph.edges) do
        edge(
          item[1],
          item[2],
          y - style.padding.y / 2,
          y + height + style.padding.y / 2
        )
      end
      local center = y + font:get_height() / 2
      if graph.incoming then
        edge(graph.lane, graph.lane, y - style.padding.y / 2, center)
      end
      for _, lane in ipairs(graph.parents) do
        edge(graph.lane, lane, center, y + height + style.padding.y / 2)
      end
      renderer.draw_rect(
        x + (graph.lane - 0.5) * step - 2 * SCALE,
        center - 2 * SCALE,
        6 * SCALE,
        6 * SCALE,
        style.accent
      )
    end
    return graph.width * step + 4 * SCALE, height
  end
end

function Workbench:new(project_dir, backend)
  Workbench.super.new(self, nil, false)
  self.defer_draw, self.border.width = false, 0
  self.name = common.basename(project_dir) .. " - Source Control"
  self.project_dir, self.backend = project_dir, backend
  self.scm = require "plugins.scm"
  if self.scm.register_workbench then
    self.scm.register_workbench(self)
  end
  self.mode, self.entries, self.generation, self.preview_generation =
    "changes", {}, 0, 0
  self.history_limit = 200
  self.diff_options = { context = 3 }
  self.change_sort = "path"
  self.busy = false
  self.viewed = { changes = {}, staged = {} }
  self.review_progress_dirty = true
  self.filter_key, self.filter_generation = {}, 0
  self.repo = SelectBox(self, "Repository")
  for _, project in ipairs(core.projects or {}) do
    if self.scm.get_path_backend(project.path) then
      self.repo:add_option(common.basename(project.path), project.path)
      if project.path == project_dir then
        self.repo:set_selected(self.repo.list and #self.repo.list.rows - 1 or 1)
      end
    end
  end
  if self.repo:get_selected() == 0 then
    self.repo:add_option(common.basename(project_dir), project_dir)
    self.repo:set_selected(#self.repo.list.rows - 1)
  end
  self.repo.on_selected = function(_, _, path)
    if self.busy then
      return
    end
    local selected_backend = self.scm.get_path_backend(path)
    if selected_backend then
      self.project_dir, self.backend, self.history_target =
        path, selected_backend, nil
      self.name = common.basename(path) .. " - Source Control"
      if
        self.mode == "staged" and not selected_backend:has_staging()
        or self.mode == "stashes" and not selected_backend:supports_stashes()
      then
        self.mode = "changes"
      end
      self:refresh()
    end
  end
  self.branch = Label(self, "")
  self.branch.foreground_color = style.accent
  self.toolbar = {
    button(self, "Refresh", "Reload repository state", function()
      self:refresh()
    end),
    button(self, "Fetch", "Fetch remote branches and tags", function()
      self:remote "fetch"
    end),
    button(self, "Pull", "Pull from the configured remote", function()
      self:remote "pull"
    end),
    button(self, "Push", "Push to the configured remote", function()
      self:remote "push"
    end),
  }
  self.compact_actions = SelectBox(self, "Actions")
  for _, item in ipairs({
    { "Refresh", "refresh" },
    { "Fetch", "fetch" },
    { "Pull", "pull" },
    { "Push", "push" },
    { "Commit...", "commit" },
    { "Amend...", "amend" },
    { "Repository Tools...", "tools" },
  }) do
    self.compact_actions:add_option(item[1], item[2])
  end
  self.compact_actions.on_selected = function(_, _, action)
    if action == "tools" then
      self.scm.open_repository_tools(self.project_dir)
    elseif action == "refresh" then
      self:refresh()
    elseif action == "commit" then
      self.scm.open_commit_message(self.project_dir)
    elseif action == "amend" then
      self.scm.open_amend_commit_message(self.project_dir)
    else
      self:remote(action)
    end
  end
  self.mode_select = SelectBox(self, "View")
  for _, item in ipairs({
    { "Changes", "changes" },
    { "Staged Changes", "staged" },
    { "History", "history" },
    { "Branches", "branches" },
    { "Tags", "tags" },
    { "Stashes", "stashes" },
  }) do
    if item[2] ~= "staged" or backend:has_staging() then
      self.mode_select:add_option(item[1], item[2])
    end
  end
  self.mode_select:set_selected(1)
  self.mode_select.on_selected = function(_, _, mode)
    if
      mode == "staged" and not self.backend:has_staging()
      or mode == "stashes" and not self.backend:supports_stashes()
    then
      mode = "changes"
      self.mode_select:set_selected(1)
    end
    self.mode, self.history_target = mode, nil
    self.search:set_text ""
    self:refresh()
  end
  self.nav = {}
  for _, item in ipairs({
    { "changes", "Changes" },
    { "staged", "Staged Changes" },
    { "history", "History" },
    { "branches", "Branches" },
    { "tags", "Tags" },
    { "stashes", "Stashes" },
  }) do
    local mode = item[1]
    self.nav[mode] = button(self, item[2], item[2], function()
      self.mode, self.history_target = mode, nil
      self.search:set_text ""
      self:refresh()
    end)
  end
  self.commit = button(
    self,
    "Commit...",
    "Review the commit message in the editor",
    function()
      self.scm.open_commit_message(self.project_dir)
    end
  )
  self.amend = button(self, "Amend...", "Amend the current commit", function()
    self.scm.open_amend_commit_message(self.project_dir)
  end)
  self.operation_label = Label(self, "")
  self.tools = button(
    self,
    "Tools...",
    "Repository tools and remote operations",
    function()
      self.scm.open_repository_tools(self.project_dir)
    end
  )
  self.operation_label.foreground_color = style.warn
  self.continue = button(
    self,
    "Continue",
    "Continue the interrupted repository operation",
    function()
      self:resolve_operation "continue"
    end
  )
  self.abort = button(
    self,
    "Abort...",
    "Abort the interrupted repository operation",
    function()
      self:resolve_operation "abort"
    end
  )
  self.heading = Label(self, "Changes")
  self.skip = button(self, "Skip...", "Skip the interrupted commit", function()
    self:resolve_operation "skip"
  end)
  self.search = TextBox(self, "", "Filter...")
  self.search.on_change = function()
    self:queue_filter()
  end
  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list.on_row_click = function(_, _, entry)
    self:select(entry)
  end
  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(list, button, x, y, clicks)
    local processed = list_on_mouse_pressed(list, button, x, y, clicks)
    if processed and not list.is_scrolling and button == "left" and clicks == 2
      and self.mode == "history" and not self.loading and not self.busy
    then
      local index = list:get_row_at_position(x, y)
      local entry = index and list:get_row_data(index)
      if entry then
        list:set_selected(index)
        self:select(entry)
        self:open_commit_diff()
      end
    end
    return processed
  end
  self.detail = Label(self, "")
  self.detail.scrollable, self.detail.clickable = true, true
  self.preview = DiffPreview(self)
  self.commit_details = CommitDetails(self)
  self.viewed_checkbox = CheckBox(self, "Viewed")
  self.viewed_checkbox.on_checked = function(_, checked)
    self:mark_viewed(checked)
  end
  self.next_unreviewed = button(
    self,
    "Next Unreviewed",
    "Select the next file not yet reviewed",
    function()
      self:select_next_unreviewed()
    end
  )
  self.status = Label(self, "")
  self.status.foreground_color = style.dim
  self.actions = {}
  local function action(id, label, tooltip, fn)
    self.actions[id] = button(self, label, tooltip, fn)
  end
  action("file", "Open File", "Open the selected file in the editor", function()
    self:open_file()
  end)
  action("add", "Add to Repository", "Track the selected file", function()
    local entry = self.selected
    if self.loading or self.mode ~= "changes"
      or not entry or entry.status ~= "untracked"
    then
      return
    end
    self:mutate(function(done)
      self.backend:add_path(
        entry.new_path or entry.path, self.project_dir, done
      )
    end)
  end)
  action("resolve", "Resolve...", "Open the conflict editor", function()
    if self.selected then
      self.scm.open_conflict(
        self.selected.new_path or self.selected.path,
        self.project_dir
      )
    end
  end)
  action(
    "binary",
    "Image / Binary...",
    "Compare binary file versions",
    function()
      if self.selected then
        self.scm.open_binary_diff(
          self.selected.new_path or self.selected.path,
          self.project_dir,
          self.mode == "staged"
        )
      end
    end
  )
  action("stage", "+ File", "Stage the selected file", function()
    self:stage(false, false)
  end)
  action("unstage", "- File", "Unstage the selected file", function()
    self:stage(true, false)
  end)
  action("hunk", "+ Hunk", "Stage the selected hunk", function()
    self:stage(false, true)
  end)
  action("unhunk", "- Hunk", "Unstage the selected hunk", function()
    self:stage(true, true)
  end)
  action("lines", "+ Lines", "Stage the selected lines", function()
    self:stage(false, true, true)
  end)
  action("unlines", "- Lines", "Unstage the selected lines", function()
    self:stage(true, true, true)
  end)
  action(
    "discard",
    "Discard...",
    "Restore the selected tracked file",
    function()
      if self.selected then
        self.scm.revert_file(self.selected.new_path or self.selected.path)
      end
    end
  )
  action("diff", "View Diff", "Open the selected commit's diff viewer", function()
    self:open_commit_diff()
  end)
  action(
    "pick",
    "Cherry Pick...",
    "Apply the selected commit to the current checkout",
    function()
      if self.selected then
        self.scm.cherry_pick(self.selected.hash, self.project_dir, function()
          self:refresh()
        end)
      end
    end
  )
  action("copy", "Copy Hash", "Copy the selected commit hash", function()
    if self.selected then
      system.set_clipboard(self.selected.hash or self.selected.commit)
    end
  end)
  action(
    "history",
    "History",
    "Show commits on the selected branch or tag",
    function()
      self:ref_history()
    end
  )
  action(
    "checkout",
    "Checkout...",
    "Check out the selected branch or tag",
    function()
      local entry = self.selected
      if not entry then
        return
      end
      MessageBox.warning(
        "SCM Checkout",
        "Check out '" .. entry.name .. "'?",
        function(_, id)
          if id == 1 then
            self.scm.checkout(entry.name, self.project_dir)
          end
        end,
        MessageBox.BUTTONS_YES_NO
      )
    end
  )
  action("manage", "Manage...", "Open branch or tag management", function()
    if self.mode == "tags" then
      self.scm.open_tags_list(self.project_dir)
    else
      self.scm.open_branches_list(self.project_dir)
    end
  end)
  action("create", "Create...", "Create a branch or tag", function()
    local fn = self.mode == "tags" and self.scm.create_tag
      or self.scm.create_branch
    fn(self.project_dir, function(ok)
      if ok then
        self:refresh()
      end
    end)
  end)
  action("more", "Load More", "Load another 200 commits", function()
    self.history_limit = self.history_limit + 200
    self:refresh()
  end)
  action(
    "save-stash",
    "Stash...",
    "Save tracked changes and restore the working tree",
    function()
      repository_actions.stash(self.backend, self.project_dir, function()
        self:refresh()
      end)
    end
  )
  action(
    "apply-stash",
    "Apply Stash...",
    "Apply the stash and keep its saved copy",
    function()
      local entry = self.selected
      if not entry then
        return
      end
      repository_actions.apply_stash(
        self.backend,
        self.project_dir,
        entry,
        function()
          self:refresh()
        end
      )
    end
  )
  action(
    "delete-stash",
    "Delete Stash...",
    "Delete the selected saved stash",
    function()
      local entry = self.selected
      if not entry then
        return
      end
      MessageBox.warning(
        "SCM Delete Stash",
        "Delete saved stash '" .. entry.name .. "'?",
        function(_, id)
          if id == 1 then
            self:mutate(function(cb)
              self.backend:delete_stash(entry.id, self.project_dir, cb)
            end)
          end
        end,
        MessageBox.BUTTONS_YES_NO
      )
    end
  )
  self.diff_modes = {
    button(self, "Options...", "Diff context and whitespace", function()
      local fields = {
        {
          id = "context",
          label = "Context",
          value = self.diff_options.context,
          options = {
            { "3 lines", 3 },
            { "10 lines", 10 },
            { "50 lines", 50 },
            { "Full file", 1000000 },
          },
        },
        {
          id = "whitespace",
          label = "Ignore whitespace changes",
          kind = "check",
          value = self.diff_options.whitespace,
        },
        {
          id = "errors",
          label = "Highlight trailing whitespace",
          kind = "check",
          value = self.preview.whitespace_errors,
        },
      }
      if self.mode == "changes" or self.mode == "staged" then
        fields[#fields + 1] = {
          id = "sort",
          label = "Changed-file order",
          value = self.change_sort,
          options = {
            { "Path", "path" },
            { "Status", "status" },
            { "Last modified (newest first)", "modified" },
          },
        }
      end
      FormDialog("SCM Diff Options", fields, function(values, done)
        self.diff_options =
          { context = values.context, whitespace = values.whitespace }
        self.preview.whitespace_errors = values.errors
        local changed_sort = values.sort and values.sort ~= self.change_sort
        self.change_sort = values.sort or self.change_sort
        done(true)
        if changed_sort then
          self:queue_filter()
        else
          self:select(self.selected)
        end
      end):show()
    end),
    button(self, "Unified", "Unified diff", function()
      self.preview.side_by_side = false
      self:schedule_update()
    end),
    button(self, "Split", "Side-by-side diff", function()
      self.preview.side_by_side = true
      self:schedule_update()
    end),
    button(self, "<", "Previous hunk", function()
      self.preview:move_hunk(-1)
    end),
    button(self, ">", "Next hunk", function()
      self.preview:move_hunk(1)
    end),
  }
  self:show()
  if backend then
    self:refresh()
  end
end

function Workbench:try_close(do_close)
  self.commit_details:clear()
  self.generation, self.preview_generation =
    self.generation + 1, self.preview_generation + 1
  self.preview.generation = self.preview.generation + 1
  core.threads[self.filter_key] = nil
  core.threads[self.preview.parse_key] = nil
  do_close()
end

function Workbench:remote(operation)
  if self.busy then
    return
  end
  self.busy = true
  self.status:set_label(operation .. "...")
  self.scm[operation](self.project_dir, function(ok, errmsg)
    self.busy = false
    if ok then
      self:refresh()
    else
      self.status:set_label(errmsg or (operation .. " cancelled"))
    end
  end)
end

function Workbench:mutate(run)
  if self.busy then
    return
  end
  self.busy = true
  run(function(ok, errmsg)
    self.busy = false
    if not ok then
      MessageBox.error(
        "SCM Operation Failed",
        errmsg and errmsg ~= "" and errmsg or "Operation failed."
      )
    end
    self.scm.update()
    self:refresh()
  end)
end

function Workbench:resolve_operation(action)
  if not self.operation or self.busy then
    return
  end
  local kind = self.operation.kind
  if action == "continue" and self.operation.commit_required then
    self.scm.open_commit_message(self.project_dir)
    return
  end
  local run = function()
    self:mutate(function(cb)
      self.backend:resolve_operation(self.project_dir, kind, action, cb)
    end)
  end
  if action == "abort" or action == "skip" then
    MessageBox.warning(
      "SCM " .. action .. " " .. kind,
      action == "skip"
          and "Skip this commit and discard its resolution changes?"
        or self.operation.abort_warning
        or "Abort the current "
          .. kind
          .. " and discard its resolution changes?",
      function(_, id)
        if id == 1 then
          run()
        end
      end,
      MessageBox.BUTTONS_YES_NO
    )
  else
    run()
  end
end

function Workbench:refresh()
  self.generation, self.preview_generation =
    self.generation + 1, self.preview_generation + 1
  self.filter_generation = self.filter_generation + 1
  core.threads[self.filter_key] = nil
  local generation, mode = self.generation, self.mode
  local selected_key = identity(self.selected)
  self.refreshing = true
  self.loading = self.snapshot_mode ~= mode
  if self.loading then
    self.commit_details:clear()
    self.preview:set_message "Loading..."
    self.status:set_label("Loading " .. mode .. "...")
  end
  self.backend:get_branch(self.project_dir, function(branch)
    if generation == self.generation then
      self.branch:set_label(branch or "Detached checkout")
      core.redraw = true
    end
  end)
  if self.backend.get_operation_status then
    self.backend:get_operation_status(self.project_dir, function(operation)
      if generation ~= self.generation then
        return
      end
      self.operation = operation
      self.operation_label:set_label(
        operation and (operation.kind .. " in progress") or ""
      )
      self:schedule_update()
    end)
  end
  local callback = function(entries, errmsg)
    if generation ~= self.generation then
      return
    end
    if not entries then
      self.loading, self.refreshing = false, false
      self.snapshot_key, self.snapshot_mode = nil, nil
      self.entries = {}
      reset_list(self.list)
      self:select(nil)
      self.status:set_label(
        errmsg and errmsg ~= "" and errmsg or "Could not load repository state"
      )
      self.preview:set_message "Repository query failed"
      self.commit_details:clear()
      return
    end
    local signature = review.snapshot_key(entries, function()
      self.backend:yield()
    end)
    if generation ~= self.generation then
      return
    end
    if
      (mode == "changes" or mode == "staged")
      and (next(self.viewed.changes) or next(self.viewed.staged))
    then
      local valid = { changes = {}, staged = {} }
      for i, entry in ipairs(entries) do
        if entry.unstaged then
          valid.changes[identity(entry)] = true
        end
        if entry.staged then
          valid.staged[identity(entry)] = true
        end
        if i % 100 == 0 then
          self.backend:yield()
        end
      end
      if generation ~= self.generation then
        return
      end
      for pending, marks in pairs(self.viewed) do
        for path in pairs(marks) do
          if not valid[pending][path] then
            marks[path] = nil
          end
        end
      end
      self.review_progress_dirty = true
    end
    self.loading, self.refreshing = false, false
    if self.snapshot_key == signature and self.snapshot_mode == mode then
      self.entries = entries
      if self.selected then self:select(self.selected) end
      self.status:set_label(#self.list.rows .. " items")
      return
    end
    self.snapshot_key, self.snapshot_mode = signature, mode
    self.entries = entries
    if mode == "history" and entries[1] and entries[1].parents ~= nil then
      local graphs = review.graph(entries)
      for i, graph in ipairs(graphs) do
        entries[i].graph = graph
      end
    end
    self:filter(selected_key)
    self.status:set_label(
      tostring(#self.list.rows)
        .. " items"
        .. (
          mode == "history" and " / " .. self.history_limit .. " loaded limit"
          or ""
        )
    )
  end
  if mode == "changes" or mode == "staged" then
    self.backend:get_working_changes(self.project_dir, callback)
  elseif mode == "history" then
    self.backend:get_review_history(
      self.project_dir,
      callback,
      self.history_target,
      self.history_limit,
      self.history_target_type
    )
  elseif mode == "branches" then
    self.backend:get_branches(self.project_dir, callback)
  elseif mode == "tags" then
    self.backend:get_tags(self.project_dir, callback)
  end
  if mode == "stashes" then
    self.backend:get_stashes(self.project_dir, callback)
  end
end

function Workbench:queue_filter()
  self.filter_generation = self.filter_generation + 1
  local generation = self.filter_generation
  core.add_thread(function()
    coroutine.yield(0.12)
    if generation == self.filter_generation then
      self:filter(nil, generation)
    end
  end, self.filter_key)
end

function Workbench:filter(selected_key, filter_generation)
  if self.loading then
    return
  end
  selected_key = selected_key or identity(self.selected)
  reset_list(self.list)
  local mode, query = self.mode, self.search:get_text()
  local show_graph = query == ""
  local matches = review.compile_query(query)
  self.list.columns = {}
  if mode == "history" then
    if show_graph and self.entries[1] and self.entries[1].graph then
      self.list:add_column ""
    end
    self.list:add_column "Commit"
    self.list:add_column "Author"
    self.list:add_column "Date"
  elseif mode == "branches" or mode == "tags" or mode == "stashes" then
    self.list:add_column(
      mode == "branches" and "Branch" or mode == "tags" and "Tag" or "Stash"
    )
    self.list:add_column "Last Commit"
  else
    self.list:add_column "Status"
    self.list:add_column "File"
  end
  local selection, working, staged = nil, 0, 0
  local generation, query_generation = self.generation, self.filter_generation
  local entries = self.entries
  if mode == "changes" or mode == "staged" then
    entries = review.sort_changes(entries, self.change_sort, function(path)
      local info = system.get_file_info(path)
      return info and info.modified or 0
    end, function()
      self.backend:yield()
    end)
    if
      generation ~= self.generation
      or query_generation ~= self.filter_generation
    then
      return
    end
  end
  for i, entry in ipairs(entries) do
    if filter_generation and i % 100 == 0 then
      coroutine.yield()
      if filter_generation ~= self.filter_generation then
        return
      end
    end
    if not filter_generation and i % 100 == 0 then
      self.backend:yield()
      if
        generation ~= self.generation
        or query_generation ~= self.filter_generation
      then
        return
      end
    end
    if entry.unstaged then
      working = working + 1
    end
    if entry.staged then
      staged = staged + 1
    end
    local path = entry.new_path or entry.path or ""
    local fields = {
      author = entry.author or "",
      message = entry.summary or entry.message or "",
      hash = entry.hash or entry.commit or "",
      ref = entry.refs or entry.name or "",
      path = path,
      status = entry.conflicted and "conflict" or entry.status or "",
    }
    local include = mode ~= "changes" and mode ~= "staged"
      or mode == "staged" and entry.staged
      or mode == "changes" and entry.unstaged
    if include and matches(fields) then
      local row
      if mode == "history" then
        row = {
          style.text,
          entry.summary or "",
          ListBox.NEWLINE,
          style.accent,
          (entry.hash or ""):sub(1, 10)
            .. (entry.refs and entry.refs ~= "" and "  " .. entry.refs or ""),
          ListBox.COLEND,
          style.dim,
          entry.author or "",
          ListBox.COLEND,
          style.dim,
          entry.date or "",
        }
        if show_graph and entry.graph then
          table.insert(row, 1, ListBox.COLEND)
          table.insert(row, 1, graph_cell(entry.graph))
        end
      elseif mode == "branches" or mode == "tags" or mode == "stashes" then
        row = {
          style.accent,
          entry.name,
          ListBox.COLEND,
          style.text,
          entry.message or "",
          ListBox.NEWLINE,
          style.dim,
          (entry.commit or ""):sub(1, 10) .. "  " .. (entry.date or ""),
        }
      else
        local color = entry.conflicted and style.error
          or entry.status == "added" and style.good
          or entry.status == "deleted" and style.error
          or style.warn
        row = {
          color,
          fields.status,
          ListBox.COLEND,
          style.text,
          common.relative_path(self.project_dir, path),
        }
      end
      self.list:add_row(row, entry)
      core.redraw = true
      if identity(entry) == selected_key then
        selection = #self.list.rows
      end
    end
  end
  if mode == "changes" or mode == "staged" then
    self.working_count, self.staged_count = working, staged
    self.nav.changes:set_label("Changes (" .. working .. ")")
    self.nav.staged:set_label("Staged (" .. staged .. ")")
  end
  if
    self.list.size.x ~= self.list_container.size.x
    or self.list.size.y ~= self.list_container.size.y
  then
    self.list:resize_to_parent()
  end
  self.list:set_selected(selection or (#self.list.rows > 0 and 1 or nil))
  self:select(self.list:get_row_data(self.list:get_selected() or 0))
  self:schedule_update()
end

function Workbench:select(entry)
  local same_preview = entry ~= nil
    and self.preview_entry == identity(entry)
    and self.preview_mode == self.mode
  self.preview_entry, self.preview_mode = identity(entry), self.mode
  self.selected = entry
  self.preview_generation = self.preview_generation + 1
  local generation = self.preview_generation
  if not same_preview then
    self.reviewed_diff = nil
    self.viewed_checkbox:set_checked(false)
    self.detail:set_label ""
    self.preview:set_message(
      entry and "Loading diff..."
        or (self.mode == "changes" and "Working tree clean" or "No items")
    )
  end
  if not entry then
    self.commit_details:clear()
    return
  end
  local mode, path = self.mode, entry.new_path or entry.path
  local hash = mode == "history" and entry.hash
    or (mode == "branches" or mode == "tags") and entry.commit
  if hash then
    self.commit_details:load(self.backend, self.project_dir, hash, {
      summary = entry.summary or mode == "branches" and entry.message,
      author = entry.author, date = entry.date,
    })
  else
    self.commit_details:clear()
  end
  local callback = function(diff, errmsg, read_error)
    errmsg = read_error or type(errmsg) == "string" and errmsg or nil
    if generation ~= self.preview_generation then
      return
    end
    if diff then
      if self.viewed[mode] then
        local fingerprint = review.diff_fingerprint(diff, function()
          self.backend:yield()
        end)
        if generation ~= self.preview_generation then
          return
        end
        local key = identity(entry)
        if self.viewed[mode][key] ~= fingerprint then
          self.viewed[mode][key] = nil
        end
        self.reviewed_diff = fingerprint
        self.review_progress_dirty = true
        self.viewed_checkbox:set_checked(self.viewed[mode][key] ~= nil)
      end
      self.preview:set_diff(diff, path)
    else
      self.preview:set_message(errmsg or "Diff unavailable")
    end
  end
  if mode == "changes" or mode == "staged" then
    self.detail:set_label(
      common.relative_path(self.project_dir, path)
        .. "\n"
        .. (
          entry.conflicted and "Merge conflict"
          or mode == "staged" and "Index"
          or "Working tree"
        )
    )
    if mode == "staged" then
      if self.backend.get_review_diff then
        self.backend:get_review_diff(path, self.project_dir, callback, {
          staged = true,
          context = self.diff_options.context,
          whitespace = self.diff_options.whitespace,
        })
      else
        self.backend:get_staged_file_diff(path, self.project_dir, callback)
      end
    elseif entry.status == "untracked" then
      local info = system.get_file_info(path)
      if not info or info.type ~= "file" then
        callback(nil, "Untracked directory")
      elseif info.size > 1024 * 1024 then
        callback(nil, "File exceeds 1 MiB preview limit")
      else
        local file = io.open(path, "rb")
        local text = file and file:read "*a"
        if file then
          file:close()
        end
        if not text then
          callback(nil, "Could not read file")
        elseif text:find "%z" then
          callback(nil, "Binary file")
        else
          callback(
            "--- /dev/null\n+++ "
              .. path
              .. "\n@@ -0,0 +1 @@\n+"
              .. text:gsub("\n", "\n+"):gsub("%+$", "")
              .. "\n"
          )
        end
      end
    else
      if self.backend.get_review_diff then
        self.backend:get_review_diff(
          path,
          self.project_dir,
          callback,
          self.diff_options
        )
      else
        self.backend:get_file_diff(path, self.project_dir, callback)
      end
    end
  elseif mode == "history" then
    self.detail:set_label(
      (entry.summary or "")
        .. "\n"
        .. entry.hash
        .. "  "
        .. (entry.author or "")
        .. "  "
        .. (entry.date or "")
    )
    self.backend:get_commit_diff(entry.hash, self.project_dir, callback)
  elseif mode == "stashes" then
    self.detail:set_label(entry.name .. "\n" .. (entry.message or ""))
    self.backend:get_stash_diff(entry.id, self.project_dir, callback)
  else
    self.detail:set_label(
      entry.name
        .. "\n"
        .. (entry.commit or "")
        .. "  "
        .. (entry.message or "")
    )
    self.backend:get_commit_diff(entry.commit, self.project_dir, callback)
  end
end

function Workbench:mark_viewed(checked)
  local marks = self.viewed[self.mode]
  if not marks or not self.selected or not self.reviewed_diff then
    self.viewed_checkbox:set_checked(false)
    return
  end
  marks[identity(self.selected)] = checked and self.reviewed_diff or nil
  self.review_progress_dirty = true
  core.redraw = true
end

function Workbench:select_next_unreviewed()
  local marks = self.viewed[self.mode]
  if not marks then
    return
  end
  local count, current = #self.list.rows, self.list:get_selected() or 0
  for offset = 1, count do
    local index = (current + offset - 1) % count + 1
    local entry = self.list:get_row_data(index)
    if entry and not marks[identity(entry)] then
      self.list:set_selected(index)
      self:select(entry)
      return
    end
  end
end

function Workbench:stage(reverse, partial, lines)
  if self.busy or not self.selected or self.loading then
    return
  end
  local entry = self.selected
  if partial and self.diff_options.whitespace then
    MessageBox.error(
      "SCM Stage",
      "Disable Ignore Whitespace before partial staging."
    )
    return
  end
  if entry.conflicted and partial then
    MessageBox.error(
      "SCM Stage",
      "Resolve the conflict in the editor, then stage the whole file."
    )
    return
  end
  local patch = partial
    and review.hunk_patch(
      self.preview.selected_hunk,
      lines and self.preview.line_selection or nil,
      reverse
    )
  if partial and not patch then
    return
  end
  self.busy = true
  local callback = function(ok, errmsg)
    self.busy = false
    if ok then
      self.scm.update()
      self:refresh()
    else
      MessageBox.error(
        "SCM Staging Failed",
        errmsg and errmsg ~= "" and errmsg or "Could not update the index."
      )
    end
  end
  if partial then
    self.backend:apply_index_patch(patch, self.project_dir, reverse, callback)
  else
    self.backend:stage_change(entry, self.project_dir, reverse, callback)
  end
end

function Workbench:open_file()
  if not self.selected then
    return
  end
  local path = self.selected.new_path or self.selected.path
  local info = path and system.get_file_info(path)
  if info and info.type == "file" then
    core.root_view:open_doc(core.open_doc(path))
  end
end

function Workbench:open_commit_diff()
  if self.mode ~= "history" or self.loading or self.busy
    or not self.selected or not self.selected.hash
  then
    return
  end
  self.scm.open_commit_diff(self.selected.hash, self.project_dir)
end

function Workbench:ref_history()
  if not self.selected then
    return
  end
  self.history_target, self.history_target_type =
    self.selected.name, self.mode == "tags" and "tag" or "branch"
  self.mode = "history"
  self.search:set_text ""
  self:refresh()
end

function Workbench:update()
  if not Workbench.super.update(self) then
    return false
  end
  local gap, row = 8 * SCALE, style.font:get_height() + 8 * SCALE
  local w, h = self.size.x, self.size.y
  local compact = w < 850 * SCALE or h < 500 * SCALE
  local narrow = w < 650 * SCALE
  local sidebar = compact and 0 or math.min(180 * SCALE, w * 0.2)
  self.repo:set_position(gap, gap)
  self.repo:set_size(
    math.max(100 * SCALE, math.min(w * 0.32, 260 * SCALE)),
    row
  )
  local tx = self.repo:get_right() + gap
  for _, control in ipairs(self.toolbar) do
    control:set_position(tx, gap)
    control.visible = not narrow
    tx = tx + control:get_width() + gap
  end
  self.compact_actions.visible = narrow
  self.compact_actions:set_position(w * 0.55, gap)
  self.compact_actions:set_size(w * 0.45 - gap, row)
  self.branch:set_position(gap, gap * 2 + row)
  self.branch:set_size(w - gap * 2, row)
  local top = gap * 3 + row * 2
  local nx, ny = gap, top
  for _, mode in ipairs({
    "changes",
    "staged",
    "history",
    "branches",
    "tags",
    "stashes",
  }) do
    local control = self.nav[mode]
    control.visible = mode ~= "staged" or self.backend:has_staging()
    if mode == "stashes" then
      control.visible = self.backend:supports_stashes()
    end
    if narrow then
      control.visible = false
    end
    if control.visible then
      control:set_label(
        mode == "changes" and ("Changes (" .. (self.working_count or 0) .. ")")
          or mode == "staged" and ("Staged (" .. (self.staged_count or 0) .. ")")
          or mode:sub(1, 1):upper() .. mode:sub(2)
      )
      control.foreground_color = mode == self.mode and style.accent
        or style.text
      control:set_position(nx, ny)
      if sidebar > 0 then
        control:set_size(sidebar - gap * 2, row)
        ny = ny + row + gap / 2
      else
        control:set_label(
          mode == "staged" and "Staged" or mode:sub(1, 1):upper() .. mode:sub(2)
        )
        nx = nx + control:get_width() + gap / 2
      end
    end
  end
  self.mode_select.visible = narrow
  self.mode_select:set_position(gap, top)
  self.mode_select:set_size(w - gap * 2, row)
  self.commit:set_position(
    sidebar > 0 and gap
      or w - self.commit:get_width() - self.amend:get_width() - gap * 3,
    sidebar > 0 and ny + gap * 2 or gap * 2 + row
  )
  self.amend:set_position(
    sidebar > 0 and gap or self.commit:get_right() + gap,
    sidebar > 0 and self.commit:get_bottom() + gap / 2 or gap * 2 + row
  )
  self.commit.visible, self.amend.visible = not narrow, not narrow
  self.tools.visible = not narrow
  self.tools:set_position(
    sidebar > 0 and gap
      or self.commit.position.rx - self.tools:get_width() - gap,
    sidebar > 0 and self.amend:get_bottom() + gap or self.amend.position.ry
  )
  self.operation_label.visible = self.operation ~= nil
  self.continue:set_label(
    self.operation and self.operation.commit_required and "Commit..."
      or "Continue"
  )
  self.abort:set_label(
    self.operation and self.operation.commit_required and "Undo..."
      or "Abort..."
  )
  self.continue.visible, self.abort.visible =
    self.operation ~= nil, self.operation ~= nil
  self.operation_label:set_position(sidebar + gap, top)
  self.operation_label:set_size(math.max(1, w - sidebar - gap * 2), row)
  self.continue:set_position(sidebar + gap, top + row)
  self.abort:set_position(self.continue:get_right() + gap, top + row)
  self.skip.visible = self.operation ~= nil
    and not self.operation.commit_required
    and self.operation.kind ~= "merge"
  self.skip:set_position(self.abort:get_right() + gap, top + row)
  if self.operation then
    top = top + row * 2 + gap
  end
  local content_x = sidebar + gap
  if compact then
    top = top + row + gap
  end
  local available = math.max(1, w - content_x - gap)
  local stacked = narrow
  local list_w = stacked and available or math.floor(available * 0.43)
  local list_bottom = stacked and top + math.max(row * 4, (h - top) * 0.36)
    or h - row - gap
  self.heading:set_label(
    self.mode == "history" and (self.history_target or "All History")
      or self.mode:sub(1, 1):upper() .. self.mode:sub(2)
  )
  self.heading:set_position(content_x, top)
  self.heading:set_size(list_w, row)
  self.search:set_position(content_x, top + row)
  self.search:set_size(list_w)
  local list_top = self.search:get_bottom() + gap / 2
  self.list_container:set_position(content_x, list_top)
  self.list_container:set_size(
    list_w,
    math.max(1, list_bottom - list_top)
  )
  self.list:resize_to_parent()
  local dx = stacked and content_x or content_x + list_w + gap
  local dy = stacked and list_bottom + gap or top
  local dw = math.max(1, w - dx - gap)
  self.detail:set_position(dx, dy)
  self.detail:set_size(dw, row * 2)
  self.detail.visible = not self.commit_details.visible
  local details_height = self.commit_details.visible
    and self.commit_details:layout(dx, dy, dw,
      math.min(220 * SCALE, math.max(0, h - dy) * 0.3))
    or row * 2
  dy = dy + details_height + gap / 2
  local pending = self.mode == "changes" or self.mode == "staged"
  local selected = self.selected ~= nil and not self.loading and not self.busy
  local untracked = selected and self.selected.status == "untracked"
  local staging = pending and self.backend:has_staging() and not untracked
  local hunk = self.preview.selected_hunk
  local partial = hunk
    and hunk.file.partial
    and not self.diff_options.whitespace
  local active = {
    binary = pending and selected,
    resolve = pending and selected and self.selected.conflicted,
    file = pending and selected,
    add = self.mode == "changes" and untracked
      and self.backend.add_path ~= nil,
    stage = staging and self.mode == "changes" and selected,
    unstage = staging and self.mode == "staged" and selected,
    hunk = staging
      and self.mode == "changes"
      and selected
      and self.backend:supports_partial_staging()
      and partial ~= nil
      and partial,
    unhunk = staging
      and self.mode == "staged"
      and selected
      and self.backend:supports_partial_staging()
      and partial ~= nil
      and partial,
    lines = staging
      and not self.diff_options.whitespace
      and self.mode == "changes"
      and selected
      and self.preview.line_selection ~= nil
      and self.backend:supports_partial_staging(),
    unlines = staging
      and not self.diff_options.whitespace
      and self.mode == "staged"
      and selected
      and self.preview.line_selection ~= nil
      and self.backend:supports_partial_staging(),
    discard = self.mode == "changes"
      and selected
      and self.selected.status ~= "untracked",
    diff = self.mode == "history" and selected
      and self.selected.hash ~= nil,
    pick = self.mode == "history"
      and selected
      and self.backend:supports_cherry_pick(),
    copy = not pending
      and selected
      and (self.selected.hash or self.selected.commit) ~= nil,
    history = (self.mode == "branches" or self.mode == "tags") and selected,
    checkout = (self.mode == "branches" or self.mode == "tags") and selected,
    manage = self.mode == "branches" or self.mode == "tags",
    create = self.mode == "branches" or self.mode == "tags",
    more = self.mode == "history",
    ["save-stash"] = (pending or self.mode == "stashes")
      and self.backend:supports_stashes(),
    ["apply-stash"] = self.mode == "stashes" and selected,
    ["delete-stash"] = self.mode == "stashes" and selected,
  }
  local ax, ay = dx, dy
  for _, id in ipairs({
    "file",
    "add",
    "resolve",
    "binary",
    "stage",
    "unstage",
    "hunk",
    "unhunk",
    "lines",
    "unlines",
    "discard",
    "diff",
    "pick",
    "copy",
    "history",
    "checkout",
    "manage",
    "create",
    "more",
    "save-stash",
    "apply-stash",
    "delete-stash",
  }) do
    local control = self.actions[id]
    control.visible = active[id] == true
    if control.visible then
      if ax + control:get_width() > dx + dw then
        ax, ay = dx, ay + row
      end
      control:set_position(ax, ay)
      ax = ax + control:get_width() + gap / 2
    end
  end
  ay = ay + row
  ax = dx
  self.viewed_checkbox.visible = pending
    and selected
    and self.reviewed_diff ~= nil
  self.next_unreviewed.visible = pending and selected
  if pending and selected then
    if self.review_progress_dirty then
      local marks, count, total = self.viewed[self.mode], 0, 0
      for _, entry in ipairs(self.entries) do
        if
          self.mode == "staged" and entry.staged
          or self.mode == "changes" and entry.unstaged
        then
          total = total + 1
          if marks[identity(entry)] then
            count = count + 1
          end
        end
      end
      self.viewed_checkbox:set_label("Viewed (" .. count .. "/" .. total .. ")")
      self.review_progress_dirty = false
    end
    for _, control in ipairs({ self.viewed_checkbox, self.next_unreviewed }) do
      if control.visible then
        if ax + control:get_width() > dx + dw then
          ax, ay = dx, ay + row
        end
        control:set_position(ax, ay)
        ax = ax + control:get_width() + gap
      end
    end
    ax, ay = dx, ay + row
  end
  for _, control in ipairs(self.diff_modes) do
    if ax + control:get_width() > dx + dw then
      ax, ay = dx, ay + row
    end
    control:set_position(ax, ay)
    ax = ax + control:get_width() + gap / 2
  end
  self.preview:set_position(dx, ay + row)
  self.preview:set_size(dw, math.max(1, h - ay - row * 2 - gap))
  self.status:set_position(content_x, h - row)
  self.status:set_size(available, row)
  return true
end

command.add(function()
  return core.active_view:is(Workbench), core.active_view
end, {
  ["scm-workbench:refresh"] = function(view)
    view:refresh()
  end,
  ["scm-workbench:next-item"] = function(view)
    local index = math.min(#view.list.rows, (view.list:get_selected() or 0) + 1)
    if index > 0 then
      view.list:set_selected(index)
      view:select(view.list:get_row_data(index))
    end
  end,
  ["scm-workbench:previous-item"] = function(view)
    local index = math.max(1, (view.list:get_selected() or 2) - 1)
    view.list:set_selected(index)
    view:select(view.list:get_row_data(index))
  end,
})
keymap.add({
  ["f5"] = "scm-workbench:refresh",
  ["alt+down"] = "scm-workbench:next-item",
  ["alt+up"] = "scm-workbench:previous-item",
})

return Workbench
