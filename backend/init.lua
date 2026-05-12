local core = require "core"
local util = require "plugins.scm.util"
local DirWatch = require "core.dirwatch"
local Object = require "core.object"

---@alias plugins.scm.backend.filestatus
---| "added"
---| "edited"
---| "deleted"
---| "renamed"
---| "unchanged"
---| "untracked"

---@class plugins.scm.backend.filechange
---@field status plugins.scm.backend.filestatus
---@field staged boolean
---@field path string
---@field new_path string?

---@class plugins.scm.backend.stats
---@field inserts integer
---@field deletes integer
---@field modified integer

---@class plugins.scm.backend.branch
---@field name string
---@field remote? string
---@field remote_only? boolean
---@field date? string
---@field commit string
---@field message? string

---@class plugins.scm.backend.tag
---@field name string
---@field date? string
---@field commit string
---@field message? string
---@field annotated? boolean

---@class plugins.scm.backend.cache
---@field name string
---@field path string
---@field expires number
---@field value any

---Representation of a commit data.
---@class plugins.scm.backend.commit
---@field hash string
---@field author string
---@field date string
---@field summary string
---@field message? string

---@class plugins.scm.backend.blame
---@field commit string
---@field author string
---@field date string

---@alias plugins.scm.backend.onexecute fun(proc?:process, errmsg?:string, errcode?:number)
---@alias plugins.scm.backend.ongetdiff fun(diff?:string, cached?:boolean)
---@alias plugins.scm.backend.ongetfile fun(content?:string)
---@alias plugins.scm.backend.ongetbranch fun(branch?:string, cached?:boolean)
---@alias plugins.scm.backend.ongetbranches fun(branches?:plugins.scm.backend.branch[], cached?:boolean)
---@alias plugins.scm.backend.ongettags fun(tags?:plugins.scm.backend.tag[], cached?:boolean)
---@alias plugins.scm.backend.ongetchanges fun(changes?:plugins.scm.backend.filechange[], cached?:boolean)
---@alias plugins.scm.backend.ongetcommithistory fun(changes?:plugins.scm.backend.commit[], cached?:boolean)
---@alias plugins.scm.backend.ongetcommit fun(changes:plugins.scm.backend.commit, cached?:boolean)
---@alias plugins.scm.backend.ongetfilestatus fun(status?:plugins.scm.backend.filestatus, cached?:boolean)
---@alias plugins.scm.backend.ongetfileblame fun(list?:plugins.scm.backend.blame[], cached?:boolean)
---@alias plugins.scm.backend.ongetstaged fun(files?:table<string,boolean>, cached?:boolean)
---@alias plugins.scm.backend.ongetstats fun(stats?:plugins.scm.backend.stats, cached?:boolean)
---@alias plugins.scm.backend.ongetstatus fun(status?:string, cached?:boolean)
---@alias plugins.scm.backend.onnewcommit plugins.scm.backend.onexecstatus
---@alias plugins.scm.backend.onexecstatus fun(success:boolean, errmsg?:string, requires_credentials?:boolean, requires_pull_strategy?:boolean)
---@alias plugins.scm.backend.rebasestrategy "normal"|"ours"|"theirs"
---@alias plugins.scm.backend.onrebasestatus fun(success:boolean, errmsg?:string, requires_rebase_resolution?:boolean)
---@alias plugins.scm.backend.oncherrypickstatus fun(success:boolean, errmsg?:string, requires_resolution?:boolean)

---Base functionality to implement a SCM backend with async support.
---@class plugins.scm.backend : core.object
---@field name string
---@field blocking boolean
---@field command string
---@field cache plugins.scm.backend.cache[]
---@field super plugins.scm.backend
local Backend = Object:extend()

---Constructor
---@param name string
---@param command string
function Backend:new(name, command)
  self.name = name
  self.cache = {}
  self.next_clean = os.time() + 20
  self.blocking = false
  self.watch = DirWatch()
  self:set_command(command)
end

