local common = require "core.common"
local style = require "core.style"

local statusmap = {}

---Build one complete treeview snapshot, reusing shared ancestor entries.
---@param changes plugins.scm.backend.filechange[]
---@param directory string
---@param yield_fn? fun()
---@return table<string,plugins.scm.filechange>
---@return integer conflicts
function statusmap.build(changes, directory, yield_fn)
  local result, directories, conflicts = {}, {}, 0
  local prefix = directory:gsub("[/\\]+$", "")
  local colors = {
    added = style.good,
    edited = style.warn,
    renamed = style.warn,
    deleted = style.error,
    untracked = style.dim,
  }
  local function parents(path, conflict)
    path = common.dirname(path)
    while
      path and (path == directory or common.path_belongs_to(path, prefix))
    do
      local previous = directories[path]
      if previous and (not conflict or previous.contains_conflict) then
        break
      end
      if not previous then
        previous = result[path] or { color = style.modified }
        directories[path], result[path] = previous, previous
      end
      if conflict then
        previous.color, previous.contains_conflict = style.error, true
      end
      local parent = common.dirname(path)
      if parent == path then
        break
      end
      path = parent
    end
  end
  for i, change in ipairs(changes) do
    local path = change.new_path or change.path
    if path and common.path_belongs_to(path, prefix) then
      if change.conflicted then
        conflicts = conflicts + 1
      end
      change.color = change.conflicted and style.error
        or colors[change.status]
        or style.modified
      if change.new_path then
        change.text = common.basename(change.path)
          .. " -> "
          .. common.basename(change.new_path)
        parents(change.path, change.conflicted)
      end
      local previous = directories[path]
      if previous then
        change.contains_conflict = previous.contains_conflict
        if previous.contains_conflict then
          change.color = style.error
        end
        directories[path] = change
      end
      result[path] = change
      parents(path, change.conflicted)
    end
    if yield_fn and i % 100 == 0 then
      yield_fn()
    end
  end
  return result, conflicts
end

return statusmap
