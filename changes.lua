---Provides functionality to parse a diff.
---@class plugins.scm.changes
local changes = {}

---Add a range to a hash table for easy lookup,
---then returns a zero range for easy resetting
---of the given `from` and `to` on call.
---@param t table<string,table<integer>>
---@param from integer
---@param to integer
---@return integer zero_from
---@return integer zero_to
local function add_range(t, from, to)
  t[tostring(from)..tostring(to)] = {from, to}
  return 0, 0
end

---@alias plugins.scm.changes.linestatus
---| "addition"
---| "deletion"
---| "modification"

---Diff additions, deletions and modifications parser.
---@param diff string The diff string to parse in unified format
---@return table<integer, plugins.scm.changes.linestatus> line_changes
function changes.parse(diff)
  local inserts, dranges, iranges, alines = {}, {}, {}, {}
  local rdstart, rdend, rastart, raend = 0, 0, 0 ,0
  local dstart, deletions, astart, acount, additions = 0, 0, 0, 0, 0
  for line in diff:gmatch("[^\n]+") do
    if (astart == 0 and dstart == 0) and line:match("^@@%s+") then
      dstart, deletions, astart, additions = line:match(
        "^@@%s+%-(%d+),(%d+)%s+%+(%d+),(%d+)%s+@@"
      )
      rdstart, rdend, rastart, raend = 0, 0, 0 ,0
      dstart = tonumber(dstart) or 0
      deletions = (tonumber(deletions) or 0) + dstart
      astart = tonumber(astart) or 0
      additions = (tonumber(additions) or 0) + astart
    elseif dstart > 0 or astart > 0 then
      local type = line:match("^([%+%-%s])")
      if type then
        if dstart > 0 and (type == "-" or type:match("%s")) then
          if type == "-" then
            if rdstart == 0 then
              rdstart = dstart + acount
              rdend = rdstart
            elseif rdend == dstart - 1 then
              rdend = rdend + 1
            end
            acount = acount - 1
          elseif rdstart ~= 0 then
            rdstart, rdend = add_range(dranges, rdstart, rdend)
          end
          dstart = dstart + 1
          if dstart >= deletions then dstart = 0 end
        end
        if astart > 0 and (type == "+" or type:match("%s")) then
          if type == "+" then
            if rastart == 0 then
              rastart = astart
              raend = rastart
            elseif raend == astart - 1 then
              raend = raend + 1
            end
            alines[astart] = true
            acount = acount + 1
          elseif rastart ~= 0 then
            rastart, raend = add_range(iranges, rastart, raend)
          end
          astart = astart + 1
          if astart >= additions then astart = 0 end
        end
        if astart == 0 and dstart == 0 then
          if rastart ~= 0 then
            add_range(iranges, rastart, raend)
          end
          if rdstart ~= 0 then
            add_range(dranges, rdstart, rdend)
          end
        end
      end
    end
  end

  -- detect modifications and keep only first deleted line
  for pos, range in pairs(dranges) do
    if iranges[pos] then
      iranges[pos] = nil
      for i=range[1], range[2] do
        inserts[i] = "modification"
      end
    else
      for i=range[1], range[2] do
        if alines[i] then -- a line is also added so store as modification
          inserts[i] = "modification"
        else -- otherwise we are only interested on first deletion
          inserts[i] = "deletion"
          break
        end
      end
    end
  end

  -- append the remaining addition ranges
  for _, range in pairs(iranges) do
    for i=range[1], range[2] do
      if not inserts[i] then
        inserts[i] = "addition"
      end
    end
  end

  return inserts
end

return changes
