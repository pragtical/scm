-- Backend implementation for Git.
-- More details at: https://git-scm.com/

local common = require "core.common"
local Backend = require "plugins.scm.backend"
local changes = require "plugins.scm.changes"

---Get top level git directory of path in order to support submodules.
---@param directory string
---@return string
local function git_toplevel_path(directory)
  -- direct implementation of: git -C "path" rev-parse --show-toplevel
  -- in order to reduce command calls and improve performance
  -- REMINDER: previously we used io.popen to call the git command but that
  --           causes the command prompt to popup on Windows and is slower
  local top_path = directory
  repeat
    if system.get_file_info(top_path .. PATHSEP .. ".git") then
      directory = top_path
      break
    end
    top_path = common.dirname(top_path)
  until not top_path
  return common.normalize_path(directory:gsub("%s+$", ""))
end

---Similar to git_toplevel_path() but with a base dir and file path
---@param directory string
---@param file? string
---@return string
local function git_repo_dir(directory, file)
  if not file then return git_toplevel_path(directory) end
  local path = file
  local path_info = system.get_file_info(path)
  while not path_info or path_info.type == "file" do
    path = common.dirname(path)
    path_info = system.get_file_info(path)
  end
  -- if path same as base directory return it
  if directory == path then
    return directory
  end
  return git_toplevel_path(path)
end

---@class plugins.scm.backend.git : plugins.scm.backend
---@field super plugins.scm.backend
local Git = Backend:extend()

function Git:new()
  self.super.new(self, "Git", "git")
  self.watch_dirs = {
    -- switch branches
    ".git",
    -- commit changes
    ".git" .. PATHSEP .. "objects",
    ".git" .. PATHSEP .. "COMMIT_EDITMSG",
    -- pushes
    ".git" .. PATHSEP .. "refs" .. PATHSEP .. "remotes",
    ".git" .. PATHSEP .. "refs" .. PATHSEP .. "tags"
  }
end

function Git:detect(directory)
  if not self.command then return false end
  local list = system.list_dir(directory)
  if list then
    for _, file in ipairs(list) do
      if file == ".git" then
        return true
      end
    end
  end
  return false
end

---@param directory string
function Git:watch_project(directory)
  for _, dir in ipairs(self.watch_dirs) do
    self.watch:watch(directory .. PATHSEP .. dir)
  end
end

---@param directory string
function Git:unwatch_project(directory)
  for _, dir in ipairs(self.watch_dirs) do
    self.watch:unwatch(directory .. PATHSEP .. dir)
  end
end

---@return boolean
function Git:has_staging()
  return true
end

---@param directory string Path of project directory
---@return process.options
function Git:get_process_options(directory)
  return {
    cwd = directory,
    env = {
      -- Let Git Credential Manager and platform askpass helpers decide how to
      -- prompt from the editor instead of forcing terminal-only prompting.
      GCM_INTERACTIVE = "auto",
      GIT_TERMINAL_PROMPT = "0",
      SSH_ASKPASS_REQUIRE = "prefer"
    }
  }
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:stage_file(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "add", common.relative_path(directory, file))
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:unstage_file(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "restore", "--staged", common.relative_path(directory, file))
end

---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstaged
function Git:get_staged(directory, callback)
  directory = directory:gsub("[/\\]$", "")
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    ---@type table<string,boolean>
    local staged = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local trimmed_file = line:gsub("^%s+", ""):gsub("%s+$", "")
        staged[common.normalize_path(trimmed_file)] = true
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback(staged)
  end, directory, "--no-optional-locks", "diff", "--name-only", "--cached")
end

---@param directory string Project directory
---@param callback fun(has_changes:boolean)
function Git:has_commit_changes(directory, callback)
  self:get_staged(directory, function(staged_files)
    for _ in pairs(staged_files or {}) do
      callback(true)
      return
    end
    callback(false)
  end)
end

---@param callback plugins.scm.backend.ongetbranch
function Git:get_branch(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local branch = nil
    for idx, line in self:get_process_lines(proc, "stdout") do
      local result = line:match("^[^%s]+")
      if result then
        branch = result
        break
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback(branch)
  end, directory, "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD")
end

