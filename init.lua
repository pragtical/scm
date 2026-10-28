-- mod-version:3.14.0
--
-- Source Control Management plugin.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
-- Note: Some ideas and bits taken from:
-- https://github.com/vincens2005/lite-xl-gitdiff-highlight
-- https://github.com/pragtical/plugins/blob/master/plugins/gitstatus.lua
-- Thanks to everyone involved!
--
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local util = require "plugins.scm.util"
local changes = require "plugins.scm.changes"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Node = require "core.node"
local RootView = require "core.rootview"
local DirWatch = require "core.dirwatch"
local StatusView = require "core.statusview"
local Git = require "plugins.scm.backend.git"
local Fossil = require "plugins.scm.backend.fossil"
local Widget = require "widget"
local MessageBox = require "widget.messagebox"
local diffview_loaded, diffview = pcall(require, "plugins.diffview")

---@cast diffview_loaded boolean
---@cast diffview plugins.diffview

---Backends shipped with the plugin.
---@type table<string,plugins.scm.backend>
local BACKENDS

---Corrects the path set for git or fossil commands when using the settings ui.
---@param path string
---@return string path
local function config_fix_path(path)
  if not io.open(path, "rb") then
    path = common.basename(path)
  end
  return path
end

---@class config.plugins.smc
---@field highlighter boolean
---@field highlighter_alignment "right" | "left"
---@field git_path string
---@field fossil_path string
---@field diff_viewer "advanced" | "text"
---@field blame_display "bottom" | "floating"
config.plugins.smc = common.merge({
  highlighter = true,
  tab_colors = true,
  diff_viewer = "advanced",
  blame_display = "bottom",
  highlighter_alignment = "right",
  git_path = "git",
  fossil_path = "fossil",
  config_spec = {
    name = "Source Control Management",
    {
      label = "Diff Viewer",
      description = "Default viewer for file, commit, branch and tag changes.",
      path = "diff_viewer",
      type = "selection",
      default = "advanced",
      values = {
        {"Advanced (Changed Files)", "advanced"},
        {"Plain Text", "text"}
      }
    },
    {
      label = "Blame Display",
      description = "Show current-line commit details below the document or "
        .. "in a floating popup.",
      path = "blame_display",
      type = "selection",
      default = "bottom",
      values = {
        {"Bottom Pane", "bottom"},
        {"Floating Popup", "floating"}
      }
    },
    {
      label = "Highlighter",
      description = "Display or hide the changes highlighter from the gutter.",
      path = "highlighter",
      type = "toggle",
      default = true
    },
    {
      label = "SCM Tab Colors",
      description = "Show a file-status color indicator on editor tabs.",
      path = "tab_colors",
      type = "toggle",
      default = true
    },
    {
      label = "Highlighter Alignment",
      description = "The position on the gutter to draw the changes highlighter.",
      path = "highlighter_alignment",
      type = "selection",
      default = "left",
      values = {
        {"Left", "left"},
        {"Right", "right"}
      }
    },
    {
      label = "Git Path",
      description = "Path to the Git binary.",
      path = "git_path",
      type = "FILE",
      default = "git",
      filters = {"git$", "git%.exe$"},
      get_value = config_fix_path,
      set_value = config_fix_path,
      on_apply = function(value)
        BACKENDS.Git:set_command(value)
      end
    },
    {
      label = "Fossil Path",
      description = "Path to the Fossil binary.",
      path = "fossil_path",
      type = "FILE",
      default = "fossil",
      filters = {"fossil$", "fossil%.exe$"},
      get_value = config_fix_path,
      set_value = config_fix_path,
      on_apply = function(value)
        BACKENDS.Fossil:set_command(value)
      end
    }
  }
}, config.plugins.smc)

-- initialize backends
BACKENDS = { Git = Git(), Fossil = Fossil() }
BACKENDS.Git:set_command(config.plugins.smc.git_path)
BACKENDS.Fossil:set_command(config.plugins.smc.fossil_path)

---@class plugins.scm.filechange : plugins.scm.backend.filechange
---@field color renderer.color?
---@field text string?

---The scm plugin interface.
---@class plugins.scm
local scm = {}

---Show the blame information of active line.
---@type boolean
scm.show_blame = false

---List of loaded projects current branch.
---@type table<string, string>
local BRANCHES = {}

---List of loaded projects current stats.
---@type table<string, plugins.scm.backend.stats>
local STATS = {}

---List of loaded project changes.
---@type table<string,table<string,plugins.scm.filechange>>
local CHANGES = {}
local CONFLICT_COUNTS = {}
local PATH_STATUS = {}

local start_update_worker

---Opened projects SCM backends list
---@type table<string,plugins.scm.backend>
local PROJECTS = {}
setmetatable(PROJECTS, {
  __index = function(t, k)
    if k == nil then return nil end
    local v = rawget(t, k)
    if v == nil then
      for _, backend in pairs(BACKENDS) do
        if backend:detect(k) then
          v = backend
          if backend.name == "Fossil" then
            local found = false
            for _, rule in pairs(config.ignore_files) do
              if string.find(rule, "%-shm$", 1, true) then
                found = true
                break
              end
            end
            if not found then
              table.insert(config.ignore_files, "%-shm$")
              table.insert(config.ignore_files, "%-wal$")
              for _, project in ipairs(core.projects) do
                project:compile_ignore_files()
              end
            end
          end
          rawset(t, k, v)
          backend:watch_project(k)
          if start_update_worker then start_update_worker() end
        end
      end
    end
    return v
  end
})

---Last username entered in the credentials dialog by backend/project.
---@type table<string,string>
local CREDENTIAL_USERNAMES = {}

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
---@param doc core.doc
---@return integer generation
local function invalidate_doc_diff(doc)
  if doc.scm_diff_parse_key then
    core.threads[doc.scm_diff_parse_key] = nil
  end
  local generation = (doc.scm_diff_parse_generation or 0) + 1
  doc.scm_diff_parse_generation = generation
  return generation
end

---@param doc core.doc
---@param unchanged? boolean A successful status snapshot says the file is clean.
local function update_doc_diff(doc, unchanged)
  local generation = invalidate_doc_diff(doc)
  -- Disk diffs cannot describe edits which have not been saved yet.
  if doc:is_dirty() then return end
  local path = doc.abs_filename
  local project_dir = path and util.get_file_project_dir(path)
  local backend = project_dir and PROJECTS[project_dir]
  if unchanged or not backend then
    if doc.scm_diff then
      doc.scm_diff = nil
      core.redraw = true
    end
    return
  end
  local change_id = doc:get_change_id()
  local function current()
    return doc.scm_diff_parse_generation == generation
      and doc.abs_filename == path
      and doc:get_change_id() == change_id
      and not doc:is_dirty()
      and rawget(PROJECTS, project_dir) == backend
  end
  backend:get_file_diff(path, project_dir, function(diff)
    if not current() or diff == nil then return end
    if diff == "" then
      doc.scm_diff = nil
      core.redraw = true
      return
    end
    doc.scm_diff_parse_key = doc.scm_diff_parse_key or {}
    core.add_thread(function()
      local parsed_diff = changes.parse(diff, function() coroutine.yield() end)
      if current() then
        doc.scm_diff = next(parsed_diff) and parsed_diff or nil
        core.redraw = true
      end
    end, doc.scm_diff_parse_key)
  end)
end

---@param doc core.doc
local function update_doc_blame(doc)
  local generation = (doc.scm_blame_generation or 0) + 1
  doc.scm_blame_generation = generation
  if not scm.show_blame then
    if doc.blame_list then
      doc.blame_list = nil
      core.redraw = true
    end
    return
  end
  if doc:is_dirty() then return end
  if doc.abs_filename then
    local path, change_id = doc.abs_filename, doc:get_change_id()
    local project_dir = util.get_file_project_dir(path)
    if project_dir and PROJECTS[project_dir] then
      local backend = PROJECTS[project_dir]
      backend:get_file_blame(path, project_dir, function(list)
        if doc.scm_blame_generation ~= generation
          or doc.abs_filename ~= path
          or doc:get_change_id() ~= change_id
          or rawget(PROJECTS, project_dir) ~= backend
          or not scm.show_blame
        then
          return
        end
        if list and #list > 0 then
          doc.blame_list = list
        else
          doc.blame_list = nil
        end
        core.redraw = true
      end)
      return
    end
  end
  if doc.blame_list then
    doc.blame_list = nil
    core.redraw = true
  end
end

---@param path string
---@param nonblocking? boolean
local function update_doc_status(path, nonblocking)
  local project_dir = util.get_file_project_dir(path)
  local backend = PROJECTS[project_dir]
  if backend then
    if not nonblocking then backend:set_blocking_mode(true) end
    backend:get_file_status(path, project_dir, function(status)
      if status and status ~= "" then
        if PATH_STATUS[project_dir] then PATH_STATUS[project_dir][path] = nil end
        local color
        if status == "added" then
          color = style.good
        elseif status == "edited" then
          color = style.warn
        elseif status == "renamed" then
          color = style.warn
        elseif status == "deleted" then
          color = style.error
        elseif status == "untracked" then
          color = style.dim
        end
        local existing = CHANGES[project_dir] and CHANGES[project_dir][path]
        if existing and existing.conflicted then color = style.error end
        if color then
          if not CHANGES[project_dir] then CHANGES[project_dir] = {} end
          CHANGES[project_dir][path] = {
            path = path,
            color = color,
            status = status,
            conflicted = existing and existing.conflicted or nil
          }
        else
          if CHANGES[project_dir] and CHANGES[project_dir][path] then
            CHANGES[project_dir][path] = nil
          end
        end
        core.redraw = true
      end
    end)
    if not nonblocking then backend:set_blocking_mode(false) end
  end
