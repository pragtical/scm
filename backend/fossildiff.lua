local json = require "core.json"
local review = require "plugins.scm.review"
local tools = require "plugins.scm.backend.tools"

local diff = {}

local function quote(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function path_quote(path)
  return '"' .. path:gsub('[%z\1-\31\127"\\]', function(char)
    return string.format("\\%03o", char:byte())
  end) .. '"'
end

local function file_filter(path, old_path, filter)
  if not filter or filter == "." then return "" end
  local prefix = filter:gsub("/$", "") .. "/"
  return " AND (" .. path .. "=" .. quote(filter)
    .. " OR " .. old_path .. "=" .. quote(filter)
    .. " OR substr(" .. path .. ",1," .. #prefix .. ")=" .. quote(prefix)
    .. " OR substr(" .. old_path .. ",1," .. #prefix .. ")=" .. quote(prefix)
    .. ")"
end

local function working_query(path)
  local old_mode = "CASE WHEN v.islink THEN '120000' "
    .. "WHEN v.isexe THEN '100755' ELSE '100644' END"
  local new_mode = old_mode
  if PLATFORM ~= "Windows" then
    -- Fossil classifies link transitions as 7/9, exec-only changes as 6/8.
    new_mode = "CASE v.chnged WHEN 6 THEN '100755' WHEN 7 THEN '120000' "
      .. "WHEN 8 THEN '100644' ELSE " .. old_mode .. " END"
  end
  return "SELECT v.pathname AS path,v.chnged,"
    .. "coalesce(v.origname,v.pathname) AS old_path,"
    .. old_mode .. " AS old_mode," .. new_mode .. " AS new_mode"
    .. " FROM localdb.vfile v"
    .. " WHERE v.rid>0 AND NOT v.deleted"
    .. " AND (v.chnged<>0 OR v.origname<>v.pathname)"
    .. file_filter("v.pathname", "v.origname", path)
    .. " ORDER BY path;"
end

local function query(backend, directory, sql, callback)
  tools.run(backend, directory, { "sql", "--readonly", "-json", sql },
    function(output, errmsg)
      if not output then callback(nil, errmsg) return end
      local ok, rows = pcall(json.decode, output == "" and "[]" or output)
      if not ok or type(rows) ~= "table" then
        callback(nil, "Could not read Fossil diff metadata: " .. output)
        return
      end
      callback(rows)
    end)
end

local function read_modes(backend, directory, entries, callback)
  local pending = {}
  if PLATFORM ~= "Windows" then
    for i, entry in ipairs(entries) do
      if (entry.chnged == 9 or entry.old_mode ~= "120000")
        and entry.chnged ~= 0 and entry.chnged ~= 6 and entry.chnged ~= 7
        and entry.chnged ~= 8
      then
        local path = directory .. PATHSEP .. entry.path
        -- Missing files have no current mode. Never ask fsdir to stat them.
        local info = system.get_file_info(path)
        if info and info.type == "file" then
          pending[#pending + 1] = entry
        end
      end
      if i % 100 == 0 then backend:yield() end
    end
  end
  local function read(first)
    if first > #pending then callback(entries) return end
    local values, paths, size, last = {}, {}, 0, first - 1
    for i = first, math.min(first + 63, #pending) do
      local entry = pending[i]
      local value = "(" .. quote(entry.path) .. ","
        .. quote(directory .. PATHSEP .. entry.path) .. ")"
      if size + #value > 32000 and i > first then break end
      values[#values + 1], paths[entry.path] = value, entry
      size, last = size + #value, i
    end
    query(backend, directory,
      "WITH paths(path,fullpath) AS (VALUES " .. table.concat(values, ",")
        .. ") SELECT p.path,d.mode FROM paths p JOIN fsdir(p.fullpath) d;",
      function(rows, errmsg)
        if not rows then callback(nil, errmsg) return end
        for _, row in ipairs(rows) do
          local entry = paths[row.path]
          if entry and math.floor(row.mode / 4096) % 16 ~= 10 then
            entry.new_mode = row.mode % 128 >= 64 and "100755" or "100644"
          end
        end
        backend:yield()
        read(last + 1)
      end)
  end
  read(1)
end

local function mode(column)
  return "CASE WHEN " .. column .. "='l' THEN '120000' WHEN "
    .. column .. "='x' THEN '100755' ELSE '100644' END"
end

local function revision_query(from, to)
  return "WITH old AS (SELECT filename," .. mode("perm")
    .. " AS mode FROM files_of_checkin(" .. quote(from) .. ")),"
    .. "new AS (SELECT filename," .. mode("perm")
    .. " AS mode FROM files_of_checkin(" .. quote(to) .. "))"
    .. " SELECT new.filename AS path,old.mode AS old_mode,"
    .. "new.mode AS new_mode FROM new LEFT JOIN old USING(filename)"
    .. " WHERE new.mode<>coalesce(old.mode,'100644')"
    .. " UNION ALL SELECT old.filename AS path,old.mode AS old_mode,"
    .. "NULL AS new_mode FROM old LEFT JOIN new USING(filename)"
    .. " WHERE new.filename IS NULL AND old.mode<>'100644' ORDER BY path;"
end

local function metadata_header(entry)
  local lines = {}
  if entry.old_path and entry.old_path ~= entry.path then
    lines[#lines + 1] = "rename from " .. path_quote(entry.old_path)
    lines[#lines + 1] = "rename to " .. path_quote(entry.path)
  end
  if entry.old_mode ~= entry.new_mode then
    if not entry.old_mode then
      lines[#lines + 1] = "new file mode " .. entry.new_mode
    elseif not entry.new_mode then
      lines[#lines + 1] = "deleted file mode " .. entry.old_mode
    else
      lines[#lines + 1] = "old mode " .. entry.old_mode
      lines[#lines + 1] = "new mode " .. entry.new_mode
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function read_native(backend, directory, args, path, callback)
  tools.run(backend, directory, args, function(text, errmsg)
    if text or not path then callback(text, errmsg) return end
    -- A tracked rename's old path no longer exists as a Fossil path argument.
    query(backend, directory,
      "SELECT pathname FROM localdb.vfile WHERE rid>0 AND NOT deleted"
        .. " AND origname=" .. quote(path) .. " AND pathname<>origname;",
      function(rows, query_error)
        if not rows or #rows ~= 1 then
          callback(nil, query_error or errmsg)
          return
        end
        local retry = { table.unpack(args) }
        retry[#retry] = rows[1].pathname
        tools.run(backend, directory, retry, callback)
      end)
  end)
end

---Merge metadata into native file entries, adding hunkless files when needed.
---@param text string
---@param entries table[]
---@param yield_fn? fun()
---@return string
function diff.enrich(text, entries, yield_fn)
  local useful = {}
  for i, entry in ipairs(entries) do
    if entry.old_mode ~= entry.new_mode
      or entry.old_path and entry.old_path ~= entry.path
    then
      useful[#useful + 1] = entry
    end
    if yield_fn and i % 100 == 0 then yield_fn() end
  end
  entries = useful
  if #entries == 0 then return text end
  if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
  local parsed, pending = review.diff(text, yield_fn), {}
  for i, entry in ipairs(entries) do
    pending[entry.path] = entry
    if yield_fn and i % 100 == 0 then yield_fn() end
  end
  local parts, cursor = {}, 1
  for i, file in ipairs(parsed.files) do
    local entry = pending[file.path]
    if entry then
      local position = file.hunks[1] and file.hunks[1].start or file.finish + 1
      parts[#parts + 1] = text:sub(cursor, position - 1)
      parts[#parts + 1] = metadata_header(entry)
      pending[entry.path], cursor = nil, position
    end
    if yield_fn and i % 100 == 0 then yield_fn() end
  end
  parts[#parts + 1] = text:sub(cursor)
  for i, entry in ipairs(entries) do
    if pending[entry.path] then
      parts[#parts + 1] = "diff --git "
        .. path_quote("a/" .. (entry.old_path or entry.path)) .. " "
        .. path_quote("b/" .. entry.path) .. "\n" .. metadata_header(entry)
    end
    if yield_fn and i % 100 == 0 then yield_fn() end
  end
  return table.concat(parts)
end

---Read native patches and their omitted Fossil metadata asynchronously.
---@param backend plugins.scm.backend.fossil
---@param directory string
---@param args string[]
---@param callback fun(text?:string, errmsg?:string)
---@param options? { historical?:boolean, path?:string, stash?:string }
function diff.read(backend, directory, args, callback, options)
  options = options or {}
  local path = options.path
  if path and PATHSEP == "\\" then path = path:gsub("\\", "/") end
  directory = system.absolute_path(directory) or directory
  read_native(backend, directory, args, path, function(text, errmsg)
    if not text then callback(nil, errmsg) return end
    local sql
    if options.historical then
      local header, body = text:match(
        "^(Fossil%-Diff%-From:[^\n]*\nFossil%-Diff%-To:[^\n]*\n%-+\n)(.*)$"
      )
      local from = header and header:match "Fossil%-Diff%-From:%s+(%x+)"
      local to = header and header:match "Fossil%-Diff%-To:%s+(%x+)"
      if not from or not to then
        callback(nil, "Could not determine Fossil comparison revisions.")
        return
      end
      text, sql = body, revision_query(from, to)
    elseif options.stash then
      local id = tonumber(options.stash)
      if not id or id < 1 or id ~= math.floor(id) then
        callback(nil, "Invalid Fossil stash ID.")
        return
      end
      sql = "SELECT newname AS path,origname AS old_path"
        .. " FROM localdb.stashfile WHERE stashid=" .. id
        .. " AND newname<>origname ORDER BY newname;"
    else
      sql = working_query(path)
    end
    query(backend, directory, sql, function(entries, query_error)
      if not entries then callback(nil, query_error) return end
      local function finish(metadata, mode_error)
        if not metadata then callback(nil, mode_error) return end
        callback(diff.enrich(text, metadata, function() backend:yield() end))
      end
      if options.historical or options.stash then finish(entries)
      else read_modes(backend, directory, entries, finish) end
    end)
  end)
end

return diff
