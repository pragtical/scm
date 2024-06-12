-- Backend implementation for Git.
-- More details at: https://git-scm.com/

local common = require "core.common"
local Backend = require "plugins.scm.backend"

---Get top level git directory of path in order to support submodules.
---@param self plugins.scm.backend
---@param path string
---@return string
local function git_toplevel_path(self, path)
  local git_command = io.popen(
    self.command .. " -C " .. "\"" .. path .. "\" "
      .. "rev-parse --show-toplevel",
    "r"
  )
  if git_command then
    path = git_command:read("*a")
    git_command:close()
  end
  return path:gsub("%s+$", "")
end

---Similar to git_toplevel_path() but with a base dir and file path
---@param self plugins.scm.backend
---@param directory string
---@param file? string
---@return string
local function git_repo_dir(self, directory, file)
  if not file then return git_toplevel_path(self, directory) end
  local path = file
  local path_info = system.get_file_info(path)
  while not path_info or path_info.type == "file" do
    path = common.dirname(path)
    path_info = system.get_file_info(path)
  end
  -- prevent executing git if path same as base directory
  if directory == path then
    return directory
  end
  return git_toplevel_path(self, path)
end

---@class plugins.scm.backend.git : plugins.scm.backend
---@field super plugins.scm.backend
local Git = Backend:extend()

function Git:new()
  self.super.new(self, "Git", "git")
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

---@return boolean
function Git:has_staging()
  return true
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:stage_file(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "add", common.relative_path(directory, file))
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:unstage_file(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "restore", "--staged", common.relative_path(directory, file))
end

---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstaged
function Git:get_staged(directory, callback)
  directory = directory:gsub("[/\\]$", "")
  directory = git_repo_dir(self, directory)
  local cached = self:get_from_cache("get_staged", directory)
  if cached then callback(cached, true) return end
  self:execute(function(proc)
    ---@type table<string,boolean>
    local staged = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local trimmed_file = line:gsub("^%s+", ""):gsub("%s+$", "")
        staged[trimmed_file] = true
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    self:add_to_cache("get_staged", staged, directory)
    callback(staged)
  end, directory, "--no-optional-locks", "diff", "--name-only", "--cached")
end

---@param callback plugins.scm.backend.ongetbranch
function Git:get_branch(directory, callback)
  directory = git_repo_dir(self, directory)
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

---Get list of changes for a git directory or submodule.
---@param self plugins.scm.backend
---@param directory string
---@param changes table Where to store the changes found
---@param callback? function
local function get_changes(self, directory, changes, callback)
  self:get_staged(directory, function(staged_files)
    self:execute(function(proc)
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
              path = directory .. PATHSEP .. path,
              new_path = new_path and (directory .. PATHSEP .. new_path) or nil
            })
            added[path] = true
          end
        end
        if idx % 50 == 0 then
          self:yield()
        end
      end
      if callback then
        callback()
      end
    end, directory, "--no-optional-locks", "status", "--short")
  end)
end

---@param directory string
---@param callback plugins.scm.backend.ongetchanges
function Git:get_changes(directory, callback)
  directory = directory:gsub("[/\\]$", "")
  directory = git_repo_dir(self, directory)
  local cached = self:get_from_cache("get_changes", directory)
  if cached then callback(cached, true) return end
  local changes = {}
  get_changes(self, directory, changes, function()
    -- get available submodule changes
    self:execute(function(proc)
      local submodules = {}
      local mod_changes_done = {}
      for _, line in self:get_process_lines(proc, "stdout") do
        local submodule = line:match("%S+%s+(.+)")
        if submodule then
          submodule = submodule:match("^'(.+)'$")
          local submodule_path = directory .. PATHSEP .. submodule
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
        local submodule_path = directory .. PATHSEP .. submodule
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
      self:add_to_cache("get_changes", changes, directory)
      callback(changes)
    end, directory, "submodule", "foreach", "--recursive")
  end)
end

---@param path? string
---@param directory string
---@param callback plugins.scm.backend.ongetcommithistory
function Git:get_commit_history(path, directory, callback)
  directory = git_repo_dir(self, directory, path)
  local params = {
    "log", "--oneline", "--no-decorate",
    "--pretty=format:'%an' %H %ct %s"
  }
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
  directory = git_repo_dir(self, directory)
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

---@param id string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_commit_diff(id, directory, callback)
  directory = git_repo_dir(self, directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "show", "-U", id)
end

---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_diff(directory, callback)
  directory = git_repo_dir(self, directory)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "--no-optional-locks", "diff")
end

---@param file string
---@param callback plugins.scm.backend.ongetdiff
function Git:get_file_diff(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  local cached = self:get_from_cache("get_file_diff", file)
  if cached then callback(cached, true) return end
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    self:add_to_cache("get_file_diff", diff, directory, 1)
    callback(diff)
  end, directory, "--no-optional-locks", "diff", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfilestatus
function Git:get_file_status(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  local cached = self:get_from_cache("get_file_status", file)
  if cached then callback(cached, true) return end
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
    self:add_to_cache("get_file_status", status, file, 1)
    callback(status)
  end, directory, "--no-optional-locks", "status", "-s", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfileblame
function Git:get_file_blame(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  local cached = self:get_from_cache("get_file_blame", file)
  if cached then callback(cached, true) return end
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
    self:add_to_cache("get_file_blame", list, file, 10)
    callback(#list > 0 and list or nil)
  end, directory, "--no-optional-locks", "blame", common.relative_path(directory, file))
end

---@param callback plugins.scm.backend.ongetstats
function Git:get_stats(directory, callback)
  directory = git_repo_dir(self, directory)
  self:execute(function(proc)
    local inserts = 0
    local deletes = 0
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local i, d = line:match("%s*(%d+)%s+(%d+)")
        inserts = inserts + (tonumber(i) or 0)
        deletes = deletes + (tonumber(d) or 0)
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback({inserts = inserts, deletes = deletes})
  end, directory, "--no-optional-locks", "diff", "--numstat")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstatus
function Git:get_status(directory, callback)
  directory = git_repo_dir(self, directory)
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
---@param callback plugins.scm.backend.onexecstatus
function Git:pull(directory, callback)
  directory = git_repo_dir(self, directory)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "pull")
end

---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:revert_file(file, directory, callback)
  directory = git_repo_dir(self, directory, file)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "restore", common.relative_path(directory, file))
end

---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:add_path(path, directory, callback)
  directory = git_repo_dir(self, directory, path)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "add", common.relative_path(directory, path))
end

---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:remove_path(path, directory, callback)
  directory = git_repo_dir(self, directory, path)
  self:execute(function(proc)
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
    callback(success, errmsg)
  end, directory, "rm", "-r", "--cached", common.relative_path(directory, path))
end

---@param from string Path to move
---@param to string Destination of from path
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Git:move_path(from, to, directory, callback)
  directory = git_repo_dir(self, directory, from)
  self:execute(
    function(proc)
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
      callback(success, errmsg)
    end,
    directory, "mv",
    common.relative_path(directory, from),
    common.relative_path(directory, to)
  )
end


return Git