end

--------------------------------------------------------------------------------
-- Source Control Management API
--------------------------------------------------------------------------------
---Get a file branch or current project branch if no file given.
---@param abs_filename? string
---@return string?
function scm.get_branch(abs_filename)
  local project = util.get_project_dir(abs_filename)
  return BRANCHES[project]
end

---Get current project insert and delete stats.
---@return plugins.scm.backend.stats?
function scm.get_stats()
  local project = util.get_current_project()
  return STATS[project]
end

---Get current project scm backend
---@return plugins.scm.backend?
function scm.get_backend()
  local project = util.get_current_project()
  return PROJECTS[project]
end

---@param path string
---@param is_changed? boolean Only get backend if file has changed
---@param is_tracked? boolean Only get backend if file is tracked
---@return plugins.scm.backend?
function scm.get_path_backend(path, is_changed, is_tracked)
  local project_dir = util.get_project_dir(path)
  if project_dir then
    if is_changed then
      if CHANGES[project_dir] and CHANGES[project_dir][path] then
        if is_tracked then
          if
            CHANGES[project_dir][path].status
            and
            CHANGES[project_dir][path].status == "untracked"
          then
            return nil
          end
        end
        return PROJECTS[project_dir]
      end
    else
      local backend = PROJECTS[project_dir]
      if is_tracked and backend then
        ---@type plugins.scm.backend.filestatus
        local status
        backend:set_blocking_mode(true)
        backend:get_file_status(path, project_dir, function(file_status)
          status = file_status
        end)
        backend:set_blocking_mode(false)
        if not status or status == "untracked" then return nil end
      end
      return backend
    end
  end
  return nil
end

---@return plugins.scm.backend.filestatus
function scm.get_path_status(path)
  local backend = scm.get_path_backend(path)
  local project_dir = util.get_project_dir(path)
  if backend and project_dir then
    local status
    backend:set_blocking_mode(true)
    backend:get_file_status(path, project_dir, function(file_status)
      status = file_status
    end)
    backend:set_blocking_mode(false)
    return status
  end
  return "untracked"
end

