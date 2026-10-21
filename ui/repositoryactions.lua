local core = require "core"
local common = require "core.common"
local FormDialog = require "plugins.scm.ui.formdialog"
local MessageBox = require "widget.messagebox"

local actions = {}

local function remote_form(backend, directory, entry, finished)
  local capabilities = backend:get_capabilities()
  local fields = entry and {}
    or {
      { id = "name", label = "Remote name", value = "origin", required = true },
    }
  fields[#fields + 1] = {
    id = "url",
    label = "Fetch URL",
    value = entry and entry.url or "",
    required = true,
  }
  if entry and capabilities.remote_push_url then
    fields[#fields + 1] = {
      id = "push",
      label = "Push URL (optional)",
      value = entry.push_explicit and entry.push_url or "",
      placeholder = "Use fetch URL",
      tooltip = "Empty restores fetch-URL fallback; edits the first URL.",
    }
  end
  local dialog = FormDialog(
    entry and ("SCM Edit Remote: " .. entry.name) or "SCM Add Remote",
    fields,
    function(values, done)
      local complete = function(ok, errmsg)
        done(ok, errmsg)
        if ok and finished then
          finished()
        end
      end
      if not entry then
        backend:add_remote(directory, values.name, values.url, complete)
        return
      end
      local function push_url(ok, errmsg)
        if not ok then
          complete(false, errmsg)
          return
        end
        if
          capabilities.remote_push_url
          and values.push ~= (entry.push_explicit and entry.push_url or "")
        then
          backend:set_remote_url(
            directory,
            entry.name,
            values.push,
            true,
            complete
          )
        else
          complete(true)
        end
      end
      if values.url ~= entry.url then
        backend:set_remote_url(
          directory,
          entry.name,
          values.url,
          false,
          push_url
        )
      else
        push_url(true)
      end
    end,
    entry and "Save" or "Add"
  )
  dialog:show()
  return dialog
end

function actions.edit_remote(backend, directory, entry, finished)
  return remote_form(backend, directory, entry, finished)
end

function actions.rename_remote(backend, directory, entry, finished)
  local dialog = FormDialog("SCM Rename Remote", {
    {
      id = "name",
      label = "Remote name",
      value = entry.name,
      required = true,
    },
  }, function(values, done)
    backend:rename_remote(
      directory,
      entry.name,
      values.name,
      function(ok, errmsg)
        done(ok, errmsg)
        if ok and finished then
          finished()
        end
      end
    )
  end, "Rename")
  dialog:show()
  return dialog
end

local function confirm(title, text, run, done)
  MessageBox.warning(title, text, function(_, id)
    if id == 1 then
      run()
    else
      done(false, "Cancelled.")
    end
  end, MessageBox.BUTTONS_YES_NO)
end