---@param directory string
---@param callback plugins.scm.backend.ongetbranches
function Git:get_branches(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    ---@type plugins.scm.backend.branch[]
    local branches = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local ref, name, remote, date, commit, message = line:match(
          "^(.-)\t(.-)\t(.-)\t(.-)\t(%S+)\t(.*)$"
        )
        if name and commit and not ref:match("/HEAD$") then
          local remote_only = ref:match("^refs/remotes/") ~= nil
          table.insert(branches, {
            name = name,
            remote = remote,
            remote_only = remote_only,
            date = date,
            commit = commit,
            message = message
          })
        end
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback(branches)
  end, directory,
    "--no-optional-locks", "for-each-ref", "refs/heads", "refs/remotes",
    "--sort=-committerdate",
    "--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(committerdate:short)%09%(objectname)%09%(contents:subject)"
  )
end

---@param directory string
---@param callback plugins.scm.backend.ongettags
function Git:get_tags(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    ---@type plugins.scm.backend.tag[]
    local tags = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local name, date, peeled_commit, commit, message = line:match(
          "^(.-)\t(.-)\t(.-)\t(%S+)\t(.*)$"
        )
        if name and commit then
          local annotated = peeled_commit ~= ""
          table.insert(tags, {
            name = name,
            date = date,
            commit = annotated and peeled_commit or commit,
            message = message,
            annotated = annotated
          })
        end
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback(tags)
  end, directory,
    "--no-optional-locks", "for-each-ref", "refs/tags",
    "--sort=-creatordate",
    "--format=%(refname:short)%09%(creatordate:short)%09%(*objectname)%09%(objectname)%09%(subject)"
  )
end

---@param branch string Branch to create
---@param base_branch string Branch or revision to base the new branch from
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:create_branch(branch, base_branch, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "branch", branch, base_branch)
end

---@param branch string Branch to rebase
---@param base_branch string Branch or revision to rebase onto
---@param directory string Project directory
---@param callback plugins.scm.backend.onrebasestatus
---@param strategy? plugins.scm.backend.rebasestrategy
function Git:rebase_branch(branch, base_branch, directory, callback, strategy)
  directory = git_repo_dir(directory)
  local params = { "--no-optional-locks", "rebase" }
  if strategy == "ours" or strategy == "theirs" then
    table.insert(params, "-X")
    table.insert(params, strategy)
  elseif strategy and strategy ~= "normal" then
    callback(false, "Unknown rebase strategy: " .. tostring(strategy), false)
    return
  end
  table.insert(params, base_branch)
  table.insert(params, branch)

  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg, self:requires_rebase_resolution(errmsg))
  end, directory, table.unpack(params))
end

---@return boolean
function Git:supports_rebase_branch()
  return true
end

---@param tag string Tag to create
---@param target string Branch, tag, commit or revision to tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param annotated? boolean
---@param message? string
function Git:create_tag(tag, target, directory, callback, annotated, message)
  directory = git_repo_dir(directory)
  local params = { "tag" }
  if annotated then
    table.insert(params, "-a")
  end
  table.insert(params, tag)
  table.insert(params, target)
  if annotated then
    table.insert(params, "-m")
    table.insert(params, message or "")
  end
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, table.unpack(params))
end

---@param tag string Tag to update
---@param old_commit string Commit currently associated with the tag
---@param target string Branch, tag, commit or revision to tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param annotated? boolean
---@param message? string
function Git:update_tag(tag, old_commit, target, directory, callback, annotated, message)
  directory = git_repo_dir(directory)
  local params = { "tag", "-f" }
  if annotated then
    table.insert(params, "-a")
  end
  table.insert(params, tag)
  table.insert(params, target)
  if annotated then
    table.insert(params, "-m")
    table.insert(params, message or "")
  end
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, table.unpack(params))
end

---@param target string Branch, commit or revision to checkout
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:checkout(target, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "checkout", target)
end

---@param commit string Commit hash or revision to cherry-pick
---@param directory string Project directory
---@param callback plugins.scm.backend.oncherrypickstatus
function Git:cherry_pick(commit, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    if not proc then
      callback(false, "Could not start Git process.", false)
      return
    end
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg, self:requires_cherry_pick_resolution(errmsg))
  end, directory, "--no-optional-locks", "cherry-pick", commit)