---Read cached menu status, querying missing information asynchronously once.
---Unknown status is nil until the callback completes. No blocking SCM queries
---are performed; successful project refreshes invalidate these lookups.
---@param path string
---@param callback? fun(status?:plugins.scm.backend.filestatus, staged:boolean)
---@return plugins.scm.backend.filestatus? status
---@return boolean staged
function scm.get_cached_path_status(path, callback)
  local project_dir = util.get_project_dir(path)
  local backend = project_dir and PROJECTS[project_dir]
  if not backend then
    if callback then callback(nil, false) end
    return nil, false
  end
  local cache = PATH_STATUS[project_dir]
  if not cache then
    cache = {}
    PATH_STATUS[project_dir] = cache
  end
  local state = cache[path]
  if state then
    if callback then
      if state.pending then
        state.callbacks[#state.callbacks + 1] = callback
      else
        callback(state.status, state.staged)
      end
    end
    return state.status, state.staged
  end
  local snapshot = CHANGES[project_dir]
  local change = snapshot and snapshot[path]
  state = { pending = true, staged = false,
    callbacks = callback and { callback } or {} }
  cache[path] = state
  local function current()
    return PATH_STATUS[project_dir] == cache and cache[path] == state
      and CHANGES[project_dir] == snapshot
      and rawget(PROJECTS, project_dir) == backend
      and util.get_project_dir(path) == project_dir
  end
  local function finish(status, staged)
    local callbacks = state.callbacks
    state.callbacks = {}
    if not current() then
      for _, done in ipairs(callbacks) do
        scm.get_cached_path_status(path, done)
      end
      return
    end
    state.status, state.staged, state.pending = status, staged == true, false
    for _, done in ipairs(callbacks) do done(status, state.staged) end
  end
  if change and change.status
    and (change.staged ~= nil or not backend:has_staging()
      or change.status == "untracked")
  then
    finish(change.status, change.staged)
  else
    core.add_thread(function()
      if not current() then finish(nil, false); return end
      local function received(status)
        if not current() then finish(nil, false); return end
        if status and status ~= "unchanged" and status ~= "untracked"
          and backend:has_staging()
        then
          backend:get_staged(project_dir, function(files)
            local relative = common.relative_path(project_dir, path)
            finish(files and status, files and files[relative])
          end)
        else
          finish(status, false)
        end
      end
      if change and change.status then
        received(change.status)
      else
        backend:get_file_status(path, project_dir, received)
      end
    end)
  end
  return state.status, state.staged
end

---@return plugins.scm.filechange?
function scm.get_path_changes(path)
  local project_dir = util.get_project_dir(path)
  if CHANGES[project_dir] and CHANGES[project_dir][path] then
    return CHANGES[project_dir][path]
  end
  return nil
end

---@return boolean
function scm.is_staged(path)
  local backend = scm.get_path_backend(path)
  local project_dir = util.get_project_dir(path)
  if backend and project_dir then
    if CHANGES[project_dir] and CHANGES[project_dir][path] then
      if
        CHANGES[project_dir][path].path
        and
        CHANGES[project_dir][path].new_path
        and
        not system.get_file_info(CHANGES[project_dir][path].path)
        and
        system.get_file_info(CHANGES[project_dir][path].new_path)
      then
        path = CHANGES[project_dir][path].new_path
      else
        return CHANGES[project_dir][path].staged
      end
    end
    local staged_files
    local path_rel = common.relative_path(project_dir, path)
    backend:set_blocking_mode(true)
    backend:get_staged(project_dir, function(files)
      staged_files = files
    end)
    backend:set_blocking_mode(false)
    if staged_files[path_rel] then return true end
  end
  return false
end

---Check if the given project path is source control managed.
---@param path string
---@return boolean
function scm.is_scm_project(path)
  for _, project in ipairs(core.projects) do
    if path == project.path and PROJECTS[path] then
      return true
    end
  end
  return false
end

---Add a new SCM backend.
---@param backend plugins.scm.backend
function scm.register_backend(backend)
  BACKENDS[backend.name] = backend
  scm.request_update()
end

---Remove an existing SCM backend.
---@param name string
function scm.unregister_backend(name)
  BACKENDS[name] = nil
end

---@param title string
---@param diff string
---@param project_dir? string
---@param commit? plugins.scm.backend.commit
---@return core.view
function scm.open_diff_view(title, diff, project_dir, commit)
  local View
  if config.plugins.smc.diff_viewer == "text" then
    View = require "plugins.scm.ui.readdocview"
    local CommitDetails = require "plugins.scm.ui.commitdetails"
    if commit then diff = CommitDetails.text(commit) .. "\n\n" .. diff end
  else
    View = require "plugins.scm.ui.diffview"
  end
  local view = View(title, diff, project_dir, commit)
  core.root_view:get_active_node_default():add_view(view)
  return view
end

---Check the filesystem, not only the last project status snapshot.
---@param directory? string
---@return boolean
---@return string? errmsg
function scm.can_initialize_repository(directory)
  local tools = require "plugins.scm.backend.tools"
  return tools.can_initialize(directory or util.get_current_project(), BACKENDS)
end

---Initialize a directory using a backend that advertises this capability.
---@param directory? string
function scm.initialize_repository(directory)
  directory = directory or util.get_current_project()
  local valid, errmsg = scm.can_initialize_repository(directory)
  if not valid then
    MessageBox.error("SCM Initialize", errmsg)
    return
  end
  local show = require "plugins.scm.ui.initializedialog"
  return show(BACKENDS, directory, function(path, backend)
    local loaded = false
    for _, project in ipairs(core.projects) do
      if project.path == path then
        loaded = true
        break
      end
    end
    if not loaded then
      core.add_project(path)
    end
    core.log("SCM: initialized %s repository in '%s'.", backend.name, path)
    scm.update()
    scm.open_workbench(path)
  end)
end

---@param project_dir? string
function scm.open_diff(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_diff(project_dir, function(diff, _, errmsg)
      if errmsg then
        MessageBox.error("SCM Diff", errmsg)
      elseif diff and diff ~= "" then
        local title = "[CHANGES].diff"
        scm.open_diff_view(title, diff, project_dir)
      else
        core.warn "SCM: no changes detected."
      end
    end)
  else
    core.warn "SCM: current project directory is not versioned."
  end
end

function scm.open_path_diff(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if backend then
    local path_rel = common.relative_path(project_dir, path)
    if path_rel == "." then
      return scm.open_diff(project_dir)
    end
    backend:get_file_diff(path, project_dir, function(diff, _, errmsg)
      if errmsg then
        MessageBox.error("SCM Diff", errmsg)
      elseif diff and diff ~= "" then
        local title = string.format("%s.diff", path_rel)
        scm.open_diff_view(title, diff, project_dir)
      else
        local info = system.get_file_info(path)
        if info and info.type == "file" then
          core.warn "SCM: seems like the file is untracked."
        else
          core.warn "SCM: seems like the path only contains untracked files."
        end
      end
    end)
  end
end

---@param branch string Branch to diff
---@param head_branch? string Branch to diff from
---@param project_dir? string Project directory
function scm.open_branch_diff(branch, head_branch, project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    local function open_diff_from_head(current_branch)
      if not current_branch then
        core.warn "SCM: could not determine current branch."
        return
      end
      backend:get_branch_diff(
        branch,
        current_branch,
        project_dir,
        function(diff, _, errmsg)
          if errmsg then
            MessageBox.error("SCM Diff", errmsg)
          elseif diff and diff ~= "" then
            local title =
              string.format("[%s...%s].diff", current_branch, branch)
            scm.open_diff_view(title, diff, project_dir)
          else
            core.warn(
              "SCM: no changes detected between '%s' and '%s'.",
              current_branch,
              branch
            )
          end
        end
      )
    end
    if head_branch or BRANCHES[project_dir] then
      open_diff_from_head(head_branch or BRANCHES[project_dir])
    else
      backend:get_branch(project_dir, function(current_branch)
        open_diff_from_head(current_branch)
      end)
    end
  else
    core.warn "SCM: current project directory is not versioned."
  end
end

---@param tag string Tag to diff
---@param head_branch? string Branch to diff from
---@param project_dir? string Project directory
function scm.open_tag_diff(tag, head_branch, project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    local function open_diff_from_head(current_branch)
      if not current_branch then
        core.warn "SCM: could not determine current branch."
        return
      end
      backend:get_tag_diff(tag, current_branch, project_dir,
        function(diff, _, errmsg)
          if errmsg then
            MessageBox.error("SCM Diff", errmsg)
          elseif diff and diff ~= "" then
            local title = string.format("[%s...%s].diff", tag, current_branch)
            scm.open_diff_view(title, diff, project_dir)
          else
            core.warn(
              "SCM: no changes detected between '%s' and '%s'.",
              current_branch,
              tag
            )
          end
        end)
    end
    if head_branch or BRANCHES[project_dir] then
      open_diff_from_head(head_branch or BRANCHES[project_dir])
    else
      backend:get_branch(project_dir, function(current_branch)
        open_diff_from_head(current_branch)
      end)
    end
  else
    core.warn "SCM: current project directory is not versioned."
  end
end

function scm.open_commit_file(commit, file)
  if not diffview_loaded then
    core.warn "SCM: this functionality needs Pragtical with diff support."
    return
  end
  local project_dir = util.get_project_dir(file)
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_commit_file(commit, project_dir, file, function(content)
      if content and content ~= "" then
        diffview.string_to_file(
          content,
          file,
          (commit or "HEAD") .. "-" .. common.basename(file)
        )
      else
        core.warn(
          "SCM: file '%s' not found in choosen commit.",
          common.relative_path(project_dir, file)
        )
      end
    end)
  end
end

function scm.open_commit_diff(commit, project_dir)
  local backend = PROJECTS[project_dir]
  if backend then
    core.log "SCM: generating the diff please wait..."
    local diff, info, diff_done, info_done, diff_error
    local function open()
      if not diff_done or not info_done then return end
      local errmsg = diff_error
      if errmsg then
        MessageBox.error("SCM Diff", errmsg)
      elseif diff ~= nil then
        local title = string.format("[%s].diff", commit)
        scm.open_diff_view(title, diff, project_dir, info)
      else
        core.warn "SCM: could not retrieve the commit diff."
      end
    end
    backend:get_commit_info(commit, project_dir, function(value, _, errmsg)
      info = value or { hash = commit, summary = "Commit details unavailable",
        message = errmsg or "Could not load this commit's message." }
      info_done = true
      open()
    end)
    backend:get_commit_diff(commit, project_dir, function(value, _, errmsg)
      diff, diff_error, diff_done = value, errmsg, true
      open()
    end)
  end
end

---@param path? string
---@param target? string
---@param target_type? "branch"|"tag"
function scm.open_commit_history(path, target, target_type)
  local project_dir = util.get_project_dir(path)
  if not project_dir and PROJECTS[path] then
    project_dir = path
    path = nil
  elseif not project_dir then
    return
  end
  local backend = PROJECTS[project_dir]
  if backend then
    local path_rel = ""
    if path then
      path_rel = common.relative_path(project_dir, path)
    elseif target then
      path_rel = target
    else
      path_rel = common.basename(project_dir)
    end
    backend:get_commit_history(path, project_dir, function(history)
      if history and type(history) == "table" and #history > 0 then
        -- local title = string.format("%s.diff", path_rel)
        local HistoryResults = require "plugins.scm.ui.historyresults"
        local results = HistoryResults(project_dir, path, target, target_type, backend)
        core.root_view:get_active_node_default():add_view(results)
        backend:yield()
        for idx, commit in ipairs(history) do
          results:add_commit(commit)
          if idx % 100 == 0 then
            core.redraw = true
            results.list:resize_to_parent()
            backend:yield()
          end
        end
        core.redraw = true
        results.list:resize_to_parent()
        results:stop_searching()
      else
        core.warn("SCM: no history for '%s'.", path_rel)
      end
    end, target, target_type)
  end
end

local WORKBENCHES = setmetatable({}, { __mode = "v" })
local WORKBENCH_VIEWS = setmetatable({}, { __mode = "k" })

---@param view plugins.scm.ui.Workbench
function scm.register_workbench(view)
  WORKBENCH_VIEWS[view] = true
end

---@param project_dir? string
---@param mode? string Initial repository tools view
function scm.open_repository_tools(project_dir, mode)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    return
  end
  local RepositoryTools = require "plugins.scm.ui.repositorytools"
  core.root_view
    :get_active_node_default()
    :add_view(RepositoryTools(project_dir, backend, mode))
end

---@param path string
---@param project_dir? string
---@param staged? boolean
function scm.open_binary_diff(path, project_dir, staged)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    return
  end
  backend:get_review_versions(path, project_dir, function(versions, errmsg)
    if not versions then
      MessageBox.error("SCM Binary Diff", errmsg)
      return
    end
    local BinaryDiffView = require "plugins.scm.ui.binarydiffview"
    core.root_view
      :get_active_node_default()
      :add_view(BinaryDiffView(path, versions))
  end, staged)
end

---@param path string
---@param project_dir? string
function scm.open_conflict(path, project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    return
  end
  backend:get_conflict_versions(path, project_dir, function(versions, errmsg)
    if not versions then
      core.warn("SCM: %s", errmsg or "Conflict source files unavailable.")
    end
    local ConflictView = require "plugins.scm.ui.conflictview"
    core.root_view
      :get_active_node_default()
      :add_view(ConflictView(path, project_dir, backend, versions))
  end)
end

---Open the integrated repository review workbench.
---@param project_dir? string
function scm.open_workbench(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    core.warn "SCM: current project directory is not versioned."
    return
  end
  local view = WORKBENCHES[project_dir]
  if view and view.project_dir ~= project_dir then
    view = nil
  end
  local node = view and core.root_view.root_node:get_node_for_view(view)
  if node then
    node:set_active_view(view)
    core.set_active_view(view)
    view:refresh()
    return
  end
  local Workbench = require "plugins.scm.ui.workbench"
  view = Workbench(project_dir, backend)
  WORKBENCHES[project_dir] = view
  core.root_view:get_active_node_default():add_view(view)
end

---@param path? string
---@param target string
---@param base? string
---@param target_type? "branch"|"tag"
function scm.open_commit_range_history(path, target, base, target_type)
  local project_dir = util.get_project_dir(path)
  if not project_dir and PROJECTS[path] then
    project_dir = path
    path = nil
  elseif not project_dir then
    return
  end
  local backend = PROJECTS[project_dir]
  if backend then
    base = base or (backend.name == "Fossil" and "current" or "HEAD")
    backend:get_commit_range_history(path, project_dir, function(history)
      if history and type(history) == "table" and #history > 0 then
        local HistoryResults = require "plugins.scm.ui.historyresults"
        local results = HistoryResults(project_dir, path, target, target_type, backend, base)
        core.root_view:get_active_node_default():add_view(results)
        results:populate(history, backend)
      else
        core.warn("SCM: no commits for '%s' outside '%s'.", target, base)
      end
    end, target, base, target_type)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir? string
function scm.open_branches_list(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_branches(project_dir, function(branches)
      if branches and type(branches) == "table" and #branches > 0 then
        local BranchesList = require "plugins.scm.ui.brancheslist"
        local results = BranchesList(project_dir, backend)
        core.root_view:get_active_node_default():add_view(results)
        backend:yield()
        results:populate(branches, backend)
      else
        core.warn("SCM: no branches for '%s'.", common.basename(project_dir))
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir? string
function scm.open_tags_list(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_tags(project_dir, function(tags)
      if tags and type(tags) == "table" and #tags > 0 then
        local TagsList = require "plugins.scm.ui.tagslist"
        local results = TagsList(project_dir, backend)
        core.root_view:get_active_node_default():add_view(results)
        backend:yield()
        results:populate(tags, backend)
      else
        core.warn("SCM: no tags for '%s'.", common.basename(project_dir))
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir? string
function scm.open_project_status(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_status(project_dir, function(status)
      if status and status ~= "" then
        local ReadDocView = require "plugins.scm.ui.readdocview"
        local title = "Project Status"
        core.root_view:get_active_node_default():add_view(ReadDocView(title, status))
      else
        core.warn("SCM: no status to report.")
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir? string
function scm.open_commit_message(project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:has_commit_changes(project_dir, function(has_changes)
      if not has_changes then
        MessageBox.info(
          "SCM Commit",
          "No changes are staged or tracked for commit."
        )
        return
      end
      backend:get_status(project_dir, function(status)
        local CommitMessageView = require "plugins.scm.ui.commitmessageview"
        core.root_view:get_active_node_default():add_view(
          CommitMessageView(project_dir, backend, status)
        )
      end)
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param project_dir? string
---@param commit? string
function scm.open_amend_commit_message(project_dir, commit)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    core.warn("SCM: current project directory is not versioned.")
    return
  end

  local function open_editor(current_commit)
    if not current_commit then
      core.warn("SCM: could not determine current commit.")
      return
    end
    backend:get_commit_info(current_commit, project_dir, function(info)
      local message = ""
      if info then
        message = info.summary or ""
        if info.message and info.message ~= "" then
          message = message .. "\n\n" .. info.message
        end
      end
      backend:get_status(project_dir, function(status)
        local CommitMessageView = require "plugins.scm.ui.commitmessageview"
        core.root_view:get_active_node_default():add_view(
          CommitMessageView(project_dir, backend, status, "amend", current_commit, message)
        )
      end)
    end)
  end

  backend:get_current_commit(project_dir, function(current_commit)
    if commit and current_commit then
      local matches_current = commit == current_commit
        or commit:find(current_commit, 1, true) == 1
        or current_commit:find(commit, 1, true) == 1
      if not matches_current then
        core.warn("SCM: amend is only supported for the current commit.")
        return
      end
    end
    open_editor(current_commit or commit)
  end)
end

---@param project_dir? string
---@param message string
---@param callback? plugins.scm.backend.onnewcommit
function scm.commit(project_dir, message, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:new_commit(project_dir, message, function(success, errmsg)
      if success then
        core.log("SCM: committed changes in '%s'", project_dir)
        scm.update()
      else
        errmsg = errmsg and errmsg ~= "" and errmsg or "Commit failed."
        core.error("SCM: failed to commit '%s', %s", project_dir, errmsg)
        MessageBox.error("SCM Commit Failed", errmsg)
      end
      if callback then callback(success, errmsg) end
    end)
  else
    local errmsg = "Current project directory is not versioned."
    core.warn("SCM: %s", errmsg)
    if callback then callback(false, errmsg) end
  end
end

---@param project_dir? string
---@param commit string
---@param message string
---@param callback? plugins.scm.backend.onexecstatus
function scm.amend_commit(project_dir, commit, message, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:amend_commit(project_dir, commit, message, function(success, errmsg)
      if success then
        core.log("SCM: amended commit in '%s'", project_dir)
        scm.update()
      else
        errmsg = errmsg and errmsg ~= "" and errmsg or "Amend commit failed."
        core.error("SCM: failed to amend commit '%s', %s", project_dir, errmsg)
        MessageBox.error("SCM Amend Commit Failed", errmsg)
      end
      if callback then callback(success, errmsg) end
    end)
  else
    local errmsg = "Current project directory is not versioned."
    core.warn("SCM: %s", errmsg)
    if callback then callback(false, errmsg) end
  end
end

---@param project_dir? string
---@param message? string
function scm.new_commit(project_dir, message)
  if message then
    scm.commit(project_dir, message)
  else
    scm.open_commit_message(project_dir)
  end
end


---@param project_dir string
---@param backend plugins.scm.backend
---@param on_submit fun(username:string,password:string)
---@param on_cancel? fun()
local function request_credentials(project_dir, backend, on_submit, on_cancel)
  local function show_dialog(username)
    local key = backend.name .. "\n" .. project_dir
    username = username or CREDENTIAL_USERNAMES[key]
    local CredentialsDialog = require "plugins.scm.ui.credentialsdialog"
    local dialog = CredentialsDialog(project_dir, username)
    function dialog:on_submit(user, password)
      if user and user ~= "" then
        CREDENTIAL_USERNAMES[key] = user
      end
      on_submit(user, password)
    end
    function dialog:on_cancel()
      if on_cancel then on_cancel() end
    end
    dialog:show()
  end

  backend:get_username(project_dir, show_dialog)
end

---@param project_dir string
---@param errmsg? string
---@param on_select fun(strategy:"merge"|"rebase"|"ff-only",remember:boolean)
---@param on_cancel? fun()
local function request_pull_strategy(project_dir, errmsg, on_select, on_cancel)
  local message = {
    "Git needs a strategy to reconcile divergent branches.",
    Widget.NEWLINE,
    "Project: " .. project_dir,
    Widget.NEWLINE,
    Widget.NEWLINE,
    errmsg or "Choose how to continue this pull."
  }
  local PullStrategyDialog = require "plugins.scm.ui.pullstrategydialog"
  local dialog = PullStrategyDialog(project_dir, message)
  function dialog:on_select(strategy, remember)
    on_select(strategy, remember)
  end
  function dialog:on_cancel()
    if on_cancel then
      on_cancel()
    end
  end
  dialog:show()
end

---@param project_dir? string
---@param callback? fun(success:boolean, errmsg?:string)
function scm.pull(project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    local function pull(username, password, retried_with_credentials, strategy)
      backend:pull(project_dir, function(success, errmsg, requires_credentials, requires_pull_strategy)
        if success then
          core.log("SCM: pulled latest changes for '%s'", project_dir)
          if callback then callback(true) end
        elseif not retried_with_credentials and (
          requires_credentials or backend:requires_credentials(errmsg)
        ) then
          request_credentials(project_dir, backend, function(user, pass)
            pull(user, pass, true, strategy)
          end, function()
            core.warn("SCM: pull cancelled, credentials not provided.")
            if callback then callback(false, "credentials not provided") end
          end)
        elseif not strategy and (
          requires_pull_strategy or backend:requires_pull_strategy(errmsg)
        ) then
          request_pull_strategy(project_dir, errmsg, function(selected_strategy, remember)
            if remember then
              backend:set_pull_strategy(project_dir, selected_strategy, function(ok, config_errmsg)
                if ok then
                  pull(username, password, retried_with_credentials, selected_strategy)
                else
                  MessageBox.error(
                    "SCM Pull Strategy Failed",
                    {
                      "Project: " .. project_dir .. "\n",
                      "",
                      config_errmsg or "Unknown error"
                    }
                  )
                  if callback then callback(false, config_errmsg) end
                end
              end)
            else
              pull(username, password, retried_with_credentials, selected_strategy)
            end
          end, function()
            core.warn("SCM: pull cancelled, strategy not selected.")
            if callback then callback(false, "strategy not selected") end
          end)
        else
          core.error("SCM: failed to pull '%s', %s", project_dir, errmsg)
          if callback then callback(false, errmsg) end
        end
      end, username, password, strategy)
    end
    pull()
  elseif callback then
    callback(false, "Current project directory is not versioned.")
  end
end

---@param project_dir? string
---@param callback? fun(success:boolean, errmsg:string?)
function scm.push(project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    local function push(options, done, username, password, retried)
      backend:push(project_dir, function(success, errmsg, requires_credentials)
        if success then
          core.log("SCM: pushed latest changes for '%s'", project_dir)
        elseif not retried and (
          requires_credentials or backend:requires_credentials(errmsg)
        ) then
          request_credentials(project_dir, backend, function(user, pass)
            push(options, done, user, pass, true)
          end, function()
            local complete = done or callback
            if complete then complete(false, "Credentials not provided.") end
          end)
          return
        elseif not done then
          MessageBox.error(
            "SCM Push Failed",
            {
              "Project: " .. project_dir .. "\n",
              "",
              errmsg or "Unknown error"
            }
          )
        end
        local complete = done or callback
        if complete then complete(success, errmsg) end
      end, username, password, options)
    end
    if not backend.get_push_targets then
      push()
      return
    end
    backend:get_push_targets(project_dir, function(targets, errmsg)
      if targets then
        local PushDialog = require "plugins.scm.ui.pushdialog"
        PushDialog(project_dir, backend, targets, push, callback):show()
      elseif errmsg then
        MessageBox.error("SCM Push Failed", errmsg)
        if callback then callback(false, errmsg) end
      else
        push()
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param project_dir? string
---@param callback? fun(success:boolean, errmsg:string?)
---@param prune? boolean
function scm.fetch(project_dir, callback, prune)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    local function fetch(username, password, retried_with_credentials)
      backend:fetch(project_dir, function(success, errmsg, requires_credentials)
        if success then
          core.log("SCM: refreshed remote refs for '%s'", project_dir)
        elseif not retried_with_credentials and (
          requires_credentials or backend:requires_credentials(errmsg)
        ) then
          request_credentials(project_dir, backend, function(user, pass)
            fetch(user, pass, true)
          end, function()
            if callback then callback(false, "credentials not provided") end
          end)
          return
        else
          MessageBox.error(
            "SCM Refresh From Remote Failed",
            {
              "Project: " .. project_dir .. "\n",
              "",
              errmsg or "Unknown error"
            }
          )
        end
        if callback then callback(success, errmsg) end
      end, prune, username, password)
    end
    fetch()
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param project_dir? string
---@param callback? fun(created:boolean, errmsg:string?)
function scm.create_branch(project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_branches(project_dir, function(branches)
      if branches and type(branches) == "table" and #branches > 0 then
        local CreateBranchDialog = require "plugins.scm.ui.createbranchdialog"
        table.sort(branches, function(a, b)
          return (a.date or "") > (b.date or "")
        end)
        local dialog = CreateBranchDialog(project_dir, branches)
        function dialog:on_create(branch, base_branch, checkout)
          backend:create_branch(branch, base_branch, project_dir, function(success, errmsg)
            if success then
              core.log(
                "SCM: created branch '%s' from '%s' for '%s'",
                branch,
                base_branch,
                project_dir
              )
              if checkout then
                scm.checkout(branch, project_dir)
              end
            else
              MessageBox.error(
                "SCM Create Branch Failed",
                {
                  "Branch: " .. branch .. "\n",
                  "Base Branch: " .. base_branch .. "\n",
                  "Project: " .. project_dir .. "\n",
                  "",
                  errmsg or "Unknown error"
                }
              )
            end
            if callback then callback(success, errmsg) end
          end)
        end
        dialog:show()
      else
        core.warn("SCM: no branches found for '%s'.", project_dir)
        if callback then callback(false) end
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param branch string Branch to rebase
---@param base_branch string Branch or revision to rebase onto
---@param project_dir? string
---@param strategy? plugins.scm.backend.rebasestrategy
---@param callback? fun(rebased:boolean, errmsg:string?)
function scm.rebase_branch(branch, base_branch, project_dir, strategy, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:rebase_branch(branch, base_branch, project_dir, function(success, errmsg, requires_resolution)
      if success then
        core.log(
          "SCM: rebased branch '%s' onto '%s' for '%s'",
          branch,
          base_branch,
          project_dir
        )
      elseif requires_resolution or backend:requires_rebase_resolution(errmsg) then
        MessageBox.error(
          "SCM Rebase Stopped",
          {
            "The rebase stopped because conflicts need manual resolution.",
            Widget.NEWLINE,
            "Branch: " .. branch,
            Widget.NEWLINE,
            "Base Branch: " .. base_branch,
            Widget.NEWLINE,
            "Project: " .. project_dir,
            Widget.NEWLINE,
            Widget.NEWLINE,
            errmsg or "Resolve conflicts, then continue or abort the rebase with your SCM."
          }
        )
      else
        MessageBox.error(
          "SCM Rebase Branch Failed",
          {
            "Branch: " .. branch,
            Widget.NEWLINE,
            "Base Branch: " .. base_branch,
            Widget.NEWLINE,
            "Project: " .. project_dir,
            Widget.NEWLINE,
            Widget.NEWLINE,
            errmsg or "Unknown error"
          }
        )
      end
      if callback then callback(success, errmsg) end
    end, strategy)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param branch_data plugins.scm.backend.branch
---@param project_dir? string
---@param callback? fun(rebased:boolean, errmsg:string?)
function scm.open_rebase_branch_dialog(branch_data, project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    if not backend:supports_rebase_branch() then
      MessageBox.error("SCM Rebase Branch", "This backend does not support branch rebasing.")
      if callback then callback(false) end
      return
    end
    backend:get_branches(project_dir, function(branches)
      if branches and type(branches) == "table" and #branches > 1 then
        local RebaseBranchDialog = require "plugins.scm.ui.rebasebranchdialog"
        table.sort(branches, function(a, b)
          return (a.date or "") > (b.date or "")
        end)
        local dialog = RebaseBranchDialog(project_dir, branch_data, branches)
        function dialog:on_rebase(branch, base_branch, strategy)
          scm.rebase_branch(branch, base_branch, project_dir, strategy, callback)
        end
        dialog:show()
      else
        core.warn("SCM: no base branches found for '%s'.", project_dir)
        if callback then callback(false) end
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param project_dir? string
---@param callback? fun(created:boolean, errmsg:string?)
function scm.create_tag(project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_commit_history(nil, project_dir, function(commits)
      if commits and type(commits) == "table" and #commits > 0 then
        local CreateTagDialog = require "plugins.scm.ui.createtagdialog"
        local dialog = CreateTagDialog(project_dir, commits)
        function dialog:on_create(tag, target, annotated, message)
          backend:create_tag(tag, target, project_dir, function(success, errmsg)
            if success then
              core.log(
                "SCM: created tag '%s' from '%s' for '%s'",
                tag,
                target,
                project_dir
              )
            else
              MessageBox.error(
                "SCM Create Tag Failed",
                {
                  "Tag: " .. tag .. "\n",
                  "Target: " .. target .. "\n",
                  "Project: " .. project_dir .. "\n",
                  "",
                  errmsg or "Unknown error"
                }
              )
            end
            if callback then callback(success, errmsg) end
          end, annotated, message)
        end
        dialog:show()
      else
        core.warn("SCM: no commit targets found for '%s'.", project_dir)
        if callback then callback(false) end
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param tag_data plugins.scm.backend.tag
---@param project_dir? string
---@param callback? fun(updated:boolean, errmsg:string?)
function scm.update_tag(tag_data, project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:get_commit_history(nil, project_dir, function(commits)
      if commits and type(commits) == "table" and #commits > 0 then
        local CreateTagDialog = require "plugins.scm.ui.createtagdialog"
        local dialog = CreateTagDialog(project_dir, commits, tag_data)
        function dialog:on_create(tag, target, annotated, message)
          backend:update_tag(tag, tag_data.commit, target, project_dir, function(success, errmsg)
            if success then
              core.log(
                "SCM: updated tag '%s' from '%s' to '%s' for '%s'",
                tag,
                tag_data.commit,
                target,
                project_dir
              )
            else
              MessageBox.error(
                "SCM Edit Tag Failed",
                {
                  "Tag: " .. tag .. "\n",
                  "Target: " .. target .. "\n",
                  "Project: " .. project_dir .. "\n",
                  "",
                  errmsg or "Unknown error"
                }
              )
            end
            if callback then callback(success, errmsg) end
          end, annotated, message)
        end
        dialog:show()
      else
        core.warn("SCM: no commit targets found for '%s'.", project_dir)
        if callback then callback(false) end
      end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param target string Branch, commit or revision to checkout
---@param project_dir? string
function scm.checkout(target, project_dir)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:checkout(target, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: checked out '%s' for '%s'", target, project_dir)
      else
        MessageBox.error(
          "SCM Checkout Failed",
          {
            "Target: " .. target .. "\n",
            "Project: " .. project_dir .. "\n",
            "",
            errmsg or "Unknown error"
          }
        )
      end
      scm.update()
      scm.review_operation(project_dir)
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
  end
end

---@param commit string Commit hash or revision to cherry-pick
---@param project_dir? string
---@param callback? fun(success:boolean, errmsg:string?)
function scm.cherry_pick(commit, project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if not backend then
    local errmsg = "Current project directory is not versioned."
    core.warn("SCM: %s", errmsg)
    if callback then callback(false, errmsg) end
    return
  end
  if not backend:supports_cherry_pick() then
    local errmsg = "This backend does not support cherry-picking commits."
    MessageBox.error("SCM Cherry Pick", errmsg)
    if callback then callback(false, errmsg) end
    return
  end

  MessageBox.warning(
    "SCM Cherry Pick",
    {
      "Do you really want to cherry-pick this commit?",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Commit: " .. commit,
      Widget.NEWLINE,
      "Project: " .. project_dir
    },
    function(_, button_id)
      if button_id ~= 1 then
        if callback then callback(false, "Cherry-pick cancelled.") end
        return
      end

      backend:cherry_pick(commit, project_dir, function(success, errmsg, requires_resolution)
        if success then
          core.log("SCM: cherry-picked commit '%s' in '%s'", commit, project_dir)
          scm.update()
        elseif requires_resolution or backend:requires_cherry_pick_resolution(errmsg) then
          MessageBox.error(
            "SCM Cherry Pick Stopped",
            {
              "The cherry-pick stopped because conflicts need manual resolution.",
              Widget.NEWLINE,
              Widget.NEWLINE,
              "Commit: " .. commit,
              Widget.NEWLINE,
              "Project: " .. project_dir,
              Widget.NEWLINE,
              Widget.NEWLINE,
              errmsg or "Resolve conflicts, then continue or abort the cherry-pick with your SCM."
            }
          )
        else
          MessageBox.error(
            "SCM Cherry Pick Failed",
            {
              "Commit: " .. commit,
              Widget.NEWLINE,
              "Project: " .. project_dir,
              Widget.NEWLINE,
              Widget.NEWLINE,
              errmsg or "Unknown error"
            }
          )
        end
        if callback then callback(success, errmsg) end
      end)
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---@param branch string Branch to delete
---@param project_dir? string
---@param force? boolean Force deletion when supported by the backend
---@param callback? fun(deleted:boolean, errmsg:string?)
function scm.delete_branch(branch, project_dir, force, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:delete_branch(branch, project_dir, function(success, errmsg)
      if success then
        local action = backend.name == "Fossil"
          and "closed"
          or (force and "force deleted" or "deleted")
        core.log("SCM: %s branch '%s' for '%s'",
          action,
          branch,
          project_dir
        )
      else
        MessageBox.error(
          "SCM Delete Branch Failed",
          {
            "Branch: " .. branch .. "\n",
            "Project: " .. project_dir .. "\n",
            "",
            errmsg or "Unknown error"
          }
        )
      end
      if callback then callback(success, errmsg) end
    end, force)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param tag string Tag to delete
---@param commit string Commit associated with the tag
---@param project_dir? string
---@param callback? fun(deleted:boolean, errmsg:string?)
function scm.delete_tag(tag, commit, project_dir, callback)
  project_dir = project_dir or util.get_current_project()
  local backend = PROJECTS[project_dir]
  if backend then
    backend:delete_tag(tag, commit, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: deleted tag '%s' for '%s'", tag, project_dir)
      else
        MessageBox.error(
          "SCM Delete Tag Failed",
          {
            "Tag: " .. tag .. "\n",
            "Project: " .. project_dir .. "\n",
            "",
            errmsg or "Unknown error"
          }
        )
      end
      if callback then callback(success, errmsg) end
    end)
  else
    core.warn("SCM: current project directory is not versioned.")
    if callback then callback(false) end
  end
end

---@param path string
function scm.revert_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    MessageBox.warning(
      "SCM Restore File",
      {
        "Do you really want to revert local changes?\n\n",
        "File: " .. path_rel
      },
      function(_, button_id)
        if button_id == 1 then
          backend:revert_file(path, project_dir, function(success, errmsg)
            if success then
              core.log("SCM: file '%s' changes reverted", path_rel)
              update_doc_status(path)
              util.reload_doc(path)
            else
              core.error("SCM: failed reverting '%s', %s", path_rel, errmsg)
            end
          end)
        end
      end,
      MessageBox.BUTTONS_YES_NO
    )
  end
end

---@param path string
function scm.add_path(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    backend:add_path(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' added", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed adding '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@param path string
function scm.remove_path(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend then
    local path_rel = common.relative_path(project_dir, path)
    backend:remove_path(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' removed", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed removing '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@field from string
---@field to string
---@field callback fun(oldname:string, newname:string):any
function scm.move_path(from, to, callback)
  local project_dir = util.get_project_dir(from)
  local backend = PROJECTS[project_dir]
  local moved = false
  if
    backend and common.path_belongs_to(from, project_dir)
    and
    common.path_belongs_to(to, project_dir)
  then
    local from_rel = common.relative_path(project_dir, from)
    local to_rel = common.relative_path(project_dir, to)
    backend:set_blocking_mode(true)
    backend:move_path(from, to, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' moved to '%s'", from_rel, to_rel)
        update_doc_status(to, true)
      else
        core.error(
          "SCM: failed moving '%s' to '%s' with: %s",
          from_rel, to_rel, errmsg
        )
      end
    end)
    backend:set_blocking_mode(false)
  end
  if system.get_file_info(to) then
    return true
  end
  return callback(from, to)
end

---@param path string
function scm.stage_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend and backend:has_staging() then
    local path_rel = common.relative_path(project_dir, path)
    backend:stage_file(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' staged", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed staging '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---@param path string
function scm.unstage_file(path)
  local project_dir = util.get_project_dir(path)
  local backend = PROJECTS[project_dir]
  if project_dir and backend and backend:has_staging() then
    local path_rel = common.relative_path(project_dir, path)
    backend:unstage_file(path, project_dir, function(success, errmsg)
      if success then
        core.log("SCM: file '%s' unstaged", path_rel)
        update_doc_status(path)
      else
        core.error("SCM: failed unstaging '%s', %s", path_rel, errmsg)
      end
    end)
  end
end

---Go to next change in a file.
---@param doc? core.doc
function scm.next_change(doc)
  doc = doc or util.get_current_doc()
  if not doc or not doc.scm_diff then return end
  local line, col = doc:get_selection()

  while doc.scm_diff[line] do
    line = line + 1
  end

  while line < #doc.lines do
    if doc.scm_diff[line] then
      doc:set_selection(line, col, line, col)
      return
    end
    line = line + 1
  end
end

---Go to previous change in a file.
---@param doc? core.doc
function scm.previous_change(doc)
  doc = doc or util.get_current_doc()
  if not doc or not doc.scm_diff then return end
  local line, col = doc:get_selection()

  while doc.scm_diff[line] do
    line = line - 1
  end

  while line > 0 do
    if doc.scm_diff[line] then
      doc:set_selection(line, col, line, col)
      return
    end
    line = line - 1
  end
end

local statusmap = require "plugins.scm.statusmap"
local scanner = require("plugins.scm.scanner").new()

---Update the SCM status of all open projects.
function scm.update()
  local open, jobs = {}, {}
  for _, project in ipairs(core.projects) do
    local directory = project.path
    open[directory] = true
    local backend = PROJECTS[directory]
    if backend then
      jobs[#jobs + 1] = { directory = directory, backend = backend }
    end
  end
  for project_dir, project_backend in pairs(PROJECTS) do
    if not open[project_dir] then
      BRANCHES[project_dir] = nil
      STATS[project_dir] = nil
      CHANGES[project_dir] = nil
      PATH_STATUS[project_dir] = nil
      CONFLICT_COUNTS[project_dir] = nil
      rawset(PROJECTS, project_dir, nil)
      project_backend:unwatch_project(project_dir)
    end
  end
  scanner:request(jobs, function(job, finished)
    local project_dir, project_backend = job.directory, job.backend
    if rawget(PROJECTS, project_dir) ~= project_backend then
      finished()
      return
    end
    local pending = 3
    local function complete()
      pending = pending - 1
      if pending == 0 then
        finished()
      end
    end
    local function current()
      return rawget(PROJECTS, project_dir) == project_backend
    end

    -- Tree colors should not wait for branch lookup or large line-stat diffs.
    project_backend:get_changes(project_dir, function(filechanges, cached)
      if
        not current()
        or cached and CHANGES[project_dir]
        or type(filechanges) ~= "table"
      then
        complete()
        return
      end
      local changed_files, conflicts = statusmap.build(
        filechanges,
        project_dir,
        function()
          project_backend:yield()
        end
      )
      if current() then
        CHANGES[project_dir] = changed_files
        PATH_STATUS[project_dir] = nil
        CONFLICT_COUNTS[project_dir] = conflicts
        core.redraw = true
        for _, doc in ipairs(core.docs) do
          local path = doc.abs_filename
          if path and util.get_file_project_dir(path) == project_dir then
            update_doc_diff(doc, changed_files[path] == nil)
            update_doc_blame(doc)
          end
        end
        for view in pairs(WORKBENCH_VIEWS) do
          if
            view.project_dir == project_dir
            and not view.busy
            and not view.loading
            and not view.refreshing
          then
            local node = core.root_view.root_node:get_node_for_view(view)
            if node and node.active_view == view then
              view:refresh()
            end
          end
        end
      end
      complete()
    end)
    project_backend:get_branch(project_dir, function(branch, cached)
      if current() and not cached then
        BRANCHES[project_dir] = branch
        core.redraw = true
      end
      complete()
    end)
    project_backend:get_stats(project_dir, function(stats, cached)
      if current() and not cached then
        STATS[project_dir] = stats
        core.redraw = true
      end
      complete()
    end)
  end)
end

--------------------------------------------------------------------------------
-- Keep the project branch, changes and stats updated
--------------------------------------------------------------------------------
local update_queued = false
local function queue_update()
  update_queued = true
  if start_update_worker then start_update_worker() end
end

---Request a status refresh through the existing coalesced update worker.
---This does not start a scan immediately or add filesystem watches.
function scm.request_update()
  queue_update()
end

---Keep the coalesced worker alive only while a scan or repository watch needs it.
start_update_worker = function()
  if core.threads[scm] then return end
  core.add_thread(function()
    coroutine.yield(1) -- give startup a bit of time
    while true do
      local watching = false
      local active_backends = {}
      for _, backend in pairs(PROJECTS) do active_backends[backend] = true end
      for backend in pairs(active_backends) do
        watching = true
        backend.watch:check(function(file) queue_update() end)
      end
      if not scanner.running and update_queued then
        update_queued = false
        scm.update()
        -- A completed refresh may have just registered its repository watches.
        watching = true
      end
      if not watching and not scanner.running and not update_queued then return end
      coroutine.yield(1)
    end
  end, scm)
end

queue_update() -- perform update on startup

local dirwatch_check = DirWatch.check
function DirWatch:check(...)
  local has_change = dirwatch_check(self, ...)
  if has_change then queue_update() end
  return has_change
end

local core_add_project = core.add_project
function core.add_project(project)
  project = core_add_project(project)
  queue_update()
  return project
end

local core_remove_project = core.remove_project
function core.remove_project(project, force)
  project = core_remove_project(project, force)
  queue_update()
  return project
end

local core_set_project = core.set_project
function core.set_project(project)
  project = core_set_project(project)
  queue_update()
  return project
end

local core_open_project = core.open_project
function core.open_project(project)
  core_open_project(project)
  queue_update()
end

--------------------------------------------------------------------------------
-- Override Doc to register diff changes, blame history and file status
--------------------------------------------------------------------------------
local doc_save = Doc.save
function Doc:save(...)
  doc_save(self, ...)
  update_doc_status(self.abs_filename)
  update_doc_diff(self)
  update_doc_blame(self)
  queue_update()
end

local doc_new = Doc.new
function Doc:new(...)
  doc_new(self, ...)
  update_doc_diff(self)
  update_doc_blame(self)
  queue_update()
end

local doc_load = Doc.load
function Doc:load(...)
  doc_load(self, ...)
  update_doc_diff(self)
  update_doc_blame(self)
  queue_update()
end

local doc_raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  doc_raw_insert(self, line, col, text, undo_stack, time)
  invalidate_doc_diff(self)
  local diffs = self.scm_diff or {}
  if diffs[line] ~= "addition" then
    diffs[line] = "modification"
  end
  local count = line
  for _ in (text .. "\n"):gmatch("(.-)\n") do
    if count ~= line then
      diffs[count] = "addition"
    end
    count = count + 1
  end
  self.scm_diff = diffs
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  invalidate_doc_diff(self)
  local diffs = self.scm_diff or {}
  if line1 ~= line2 then
    local minline = math.min(line1, line2)
    local maxline = math.max(line1, line2)
    for line = minline+1, maxline do
      diffs[line] = "deletion"
    end
  else
    diffs[line1] = "modification"
  end
  self.scm_diff = diffs
end

local doc_clear_undo_redo = Doc.clear_undo_redo
function Doc:clear_undo_redo()
  doc_clear_undo_redo(self)
  self.scm_diff = nil
end

--------------------------------------------------------------------------------
-- Override DocView to draw changes on gutter
--------------------------------------------------------------------------------
local DIFF_WIDTH = 3
local docview_draw_line_gutter = DocView.draw_line_gutter
local docview_get_gutter_width = DocView.get_gutter_width

function DocView:draw_line_gutter(line, x, y, width)
  if not self.doc or not self.doc.scm_diff
    or not config.plugins.smc.highlighter
  then
    return docview_draw_line_gutter(self, line, x, y, width)
  end

  local lh = docview_draw_line_gutter(self, line, x, y, width)
  local gw, gpad = docview_get_gutter_width(self)
  local diff_type = self.doc.scm_diff[line]
  local align = config.plugins.smc.highlighter_alignment

  if diff_type == nil then return end

  local color = style.good
  if diff_type == "deletion" then
    color = style.error
  elseif diff_type == "modification" then
    color = style.warn
  end

  if align == "right" then
    x = x + gw - style.padding.x / 2
  else
    if config.show_line_numbers then
      local colw = self:get_font():get_width(#self.doc.lines)
      x = x + gw - colw - gpad
    else
      local lx = self:get_line_screen_position(line, 1)
      x = lx - style.padding.x
    end
  end

  local yoffset = self:get_line_text_y_offset()
  local visual_height = self:get_line_visual_height(line)
  if diff_type ~= "deletion" then
    renderer.draw_rect(x, y + yoffset, DIFF_WIDTH * SCALE, visual_height, color)
    return
  end
  if align == "right" then x = x - style.padding.x / 2 end
  renderer.draw_rect(x, y + yoffset, DIFF_WIDTH * SCALE * 4, 2, color)
  return lh
end

local blame_view
local rootview_update = RootView.update
function RootView:update()
  rootview_update(self)
  if not scm.show_blame then
    if blame_view and blame_view.visible then blame_view:hide() end
    return
  end
  local owner = core.active_view
  if blame_view and blame_view:owns_view(owner) then owner = blame_view.owner end
  -- Command and modal views should not close the current document's pane.
  if owner and (
    not owner:extends(DocView) or not owner.doc or not owner.doc.abs_filename
  ) then
    local focus = owner
    while focus and not self.root_node:get_node_for_view(focus) do
      focus = focus.parent or focus.subparent
    end
    local node = focus and self.root_node:get_node_for_view(focus)
    if blame_view and (not node or node.locked) then
      owner = blame_view.owner
    end
  end
  local node = owner and self.root_node:get_node_for_view(owner)
  local doc = owner and owner.doc
  local backend = node and node.active_view == owner
    and owner:extends(DocView) and doc and doc.blame_list and doc.abs_filename
    and scm.get_path_backend(doc.abs_filename)
  if not backend then
    if blame_view and blame_view.visible then blame_view:hide() end
    return
  end
  local display = config.plugins.smc.blame_display
  if blame_view and blame_view.display ~= display then
    blame_view:hide()
    blame_view = nil
  end
  if not blame_view then
    local BlameView = require "plugins.scm.ui.blameview"
    blame_view = BlameView(display)
    blame_view.on_close = function() command.perform "scm:toggle-blame" end
  end
  local line, col = doc:get_selection()
  blame_view:present(
    owner,
    backend,
    util.get_project_dir(doc.abs_filename) or owner.project_dir or "",
    doc.blame_list[line],
    line,
    col
  )
end

--------------------------------------------------------------------------------
-- Override rename to execute it on the SCM
--------------------------------------------------------------------------------
local os_rename = os.rename
function os.rename(oldname, newname)
  return scm.move_path(oldname, newname, os_rename)
end

--------------------------------------------------------------------------------
-- StatusBar Item to show current branch and stats
--------------------------------------------------------------------------------
local draw_tab_title = Node.draw_tab_title
function Node:draw_tab_title(view, font, active, hovered, x, y, w, h)
  draw_tab_title(self, view, font, active, hovered, x, y, w, h)
  if not config.plugins.smc.tab_colors then
    return
  end
  local path = view and view.doc and view.doc.abs_filename
  local change = path and scm.get_path_changes(path)
  if change and change.color then
    renderer.draw_rect(x, y + h - 2 * SCALE, w, 2 * SCALE, change.color)
  end
end

local scm_status_item = core.status_view:add_item({
  name = "status:scm",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local project = util.get_current_project()

    if
      not PROJECTS[project]
      or
      not BRANCHES[project] or not STATS[project]
    then
      return {}
    end

    local bcolor = (
      STATS[project].inserts ~= 0
      or STATS[project].deletes ~= 0
      or STATS[project].modified ~= 0
    )
      and style.accent or style.text
    local icolor = STATS[project].inserts ~= 0 and style.diff_insert or style.text
    local mcolor = STATS[project].modified ~= 0 and style.diff_modify or style.text
    local dcolor = STATS[project].deletes ~= 0 and style.diff_delete or style.text

    local conflicts = CONFLICT_COUNTS[project] or 0
    return {
      bcolor, BRANCHES[project],
      style.dim, "  ",
      icolor, "+", STATS[project].inserts,
      style.dim, " / ",
      mcolor, "~", STATS[project].modified,
      style.dim, " / ",
      dcolor, "-", STATS[project].deletes,
      style.error, conflicts > 0 and ("  !" .. conflicts) or "",
    }
  end,
  position = -1,
  tooltip = "current branch",
  separator = core.status_view.separator2
})

scm_status_item.on_click = function(button)
  if button == "right" then
    command.perform "scm:global-diff"
  else
    local view = core.command_view
    if view:is_open() then return end
    command.perform "core:find-command"
    view:restore_state { text = "Scm: " }
  end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function prepare_checkout(project_dir, proceed, cancel)
  local backend = PROJECTS[project_dir]
  if not backend or not backend:supports_stashes() then
    proceed()
    return
  end
  backend:get_working_changes(project_dir, function(changes, errmsg)
    if not changes then
      MessageBox.error("SCM Checkout", errmsg or "Could not inspect changes.")
      if cancel then
        cancel()
      end
      return
    end
    if #changes == 0 then
      proceed()
      return
    end
    MessageBox.warning(
      "SCM Local Changes",
      "Stash local changes first? No keeps them in the checkout; Cancel "
        .. "leaves the repository unchanged.",
      function(_, id)
        if id == 1 then
          require("plugins.scm.ui.repositoryactions").stash(
            backend,
            project_dir,
            proceed
          )
        elseif id == 2 then
          proceed()
        elseif cancel then
          cancel()
        end
      end,
      MessageBox.BUTTONS_YES_NO_CANCEL
    )
  end)
end

local checkout = scm.checkout
function scm.checkout(target, project_dir)
  project_dir = project_dir or util.get_current_project()
  prepare_checkout(project_dir, function()
    checkout(target, project_dir)
  end)
end

local rebase_branch = scm.rebase_branch
function scm.rebase_branch(branch, base, project_dir, strategy, callback)
  project_dir = project_dir or util.get_current_project()
  prepare_checkout(project_dir, function()
    rebase_branch(branch, base, project_dir, strategy, function(ok, errmsg)
      scm.update()
      scm.review_operation(project_dir)
      if callback then
        callback(ok, errmsg)
      end
    end)
  end, function()
    if callback then
      callback(false, "Cancelled.")
    end
  end)
end

---Expose operation recovery after commands that can stop with conflicts.
---@param project_dir string
function scm.review_operation(project_dir)
  local backend = PROJECTS[project_dir]
  if not backend then
    return
  end
  backend:get_operation_status(project_dir, function(operation)
    if operation then
      scm.open_workbench(project_dir)
    end
  end)
end

for _, name in ipairs({ "pull", "cherry_pick" }) do
  local original = scm[name]
  scm[name] = function(...)
    local args = table.pack(...)
    local callback_index = name == "pull" and 2 or 3
    local project_index = name == "pull" and 1 or 2
    local project = args[project_index] or util.get_current_project()
    local callback = args[callback_index]
    args[callback_index] = function(ok, errmsg)
      scm.update()
      scm.review_operation(project)
      if callback then
        callback(ok, errmsg)
      end
    end
    original(table.unpack(args, 1, math.max(args.n, callback_index)))
  end
end

command.add(function()
  return scm.can_initialize_repository()
end, {
  ["scm:initialize-repository"] = function()
    scm.initialize_repository()
  end,
})

command.add(
  function()
    local valid = false
    local project_dir = nil
    local av = core.active_view
    if av and av.doc and av.doc.abs_filename then
      project_dir = util.get_project_dir(av.doc.abs_filename)
      if project_dir and PROJECTS[project_dir] then valid = true end
    end
    if not valid and PROJECTS[core.root_project().path] then
      valid, project_dir = true, core.root_project().path
    end
    return valid, project_dir
  end, {

  ["scm:global-diff"] = function(project_dir)
    scm.open_diff(project_dir)
  end,

  ["scm:project-status"] = function(project_dir)
    scm.open_project_status(project_dir)
  end,

  ["scm:workbench"] = function(project_dir)
    scm.open_workbench(project_dir)
  end,

  ["scm:repository-tools"] = function(project_dir)
    scm.open_repository_tools(project_dir)
  end,

  ["scm:manage-remotes"] = function(project_dir)
    local backend = PROJECTS[project_dir]
    if backend and backend:get_capabilities().remotes then
      scm.open_repository_tools(project_dir, "remotes")
    end
  end,

  ["scm:merge-branches"] = function(project_dir)
    local backend = PROJECTS[project_dir]
    if backend and backend:get_capabilities().merge then
      require "plugins.scm.ui.repositoryactions".merge(backend, project_dir,
        function() scm.update() end)
    end
  end,

  ["scm:push"] = function(project_dir)
    scm.push(project_dir)
  end,

  ["scm:new-commit"] = function(project_dir)
    scm.open_commit_message(project_dir)
  end,

  ["scm:amend-current-commit"] = function(project_dir)
    scm.open_amend_commit_message(project_dir)
  end,

  ["scm:view-branches"] = function(project_dir)
    scm.open_branches_list(project_dir)
  end,

  ["scm:create-branch"] = function(project_dir)
    scm.create_branch(project_dir)
  end,

  ["scm:view-tags"] = function(project_dir)
    scm.open_tags_list(project_dir)
  end,

  ["scm:create-tag"] = function(project_dir)
    scm.create_tag(project_dir)
  end
})

command.add(
  function()
    local valid = false
    local path = nil
    local av = core.active_view
    if av and av.doc and av.doc.abs_filename then
      if scm.get_path_backend(av.doc.abs_filename, false, true) then
        valid = true
        path = av.doc.abs_filename
      end
    end
    if not valid and PROJECTS[core.root_project().path] then
      valid, path = true, core.root_project().path
    end
    return valid, path
  end, {

  ["scm:commits-history"] = function(path)
    scm.open_commit_history(path)
  end
})

command.add(nil, {
  ["scm:toggle-blame"] = function()
    scm.show_blame = not scm.show_blame
    if blame_view then
      blame_view.dismissed_key = nil
      blame_view:hide()
    end
    for _, doc in ipairs(core.docs) do
      update_doc_blame(doc)
    end
    core.log(
      "SCM: %s blame information",
      scm.show_blame and "showing" or "hiding"
    )
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return scm.show_blame and doc.blame_list, doc
  end, {

  ["scm:view-blame-diff"] = function(doc)
    ---@cast doc core.doc
    local line = doc:get_selection()
    scm.open_commit_diff(
      doc.blame_list[line].commit,
      util.get_file_project_dir(doc.abs_filename)
    )
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_backend(doc.abs_filename)
      and scm.get_path_status(doc.abs_filename) == "untracked"
      , doc
  end, {

  ["scm:file-add"] = function(doc)
    ---@cast doc core.doc
    scm.add_path(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_status(doc.abs_filename) == "unchanged"
      , doc
  end, {

  ["scm:file-remove"] = function(doc)
    scm.remove_path(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local path = doc.abs_filename
      local status = scm.get_path_status(path)
      if status == "edited" and not scm.is_staged(path) then
        local backend = scm.get_path_backend(path)
        if backend and backend:has_staging() then
          return true, doc
        end
      end
    end
    return false
  end, {

  ["scm:staging-add"] = function(doc)
    scm.stage_file(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local backend = scm.get_path_backend(doc.abs_filename)
      if backend and backend:has_staging() then
        if scm.is_staged(doc.abs_filename) then
          return true, doc
        end
      end
    end
    return false
  end, {

  ["scm:staging-remove"] = function(doc)
    scm.unstage_file(doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local path = doc.abs_filename
      local status = scm.get_path_status(path)
      local backend = scm.get_path_backend(path)
      if backend and backend:has_staging() then
        if status == "edited" and not scm.is_staged(path) then
          return true, doc
        end
      elseif backend then
        return scm.get_path_backend(doc.abs_filename, true, true), doc
      end
    end
    return false
  end, {

  ["scm:file-revert"] = function(doc)
    scm.revert_file(doc.abs_filename)
  end,
})

command.add(
  function()
    local doc = util.get_current_doc()
    return doc
      and scm.get_path_status(doc.abs_filename) == "edited"
      and not scm.is_staged(doc.abs_filename)
      , doc
  end, {

  ["scm:file-diff"] = function(doc)
    scm.open_path_diff(doc.abs_filename)
  end,

  ["scm:compare-with-head"] = function(doc)
    scm.open_commit_file(nil, doc.abs_filename)
  end
})

command.add(
  function()
    local doc = util.get_current_doc()
    if doc then
      local project_dir = util.get_file_project_dir(doc.abs_filename)
      if
        CHANGES[project_dir] and CHANGES[project_dir][doc.abs_filename]
        and
        doc.scm_diff
      then
        return true, doc
      end
    end
    return false
  end, {

  ["scm:goto-previous-change"] = function(doc)
    scm.previous_change(doc)
  end,

  ["scm:goto-next-change"] = function(doc)
    scm.next_change(doc)
  end,
})

core.menu_view:register({ "tools" }, {
  { id = "scm", text = "Source Control", items = {
    { id = "workbench", text = "Repository Workbench", command = "scm:workbench" },
    { id = "repository-tools", text = "Repository Tools",
      command = "scm:repository-tools" },
    { id = "remotes", text = "Manage Remotes", command = "scm:manage-remotes" },
    { id = "initialize", text = "Initialize Repository...",
      command = "scm:initialize-repository" },
    { id = "merge", text = "Merge Branches...", command = "scm:merge-branches" },
    { id = "status", text = "Project Status", command = "scm:project-status" },
    { id = "diff", text = "Project Diff", command = "scm:global-diff" },
    { id = "history", text = "Commit History", command = "scm:commits-history" },
    core.menu_view.DIVIDER,
    { id = "commit", text = "New Commit...", command = "scm:new-commit" },
    { id = "amend", text = "Amend Current Commit...",
      command = "scm:amend-current-commit" },
    { id = "push", text = "Push to Remote", command = "scm:push" },
    core.menu_view.DIVIDER,
    { id = "branches", text = "Branches", command = "scm:view-branches" },
    { id = "new-branch", text = "Create Branch...", command = "scm:create-branch" },
    { id = "tags", text = "Tags", command = "scm:view-tags" },
    { id = "new-tag", text = "Create Tag...", command = "scm:create-tag" },
    core.menu_view.DIVIDER,
    { id = "file-diff", text = "File Diff", command = "scm:file-diff" },
    { id = "compare-head", text = "Compare File With HEAD",
      command = "scm:compare-with-head" },
    { id = "stage", text = "Stage File", command = "scm:staging-add" },
    { id = "unstage", text = "Unstage File", command = "scm:staging-remove" },
    { id = "previous-change", text = "Previous Change",
      command = "scm:goto-previous-change" },
    { id = "next-change", text = "Next Change", command = "scm:goto-next-change" },
    core.menu_view.DIVIDER,
    { id = "blame", text = "Show Blame", command = "scm:toggle-blame",
      checked = function() return scm.show_blame end }
  } }
}, "scm")

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------
keymap.add {
  ["ctrl+shift+g"] = "scm:workbench",
  ["ctrl+alt+["]  = "scm:goto-previous-change",
  ["ctrl+alt+]"]  = "scm:goto-next-change",
  ["ctrl+alt+b"]  = "scm:toggle-blame",
  ["alt+b"]       = "scm:view-blame-diff",
}

--------------------------------------------------------------------------------
-- Load TreeView support if the plugin is enabled
--------------------------------------------------------------------------------
require "plugins.scm.treeview"


return scm
