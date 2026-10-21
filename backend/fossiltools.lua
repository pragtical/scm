local common = require "core.common"
local tools = require "plugins.scm.backend.tools"
local json = require "core.json"
local fossildiff = require "plugins.scm.backend.fossildiff"

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read "*a"
  file:close()
  return text
end

return function(Fossil)
  function Fossil:get_capabilities()
    return {
      merge = true,
      conflict_versions = true,
      remotes = true,
      default_remote = true,
      initialize = true,
    }
  end

  function Fossil:init_repository(directory, callback, options)
    local ok, errmsg = tools.can_initialize(directory)
    if not ok then
      callback(false, errmsg)
      return
    end
    options = options or {}
    local repository = options.repository
    if
      not tools.safe_ref(repository)
      or not common.is_absolute_path(repository)
      or system.get_file_info(repository)
    then
      callback(false, "Choose a new absolute repository filename.")
      return
    end
    local user = options.username
    if not tools.safe_ref(user) then
      callback(false, "Enter an administrator username.")
      return
    end
    tools.run(
      self,
      directory,
      { "new", repository, "--admin-user", user },
      function(output, err)
        if not output then
          callback(false, err)
          return
        end
        tools.run(
          self,
          directory,
          { "open", repository, "--keep", "--nosync" },
          function(opened, open_error)
            if not opened then
              callback(
                false,
                "Repository was created at '"
                  .. repository
                  .. "' but could not be opened:\n"
                  .. (open_error or "")
              )
            else
              tools.run(
                self,
                directory,
                { "user", "default", user },
                tools.status(callback)
              )
            end
          end
        )
      end
    )
  end

  function Fossil:get_init_options(directory)
    return {
      {
        id = "repository",
        label = "New repository file",
        kind = "file",
        required = true,
        value = (common.dirname(directory) or directory)
          .. PATHSEP
          .. common.basename(directory)
          .. ".fossil",
      },
      {
        id = "username",
        label = "Administrator username",
        required = true,
        value = os.getenv "USER" or os.getenv "USERNAME" or "",
      },
    }
  end

  function Fossil:get_remotes(directory, callback)
    tools.run(self, directory, { "remote", "list" }, function(output, errmsg)
      if not output then
        callback(nil, errmsg)
        return
      end
      local result = {}
      for line in output:gmatch "[^\r\n]+" do
        local name, url = line:match "^%s*(%S+)%s+(.-)%s*$"
        if name and url ~= "" then
          result[#result + 1] = {
            name = name,
            url = url,
            push_url = url,
            is_default = name == "default",
          }
        end
      end
      callback(result)
    end)
  end

  local function valid_remote(name, url)
    return tools.safe_ref(name)
      and not name:find "%s"
      and tools.safe_ref(url)
      and (url:match "^%a[%w+.-]*://" or common.is_absolute_path(url))
  end

  function Fossil:add_remote(directory, name, url, callback)
    if not valid_remote(name, url) then
      callback(false, "Enter a valid remote name and URL.")
      return
    end
    -- Fossil's add command replaces existing names. Creation must not do so.
    self:get_remotes(directory, function(remotes, errmsg)
      if not remotes then
        callback(false, errmsg)
        return
      end
      for _, remote in ipairs(remotes) do
        if remote.name == name then
          callback(false, "Remote already exists.")
          return
        end
      end
      local args = name == "default" and { "remote", url }
        or { "remote", "add", name, url }
      tools.run(self, directory, args, tools.status(callback))
    end)
  end

  function Fossil:set_remote_url(directory, name, url, push, callback)
    if push or not valid_remote(name, url) then
      callback(false, "Fossil uses one URL for both fetch and push.")
      return
    end
    local args = name == "default" and { "remote", url }
      or { "remote", "add", name, url }
    tools.run(self, directory, args, tools.status(callback))
  end

  function Fossil:remove_remote(directory, name, callback)
    if not tools.safe_ref(name) or name:find "%s" then
      callback(false, "Enter a valid remote name.")
      return
    end
    local args = name == "default" and { "remote", "off" }
      or { "remote", "delete", name }
    tools.run(self, directory, args, tools.status(callback))
  end

  function Fossil:set_default_remote(directory, name, callback)
    self:get_remotes(directory, function(remotes, errmsg)
      if not remotes then
        callback(false, errmsg)
        return
      end
      for _, remote in ipairs(remotes) do
        if remote.name == name then
          tools.run(
            self,
            directory,
            { "remote", remote.url },
            tools.status(callback)
          )
          return
        end
      end
      callback(false, "Remote does not exist.")
    end)
  end

  function Fossil:get_operation_status(directory, callback)
    tools.run(
      self,
      directory,
      { "changes", "--merge", "--classify" },
      function(output, errmsg)
        if not output then
          callback(nil, errmsg)
          return
        end
        if
          output:find("MERGED_WITH", 1, true)
          or output:find("CHERRYPICK", 1, true)
          or output:find("INTEGRATED_WITH", 1, true)
        then
          callback({
            kind = "merge",
            commit_required = true,
            abort_warning = "Fossil undo restores the last undoable command, "
              .. "which may not be the merge if another undoable command "
              .. "ran afterward. Undo the latest command?",
          })
        elseif output:find("CONFLICT", 1, true) then
          callback({
            kind = "update",
            commit_required = true,
            abort_warning = "Fossil undo restores the last undoable command. "
              .. "Undo the latest update or merge?",
          })
        else
          callback(nil)
        end
      end
    )
  end

  function Fossil:resolve_operation(directory, operation, action, callback)
    if operation ~= "merge" and operation ~= "update" or action ~= "abort" then
      callback(false, "Fossil merges are completed by creating a commit.")
      return
    end
    -- Native one-level undo restores the pre-merge checkout, not Git reset.
    tools.run(self, directory, { "undo" }, tools.status(callback))
  end

  function Fossil:merge_branch(source, target, directory, callback, strategy)
    if strategy and strategy ~= "normal" and strategy ~= "integrate" then
      callback(false, "Fossil supports normal or integrate merges.")
      return
    end
    if not tools.safe_ref(source) or not tools.safe_ref(target) then
      callback(false, "Invalid branch.")
      return
    end
    self:get_working_changes(directory, function(changes, err)
      if not changes or #changes > 0 then
        callback(false, err or "Commit or stash changes before merging.")
        return
      end
      self:checkout(target, directory, function(ok, errmsg)
        if not ok then
          callback(false, errmsg)
          return
        end
        local args = { "merge", "--nosync", "--keep-merge-files" }
        if strategy == "integrate" then
          args[#args + 1] = "--integrate"
        end
        args[#args + 1] = source
        tools.run(self, directory, args, function(output, merge_err)
          if not output then
            callback(false, merge_err)
            return
          end
          self:get_working_changes(directory, function(list, list_err)
            if not list then
              callback(false, list_err)
              return
            end
            for _, entry in ipairs(list) do
              if entry.conflicted then
                callback(false, "Resolve merge conflicts, then commit.")
                return
              end
            end
            callback(true)
          end)
        end)
      end)
    end)
  end

  function Fossil:get_conflict_versions(path, directory, callback)
    local relative, errmsg = tools.path(directory, path)
    if not relative then
      callback(nil, errmsg)
      return
    end
    local result = {
      base = read(path .. "-baseline"),
      ours = read(path .. "-original"),
      theirs = read(path .. "-merge"),
    }
    if result.base and result.ours and result.theirs then
      callback(result)
    else
      callback(
        nil,
        "Merge source files are unavailable. Use the conflict "
          .. "markers in the result, or merge with --keep-merge-files."
      )
    end
  end

  function Fossil:get_review_diff(path, directory, callback, options)
    options = options or {}
    local args = {
      "diff",
      "--internal",
      "--unified",
      "--verbose",
      "--context",
      tostring(options.context == 1000000 and -1 or options.context or 3),
    }
    if options.whitespace then
      args[#args + 1] = "--ignore-all-space"
    end
    local relative
    if path then
      local err
      relative, err = tools.path(directory, path)
      if not relative then
        callback(nil, err)
        return
      end
      args[#args + 1], args[#args + 2] = "--", relative
    end
    fossildiff.read(self, directory, args, callback, {
      path = relative,
    })
  end

  function Fossil:get_review_versions(path, directory, callback)
    local relative, errmsg = tools.path(directory, path)
    if not relative then
      callback(nil, errmsg)
      return
    end
    tools.run(
      self,
      directory,
      { "cat", "-r", "current", relative },
      function(before)
        local after = read(path) or ""
        if #after > 16 * 1024 * 1024 or #(before or "") > 16 * 1024 * 1024 then
          callback(nil, "Binary preview exceeds 16 MiB.")
          return
        end
        callback({ before = before or "", after = after })
      end
    )
  end

  function Fossil:get_sync_history(directory, callback)
    callback({
      incoming = {},
      outgoing = {},
      note = "Fossil synchronizes repository artifacts, not remote-tracking "
        .. "branches. Fetch and pull import check-ins without updating the "
        .. "checkout. Push publishes shareable artifacts. Per-remote "
        .. "ahead/behind counts are not exposed by Fossil.",
    })
  end

  function Fossil:search_history(directory, query, callback, limit, target)
    local function quote(text)
      return "'" .. tostring(text):gsub("%z", ""):gsub("'", "''") .. "'"
    end
    local author = "coalesce(e.euser,e.user,'')"
    local summary = "coalesce(e.ecomment,e.comment,'')"
    local where, prefix = { "e.type='ci'" }, ""
    if target and target ~= "" then
      prefix = "WITH RECURSIVE ancestors(rid) AS (SELECT "
        .. "symbolic_name_to_rid("
        .. quote(target)
        .. ") UNION "
        .. "SELECT p.pid FROM plink p JOIN ancestors a ON p.cid=a.rid) "
      where[#where + 1] = "e.objid IN (SELECT rid FROM ancestors)"
    end
    for _, field in ipairs({ { "author", author }, { "message", summary } }) do
      if query[field[1]] and query[field[1]] ~= "" then
        where[#where + 1] = "instr(lower("
          .. field[2]
          .. "),lower("
          .. quote(query[field[1]])
          .. "))>0"
      end
    end
    if query.path and query.path ~= "" then
      local path = query.path:gsub("\\", "/"):gsub("/$", "")
      where[#where + 1] = "EXISTS(SELECT 1 FROM mlink m JOIN filename f "
        .. "ON f.fnid=m.fnid WHERE m.mid=e.objid AND (f.name="
        .. quote(path)
        .. " OR substr(f.name,1,"
        .. (#path + 1)
        .. ")="
        .. quote(path .. "/")
        .. "))"
    end
    local sql = prefix
      .. "SELECT b.uuid AS hash,"
      .. author
      .. " AS author,"
      .. "datetime(e.mtime) AS date,"
      .. summary
      .. " AS summary "
      .. "FROM event e JOIN blob b ON b.rid=e.objid WHERE "
      .. table.concat(where, " AND ")
      .. " ORDER BY e.mtime DESC LIMIT "
      .. math.max(1, math.min(10000, math.floor(tonumber(limit) or 200)))
    tools.run(
      self,
      directory,
      { "sql", "--readonly", "-json", sql },
      function(output, errmsg)
        if not output then
          callback(nil, errmsg)
          return
        end
        local ok, rows = pcall(json.decode, output == "" and "[]" or output)
        if not ok or type(rows) ~= "table" then
          callback(nil, "Could not parse Fossil search results.")
          return
        end
        callback(rows)
      end
    )
  end
end
