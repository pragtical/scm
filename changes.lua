---Provides functionality to parse a diff.
---@class plugins.scm.changes
local changes = {}

---@alias plugins.scm.changes.linestatus
---| "addition"
---| "deletion"
---| "modification"

---@class plugins.scm.changes.group
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match(
    "^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@"
  )
  if not old_start then return nil end
  old_start = tonumber(old_start) or 0
  new_start = tonumber(new_start) or 0
  old_count = old_count ~= "" and tonumber(old_count) or 1
  new_count = new_count ~= "" and tonumber(new_count) or 1
  return old_start, old_count, new_start, new_count
end

local function flush_group(group, on_group)
  if group.old_count > 0 or group.new_count > 0 then
    on_group(group)
  end
  group.old_start = 0
  group.old_count = 0
  group.new_start = 0
  group.new_count = 0
end

local function start_old_group(group, old_line, new_line)
  if group.old_count == 0 and group.new_count == 0 then
    group.old_start = old_line
    group.new_start = new_line
  elseif group.old_count == 0 then
    group.old_start = old_line
  end
end

local function start_new_group(group, old_line, new_line)
  if group.old_count == 0 and group.new_count == 0 then
    group.old_start = old_line
    group.new_start = new_line
  elseif group.new_count == 0 then
    group.new_start = new_line
  end
end

local function each_change_group(diff, on_group, yield_fn)
  local old_line, new_line
  local group = { old_start = 0, old_count = 0, new_start = 0, new_count = 0 }
  local iterations = 0

  for line in diff:gmatch("[^\n]+") do
    iterations = iterations + 1
    if yield_fn and iterations % 100 == 0 then
      yield_fn()
    end

    local hunk_old, _, hunk_new = parse_hunk_header(line)
    if hunk_old then
      flush_group(group, on_group)
      old_line = hunk_old
      new_line = hunk_new
    elseif old_line and new_line then
      local kind = line:sub(1, 1)
      if kind == "-" then
        start_old_group(group, old_line, new_line)
        group.old_count = group.old_count + 1
        old_line = old_line + 1
      elseif kind == "+" then
        start_new_group(group, old_line, new_line)
        group.new_count = group.new_count + 1
        new_line = new_line + 1
      elseif kind == " " then
        flush_group(group, on_group)
        old_line = old_line + 1
        new_line = new_line + 1
      elseif line:match("^\\ No newline at end of file") then
        -- ignore marker
      else
        flush_group(group, on_group)
        old_line = nil
        new_line = nil
      end
    end
  end

  flush_group(group, on_group)
end

---Diff additions, deletions and modifications parser for gutter rendering.
---@param diff string The diff string to parse in unified format
---@param yield_fn? fun()
---@return table<integer, plugins.scm.changes.linestatus> line_changes
function changes.parse(diff, yield_fn)
  local line_changes = {}
  each_change_group(diff, function(group)
    local modified = math.min(group.old_count, group.new_count)
    for i = 0, modified - 1 do
      line_changes[group.new_start + i] = "modification"
    end
    for i = modified, group.new_count - 1 do
      line_changes[group.new_start + i] = "addition"
    end
    if group.old_count > modified and group.new_count == 0 then
      line_changes[group.new_start] = "deletion"
    end
  end, yield_fn)
  return line_changes
end

---Calculate insert, delete and modified line counts from a unified diff.
---@param diff string The diff string to parse in unified format
---@param yield_fn? fun()
---@return plugins.scm.backend.stats
function changes.stats(diff, yield_fn)
  local stats = { inserts = 0, deletes = 0, modified = 0 }
  each_change_group(diff, function(group)
    local modified = math.min(group.old_count, group.new_count)
    stats.modified = stats.modified + modified
    stats.deletes = stats.deletes + group.old_count - modified
    stats.inserts = stats.inserts + group.new_count - modified
  end, yield_fn)
  return stats
end

return changes
