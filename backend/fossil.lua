-- Backend implementation for Fossil.
-- More details at: https://www.fossil-scm.org/

local common = require "core.common"
local Backend = require "plugins.scm.backend"
local changes = require "plugins.scm.changes"

---@class plugins.scm.backend.fossil : plugins.scm.backend
---@field super plugins.scm.backend
local Fossil = Backend:extend()

function Fossil:new()
  self.super.new(self, "Fossil", "fossil")
end

---@param errmsg? string
---@return boolean
function Fossil:requires_credentials(errmsg)
  errmsg = (errmsg or ""):lower()
  return errmsg:find("password", 1, true) ~= nil
    or errmsg:find("not authorized", 1, true) ~= nil
    or errmsg:find("unauthorized", 1, true) ~= nil
    or errmsg:find("authorization", 1, true) ~= nil
    or errmsg:find("authentication", 1, true) ~= nil
    or errmsg:find("login failed", 1, true) ~= nil
    or errmsg:find("401", 1, true) ~= nil
end

---@param proc process
---@param callback plugins.scm.backend.onexecstatus
function Fossil:handle_exec_status(proc, callback)
  if not proc then
    callback(false, "Could not start Fossil process.", false)
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
  callback(success, errmsg, self:requires_credentials(errmsg))
end

---@param username? string
---@param password? string
---@return boolean
function Fossil:has_credentials(username, password)
  return username ~= nil and username ~= ""
    and password ~= nil and password ~= ""
end

---@param value string
---@return string
function Fossil:url_escape(value)
  return (value:gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

---@param url string
---@param username string
---@param password string
---@return string?
function Fossil:add_url_credentials(url, username, password)
  url = url:match("^%s*(.-)%s*$")
  if url == "" or url == "off" then
    return nil
  end
  local scheme, rest = url:match("^([%w][%w%+%-%.]*://)(.+)$")
  if not scheme then
    return nil
  end

  local authority, path = rest:match("^([^/]*)(.*)$")
  if not authority or authority == "" then
    return nil
  end
  local host = authority:match("@(.+)$") or authority
  return scheme
    .. self:url_escape(username)
    .. ":"
    .. self:url_escape(password)
    .. "@"
    .. host
    .. (path or "")
end

---@param url string
---@return string?
function Fossil:get_url_username(url)
  url = url:match("^%s*(.-)%s*$")
  url = url:match("([%w][%w%+%-%.]*://%S+)") or url
  local rest = url:match("^[%w][%w%+%-%.]*://(.+)$")
  if not rest then
    return nil
  end

  local authority = rest:match("^([^/]*)")
  if not authority then
    return nil
  end
  local userinfo = authority:match("^(.-)@")
  if not userinfo or userinfo == "" then
    return nil
  end
  local username = userinfo:match("^([^:]+)")
  return username ~= "" and username or nil
end

---@param directory string Project directory
---@param callback fun(url?:string, errmsg?:string)
function Fossil:get_authenticated_remote_url(directory, username, password, callback)
  self:execute(function(proc)
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if not proc or proc:returncode() ~= 0 then
      callback(nil, stderr ~= "" and stderr or stdout)
      return
    end

    local remote_url = stdout:match("^%s*(.-)%s*$")
    local authenticated_url = self:add_url_credentials(remote_url, username, password)
    if authenticated_url then
      callback(authenticated_url)
    else
      callback(nil, "Could not determine a HTTP remote URL for Fossil credentials.")
    end
  end, directory, "remote")
end

---@param directory string Project directory
---@param callback fun(username?:string)
function Fossil:get_username(directory, callback)
  self:execute(function(proc)
    if not proc then
      callback(nil)
      return
    end
    local stdout = self:get_process_output(proc, "stdout")
    if not proc or proc:returncode() ~= 0 then
      callback(nil)
      return
    end
    callback(self:get_url_username(stdout))
  end, directory, "remote")
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
---@param callback plugins.scm.backend.ongetbranches
function Fossil:get_branches(directory, callback)
  self:execute(function(proc)
    ---@type plugins.scm.backend.branch[]
    local branches = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      if line ~= "" then
        local name = line:match("^%s*[%*#]?%s*(.-)%s*$")
        if name and name ~= "" then
          table.insert(branches, {
            name = name,
            commit = ""
          })
        end
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end

    if #branches == 0 then
      callback(branches)
      return
    end

    local done = 0
    for _, branch in ipairs(branches) do
      self:execute(function(branch_proc)
        for idx, line in self:get_process_lines(branch_proc, "stdout") do
          local commit, date, message = line:match("^([A-Fa-f0-9]+)\t(.-)\t(.*)$")
          if commit then
            branch.commit = commit
            branch.date = date
            branch.message = message
            break
          end
          if idx % 50 == 0 then
            self:yield()
          end
        end
        done = done + 1
      end, directory, "timeline", "-n", "1", "-b", branch.name, "-F", "%H\t%d\t%c")
    end

    while done < #branches do
      self:yield()
    end

    callback(branches)
  end, directory, "branch", "list")
end

---@param directory string
---@param callback plugins.scm.backend.ongettags
function Fossil:get_tags(directory, callback)
  self:execute(function(proc)
    ---@type plugins.scm.backend.tag[]
    local tags = {}
    for idx, line in self:get_process_lines(proc, "stdout") do
      local name = line:match("^%s*(.-)%s*$")
      if name and name ~= "" then
        table.insert(tags, {
          name = name,
          commit = ""
        })
      end
      if idx % 50 == 0 then
        self:yield()
      end
    end

    if #tags == 0 then
      callback(tags)
      return
    end

    local done = 0
    for _, tag in ipairs(tags) do
      self:execute(function(find_proc)
        local commit = nil
        for idx, line in self:get_process_lines(find_proc, "stdout") do
          commit = line:match("^%s*([A-Fa-f0-9]+)%s*$")
          if commit then break end
          if idx % 50 == 0 then
            self:yield()
          end
        end

        if commit then
          tag.commit = commit
          self:execute(function(timeline_proc)
            for idx, line in self:get_process_lines(timeline_proc, "stdout") do
              local hash, date, message = line:match("^([A-Fa-f0-9]+)\t(.-)\t(.*)$")
              if hash then
                tag.date = date
                tag.message = message
                break
              end
              if idx % 50 == 0 then
                self:yield()
              end
            end
            done = done + 1
          end, directory, "timeline", "before", commit, "-n", "1", "-F", "%H\t%d\t%c")
        else
          done = done + 1
        end
      end, directory, "tag", "find", "-t", "ci", "--raw", tag.name)
    end

    while done < #tags do
      self:yield()
    end

    local filtered = {}
    for _, tag in ipairs(tags) do
      if tag.commit ~= "" then
        table.insert(filtered, tag)
      end
    end
    callback(filtered)
  end, directory, "tag", "list", "--tagtype", "singleton")
end

---@param branch string Branch to create
---@param base_branch string Branch or revision to base the new branch from
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:create_branch(branch, base_branch, directory, callback)
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
  end, directory, "branch", "new", branch, base_branch)
