local common = require "core.common"
local tools = require "plugins.scm.backend.tools"
local json = require "core.json"
local util = require "plugins.scm.util"
local REWRITE_ACTIONS = { pick = true, squash = true, drop = true }

return function(Git)
  function Git:get_capabilities()
    return {
      merge = true,
      initialize = true,
      sync_history = true,
      history_contents = true,
      remote_refs = true,
      remotes = true,
      remote_rename = true,
      remote_push_url = true,
      worktrees = true,
      submodules = true,
      lfs = util.command_exists "git-lfs"
        or util.command_exists(
          (common.dirname(self.command or "git") or ".") .. PATHSEP .. "git-lfs"
        ),
      rewrite = true,
      conflict_versions = true,
      stash_untracked = true,
      stash_index = true,
    }
  end

  function Git:init_repository(directory, callback, options)
    local ok, errmsg = tools.can_initialize(directory)
    if not ok then
      callback(false, errmsg)
      return
    end
    local branch = options and options.branch or "main"
    if not tools.safe_ref(branch) then
      callback(false, "Enter a valid initial branch name.")
      return
    end
    tools.run(
      self,
      directory,
      { "init", "--initial-branch=" .. branch, "." },
      tools.status(callback)
    )
  end

  function Git:get_init_options(directory)
    return {
      {
        id = "branch",
        label = "Initial branch",
        value = "main",
        required = true,
      },
    }
  end

  function Git:get_remotes(directory, callback)
    tools.run(
      self,
      directory,
      { "config", "--null", "--list" },
      function(output, errmsg)
        if not output then
          callback(nil, errmsg)
          return
        end
        local result, indexed = {}, {}
        for record in output:gmatch "([^%z]+)%z" do
          local key, value = record:match "^([^\n]+)\n(.*)$"
          local name, field = (key or ""):match "^remote%.(.+)%.([^.]+)$"
          if name then
            if not indexed[name] then
              indexed[name] = { name = name, fetch_urls = {}, push_urls = {} }
              result[#result + 1] = indexed[name]
            end
            local entry = indexed[name]
            local urls = field == "url" and entry.fetch_urls
              or field == "pushurl" and entry.push_urls
            if urls then
              urls[#urls + 1] = value
            end
          end
        end
        table.sort(result, function(a, b)
          return a.name < b.name
        end)
        for _, entry in ipairs(result) do
          entry.url = entry.fetch_urls[1] or ""
          entry.push_url = entry.push_urls[1] or entry.url
          entry.push_explicit = #entry.push_urls > 0
        end
        callback(result)
      end
    )
  end

  function Git:get_push_targets(directory, callback)
    self:get_remotes(directory, function(remotes, errmsg)
      if not remotes then
        callback(nil, errmsg)
        return
      elseif #remotes == 0 then
        callback(nil, "No remotes are configured. Add one in Repository Tools.")
        return
      end
      local fallback = #remotes == 1 and remotes[1].name or nil
      for _, remote in ipairs(remotes) do
        if remote.name == "origin" then fallback = "origin" end
      end
      tools.run(self, directory, {
        "for-each-ref",
        "--format=%(HEAD)%00%(refname:strip=2)%00%(push)%00"
          .. "%(push:remotename)%00%(push:remoteref)%00%(upstream)%00"
          .. "%(upstream:remotename)%00%(upstream:remoteref)",
        "refs/heads/",
      }, function(output, err)
        if not output then
          callback(nil, err)
          return
        end
        local result = { remotes = remotes, branches = {} }
        for line in output:gmatch "[^\r\n]+" do
          local head, name, push, remote, target, upstream, up_remote, up_ref =
            line:match("^(.-)%z(.-)%z(.-)%z(.-)%z(.-)%z(.-)%z(.-)%z(.*)$")
          if name then
            remote = remote ~= "" and remote or fallback
            -- Normal push.default modes can leave push:remoteref empty.
            if target == "" then
              if remote == up_remote and (push == "" or push == upstream) then
                target = up_ref
              elseif remote then
                local prefix = "refs/remotes/" .. remote .. "/"
                if push:sub(1, #prefix) == prefix then
                  target = "refs/heads/" .. push:sub(#prefix + 1)
                end
              end
            end
            target = target:match "^refs/heads/(.+)$" or name
            result.branches[#result.branches + 1] = {
              name = name, remote = remote, target = target,
              upstream = upstream ~= "" and upstream or nil,
            }
            if head == "*" then result.branch = name end
          end
          if #result.branches % 100 == 0 then self:yield() end
        end
        if #result.branches == 0 then
          callback(nil,
            "No local branches are available. Create a commit first.")
          return
        end
        callback(result)
      end)
    end)
  end

  function Git:add_remote(directory, name, url, callback)
    if not tools.safe_ref(name) or not tools.safe_ref(url) then
      callback(false, "Enter a valid remote name and URL.")
      return
    end
    tools.run(
      self,
      directory,
      { "remote", "add", name, url },
      tools.status(callback)
    )
  end

  function Git:set_remote_url(directory, name, url, push, callback)
    if
      not tools.safe_ref(name)
      or not (push and url == "" or tools.safe_ref(url))
    then
      callback(false, "Enter a valid remote name and URL.")
      return
    end
    if push and url == "" then
      -- Only clear explicit push URLs; an absent key already uses fetch URLs.
      self:get_remotes(directory, function(remotes, errmsg)
        if not remotes then
          callback(false, errmsg)
          return
        end
        for _, remote in ipairs(remotes) do
          if remote.name == name then
            if not remote.push_explicit then
              callback(true)
              return
            end
            tools.run(self, directory, {
              "config",
              "--local",
              "--unset-all",
              "remote." .. name .. ".pushurl",
            }, tools.status(callback))
            return
          end
        end
        callback(false, "Remote does not exist.")
      end)
      return
    end
    self:get_remotes(directory, function(remotes, errmsg)
      if not remotes then
        callback(false, errmsg)
        return
      end
      for _, remote in ipairs(remotes) do
        if remote.name == name then
          local urls = push and remote.push_urls or remote.fetch_urls
          local args
          if #urls > 1 then
            -- Match the literal first value, preserving other configured URLs.
            args = {
              "config",
              "--local",
              "--fixed-value",
              "--replace-all",
              "remote." .. name .. (push and ".pushurl" or ".url"),
              url,
              urls[1],
            }
          else
            args = { "remote", "set-url" }
            if push then
              args[#args + 1] = "--push"
            end
            args[#args + 1], args[#args + 2] = name, url
          end
          tools.run(self, directory, args, tools.status(callback))
          return
        end
      end
      callback(false, "Remote does not exist.")
    end)
  end

  function Git:rename_remote(directory, name, new_name, callback)
    if not tools.safe_ref(name) or not tools.safe_ref(new_name) then
      callback(false, "Enter a valid remote name.")
      return
    end
    tools.run(
      self,
      directory,
      { "remote", "rename", name, new_name },
      tools.status(callback)
    )
  end

  function Git:remove_remote(directory, name, callback)
    if not tools.safe_ref(name) then
      callback(false, "Enter a valid remote name.")
      return
    end
    tools.run(
      self,
      directory,
      { "remote", "remove", name },
      tools.status(callback)
    )
  end

  function Git:get_sync_history(directory, callback, limit)
    tools.run(
      self,
      directory,
      { "rev-parse", "--abbrev-ref", "@{upstream}" },
      function(upstream, errmsg)
        if not upstream then
          callback(nil, errmsg)
          return
        end
        upstream = upstream:gsub("[\r\n]+$", "")
        local result = { upstream = upstream }
        local format = "--format=%H%x00%an%x00%ai%x00%s"
        local function read(direction, range, next_step)
          tools.run(self, directory, {
            "log",
            "--no-color",
            "-n",
            tostring(limit or 200),
            format,
            range,
            "--",
          }, function(output, err)
            if not output then
              callback(nil, err)
              return
            end
            result[direction] = tools.commits(output)
            next_step()
          end)
        end
        read("incoming", "HEAD.." .. upstream, function()
          read("outgoing", upstream .. "..HEAD", function()
            callback(result)
          end)
        end)
      end
    )
  end

  function Git:get_remote_ref_tip(directory, remote, name, kind, callback)
    if not tools.safe_ref(remote) or not tools.safe_ref(name) then
      callback(nil, "Invalid remote or reference.")
      return
    end
    if kind == "branch" then
      tools.run(
        self,
        directory,
        { "rev-parse", "--verify", "refs/remotes/" .. remote .. "/" .. name },
        function(output, errmsg)
          callback(output and output:match "^(%x+)", errmsg)
        end
      )
    elseif kind == "tag" then
      tools.run(
        self,
        directory,
        { "ls-remote", "--refs", remote, "refs/tags/" .. name },
        function(output, errmsg)
          callback(output and (output:match "^(%x+)" or ""), errmsg)
        end
      )
    else
      callback(nil, "Invalid reference kind.")
    end
  end

  function Git:push_ref(directory, remote, name, kind, options, callback)
    options = options or {}
    local target = options.target or name
    if
      not tools.safe_ref(remote)
      or not tools.safe_ref(name)
      or not tools.safe_ref(target)
      or kind ~= "branch" and kind ~= "tag"
    then
      callback(false, "Invalid remote or reference.")
      return
    end
    local prefix = kind == "tag" and "refs/tags/" or "refs/heads/"
    local args = { "push" }
    if options.upstream and kind == "branch" then
      args[#args + 1] = "--set-upstream"
    end
    local function push(expected)
      if options.lease then
        if
          type(expected) ~= "string"
          or expected ~= ""
            and (not expected:match "^%x+$" or #expected < 40 or #expected > 64)
        then
          callback(false, "Invalid expected remote tip.")
          return
        end
        args[#args + 1] = "--force-with-lease="
          .. prefix
          .. target
          .. ":"
          .. expected
      end
      args[#args + 1] = remote
      args[#args + 1] = options.delete and (":" .. prefix .. target)
        or prefix .. name .. ":" .. prefix .. target
      tools.run(self, directory, args, tools.status(callback))
    end
    if options.lease then
      if options.expected ~= nil then
        push(options.expected)
      else
        self:get_remote_ref_tip(
          directory,
          remote,
          target,
          kind,
          function(expected, errmsg)
            if expected == nil then
              callback(false, errmsg)
            else
              push(expected)
            end
          end
        )
      end
    else
      push ""
    end
  end

  function Git:merge_branch(source, target, directory, callback, strategy)
    if not tools.safe_ref(source) or not tools.safe_ref(target) then
      callback(false, "Invalid branch.")
      return
    end
    if
      strategy
      and strategy ~= "normal"
      and strategy ~= "ours"
      and strategy ~= "theirs"
      and strategy ~= "ff-only"
    then
      callback(false, "Unsupported merge strategy.")
      return
    end
    self:get_working_changes(directory, function(changes, errmsg)
      if not changes then
        callback(false, errmsg)
        return
      end
      if #changes > 0 then
        callback(false, "Commit or stash changes before merging.")
        return
      end
      self:checkout(target, directory, function(ok, err)
        if not ok then
          callback(false, err)
          return
        end
        local args = { "-c", "core.editor=true", "merge", "--no-edit" }
        if strategy == "ff-only" then
          args[#args + 1] = "--ff-only"
        elseif strategy == "ours" or strategy == "theirs" then
          args[#args + 1] = "-X"
          args[#args + 1] = strategy
        end
        args[#args + 1], args[#args + 2] = "--", source
        tools.run(self, directory, args, tools.status(callback))
      end)
    end)
  end

  function Git:get_conflict_versions(path, directory, callback)
    local relative, errmsg = tools.path(directory, path)
    if not relative then
      callback(nil, errmsg)
      return
    end
    local result, stages = {}, { "base", "ours", "theirs" }
    local function read(i)
      if i > 3 then
        callback(result)
        return
      end
      tools.run(
        self,
        directory,
        { "show", ":" .. i .. ":" .. relative },
        function(output, err)
          -- Missing stages are valid for add/add and modify/delete conflicts.
          if
            not output
            and not (err or ""):find("does not exist", 1, true)
            and not (err or ""):find("not at stage", 1, true)
          then
            callback(nil, err)
            return
          end
          result[stages[i]] = output or ""
          read(i + 1)
        end
      )
    end
    read(1)
  end

  function Git:get_review_diff(path, directory, callback, options)
    options = options or {}
    local args = {
      "diff", "--no-ext-diff", "--no-textconv", "--no-color",
      "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short",
    }
    if options.staged then
      args[#args + 1] = "--cached"
    end
    args[#args + 1] = "--unified=" .. tostring(options.context or 3)
    if options.whitespace then
      args[#args + 1] = "--ignore-all-space"
    end
    args[#args + 1] = "--"
    if path then
      local relative, err = tools.path(directory, path)
      if not relative then
        callback(nil, err)
        return
      end
      args[#args + 1] = relative
    end
    tools.run(self, directory, args, callback)
  end

  function Git:get_review_versions(path, directory, callback, staged)
    local relative, errmsg = tools.path(directory, path)
    if not relative then
      callback(nil, errmsg)
      return
    end
    tools.run(
      self,
      directory,
      { "show", (staged and "HEAD:" or ":") .. relative },
      function(before)
        if staged then
          tools.run(
            self,
            directory,
            { "show", ":" .. relative },
            function(after)
              callback({ before = before or "", after = after or "" })
            end
          )
        else
          local file = io.open(path, "rb")
          local after = file and file:read(16 * 1024 * 1024 + 1) or ""
          if file then
            file:close()
          end
          if #after > 16 * 1024 * 1024 then
            callback(nil, "Binary preview exceeds 16 MiB.")
            return
          end
          callback({ before = before or "", after = after })
        end
      end
    )
  end

  function Git:get_worktrees(directory, callback)
    tools.run(
      self,
      directory,
      { "worktree", "list", "--porcelain", "-z" },
      function(output, errmsg)
        local result, entry = {}, nil
        for field in (output or ""):gmatch "([^%z]+)%z" do
          local key, value = field:match "^(%S+)%s?(.*)$"
          if key == "worktree" then
            entry = { path = value, name = value }
            result[#result + 1] = entry
          elseif entry then
            entry[key] = value ~= "" and value or true
          end
        end
        callback(output and result, errmsg)
      end
    )
  end

  function Git:add_worktree(directory, path, branch, callback, new_branch)
    if
      not path
      or path == ""
      or path:find "%z"
      or not tools.safe_ref(branch)
      or new_branch and new_branch ~= "" and not tools.safe_ref(new_branch)
    then
      callback(false, "A directory and existing branch are required.")
      return
    end
    local args = { "worktree", "add" }
    if new_branch and new_branch ~= "" then
      args[#args + 1], args[#args + 2] = "-b", new_branch
    end
    args[#args + 1], args[#args + 2], args[#args + 3] = "--", path, branch
    tools.run(self, directory, args, tools.status(callback))
  end

  function Git:remove_worktree(directory, path, callback)
    -- No force: Git protects dirty, locked, and main worktrees.
    tools.run(
      self,
      directory,
      { "worktree", "remove", "--", path },
      tools.status(callback)
    )
  end

  function Git:get_submodules(directory, callback)
    tools.run(
      self,
      directory,
      { "submodule", "status", "--recursive" },
      function(output, errmsg)
        local result = {}
        -- Read configured paths independently; status text is not path-safe.
        if not output then
          callback(nil, errmsg)
          return
        end
        tools.run(self, directory, {
          "config",
          "-z",
          "--file",
          ".gitmodules",
          "--get-regexp",
          "^submodule\\..*\\.path$",
        }, function(paths)
          for record in (paths or ""):gmatch "([^%z]+)%z" do
            local path = record:match "\n(.*)$"
            if path then
              result[#result + 1] = {
                name = path,
                path = common.normalize_path(directory .. PATHSEP .. path),
                message = output,
              }
            end
          end
          callback(result)
        end)
      end
    )
  end

  function Git:update_submodule(directory, path, callback)
    local relative, err = tools.path(directory, path)
    if not relative then
      callback(false, err)
      return
    end
    tools.run(
      self,
      directory,
      { "submodule", "update", "--init", "--recursive", "--", relative },
      tools.status(callback)
    )
  end

  function Git:get_lfs_files(directory, callback)
    tools.run(
      self,
      directory,
      { "lfs", "ls-files", "--json" },
      function(output, errmsg)
        if not output then
          callback(nil, errmsg)
          return
        end
        local ok, decoded = pcall(json.decode, output)
        if not ok or type(decoded) ~= "table" then
          callback(nil, "Git LFS returned invalid JSON.")
          return
        end
        local result = {}
        for _, item in
          ipairs(type(decoded.files) == "table" and decoded.files or {})
        do
          result[#result + 1] = {
            name = item.name,
            path = directory .. PATHSEP .. item.name,
            commit = item.oid,
            message = tostring(item.size)
              .. " bytes / "
              .. (item.checkout and "Checked out" or "Pointer only"),
          }
        end
        callback(result)
      end
    )
  end

  function Git:fetch_lfs(directory, callback)
    tools.run(self, directory, { "lfs", "pull" }, tools.status(callback))
  end

  function Git:search_history(directory, query, callback, limit, target)
    if target and not tools.safe_ref(target) then
      callback(nil, "Invalid revision.")
      return
    end
    local args = {
      "log",
      "--no-color",
      "--fixed-strings",
      "-i",
      "-n",
      tostring(limit or 200),
      "--format=%H%x00%an%x00%ai%x00%s",
    }
    if query.author and query.author ~= "" then
      args[#args + 1] = "--author=" .. query.author
    end
    if query.message and query.message ~= "" then
      args[#args + 1] = "--grep=" .. query.message
    end
    if query.contents and query.contents ~= "" then
      args[#args + 1] = "-G" .. query.contents
    end
    args[#args + 1] = target or "--all"
    args[#args + 1] = "--"
    if query.path and query.path ~= "" then
      args[#args + 1] = ":(literal)" .. query.path
    end
    tools.run(self, directory, args, function(output, errmsg)
      callback(output and tools.commits(output), errmsg)
    end)
  end

  function Git:rewrite_history(directory, plan, callback)
    if #plan == 0 then
      callback(false, "The rewrite plan is empty.")
      return
    end
    self:get_working_changes(directory, function(changes, err)
      if not changes or #changes > 0 then
        callback(false, err or "Commit or stash all changes first.")
        return
      end
      tools.run(
        self,
        directory,
        { "rev-parse", "--abbrev-ref", "HEAD" },
        function(branch, branch_err)
          if not branch or branch:match "^HEAD[%s]*$" then
            callback(false, branch_err or "Check out a local branch first.")
            return
          end
          tools.run(
            self,
            directory,
            { "rev-list", "--first-parent", "--max-count=" .. #plan, "HEAD" },
            function(output, list_err)
              if not output then
                callback(false, list_err)
                return
              end
              local hashes, present, lines, picked = {}, {}, {}, false
              for hash in output:gmatch "%x+" do
                hashes[#hashes + 1] = hash
              end
              if #hashes ~= #plan then
                callback(false, "The rewrite range changed.")
                return
              end
              for _, item in ipairs(plan) do
                local valid = false
                for _, hash in ipairs(hashes) do
                  if hash == item.hash then
                    valid = true
                  end
                end
                if
                  not valid
                  or present[item.hash]
                  or not REWRITE_ACTIONS[item.action]
                  or item.action == "squash" and not picked
                then
                  callback(false, "Invalid rewrite plan.")
                  return
                end
                present[item.hash] = true
                picked = picked or item.action == "pick"
                lines[#lines + 1] = item.action .. " " .. item.hash
              end
              if not picked then
                callback(false, "Keep at least one commit.")
                return
              end
              local oldest = hashes[#hashes]
              tools.run(
                self,
                directory,
                { "rev-parse", oldest .. "^" },
                function(parent, parent_err)
                  if not parent then
                    callback(false, parent_err)
                    return
                  end
                  parent = parent:gsub("%s+$", "")
                  tools.run(
                    self,
                    directory,
                    { "rev-list", "--merges", parent .. "..HEAD" },
                    function(merges, merge_err)
                      if not merges or merges ~= "" then
                        callback(
                          false,
                          merge_err or "Merge commits cannot be rewritten here."
                        )
                        return
                      end
                      -- Reject any selected commit reachable from a remote ref.
                      local function check(i)
                        if i <= #hashes then
                          tools.run(self, directory, {
                            "for-each-ref",
                            "--format=%(refname)",
                            "--contains=" .. hashes[i],
                            "refs/remotes",
                          }, function(refs, refs_err)
                            if not refs or refs ~= "" then
                              callback(
                                false,
                                refs_err
                                  or "A selected commit is shared on a remote."
                              )
                            else
                              check(i + 1)
                            end
                          end)
                          return
                        end
                        local backup = "scm-backup/"
                          .. os.date "%Y%m%d-%H%M%S"
                          .. "-"
                          .. tostring(math.random(100000, 999999))
                        tools.run(
                          self,
                          directory,
                          { "branch", backup, "HEAD" },
                          function(created, create_err)
                            if not created then
                              callback(false, create_err)
                              return
                            end
                            self:with_commit_message_file(
                              table.concat(lines, "\n") .. "\n",
                              function(todo, cleanup, file_err)
                                if not todo then
                                  callback(false, file_err)
                                  return
                                end
                                local quote = function(s)
                                  return "'" .. s:gsub("'", "'\\''") .. "'"
                                end
                                local script = "#!/bin/sh\ncp "
                                  .. quote(todo)
                                  .. ' "$1"\n'
                                self:with_commit_message_file(
                                  script,
                                  function(editor, remove_editor, editor_err)
                                    if not editor then
                                      cleanup()
                                      callback(false, editor_err)
                                      return
                                    end
                                    tools.run(
                                      self,
                                      directory,
                                      { "rebase", "--interactive", parent },
                                      function(result, rebase_err)
                                        cleanup()
                                        remove_editor()
                                        callback(
                                          result ~= nil,
                                          rebase_err,
                                          backup
                                        )
                                      end,
                                      {
                                        GIT_SEQUENCE_EDITOR = "sh "
                                          .. quote(editor),
                                        GIT_EDITOR = "true",
                                      }
                                    )
                                  end
                                )
                              end
                            )
                          end
                        )
                      end
                      check(1)
                    end
                  )
                end
              )
            end
          )
        end
      )
    end)
  end
end