---Set the path to the scm executable.
---@param command string
---@return boolean found
function Backend:set_command(command)
  if util.command_exists(command) then
    self.command = command
    return true
  end
  self.command = nil
  return false
end

---Execute coroutine.yield if blocking mode is disabled.
---@param wait? number
function Backend:yield(wait)
  if not self.blocking then
    local co, is_main = coroutine.running()
    -- only yield if we are inside a coroutine
    if co and not is_main then
      coroutine.yield(wait)
    end
  end
end

---Enable or disable coroutine execution of process calls.
---@param enabled boolean
function Backend:set_blocking_mode(enabled)
  self.blocking = enabled
end

---Add a value into a temporary cache, this is useful to cache the ouput
---of commands for faster retrieveal until the given expire period.
---@param name string
---@param value any
---@param path string
---@param expires? integer Amount of seconds to expire, defaults to 5
function Backend:add_to_cache(name, value, path, expires)
  local found = nil
  for i, cache in ipairs(self.cache) do
    if cache.name == name and cache.path == path then
      found = i
      break
    end
  end

  if found then
    self.cache[found].value = value
    self.cache[found].expires = os.time() + (expires or 5)
  else
    table.insert(self.cache, {
      name = name,
      value = value,
      path = path,
      expires = os.time() + (expires or 5)
    })
  end
end

---Removes all expired cached elements.
function Backend:clean_cache()
  local current_time = os.time()

  if self.next_clean > current_time then return end

  local deleted = 0
  for i=1, #self.cache do
    local cache = self.cache[i-deleted]
    if cache.expires < current_time then
      table.remove(self.cache, i-deleted)
      deleted = deleted + 1
    end
  end

  self.next_clean = current_time + 20
end

---Mark a cached value as expired to force new retrieval.
---@param name string
---@param path? string
function Backend:expire_cache(name, path)
  for _, value in ipairs(self.cache) do
    if not path then
      if value.name == name then
        value.expires = 0
      end
    elseif value.name == name and value.path == path then
      value.expires = 0
      break
    end
  end
end

---Get a value that was previously stored on the cache.
---@param name string
---@param path string
function Backend:get_from_cache(name, path)
  self:clean_cache()

  local found = nil
  for i, cache in ipairs(self.cache) do
    if cache.name == name and cache.path == path then
      found = i
      break
    end
  end

  if found then
    if self.cache[found].expires >= os.time() then
      return self.cache[found].value
    end
    table.remove(self.cache, found)
  end

  return nil
end

---Iterates over all the lines that the running process is outputting.
---The iterator can return an empty line while the process gets ready to output.
---@param proc process
---@param from? string | "stdout" | "stderr"
---@return fun():integer,string
function Backend:get_process_lines(proc, from)
  local output = self:get_process_output(proc, from)
  return coroutine.wrap(function()
    local line_num = 1
    for line in (output.."\n"):gmatch("(.-)".."\n") do
      coroutine.yield(line_num, line)
      line_num = line_num + 1
    end
  end)
end

---Gets all the output of the process at once, this function yields
---while reading to allow async support when ran from a coroutine.
---@param proc process
---@param from? string | "stdout" | "stderr"
---@return string
function Backend:get_process_output(proc, from)
  if not proc then return "" end
  from = from and "read_" .. from or "read_stdout"
  local output = ""
  local read_size = 1024 * 10
  local read = proc[from](proc, read_size)
  local iterations = 0
  repeat
    if read ~= nil and read ~= "" then
      output = output .. read
    end
    iterations = iterations + 1
    if iterations % 10 == 0 then self:yield() end
    read = proc[from](proc, read_size)
  until (read == nil or read == "") and not proc:running()
  return output
end

