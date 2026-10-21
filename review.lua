---Pure data helpers for repository review and partial staging.
local review = {}

---Sort a copy; retain backend snapshot order and stable path tie-breaking.
function review.sort_changes(entries, order, modified, yield_fn)
  local sorted, times = {}, {}
  for i, entry in ipairs(entries) do
    sorted[i] = entry
    if order == "modified" then
      times[entry] = modified(entry.new_path or entry.path)
    end
    if yield_fn and i % 100 == 0 then
      yield_fn()
    end
  end
  table.sort(sorted, function(a, b)
    if order == "modified" and times[a] ~= times[b] then
      return times[a] > times[b]
    elseif order == "status" and a.status ~= b.status then
      return a.status < b.status
    end
    return (a.new_path or a.path) < (b.new_path or b.path)
  end)
  return sorted
end

---Compact non-cryptographic identity for session-local review marks.
---@param text string
---@param yield_fn? fun()
---@return string
function review.diff_fingerprint(text, yield_fn)
  local a, b = 1, 0
  for first = 1, #text, 4096 do
    for i = first, math.min(first + 4095, #text) do
      a = (a + text:byte(i)) % 65521
      b = (b + a) % 65521
    end
    if yield_fn and first % 65536 == 1 then
      yield_fn()
    end
  end
  return tostring(#text) .. ":" .. tostring(b * 65536 + a)
end
local SNAPSHOT_FIELDS = {
  "path",
  "new_path",
  "status",
  "staged",
  "unstaged",
  "conflicted",
  "hash",
  "commit",
  "name",
  "date",
  "message",
  "summary",
  "refs",
  "remote",
}

---Parse Git's machine-readable blame format, including complete commit hashes.
---@param output string
---@param yield_fn? fun()
---@return table[]
function review.git_blame(output, yield_fn)
  local list, commits, record, target, count = {}, {}, nil, nil, 0
  for line in (output .. "\n"):gmatch "([^\n]*)\n" do
    count = count + 1
    if yield_fn and count % 100 == 0 then
      yield_fn()
    end
    local hash, final = line:match "^(%x+) %d+ (%d+)"
    if hash then
      commits[hash] = commits[hash] or { commit = hash }
      record, target = commits[hash], tonumber(final)
    elseif record and line:sub(1, 1) == "\t" then
      local timestamp = tonumber(record.timestamp)
      local zone = record.zone or ""
      local sign, hours, minutes = zone:match "^([+-])(%d%d)(%d%d)$"
      local offset = hours and (tonumber(hours) * 3600 + tonumber(minutes) * 60)
        or 0
      if sign == "-" then
        offset = -offset
      end
      list[target] = {
        commit = record.commit,
        author = record.author or "",
        date = timestamp and os.date("!%Y-%m-%d", timestamp + offset) or "",
        summary = record.summary,
      }
      record, target = nil, nil
    elseif record then
      local key, value = line:match "^(%S+) (.*)$"
      if key == "author" then
        record.author = value
      elseif key == "author-time" then
        record.timestamp = value
      elseif key == "author-tz" then
        record.zone = value
      elseif key == "summary" then
        record.summary = value
      end
    end
  end
  return list
end

---Stable snapshot identity for avoiding watcher-driven list rebuilds.
---@param entries table[]
---@return string
function review.snapshot_key(entries, yield_fn)
  local parts = {}
  for i, entry in ipairs(entries) do
    if yield_fn and i % 100 == 0 then
      yield_fn()
    end
    for _, key in ipairs(SNAPSHOT_FIELDS) do
      local value = tostring(entry[key])
      parts[#parts + 1] = #value .. ":" .. value
    end
  end
  return table.concat(parts)
end

---Parse Git porcelain v1 -z, preserving spaces, tabs, and renames.
---@param output string
---@param directory string
---@return table[]
function review.git_status(output, directory, yield_fn)
  local common = require "core.common"
  local records = {}
  for record in output:gmatch "([^%z]+)%z" do
    records[#records + 1] = record
    if yield_fn and #records % 100 == 0 then
      yield_fn()
    end
  end
  local statuses = {
    A = "added",
    M = "edited",
    D = "deleted",
    R = "renamed",
    C = "added",
    T = "edited",
  }
  local result, i = {}, 1
  while records[i] do
    local record = records[i]
    local x, y, name = record:sub(1, 1), record:sub(2, 2), record:sub(4)
    local conflict = x == "U" or y == "U" or x .. y == "AA" or x .. y == "DD"
    local entry = {
      path = common.normalize_path(directory .. PATHSEP .. name),
      status = x == "?" and "untracked"
        or statuses[y]
        or statuses[x]
        or "edited",
      staged = x ~= " " and x ~= "?" and not conflict,
      unstaged = y ~= " " or x == "?" or conflict,
      conflicted = conflict,
    }
    if x == "R" or x == "C" or y == "R" or y == "C" then
      i = i + 1
      if records[i] then
        entry.new_path = entry.path
        entry.path = common.normalize_path(directory .. PATHSEP .. records[i])
      end
    end
    result[#result + 1] = entry
    if yield_fn and #result % 100 == 0 then
      yield_fn()
    end
    i = i + 1
  end
  return result
end

---Decode Git's C-quoted paths without evaluating repository names as code.
function review.diff_path(path, strip_prefix)
  local tab = path:find("\t", 1, true)
  if tab then
    path = path:sub(1, tab - 1)
  end
  if path:byte(1) == 34 and path:byte(-1) == 34 then
    local escapes = {
      a = "\a",
      b = "\b",
      t = "\t",
      n = "\n",
      v = "\v",
      f = "\f",
      r = "\r",
      ['"'] = '"',
      ["\\"] = "\\",
    }
    local decoded, i = {}, 2
    while i < #path do
      local char = path:sub(i, i)
      if char == "\\" then
        local octal = path:sub(i + 1):match "^([0-7][0-7]?[0-7]?)"
        if octal then
          char, i = string.char(tonumber(octal, 8) % 256), i + #octal
        else
          i = i + 1
          char = escapes[path:sub(i, i)] or path:sub(i, i)
        end
      end
      decoded[#decoded + 1], i = char, i + 1
    end
    path = table.concat(decoded)
  end
  if path == "/dev/null" then
    return nil
  end
  if
    strip_prefix
    and path:byte(2) == 47
    and (path:byte(1) == 97 or path:byte(1) == 98)
  then
    return path:sub(3)
  end
  return path
end

local function finish_diff_file(file, finish)
  file.finish = finish
  if not file.git then
    return
  end
  local header = file.header[1] or ""
  local old_path, new_path = header:match '^diff %-%-git (".-") (".-")$'
  if not old_path then
    old_path, new_path = header:match "^diff %-%-git (a/.-) (b/.*)$"
  end
  if new_path then
    if file.status ~= "added" then
      file.old_path = file.old_path or review.diff_path(old_path, true)
    end
    file.path = file.path or review.diff_path(new_path, true)
  end
end

local fossil_diff_status = {
  ADDED = "added", ADDED_BY_MERGE = "added", ADDED_BY_INTEGRATE = "added",
  DELETED = "deleted", MISSING = "deleted", CHANGED = "edited",
}

---Parse unified diffs into files, hunks, and numbered display rows.
---@param text string
---@param yield_fn? fun()
---@return table
function review.diff(text, yield_fn)
  if text ~= "" and text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local result = { files = {}, rows = {}, inserts = 0, deletes = 0 }
  local file, hunk, old, new, old_left, new_left
  local iterations, offset = 0, 1
  local function begin_file(git, path)
    if file then
      finish_diff_file(file, offset - 1)
    end
    file = {
      header = {}, hunks = {}, partial = git, git = git,
      path = path, start = offset, inserts = 0, deletes = 0,
      status = "edited",
    }
    result.files[#result.files + 1] = file
    hunk, old, new = nil, nil, nil
  end
  for line in text:gmatch "([^\n]*)\n" do
    iterations = iterations + 1
    if yield_fn and iterations % 100 == 0 then
      yield_fn()
    end
    local kind, path = line:match "^([A-Z_]+)%s+(.+)$"
    local status = fossil_diff_status[kind]
    local index_path = line:match "^Index: (.*)$"
    if status then
      begin_file(false, path)
      file.status = status
      file.summary = true
    elseif line:match "^diff %-%-git " then
      begin_file(true)
    elseif index_path then
      -- Fossil prefixes added/deleted files with a status, then an Index.
      if not (file and file.summary and file.path == index_path) then
        begin_file(false, index_path)
      end
      file.summary = nil
    end
    if hunk and old_left == 0 and new_left == 0
      and line:sub(1, 1) ~= "\\"
    then
      hunk = nil
    end
    if line:match "^%-%-%- " and (not file or not hunk and file.new_header)
    then
      begin_file(false)
    end
    local a, ac, b, bc =
      line:match "^@@ %-(%d+)(,?%d*) %+(%d+)(,?%d*) @@"
    if a then
      if not file then
        begin_file(false)
      end
      hunk = { lines = { line }, file = file, start = offset }
      file.hunks[#file.hunks + 1] = hunk
      old, new = tonumber(a), tonumber(b)
      old_left = ac == "" and 1 or tonumber(ac:sub(2))
      new_left = bc == "" and 1 or tonumber(bc:sub(2))
      result.rows[#result.rows + 1] =
        { kind = "hunk", text = line, hunk = hunk, file = file }
    elseif hunk and line:match "^[ +%-\\]" then
      hunk.lines[#hunk.lines + 1] = line
      local prefix = line:sub(1, 1)
      local row = {
        text = line:sub(2), hunk = hunk, hunk_line = #hunk.lines, file = file,
      }
      if prefix == "+" then
        row.kind, row.new = "insert", new
        new, result.inserts = new + 1, result.inserts + 1
        file.inserts = file.inserts + 1
        new_left = new_left - 1
      elseif prefix == "-" then
        row.kind, row.old = "delete", old
        old, result.deletes = old + 1, result.deletes + 1
        file.deletes = file.deletes + 1
        old_left = old_left - 1
      elseif prefix == " " then
        row.kind, row.old, row.new = "context", old, new
        old, new = old + 1, new + 1
        old_left, new_left = old_left - 1, new_left - 1
      else
        row.kind, row.text = "meta", line
      end
      result.rows[#result.rows + 1] = row
    else
      hunk = nil
      local detail = status ~= nil
      if file then
        file.header[#file.header + 1] = line
        if line:match "^%+%+%+ " then
          file.new_header = true
          file.path = review.diff_path(line:sub(5), file.git) or file.old_path
          if line:sub(5):match "^/dev/null" then
            file.status = "deleted"
          end
        elseif line:match "^%-%-%- " then
          file.old_path = review.diff_path(line:sub(5), file.git)
          if line:sub(5):match "^/dev/null" then
            file.status = "added"
          end
        elseif line:match "^rename to " then
          file.path = review.diff_path(line:sub(11))
        elseif line:match "^rename from " then
          file.old_path = review.diff_path(line:sub(13))
        elseif line:match "^copy to " then
          file.path = review.diff_path(line:sub(9))
        elseif line:match "^copy from " then
          file.old_path = review.diff_path(line:sub(11))
        end
        if line:match "^Binary files " or line:match "^GIT binary patch"
          or line:match "^cannot compute difference between binary files"
        then
          file.binary, file.partial = true, false
        end
        if line:match "^new file mode " then
          file.status, detail = "added", true
        elseif line:match "^deleted file mode " then
          file.status, detail = "deleted", true
        elseif line:match "^rename " then
          file.status, detail = "renamed", true
        elseif line:match "^copy " then
          file.status, detail = "copied", true
        elseif line:match "^old mode " or line:match "^new mode " then
          file.old_mode = line:match "^old mode (%d+)" or file.old_mode
          file.new_mode = line:match "^new mode (%d+)" or file.new_mode
          detail = true
          if file.status == "edited" or file.status == "mode_changed" then
            file.status = file.old_mode and file.new_mode
                and file.old_mode:sub(1, 3) ~= file.new_mode:sub(1, 3)
                and "type_changed" or "mode_changed"
          end
        end
        local mode = line:match "^index .+ (%d+)$"
        if detail or mode == "160000" or mode == "120000" then
          file.partial = false
        end
      end
      result.rows[#result.rows + 1] = {
        kind = "meta", text = line, file = file, detail = detail,
      }
    end
    offset = offset + #line + 1
  end
  if file then
    finish_diff_file(file, #text)
  end
  return result
end

---Extract one whole hunk for git apply --cached; never include sibling hunks.
---@param hunk table?
---@return string? patch
function review.hunk_patch(hunk, selection, reverse)
  if not hunk or not hunk.file.partial then
    return nil
  end
  local header = table.concat(hunk.file.header, "\n")
  if
    not header:find("\n--- ", 1, true) or not header:find("\n+++ ", 1, true)
  then
    return nil
  end
  if not selection then
    return header .. "\n" .. table.concat(hunk.lines, "\n") .. "\n"
  end
  local a, b =
    math.min(selection[1], selection[2]), math.max(selection[1], selection[2])
  local lines, old_count, new_count, changed, kept = {}, 0, 0, false, false
  for i = 2, #hunk.lines do
    local line, prefix = hunk.lines[i], hunk.lines[i]:sub(1, 1)
    local selected = i >= a and i <= b
    if prefix == " " or prefix == "\\" and kept then
      lines[#lines + 1], kept = line, true
      if prefix == " " then
        old_count, new_count = old_count + 1, new_count + 1
      end
    elseif prefix == "+" or prefix == "-" then
      if selected then
        lines[#lines + 1], changed, kept = line, true, true
        if prefix == "+" then
          new_count = new_count + 1
        else
          old_count = old_count + 1
        end
      elseif (not reverse and prefix == "-") or (reverse and prefix == "+") then
        lines[#lines + 1], kept = " " .. line:sub(2), true
        old_count, new_count = old_count + 1, new_count + 1
      else
        kept = false
      end
    end
  end
  if not changed then
    return nil
  end
  local old_start, new_start = hunk.lines[1]:match "^@@ %-(%d+),?%d* %+(%d+)"
  local start = tonumber(reverse and new_start or old_start)
  local old_pos = old_count == 0 and math.max(0, start - 1) or start
  local new_pos = new_count == 0 and math.max(0, start - 1) or start
  return header
    .. string.format(
      "\n@@ -%d,%d +%d,%d @@\n",
      old_pos,
      old_count,
      new_pos,
      new_count
    )
    .. table.concat(lines, "\n")
    .. "\n"
end

---Align adjacent deletion/addition groups for a side-by-side diff.
---@param rows table[]
---@return table[]
function review.side_by_side(rows, yield_fn)
  local result, i = {}, 1
  while rows[i] do
    if yield_fn and i % 100 == 0 then
      yield_fn()
    end
    local row = rows[i]
    if row.kind == "delete" or row.kind == "insert" then
      local left, right = {}, {}
      while
        rows[i] and (rows[i].kind == "delete" or rows[i].kind == "insert")
      do
        local group = rows[i].kind == "delete" and left or right
        group[#group + 1] = rows[i]
        i = i + 1
        if yield_fn and i % 100 == 0 then
          yield_fn()
        end
      end
      for n = 1, math.max(#left, #right) do
        if yield_fn and n % 100 == 0 then
          yield_fn()
        end
        if left[n] and right[n] then
          local a, b = left[n].text, right[n].text
          local prefix, suffix = 0, 0
          while
            prefix < math.min(#a, #b)
            and a:byte(prefix + 1) == b:byte(prefix + 1)
          do
            prefix = prefix + 1
          end
          while
            prefix > 0
            and (a:byte(prefix + 1) or 0) >= 128
            and (a:byte(prefix + 1) or 0) < 192
          do
            prefix = prefix - 1
          end
          while
            suffix < math.min(#a, #b) - prefix
            and a:byte(#a - suffix) == b:byte(#b - suffix)
          do
            suffix = suffix + 1
          end
          while
            suffix > 0
            and (a:byte(#a - suffix + 1) or 0) >= 128
            and (a:byte(#a - suffix + 1) or 0) < 192
          do
            suffix = suffix - 1
          end
          left[n].change_start, left[n].change_end = prefix + 1, #a - suffix
          right[n].change_start, right[n].change_end = prefix + 1, #b - suffix
        end
        result[#result + 1] =
          { left = left[n], right = right[n], hunk = row.hunk }
      end
    else
      result[#result + 1] = { left = row, right = row, hunk = row.hunk }
      i = i + 1
    end
  end
  return result
end

---Match plain terms and author:/message:/hash:/ref:/path:/status: qualifiers.
---Quoted terms are supported; a leading minus excludes a term.
---@param query string
---@return fun(fields:table<string,string>):boolean
function review.compile_query(query)
  local terms, current, quoted = {}, "", false
  for char in (query .. " "):gmatch "." do
    if char == '"' then
      quoted = not quoted
    elseif char:match "%s" and not quoted then
      if current ~= "" then
        terms[#terms + 1], current = current, ""
      end
    else
      current = current .. char
    end
  end
  if current ~= "" then
    terms[#terms + 1] = current
  end
  local compiled = {}
  for _, term in ipairs(terms) do
    local exclude = term:sub(1, 1) == "-"
    if exclude then
      term = term:sub(2)
    end
    local key, value = term:match "^(%a+):(.*)$"
    compiled[#compiled + 1] =
      { key = key, value = (value or term):lower(), exclude = exclude }
  end
  return function(fields)
    local all
    for _, term in ipairs(compiled) do
      if not term.key and not all then
        local values = {}
        for _, value in pairs(fields) do
          values[#values + 1] = tostring(value)
        end
        all = table.concat(values, " "):lower()
      end
      local haystack = term.key and tostring(fields[term.key] or ""):lower()
        or all
      local found = haystack:find(term.value, 1, true) ~= nil
      if found == term.exclude then
        return false
      end
    end
    return true
  end
end

function review.matches(query, fields)
  return review.compile_query(query)(fields)
end

---Build commit graph lanes from topologically ordered Git parent hashes.
---@param history table[]
---@return table[] graphs
function review.graph(history)
  local lanes, graphs = {}, {}
  local function find(hash)
    for i, value in ipairs(lanes) do
      if value == hash then
        return i
      end
    end
  end
  for _, commit in ipairs(history) do
    local lane = find(commit.hash)
    local incoming = lane ~= nil
    if not lane then
      lanes[#lanes + 1], lane = commit.hash, #lanes + 1
    end
    local before = {}
    for i, hash in ipairs(lanes) do
      before[i] = hash
    end
    table.remove(lanes, lane)
    local parents = {}
    for hash in (commit.parents or ""):gmatch "%S+" do
      parents[#parents + 1] = hash
    end
    for i, hash in ipairs(parents) do
      if not find(hash) then
        table.insert(
          lanes,
          i == 1 and math.min(lane, #lanes + 1) or #lanes + 1,
          hash
        )
      end
    end
    local graph = {
      lane = lane,
      incoming = incoming,
      edges = {},
      parents = {},
      width = math.max(#before, #lanes, 1),
    }
    for i, hash in ipairs(before) do
      if i ~= lane then
        graph.edges[#graph.edges + 1] = { i, find(hash) }
      end
    end
    for _, hash in ipairs(parents) do
      graph.parents[#graph.parents + 1] = find(hash)
    end
    graphs[#graphs + 1] = graph
  end
  return graphs
end

return review