function actions.remote(backend, directory, kind, delete, finished, default)
  backend:get_remotes(directory, function(remotes, errmsg)
    if not remotes then
      MessageBox.error("SCM Remote", errmsg)
      return
    end
    if #remotes == 0 then
      MessageBox.error("SCM Remote", "No remotes are configured.")
      return
    end
    local function open(refs)
      local options = {}
      for _, remote in ipairs(remotes) do
        options[#options + 1] = { remote.name, remote.name }
      end
      local fields = {
        { id = "remote", label = "Remote", options = options, required = true },
        {
          id = "name",
          label = kind == "tag" and "Tag" or "Branch",
          value = default or "",
          required = true,
        },
      }
      if refs then
        fields[2].options = {}
        for _, ref in ipairs(refs) do
          if not ref.remote_only then
            fields[2].options[#fields[2].options + 1] = { ref.name, ref.name }
          end
        end
        if #fields[2].options == 0 then
          MessageBox.error("SCM Push", "No local " .. kind .. " is available.")
          return
        end
      end
      if not delete and kind == "branch" then
        fields[#fields + 1] = {
          id = "upstream",
          label = "Set upstream tracking",
          kind = "check",
          value = true,
        }
      end
      if not delete then
        fields[#fields + 1] =
          { id = "lease", label = "Force with lease", kind = "check" }
      end
      local title = "SCM " .. (delete and "Delete Remote " or "Push ") .. kind
      local dialog = FormDialog(title, fields, function(values, done)
        local run = function()
          backend:push_ref(directory, values.remote, values.name, kind, {
            upstream = values.upstream,
            lease = values.lease,
            delete = delete,
            expected = values.expected,
          }, function(ok, err)
            done(ok, err)
            if ok and finished then
              finished()
            end
          end)
        end
        local function ask()
          if delete or values.lease then
            local expected = values.expected ~= "" and values.expected
              or "absent"
            local suffix = values.expected and ("\nExpected tip: " .. expected)
              or ""
            confirm(
              title,
              (delete and "Delete " or "Rewrite ")
                .. values.remote
                .. "/"
                .. values.name
                .. "?"
                .. suffix,
              run,
              done
            )
          else
            run()
          end
        end
        if values.lease then
          backend:get_remote_ref_tip(
            directory,
            values.remote,
            values.name,
            kind,
            function(expected, err)
              if expected == nil then
                done(false, err)
                return
              end
              values.expected = expected
              ask()
            end
          )
        else
          ask()
        end
      end, delete and "Delete" or "Push")
      dialog:show()
    end
    if delete then
      open()
    else
      local load = kind == "tag" and backend.get_tags or backend.get_branches
      load(backend, directory, function(refs, err)
        if not refs then
          MessageBox.error("SCM Push", err or "Cannot load references.")
          return
        end
        open(refs)
      end)
    end
  end)
end

function actions.merge(backend, directory, finished, source)
  backend:get_branches(directory, function(branches)
    if not branches then
      return
    end
    backend:get_branch(directory, function(current)
      local options = {}
      for _, branch in ipairs(branches) do
        if not branch.remote_only then
          options[#options + 1] = { branch.name, branch.name }
        end
      end
      if #options == 0 then
        return
      end
      local strategies = backend:has_staging()
          and {
            { "Normal", "normal" },
            { "Fast-forward only", "ff-only" },
            { "Prefer target changes", "ours" },
            { "Prefer source changes", "theirs" },
          }
        or {
          { "Normal", "normal" },
          { "Integrate and close source", "integrate" },
        }
      FormDialog("SCM Merge Branch", {
        {
          id = "source",
          label = "Source branch",
          options = options,
          value = source,
        },
        {
          id = "target",
          label = "Target branch",
          options = options,
          value = current or "",
          required = true,
        },
        { id = "strategy", label = "Conflict strategy", options = strategies },
      }, function(values, done)
        if values.source == values.target then
          done(false, "Choose different source and target branches.")
          return
        end
        confirm(
          "SCM Merge Branch",
          "Merge '" .. values.source .. "' into '" .. values.target .. "'?",
          function()
            backend:merge_branch(
              values.source,
              values.target,
              directory,
              function(ok, errmsg)
                done(ok, errmsg)
                if finished then
                  finished(ok)
                end
                require("plugins.scm").open_workbench(directory)
              end,
              values.strategy
            )
          end,
          done
        )
      end, "Merge"):show()
    end)
  end)
end

function actions.stash(backend, directory, finished)
  local capabilities = backend:get_capabilities()
  local fields = {
    {
      id = "message",
      label = "Stash message",
      value = "Work in progress",
      required = true,
    },
  }
  if capabilities.stash_untracked then
    fields[#fields + 1] = {
      id = "untracked",
      label = "Include untracked files",
      kind = "check",
    }
  end
  FormDialog("SCM Stash", fields, function(values, done)
    backend:save_stash(directory, values.message, function(ok, errmsg)
      done(ok, errmsg)
      if ok and finished then
        finished()
      end
    end, { untracked = values.untracked })
  end, "Stash"):show()
end

function actions.apply_stash(backend, directory, entry, finished)
  local fields = {}
  if backend:get_capabilities().stash_index then
    fields[1] = {
      id = "index",
      label = "Restore staged changes as staged",
      kind = "check",
    }
  end
  FormDialog("SCM Apply " .. entry.name, fields, function(values, done)
    backend:apply_stash(entry.id, directory, function(ok, errmsg)
      done(ok, errmsg)
      if finished then
        finished(ok)
      end
    end, { index = values.index })
  end, "Apply"):show()
end

function actions.search(backend, directory, finished)
  local fields = {
    { id = "author", label = "Author" },
    { id = "message", label = "Commit message" },
    { id = "path", label = "Repository-relative path" },
    { id = "target", label = "Branch / tag (empty for repository)" },
  }
  if backend:get_capabilities().history_contents then
    fields[#fields + 1] =
      { id = "contents", label = "Changed text (regular expression)" }
  end
  FormDialog("SCM Search History", fields, function(values, done)
    backend:search_history(directory, values, function(history, errmsg)
      done(history ~= nil, errmsg)
      if history then
        finished(history)
      end
    end, 200, values.target ~= "" and values.target or nil)
  end, "Search"):show()
end

function actions.worktree(backend, directory, finished)
  backend:get_branches(directory, function(branches, errmsg)
    if not branches then
      MessageBox.error("SCM Add Worktree", errmsg or "Cannot load branches.")
      return
    end
    local options = {}
    for _, branch in ipairs(branches) do
      if not branch.remote_only then
        options[#options + 1] = { branch.name, branch.name }
      end
    end
    local dialog = FormDialog("SCM Add Worktree", {
      {
        id = "path",
        label = "New worktree directory",
        required = true,
        kind = "directory",
        value = common.dirname(directory) .. PATHSEP,
      },
      {
        id = "branch",
        label = "Existing branch / base branch",
        required = true,
        options = options,
      },
      {
        id = "name",
        label = "New branch (optional)",
        placeholder = "Use existing branch",
        tooltip = "Create a new branch from the selected base.",
      },
    }, function(values, done)
      local expanded = common.home_expand(values.path)
      local path = common.is_absolute_path(expanded) and expanded
        or common.normalize_path(directory .. PATHSEP .. expanded)
      backend:add_worktree(directory, path, values.branch, function(ok, errmsg)
        done(ok, errmsg)
        if ok and finished then
          finished()
        end
      end, values.name)
    end, "Add")
    dialog:show()
  end)
end

return actions