end

---@return boolean
function Git:supports_cherry_pick()
  return true
end

---@param branch string Branch to delete
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param force? boolean Force deletion
function Git:delete_branch(branch, directory, callback, force)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "--no-optional-locks", "branch", force and "-D" or "-d", "--", branch)
end

---@param tag string Tag to delete
---@param commit string Commit associated with the tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:delete_tag(tag, commit, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "--no-optional-locks", "tag", "-d", "--", tag)
end

---Get list of changes for a git directory or submodule.
---@param self plugins.scm.backend
---@param directory string
---@param changes table Where to store the changes found
---@param callback? function
local function get_changes(self, directory, changes, callback)
  self:get_staged(directory, function(staged_files)
    self:execute(function(proc)
      if not proc then
        if callback then callback(false) end
        return
      end
      ---@type plugins.scm.backend.filechange[]
      local added = {}
      for idx, line in self:get_process_lines(proc, "stdout") do
        if line ~= "" then
          local status, path = line:match("%s*(%S+)%s+(%S+)")
          local new_path = nil
          if status and path and not added[path] then
            if status == "A" then
              status = "added"
            elseif status == "D" then
              status = "deleted"
            elseif status == "M" then
              status = "edited"
            elseif status == "R" then
              status = "renamed"
              new_path = line:match("%s*%S+%s+%S+%s*%S+%s*(%S+)")
            elseif status == "??" then
              status = "untracked"
            end
            table.insert(changes, {
              status = status,
              staged = staged_files[path] or nil,
              path = common.normalize_path(directory .. PATHSEP .. path),
              new_path = new_path and common.normalize_path(directory .. PATHSEP .. new_path) or nil
            })
            added[path] = true
          end
        end
        if idx % 50 == 0 then
          self:yield()
        end
      end
      if proc:returncode() ~= 0 then
        if callback then callback(false) end
        return
      end
      if callback then
        callback(true)
      end
    end, directory, "--no-optional-locks", "status", "--short")
  end)
end

---@param directory string
---@param callback plugins.scm.backend.ongetchanges
function Git:get_changes(directory, callback)
  directory = directory:gsub("[/\\]$", "")
  directory = git_repo_dir(directory)
  local changes = {}
  get_changes(self, directory, changes, function(success)
    if not success then
      callback(nil)
      return
    end
    -- get available submodule changes
    self:execute(function(proc)
      if not proc then
        callback(changes)
        return
      end
      local submodules = {}
      local mod_changes_done = {}
      for _, line in self:get_process_lines(proc, "stdout") do
        local submodule = line:match("%S+%s+(.+)")
        if submodule then
          submodule = submodule:match("^'(.+)'$")
          local submodule_path = common.normalize_path(directory .. PATHSEP .. submodule)
          local submodule_info = system.get_file_info(submodule_path)
          if
            submodule ~= ""
            and
            submodule_info and submodule_info.type == "dir"
          then
            table.insert(submodules, submodule)
          end
        end
      end
      for idx, submodule in ipairs(submodules) do
        local submodule_path = common.normalize_path(directory .. PATHSEP .. submodule)
        get_changes(self, submodule_path, changes, function()
          mod_changes_done[idx] = true
        end)
      end
      local alldone = false
      while not alldone do
        alldone = true
        for idx, _ in ipairs(submodules) do
          if not mod_changes_done[idx] then
            alldone = false
            break
          end
        end
        self:yield()
      end
      callback(changes)
    end, directory, "submodule", "foreach", "--recursive")
  end)
end

---@param path? string
---@param directory string
---@param callback plugins.scm.backend.ongetcommithistory
---@param target? string
---@param target_type? "branch"|"tag"
function Git:get_commit_history(path, directory, callback, target, target_type)
  directory = git_repo_dir(directory, path)
  local params = {
    "log", "--oneline", "--no-decorate",
    "--pretty=format:'%an' %H %ct %s"
  }
  if target then
    table.insert(params, target)
  end
  if path then
    table.insert(params, "--")
    table.insert(params, common.relative_path(directory, path))
  end
  self:execute(function(proc)
    ---@type plugins.scm.backend.commit[]
    local history = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      local author, hash, date, summary = line:match("('.-') (%S+) (%S+) (.*)")
      if author then
        table.insert(history, {
          author = author:match("'(.*)'"),
          hash = hash,
          date = os.date("%Y-%m-%d %I:%M %p", tonumber(date)),
          summary = summary
        })
      end
      if idx % 100 == 0 then
        self:yield()
      end
    end
    callback(history)
  end, directory, table.unpack(params))