end

---@param tag string Tag to create
---@param target string Branch, tag, commit or revision to tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param annotated? boolean
---@param message? string
function Fossil:create_tag(tag, target, directory, callback, annotated, message)
  local params = { "tag", "add", tag, target }
  if annotated and message and message ~= "" then
    table.insert(params, message)
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
function Fossil:update_tag(tag, old_commit, target, directory, callback, annotated, message)
  self:execute(function(cancel_proc)
    local cancel_stdout = self:get_process_output(cancel_proc, "stdout")
    local cancel_stderr = self:get_process_output(cancel_proc, "stderr")
    if not cancel_proc or cancel_proc:returncode() ~= 0 then
      local errmsg = cancel_stderr ~= "" and cancel_stderr or cancel_stdout
      callback(false, errmsg)
      return
    end

    local params = { "tag", "add", tag, target }
    if annotated and message and message ~= "" then
      table.insert(params, message)
    end
    self:execute(function(add_proc)
      local success = false
      local errmsg = ""
      local stdout = self:get_process_output(add_proc, "stdout")
      local stderr = self:get_process_output(add_proc, "stderr")
      if add_proc and add_proc:returncode() == 0 then
        success = true
      else
        if stderr ~= "" then
          errmsg = stderr
        elseif stdout ~= "" then
          errmsg = stdout
        end
        errmsg = "Tag was cancelled but could not be recreated: " .. errmsg
      end
      callback(success, errmsg)
    end, directory, table.unpack(params))
  end, directory, "tag", "cancel", tag, old_commit)
end

---@param target string Branch, commit or revision to checkout
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:checkout(target, directory, callback)
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
  end, directory, "update", target)
end

---@param branch string Branch to close
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param force? boolean Ignored by Fossil
function Fossil:delete_branch(branch, directory, callback, force)
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
  end, directory, "branch", "close", branch)
end