---Call the scm command with the given parameters.
---@param callback plugins.scm.backend.onexecute
---@param directory string Path of project directory
---@param ... string parameters to pass to associated command
function Backend:execute(callback, directory, ...)
  if not self.command then return false end
  local command = table.pack(self.command, ...)
  local options = self:get_process_options(directory)
  local proc, errmsg, errcode
  local ran, ranerr = core.try(function()
    proc, errmsg, errcode = process.start(command, options)
    if not self.blocking then
      core.add_thread(function()
        callback(proc, errmsg, errcode)
        if proc and proc:running() then proc:kill() end
      end)
    else
      callback(proc, errmsg, errcode)
      if proc and proc:running() then proc:kill() end
    end
  end)
  if not proc then
    local msg_code = ran and {errmsg, errcode} or {ranerr, "-1"}
    core.error(
      "[SCM] error while executing '%s' - %s:%s",
      table.concat(command, " "),
      table.unpack(msg_code)
    )
  end
  return proc ~= nil
end

---Write a commit message to a temporary file and run a callback with its path.
---@param message string Commit message
---@param callback fun(filename?:string, cleanup?:fun(), errmsg?:string)
function Backend:with_commit_message_file(message, callback)
  local temp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP")
    or (PLATFORM == "Windows" and nil or "/tmp")
  local filename = temp_dir
    and core.temp_filename(".scm-commit-message", temp_dir)
    or core.temp_filename(".scm-commit-message")
  local file, errmsg = io.open(filename, "wb")
  if not file and temp_dir then
    filename = core.temp_filename(".scm-commit-message")
    file, errmsg = io.open(filename, "wb")
  end
  if not file then
    callback(nil, nil, errmsg)
    return
  end
  file:write(message)
  file:close()
  callback(filename, function()
    os.remove(filename)
  end)
end

---Build process options for SCM command execution.
---@param directory string Path of project directory
---@return process.options
function Backend:get_process_options(directory)
  return {cwd = directory}
end

---Check if given directory is source controlled by current backend.
---@param directory string Project directory
---@return boolean detected
---@diagnostic disable-next-line
function Backend:detect(directory) return false end

---Custom project watching to perform neccesary updates.
---@param directory string Project directory
---@diagnostic disable-next-line
function Backend:watch_project(directory) end

---Unregister project watching.
---@param directory string Project directory
---@diagnostic disable-next-line
function Backend:unwatch_project(directory) end

---Report if the backend has a staging area.
---@return boolean
function Backend:has_staging() return false end

---Add a file path to staging area.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:stage_file(file, directory, callback) callback(false, "not implemented") end

---Remove a file path from staging area.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:unstage_file(file, directory, callback) callback(false, "not implemented") end

---Retrieve the list of all staged files.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstaged
---@diagnostic disable-next-line
function Backend:get_staged(directory, callback) callback(nil) end

---Report if there are changes that can be committed.
---@param directory string Project directory
---@param callback fun(has_changes:boolean)
function Backend:has_commit_changes(directory, callback)
  self:get_changes(directory, function(changes)
    for _, change in ipairs(changes or {}) do
      if change.status ~= "untracked" then
        callback(true)
        return
      end
    end
    callback(false)
  end)
end

---Retrieve the current branch.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetbranch
---@diagnostic disable-next-line
function Backend:get_branch(directory, callback) callback(nil) end

---Retrieve all branches with the latest commit of each branch.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetbranches
---@diagnostic disable-next-line
function Backend:get_branches(directory, callback) callback(nil) end

---Retrieve all tags with the commit each tag points to.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongettags
---@diagnostic disable-next-line
function Backend:get_tags(directory, callback) callback(nil) end

---Create a new branch from the given base branch.
---@param branch string Branch to create
---@param base_branch string Branch or revision to base the new branch from
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:create_branch(branch, base_branch, directory, callback) callback(false, "not implemented") end

---Rebase a branch onto another branch or revision.
---@param branch string Branch to rebase
---@param base_branch string Branch or revision to rebase onto
---@param directory string Project directory
---@param callback plugins.scm.backend.onrebasestatus
---@param strategy? plugins.scm.backend.rebasestrategy Conflict strategy when supported
---@diagnostic disable-next-line
function Backend:rebase_branch(branch, base_branch, directory, callback, strategy) callback(false, "not implemented") end