end

---@param id string
---@param directory string
---@param callback plugins.scm.backend.ongetcommit
function Git:get_commit_info(id, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    ---@type plugins.scm.backend.commit
    local commit = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if not commit.hash then
        commit.hash = line:match("commit%s+([a-zA-Z0-9]+)$")
      elseif not commit.author then
        commit.author = line:match("Author:%s+(.+)$")
      elseif not commit.date then
        commit.date = line:match("Date:%s+(.+)$")
      elseif not commit.summary then
        commit.summary = line:match("    (.+)")
      else
        if commit.message then
          commit.message = commit.message .. "\n" .. (line:match("    (.+)") or "")
        elseif line ~= "" then
          local message = line:match("    (.+)")
          if message then
            commit.message = (line:match("    (.*)") or "")
          end
        end
        if idx % 10 == 0 then self:yield() end
      end
    end

    if commit.message then
      commit.message = commit.message:match("(.*)%s+$")
    end

    callback(commit)
  end, directory, "--no-optional-locks", "show", "--no-patch", id)
end

---@param directory string Project directory
---@param callback fun(commit?:string)
function Git:get_current_commit(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local stdout = self:get_process_output(proc, "stdout")
    if not proc or proc:returncode() ~= 0 then
      callback(nil)
      return
    end
    callback(stdout:match("^%s*(%S+)"))
  end, directory, "--no-optional-locks", "rev-parse", "HEAD")
end

---@param id string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_commit_diff(id, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "show", "-U", id)
end

---@param branch string
---@param head_branch string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_branch_diff(branch, head_branch, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "diff", head_branch .. "..." .. branch)
end

---@param tag string
---@param head_branch string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_tag_diff(tag, head_branch, directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "diff", tag .. "..." .. head_branch)
end

---@param id? string
---@param directory string
---@param file string
---@param callback plugins.scm.backend.ongetfile
---@diagnostic disable-next-line
function Git:get_commit_file(id, directory, file, callback)
  directory = git_repo_dir(directory)
  self:execute(
    function(proc)
      local content = self:get_process_output(proc, "stdout")
      callback(content)
    end,
    directory,
    "--no-optional-locks", "show",
    string.format('%s:%s', id or "HEAD", common.relative_path(directory, file))
  )
end

---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_diff(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "diff")
end