---@param tag string Tag to delete
---@param commit string Commit associated with the tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
function Fossil:delete_tag(tag, commit, directory, callback)
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
  end, directory, "tag", "cancel", tag, commit)
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
---@param target? string
---@param target_type? "branch"|"tag"
function Fossil:get_commit_history(path, directory, callback, target, target_type)
  local params = {
    "timeline", "-n", "0", "-F", "\"'%a' %H '%d' %c\""
  }
  if target and target_type == "tag" then
    table.insert(params, 2, "before")
    table.insert(params, 3, target)
  elseif target then
    table.insert(params, "-b")
    table.insert(params, target)
  end
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

---@param directory string Project directory
---@param callback fun(commit?:string)
function Fossil:get_current_commit(directory, callback)
  self:execute(function(proc)
    if not proc or proc:returncode() ~= 0 then
      callback(nil)
      return
    end
    local stdout = self:get_process_output(proc, "stdout")
    callback(stdout:match("checkout:%s+([a-zA-Z0-9]+)"))
  end, directory, "info")
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

---@param branch string
---@param head_branch string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Fossil:get_branch_diff(branch, head_branch, directory, callback)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "diff", "--branch", branch)
end

---@param tag string
---@param head_branch string
---@param directory string
---@param callback plugins.scm.backend.ongetdiff
function Fossil:get_tag_diff(tag, head_branch, directory, callback)
  self:execute(function(proc)
    local diff = self:get_process_output(proc, "stdout")
    callback(diff)
  end, directory, "diff", "--from", tag, "--to", head_branch)
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
    local diff = self:get_process_output(proc, "stdout")
    callback(changes.stats(diff, function() self:yield() end))
  end, directory, "diff", "-U", "0")
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
---@param message string Commit message
---@param callback plugins.scm.backend.onnewcommit
function Fossil:new_commit(directory, message, callback)
  self:with_commit_message_file(message, function(filename, cleanup, errmsg)
    if not filename then
      callback(false, errmsg or "Could not create temporary commit message file.")
      return
    end
    local started = self:execute(function(proc)
      self:handle_exec_status(proc, callback)
      if cleanup then cleanup() end
    end, directory, "commit", "-M", filename)
    if not started and cleanup then cleanup() end
  end)
end

---@param directory string Project directory
---@param commit string Current commit hash
---@param message string Commit message
---@param callback plugins.scm.backend.onexecstatus
function Fossil:amend_commit(directory, commit, message, callback)
  self:with_commit_message_file(message, function(filename, cleanup, errmsg)
    if not filename then
      callback(false, errmsg or "Could not create temporary commit message file.")
      return
    end
    local started = self:execute(function(proc)
      self:handle_exec_status(proc, callback)
      if cleanup then cleanup() end
    end, directory, "amend", commit, "-M", filename)
    if not started and cleanup then cleanup() end
  end)
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string
---@param password? string
---@param strategy? "merge"|"rebase"|"ff-only" Ignored by Fossil
function Fossil:pull(directory, callback, username, password, strategy)
  if self:has_credentials(username, password) then
    self:get_authenticated_remote_url(directory, username, password, function(url, errmsg)
      if not url then
        callback(false, errmsg or "Could not determine Fossil remote URL.")
        return
      end
      self:execute(function(proc)
        self:handle_exec_status(proc, callback)
      end, directory, "pull", url, "--once")
    end)
    return
  end
  self:execute(function(proc)
    self:handle_exec_status(proc, callback)
  end, directory, "pull")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string
---@param password? string
function Fossil:push(directory, callback, username, password)
  if self:has_credentials(username, password) then
    self:get_authenticated_remote_url(directory, username, password, function(url, errmsg)
      if not url then
        callback(false, errmsg or "Could not determine Fossil remote URL.")
        return
      end
      self:execute(function(proc)
        self:handle_exec_status(proc, callback)
      end, directory, "push", url, "--once")
    end)
    return
  end
  self:execute(function(proc)
    self:handle_exec_status(proc, callback)
  end, directory, "push")
end

---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param prune? boolean Ignored by Fossil
---@param username? string
---@param password? string
function Fossil:fetch(directory, callback, prune, username, password)
  if self:has_credentials(username, password) then
    self:get_authenticated_remote_url(directory, username, password, function(url, errmsg)
      if not url then
        callback(false, errmsg or "Could not determine Fossil remote URL.")
        return
      end
      self:execute(function(proc)
        self:handle_exec_status(proc, callback)
      end, directory, "pull", url, "--once")
    end)
    return
  end
  self:execute(function(proc)
    self:handle_exec_status(proc, callback)
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
function Fossil:remove_path(path, directory, callback)
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


return Fossil
