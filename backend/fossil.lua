-- Backend implementation for Fossil.
-- More details at: https://www.fossil-scm.org/

local common = require "core.common"
local Backend = require "plugins.scm.backend"

---@class plugins.scm.backend.fossil : plugins.scm.backend
---@field super plugins.scm.backend
local Fossil = Backend:extend()

function Fossil:new()
  self.super.new(self, "Fossil", "fossil")
end

function Fossil:detect(directory)
  if not self.command then return false end
  local list = system.list_dir(directory)
  if list then
    for _, file in ipairs(list) do
      if file == ".fslckout" then
        return true
      end
    end
  end
  return false
end

---@param directory string
function Fossil:watch_project(directory)
  self.watch:watch(directory .. PATHSEP .. ".fslckout")
end

---@param directory string
function Fossil:unwatch_project(directory)
  self.watch:unwatch(directory .. PATHSEP .. ".fslckout")
end

---@param callback plugins.scm.backend.ongetbranch
function Fossil:get_branch(directory, callback)
  self:execute(function(proc)
    local branch = nil
    for idx, line in self:get_process_lines(proc, "stdout") do
      local result = line:match("%s*%*%s*([^%s]+)")
      if result then
        branch = result
        break
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    callback(branch)
  end, directory, "branch")
end

---@param directory string
---@param callback plugins.scm.backend.ongetchanges
function Fossil:get_changes(directory, callback)
  directory = directory:gsub("[/\\]$", "")
  self:execute(function(proc)
    ---@type plugins.scm.backend.filechange[]
    local changes = {}
    local output = self:get_process_output(proc, "stdout")
    local iterations = 1
    for line in output:gmatch("[^\n]+") do
      if line ~= "" then
        local status, path = line:match("%s*(%S+)%s+(%S+)")
        local new_path = nil
        if status and path then
          if status == "ADDED" then
            status = "added"
          elseif status == "DELETED" then
            status = "deleted"
          elseif status == "EDITED" then
            status = "edited"
          elseif status == "RENAMED" then
            status = "renamed"
            new_path = line:match("%s*%S+%s+%S+%s*%S+%s*(%S+)")
          elseif status == "EXTRA" then
            status = "untracked"
          end
          table.insert(changes, {
            status = status,
            path = directory .. PATHSEP .. path,
            new_path = new_path and (directory .. PATHSEP .. new_path) or nil
          })
        end
      end
      if iterations % 100 == 0 then self:yield() end
      iterations = iterations + 1
    end
    callback(changes)
  end, directory, "changes", "--differ")
end

---@param path? string
---@param directory string
---@param callback plugins.scm.backend.ongetcommithistory
function Fossil:get_commit_history(path, directory, callback)
  local params = {
    "timeline", "-n", "0", "-F", "\"'%a' %H '%d' %c\""
  }
  if path then
    table.insert(params, "-p")
    table.insert(params, common.relative_path(directory, path))
  end
  self:execute(function(proc)
    ---@type plugins.scm.backend.commit[]
    local history = {}
    for _, line in self:get_process_lines(proc, "stdout") do
      local author, hash, date, summary = line:match("('.-') (%S+) ('.-') (.*)")
      if author then
        table.insert(history, {
          author = author:match("'(.*)'"),
          hash = hash,
          date = date:match("'(.*)'"),
          summary = summary
        })
      end
    end
    callback(history)
  end, directory, table.unpack(params))
end

---@param id string
---@param directory string
---@param callback plugins.scm.backend.ongetcommit
function Fossil:get_commit_info(id, directory, callback)
  self:execute(function(proc)
    ---@type plugins.scm.backend.commit
    local commit = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if not commit.hash then
        commit.hash, commit.date = line:match("hash:%s+([a-zA-Z0-9]+)%s+(.*)$")
      elseif not commit.summary then
        commit.summary, commit.author = line:match("comment:%s+(.-)%s+%(user: (.-)%)$")
      else
        if commit.message then
          commit.message = commit.message .. "\n" .. (line:match("(.+)") or "")
        elseif line ~= "" then
          commit.message = (line:match("(.*)") or "")
        end
        if idx % 10 == 0 then self:yield() end
      end
    end

    if commit.message then
      commit.message = commit.message:match("(.*)%s+$")
    end

    callback(commit)
  end, directory, "info", id)
end

---@param id string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Fossil:get_commit_diff(id, directory, callback)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "diff", "--unified", "-ci", id)
end

---@param id? string
---@param directory string
---@param file string
---@param callback plugins.scm.backend.ongetfile
---@diagnostic disable-next-line
function Fossil:get_commit_file(id, directory, file, callback)
  local args = { common.relative_path(directory, file) }
  if id then table.insert(args, "-r") table.insert(args, id) end
  self:execute(
    function(proc)
      local content = self:get_process_output(proc, "stdout")
      callback(content)
    end,
    directory, "cat", table.unpack(args)
  )
end

---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Fossil:get_diff(directory, callback)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "diff")
end

---@param file string
---@param callback plugins.scm.backend.ongetdiff
function Fossil:get_file_diff(file, directory, callback)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "diff", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfilestatus
function Fossil:get_file_status(file, directory, callback)
  self:execute(function(proc)
    local status = "unchanged"
    local output = self:get_process_output(proc, "stdout")
    for line in output:gmatch("[^\n]+") do
      if line ~= "" then
        status = line:match("^%S+")
        if status then
          if status == "new" then
            status = "added"
          elseif status == "deleted" then
            status = "deleted"
          elseif status == "edited" then
            status = "edited"
          elseif status == "renamed" then
            status = "renamed"
          elseif status == "unchanged" then
            status = "unchanged"
          elseif status == "unknown" then
            status = "untracked"
          end
          break
        end
      end
      self:yield()
    end
    callback(status)
  end, directory, "finfo", "-s", common.relative_path(directory, file))
end

---@param file string
---@param directory string
---@param callback plugins.scm.backend.ongetfileblame
function Fossil:get_file_blame(file, directory, callback)
  self:execute(function(proc)
    local list = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local commit, date, author = line:match(
          "^([A-Fa-f0-9]+) (%d%d%d%d%-%d%d%-%d%d)%s+(.-):"
        )
        if commit then
          table.insert(list, {
            commit = commit,
            author = author,
            date = date
          })
        end
      end
      if idx % 100 == 0 then
        self:yield()
      end
    end
    callback(#list > 0 and list or nil)
  end, directory, "blame", common.relative_path(directory, file))
end

---@param callback plugins.scm.backend.ongetstats
function Fossil:get_stats(directory, callback)
  self:execute(function(proc)
    local inserts = 0
    local deletes = 0
    local last_line = ""
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        last_line = line
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end
    local i, d = last_line:match("%s*(%d+)%s+(%d+)")
    inserts = tonumber(i) or 0
    deletes = tonumber(d) or 0
    local stats = {inserts = inserts, deletes = deletes}
    callback(stats)
  end, directory, "diff", "--numstat")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstatus
function Fossil:get_status(directory, callback)
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
  end, directory, "status")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:pull(directory, callback)
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
function Fossil:revert_file(file, directory, callback)
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
  end, directory, "revert", common.relative_path(directory, file))
end

---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:add_path(path, directory, callback)
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
function Fossil:remove_path(path, directory, callback)
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
  end, directory, "rm", common.relative_path(directory, path))
end

---@param from string Path to move
---@param to string Destination of from path
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:move_path(from, to, directory, callback)
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


return Fossil