---@param file string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_file_diff(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "diff", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfilestatus
function Git:get_file_status(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    local status = "unchanged"
    local output = self:get_process_output(proc, "stdout")
    for line in output:gmatch("[^\n]+") do
      if line ~= "" then
        status = line:match("^%s*(%S+)")
        if status then
          if status == "A" then
            status = "added"
          elseif status == "D" then
            status = "deleted"
          elseif status == "M" then
            status = "edited"
          elseif status == "R" then
            status = "renamed"
          elseif status == "??" then
            status = "untracked"
          end
          break
        end
      end
      self:yield()
    end
    callback(status)
  end, directory, "--no-optional-locks", "status", "-s", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfileblame
function Git:get_file_blame(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    ---@type plugins.scm.backend.blame[]
    local list = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local commit, author, date = line:match(
          "^%^?([A-Fa-f0-9]+) %((.-) (%d%d%d%d%-%d%d%-%d%d)"
        )
        if commit then
          table.insert(list, {
            commit = commit,
            author = author:match("^%s*(.-)%s*$"), -- trim spaces
            date = date
          })
        end
      end
      if idx % 100 == 0 then
        self:yield()
      end
    end
    callback(#list > 0 and list or nil)
  end, directory, "--no-optional-locks", "blame", common.relative_path(directory, file))
end

---@param callback plugins.scm.backend.ongetstats
function Git:get_stats(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(changes.stats(diff, function() self:yield() end))
  end, directory, "--no-optional-locks", "diff", "-U0")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstatus
function Git:get_status(directory, callback)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    local status = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if stderr ~= "" then
      status = stderr
    elseif stdout ~= "" then
      status = stdout
    end
    callback(status)
  end, directory, "--no-optional-locks", "status")
end

---@param directory string Project directory
---@param message string Commit message
---@param callback plugins.scm.backend.onnewcommit
function Git:new_commit(directory, message, callback)
  directory = git_repo_dir(directory)
  self:with_commit_message_file(message, function(filename, cleanup, errmsg)
    if not filename then
      callback(false, errmsg or "Could not create temporary commit message file.")
      return
    end
    local started = self:execute(function(proc)
      self:handle_exec_status(proc, callback)
      if cleanup then cleanup() end
    end, directory, "--no-optional-locks", "commit", "-F", filename)
    if not started and cleanup then cleanup() end
  end)
end

---@param directory string Project directory
---@param commit string Current commit hash
---@param message string Commit message
---@param callback plugins.scm.backend.onexecstatus
function Git:amend_commit(directory, commit, message, callback)
  directory = git_repo_dir(directory)
  self:with_commit_message_file(message, function(filename, cleanup, errmsg)
    if not filename then
      callback(false, errmsg or "Could not create temporary commit message file.")
      return
    end
    local started = self:execute(function(proc)
      self:handle_exec_status(proc, callback)
      if cleanup then cleanup() end
    end, directory, "--no-optional-locks", "commit", "--amend", "-F", filename)
    if not started and cleanup then cleanup() end
  end)
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string Ignored by Git
---@param password? string Ignored by Git
---@param strategy? "merge"|"rebase"|"ff-only"
function Git:pull(directory, callback, username, password, strategy)
  directory = git_repo_dir(directory)
  local params = { "pull" }
  if strategy == "merge" then
    table.insert(params, "--no-rebase")
  elseif strategy == "rebase" then
    table.insert(params, "--rebase")
  elseif strategy == "ff-only" then
    table.insert(params, "--ff-only")
  end
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg, false, self:requires_pull_strategy(errmsg))
  end, directory, table.unpack(params))
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string Ignored by Git
---@param password? string Ignored by Git
function Git:push(directory, callback, username, password)
  directory = git_repo_dir(directory)
  self:execute(function(proc)
    self:handle_exec_status(proc, callback)
  end, directory, "--no-optional-locks", "push")
end

---@param errmsg? string
---@return boolean
function Git:requires_pull_strategy(errmsg)
  errmsg = (errmsg or ""):lower()
  return errmsg:find("divergent branches", 1, true) ~= nil
    and errmsg:find("need to specify how to reconcile", 1, true) ~= nil
end

---@param errmsg? string
---@return boolean
function Git:requires_rebase_resolution(errmsg)
  errmsg = (errmsg or ""):lower()
  return errmsg:find("conflict", 1, true) ~= nil
    and (
      errmsg:find("rebase --continue", 1, true) ~= nil
      or errmsg:find("resolve all conflicts", 1, true) ~= nil
      or errmsg:find("could not apply", 1, true) ~= nil
    )
end

---@param errmsg? string
---@return boolean
function Git:requires_cherry_pick_resolution(errmsg)
  errmsg = (errmsg or ""):lower()
  return errmsg:find("cherry-pick --continue", 1, true) ~= nil
    or errmsg:find("resolve all conflicts", 1, true) ~= nil
    or errmsg:find("could not apply", 1, true) ~= nil
    or errmsg:find("after resolving the conflicts", 1, true) ~= nil
end

---@param proc process
---@param callback plugins.scm.backend.onexecstatus
function Git:handle_exec_status(proc, callback)
  if not proc then
    callback(false, "Could not start Git process.")
    return
  end
  local success = false
  local errmsg = ""
  local stdout = self:get_process_output(proc, "stdout")
  local stderr = self:get_process_output(proc, "stderr")
  if proc and proc:returncode() == 0 then
    success = true
  else
    if stderr ~= "" then
      errmsg = stderr
    elseif stdout ~= "" then
      errmsg = stdout
    end
  end
  callback(success, errmsg)
end

