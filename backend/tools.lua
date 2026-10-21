local common = require "core.common"

local tools = {}

---Reject existing checkouts, their children, and bare Git repositories.
---@param directory string
---@param backends? table<string,plugins.scm.backend>
---@return boolean
---@return string? errmsg
function tools.can_initialize(directory, backends)
  local info = directory and system.get_file_info(directory)
  if not info or info.type ~= "dir" then
    return false, "Choose an existing directory."
  end
  local path = system.absolute_path(directory)
  if not path then
    return false, "Could not resolve the directory."
  end
  while path do
    for _, marker in ipairs({ ".git", ".fslckout", "_FOSSIL_" }) do
      if system.get_file_info(path .. PATHSEP .. marker) then
        return false, "This directory already belongs to a repository."
      end
    end
    local head = system.get_file_info(path .. PATHSEP .. "HEAD")
    local objects = system.get_file_info(path .. PATHSEP .. "objects")
    local refs = system.get_file_info(path .. PATHSEP .. "refs")
    if head and head.type == "file"
      and objects and objects.type == "dir"
      and refs and refs.type == "dir"
    then
      return false, "This directory already belongs to a repository."
    end
    for _, backend in pairs(backends or {}) do
      if backend:detect(path) then
        return false, "This directory already belongs to a repository."
      end
    end
    local parent = common.dirname(path)
    if parent == path then break end
    path = parent
  end
  return true
end

---Run a backend command, drain both streams, and report errors consistently.
---@param self plugins.scm.backend
---@param directory string
---@param args string[]
---@param callback fun(output?:string, errmsg?:string)
---@param env? table<string,string>
function tools.run(self, directory, args, callback, env)
  if not self.command then
    callback(nil, self.name .. " executable is unavailable.")
    return
  end
  local execute, options = self.execute, directory
  if env then
    execute = self.execute_with_options
    options = common.merge(self:get_process_options(directory))
    options.env = common.merge(options.env, env)
  end
  execute(self, function(proc, start_error)
    local stdout = self:get_process_output(proc, "stdout")
    local stderr = self:get_process_output(proc, "stderr")
    if proc and proc:returncode() == 0 then
      callback(stdout)
    else
      callback(
        nil,
        stderr ~= "" and stderr
          or stdout ~= "" and stdout
          or start_error
          or "Command failed."
      )
    end
  end, options, table.unpack(args))
end

function tools.status(callback)
  return function(output, errmsg)
    callback(output ~= nil, errmsg)
  end
end

function tools.safe_ref(ref)
  return type(ref) == "string"
    and ref ~= ""
    and ref:sub(1, 1) ~= "-"
    and not ref:find "[%z\r\n]"
end

---Split a full commit message without losing body paragraphs or indentation.
---@param text string
---@return string subject
---@return string? body
function tools.split_message(text)
  text = text:gsub("\r\n", "\n")
  local subject, body = text:match("^([^\n]*)\n?(.*)$")
  body = body:gsub("^\n+", ""):gsub("\n+$", "")
  return subject, body ~= "" and body or nil
end

function tools.path(directory, path)
  local absolute = common.normalize_path(path)
  if not common.path_belongs_to(absolute, directory) then
    return nil, "Path is outside this repository."
  end
  return common.relative_path(directory, absolute)
end

function tools.commits(output)
  local result = {}
  for line in (output or ""):gmatch "[^\r\n]+" do
    local hash, author, date, summary = line:match "^(.-)%z(.-)%z(.-)%z(.*)$"
    if hash then
      result[#result + 1] = {
        hash = hash,
        author = author,
        date = date,
        summary = summary,
      }
    end
  end
  return result
end

return tools