---Report if rebasing branches is supported.
---@return boolean
function Backend:supports_rebase_branch() return false end

---Create a new tag from the given target revision.
---@param tag string Tag to create
---@param target string Branch, tag, commit or revision to tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param annotated? boolean Create an annotated tag when supported
---@param message? string Message for annotated tags when supported
---@diagnostic disable-next-line
function Backend:create_tag(tag, target, directory, callback, annotated, message) callback(false, "not implemented") end

---Update an existing tag by replacing the target and supported metadata.
---@param tag string Tag to update
---@param old_commit string Commit currently associated with the tag
---@param target string Branch, tag, commit or revision to tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param annotated? boolean Create an annotated tag when supported
---@param message? string Message for annotated tags when supported
---@diagnostic disable-next-line
function Backend:update_tag(tag, old_commit, target, directory, callback, annotated, message) callback(false, "not implemented") end

---Checkout the given branch, commit, tag or other backend-supported revision.
---@param target string Branch, commit or revision to checkout
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:checkout(target, directory, callback) callback(false, "not implemented") end

---Cherry-pick the given commit into the current checkout.
---@param commit string Commit hash or backend-supported revision
---@param directory string Project directory
---@param callback plugins.scm.backend.oncherrypickstatus
---@diagnostic disable-next-line
function Backend:cherry_pick(commit, directory, callback) callback(false, "not implemented", false) end

---Report if cherry-picking commits is supported.
---@return boolean
function Backend:supports_cherry_pick() return false end

---Delete the given branch.
---@param branch string Branch to delete
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param force? boolean Force deletion when supported by the backend
---@diagnostic disable-next-line
function Backend:delete_branch(branch, directory, callback, force) callback(false, "not implemented") end

---Delete the given tag.
---@param tag string Tag to delete
---@param commit string Commit associated with the tag
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:delete_tag(tag, commit, directory, callback) callback(false, "not implemented") end

---Retrieve a list of file changes.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetchanges
---@diagnostic disable-next-line
function Backend:get_changes(directory, callback) callback({}, false) end

---Retrieve the commit history.
---@param path? string If not nil get commit history of specific file or directory.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetcommithistory
---@param target? string If not nil get commit history for a specific branch or tag.
---@param target_type? "branch"|"tag"
---@diagnostic disable-next-line
function Backend:get_commit_history(path, directory, callback, target, target_type) callback(nil) end

---Retrieve the entire project unified diff.
---@param id string Hash of the commit
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetcommit
---@diagnostic disable-next-line
function Backend:get_commit_info(id, directory, callback) callback(nil) end

---Retrieve the current checked out commit.
---@param directory string Project directory
---@param callback fun(commit?:string)
---@diagnostic disable-next-line
function Backend:get_current_commit(directory, callback) callback(nil) end

---Retrieve the diff for a given commit.
---@param id string Hash of the commit
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetdiff
---@diagnostic disable-next-line
function Backend:get_commit_diff(id, directory, callback) callback(nil) end

---Retrieve the diff of changes introduced by branch compared to head_branch.
---@param branch string Branch to diff
---@param head_branch string Branch to diff from
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetdiff
---@diagnostic disable-next-line
function Backend:get_branch_diff(branch, head_branch, directory, callback) callback(nil) end

---Retrieve the diff between head_branch and tag.
---@param tag string Tag to diff
---@param head_branch string Branch to diff from
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetdiff
---@diagnostic disable-next-line
function Backend:get_tag_diff(tag, head_branch, directory, callback) callback(nil) end

---Retrieve the contents of a file for a given commit.
---@param id? string Hash of the commit
---@param directory string Project directory
---@param file string File associated with the given commit
---@param callback plugins.scm.backend.ongetfile
---@diagnostic disable-next-line
function Backend:get_commit_file(id, directory, file, callback) callback(nil) end

---Retrieve the entire project unified diff.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetdiff
---@diagnostic disable-next-line
function Backend:get_diff(directory, callback) callback(nil) end