---@param directory string Project directory
---@param strategy "merge"|"rebase"|"ff-only"
---@param callback plugins.scm.backend.onexecstatus
function Git:set_pull_strategy(directory, strategy, callback)
  directory = git_repo_dir(directory)
  local params = { "config" }
  if strategy == "merge" then
    table.insert(params, "pull.rebase")
    table.insert(params, "false")
  elseif strategy == "rebase" then
    table.insert(params, "pull.rebase")
    table.insert(params, "true")
  elseif strategy == "ff-only" then
    table.insert(params, "pull.ff")
    table.insert(params, "only")
  else
    callback(false, "Unknown pull strategy: " .. tostring(strategy))
    return
  end

  self:execute(function(proc)
    self:handle_exec_status(proc, callback)
  end, directory, table.unpack(params))
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param prune? boolean
function Git:fetch(directory, callback, prune)
  directory = git_repo_dir(directory)

  local function fetch_remote(remote)
    local params = { "--no-optional-locks", "fetch", "--quiet", "--tags", "--force" }
    if prune then
      table.insert(params, "--prune")
      table.insert(params, "--prune-tags")
    end
    table.insert(params, remote)
    self:execute(function(proc)
      local success = false
      local errmsg = ""
      local stdout = self:get_process_output(proc, "stdout")
      local stderr = self:get_process_output(proc, "stderr")
      if proc and proc:returncode() == 0 then
        success = true
      else
        if stderr ~= "" then
          errmsg = stderr
        elseif stdout ~= "" then
          errmsg = stdout
        end
      end
      callback(success, errmsg)
    end, directory, table.unpack(params))
  end

  local function fetch_first_remote()
    self:execute(function(proc)
      local remote = nil
      local first_remote = nil
      for idx, line in self:get_process_lines(proc, "stdout") do
        if line ~= "" then
          first_remote = first_remote or line
          if line == "origin" then
            remote = line
            break
          end
        end
        if idx % 50 == 0 then
          self:yield()
        end
      end
      remote = remote or first_remote
      if remote then
        fetch_remote(remote)
      else
        callback(false, "no remote configured")
      end
    end, directory, "remote")
  end

  self:execute(function(branch_proc)
    local branch = nil
    for _, line in self:get_process_lines(branch_proc, "stdout") do
      branch = line:match("^%s*(.-)%s*$")
      break
    end
    if not branch or branch == "" or branch == "HEAD" then
      fetch_first_remote()
      return
    end
    self:execute(function(remote_proc)
      local remote = nil
      local stdout = self:get_process_output(remote_proc, "stdout")
      remote = stdout:match("^%s*(.-)%s*$")
      if remote and remote ~= "" then
        fetch_remote(remote)
      else
        fetch_first_remote()
      end
    end, directory, "config", "branch." .. branch .. ".remote")
  end, directory, "rev-parse", "--abbrev-ref", "HEAD")
end

---@return boolean
function Git:supports_fetch_prune()
  return true
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:revert_file(file, directory, callback)
  directory = git_repo_dir(directory, file)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "restore", common.relative_path(directory, file))
end

---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:add_path(path, directory, callback)
  directory = git_repo_dir(directory, path)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "add", common.relative_path(directory, path))
end

---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:remove_path(path, directory, callback)
  directory = git_repo_dir(directory, path)
  self:execute(function(proc)
    local success = false
    local errmsg = ""
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      success = true
    else
      if stderr ~= "" then
        errmsg = stderr
      elseif stdout ~= "" then
        errmsg = stdout
      end
    end
    callback(success, errmsg)
  end, directory, "rm", "-r", "--cached", common.relative_path(directory, path))
end

---@param from string Path to move
---@param to string Destination of from path
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:move_path(from, to, directory, callback)
  directory = git_repo_dir(directory, from)
  self:execute(
    function(proc)
      local success = false
      local errmsg = ""
      local stdout = self:get_process_output(proc, "stdout")
      local stderr = self:get_process_output(proc, "stderr")
      if proc and proc:returncode() == 0 then
        success = true
      else
        if stderr ~= "" then
          errmsg = stderr
        elseif stdout ~= "" then
          errmsg = stdout
        end
      end
      callback(success, errmsg)
    end,
    directory, "mv",
    common.relative_path(directory, from),
    common.relative_path(directory, to)
  )
end


return Git
