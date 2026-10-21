local core = require "core"
local command = require "core.command"
local actions = require "plugins.scm.ui.repositoryactions"

---Attach optional backend-aware remote and merge actions to a reference view.
return function(View, prefix, kind)
  local function predicate(capability)
    return function()
      local view = core.active_view
      return view:is(View)
        and not view.searching
        and view:get_selected_data()
        and view.backend.get_capabilities
        and view.backend:get_capabilities()[capability],
        view
    end
  end
  local push, delete = prefix .. ":push-remote", prefix .. ":delete-remote"
  command.add(predicate "remote_refs", {
    [push] = function(view)
      local entry = view:get_selected_data()
      if entry.remote_only then
        return
      end
      actions.remote(view.backend, view.project_dir, kind, false, function()
        view:refresh()
      end, entry.name)
    end,
    [delete] = function(view)
      local entry = view:get_selected_data()
      local name = entry.remote_only and entry.name:gsub("^[^/]+/", "")
        or entry.name
      actions.remote(view.backend, view.project_dir, kind, true, function()
        view:refresh()
      end, name)
    end,
  })
  View.menu:register(predicate "remote_refs", {
    { text = "Push " .. kind .. "...", command = push },
    { text = "Delete remote " .. kind .. "...", command = delete },
  })
  if kind == "branch" then
    local merge = prefix .. ":merge"
    command.add(predicate "merge", {
      [merge] = function(view)
        actions.merge(view.backend, view.project_dir, function()
          view:refresh()
        end, view:get_selected_data().name)
      end,
    })
    View.menu:register(predicate "merge", {
      { text = "Merge Branch...", command = merge },
    })
  end
end
