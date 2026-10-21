local conflicts = {}

---Locate complete diff3/ordinary conflict blocks without interpreting content.
---@param lines string[]
---@return table[]
function conflicts.parse(lines)
  local result, block = {}, nil
  for i, line in ipairs(lines) do
    if line:match "^<<<<<<<" then
      block = { first = i, ours = {}, base = {}, theirs = {}, side = "ours" }
    elseif block and line:match "^|||||||" then
      block.side, block.has_base = "base", true
    elseif block and line:match "^=======%s*$" then
      block.side = "theirs"
    elseif block and line:match "^>>>>>>>" then
      block.last = i
      result[#result + 1] = block
      block = nil
    elseif block then
      local side = block[block.side]
      side[#side + 1] = line
    end
  end
  return result
end

function conflicts.has_markers(lines)
  for _, line in ipairs(lines) do
    if
      line:match "^<<<<<<<"
      or line:match "^>>>>>>>"
      or line:match "^|||||||"
    then
      return true
    end
  end
  return false
end

function conflicts.text(block, choice)
  if choice == "both" then
    return table.concat(block.ours) .. table.concat(block.theirs)
  end
  return table.concat(block[choice] or {})
end

return conflicts