---Retrieve the unified diff for the given file.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetdiff
---@diagnostic disable-next-line
function Backend:get_file_diff(file, directory, callback) callback(nil) end

---Retrieve the current status of the given file.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetfilestatus
---@diagnostic disable-next-line
function Backend:get_file_status(file, directory, callback) callback("unchanged") end

---Retrieve the blame information for every line on a file.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetfileblame
---@diagnostic disable-next-line
function Backend:get_file_blame(file, directory, callback) callback(nil) end

---Retrieve insertion and deletion stats for an entire project.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstats
---@diagnostic disable-next-line
function Backend:get_stats(directory, callback) callback({inserts = 0, deletes = 0, modified = 0}) end

---Retrieve the status description for an entire repo.
---@param directory string Project directory
---@param callback plugins.scm.backend.ongetstatus
---@diagnostic disable-next-line
function Backend:get_status(directory, callback) callback(nil) end

---Create a new commit.
---@param directory string Project directory
---@param message string Commit message
---@param callback plugins.scm.backend.onnewcommit
---@diagnostic disable-next-line
function Backend:new_commit(directory, message, callback) callback(false, "not implemented") end

---Amend the current commit.
---@param directory string Project directory
---@param commit string Current commit hash
---@param message string Commit message
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:amend_commit(directory, commit, message, callback) callback(false, "not implemented") end

---Pull latest changes.
---TODO: this is a WIP we should handle remote and branch
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string
---@param password? string
---@param strategy? "merge"|"rebase"|"ff-only"
---@diagnostic disable-next-line
function Backend:pull(directory, callback, username, password, strategy) callback(false, "not implemented") end

---Push local changes to the configured remote.
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param username? string
---@param password? string
---@diagnostic disable-next-line
function Backend:push(directory, callback, username, password) callback(false, "not implemented") end

---Fetch remote references without updating the current checkout.
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@param prune? boolean Remove locally cached remote refs deleted upstream when supported
---@param username? string
---@param password? string
---@diagnostic disable-next-line
function Backend:fetch(directory, callback, prune, username, password) callback(false, "not implemented") end

---Report if fetch supports pruning refs deleted upstream.
---@return boolean
function Backend:supports_fetch_prune() return false end

---Report if a backend error can be retried after asking the user for credentials.
---@param errmsg? string
---@return boolean
function Backend:requires_credentials(errmsg) return false end

---Retrieve the username currently remembered by the backend, when available.
---@param directory string Project directory
---@param callback fun(username?:string)
---@diagnostic disable-next-line
function Backend:get_username(directory, callback) callback(nil) end

---Report if a backend error can be retried after choosing a pull strategy.
---@param errmsg? string
---@return boolean
function Backend:requires_pull_strategy(errmsg) return false end

---Report if a backend error means a rebase stopped for manual resolution.
---@param errmsg? string
---@return boolean
function Backend:requires_rebase_resolution(errmsg) return false end

---Report if a backend error means a cherry-pick stopped for manual resolution.
---@param errmsg? string
---@return boolean
function Backend:requires_cherry_pick_resolution(errmsg) return false end

---Set the backend's default pull strategy for this repository.
---@param directory string Project directory
---@param strategy "merge"|"rebase"|"ff-only"
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:set_pull_strategy(directory, strategy, callback) callback(false, "not implemented") end

---Restore a file to its previous HEAD state before any changes.
---@param file string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:revert_file(file, directory, callback) callback(false, "not implemented") end

---Add a directory or file to repository
---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:add_path(path, directory, callback) callback(false, "not implemented") end

---Remove a file or directory from repository without deleting it.
---@param path string Absolute path to file
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:remove_path(path, directory, callback) callback(false, "not implemented") end

---Rename a path of a directory or file in the repository.
---@param from string Path to move
---@param to string Destination of from path
---@param directory string Project directory
---@param callback plugins.scm.backend.onexecstatus
---@diagnostic disable-next-line
function Backend:move_path(from, to, directory, callback) callback(false, "not implemented") end


return Backend
