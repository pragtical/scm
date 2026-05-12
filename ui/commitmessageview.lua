local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Highlighter = require "core.doc.highlighter"
local MessageBox = require "widget.messagebox"

local TITLE_LIMIT = 50
local BODY_LIMIT = 72
local COMMENT_CHAR = "#"
local ERROR_TOKEN = "scm.error"

local function update_syntax_styles()
  style.syntax[ERROR_TOKEN] = style.error
end

local function rtrim(value)
  return (value:gsub("%s+$", ""))
end

local function strip_newline(value)
  return (value:gsub("\n$", ""))
end

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function build_comment_line(line)
  if line == "" then return COMMENT_CHAR end
  return COMMENT_CHAR .. " " .. line
end

local function build_initial_text(status, message)
  local lines = split_lines(message or "")
  if #lines == 0 then
    table.insert(lines, "")
  end
  if lines[#lines] ~= "" then
    table.insert(lines, "")
  end
  table.insert(lines, "")
  local comments = {
    build_comment_line("Please enter the commit message for your changes."),
    build_comment_line("Lines starting with '#' will be ignored."),
    build_comment_line("An empty message aborts the commit."),
    COMMENT_CHAR
  }
  for _, line in ipairs(comments) do
    table.insert(lines, line)
  end

  if status and status ~= "" then
    for _, line in ipairs(split_lines(status)) do
      table.insert(lines, build_comment_line(line))
    end
  end

  return table.concat(lines, "\n") .. "\n"
end

local function is_comment(line)
  return strip_newline(line):match("^%s*" .. COMMENT_CHAR) ~= nil
end

local function split_comment(line)
  local hash_start = line:find(COMMENT_CHAR, 1, true)
  if not hash_start then return nil end
  local marker_end = hash_start
  if line:sub(marker_end + 1, marker_end + 1) == " " then
    marker_end = marker_end + 1
  end
  return line:sub(1, marker_end), line:sub(marker_end + 1)
end

local function split_indented_status(body)
  local indent_end = 0
  for i = 1, #body do
    local char = body:sub(i, i)
    if char ~= " " and char ~= "\t" then
      break
    end
    indent_end = i
  end
  if indent_end == 0 then return nil end

  local colon = body:find(":", indent_end + 1, true)
  if not colon then return nil end
  return body:sub(1, indent_end), body:sub(indent_end + 1, colon), body:sub(colon + 1)
end

local function wrap_text_line(text, limit)
  local line = strip_newline(text)
  if #line <= limit or line:match("^%s*$") then return nil end

  local indent = line:match("^(%s*)") or ""
  local wrapped = {}
  local rest = line
  local first_break_at
  local first_trimmed_spaces
  while #rest > limit do
    local break_at
    for i = math.min(#rest, limit), #indent + 1, -1 do
      if rest:sub(i, i):match("%s") then
        break_at = i
        break
      end
    end
    if not break_at then return nil end
    first_break_at = first_break_at or break_at
    table.insert(wrapped, rtrim(rest:sub(1, break_at - 1)))
    local next_rest = rest:sub(break_at + 1)
    local spaces, trimmed = next_rest:match("^(%s*)(.*)$")
    if first_trimmed_spaces == nil then
      first_trimmed_spaces = #spaces
    end
    rest = indent .. (trimmed or "")
  end
  table.insert(wrapped, rest)
  return table.concat(wrapped, "\n"), first_break_at, first_trimmed_spaces or 0
end

--------------------------------------------------------------------------------
-- Commit Message Highlighter
--------------------------------------------------------------------------------

---@class plugins.scm.ui.commitmessagehighlighter : core.doc.highlighter
local CommitMessageHighlighter = Highlighter:extend()

function CommitMessageHighlighter:tokenize_line(idx)
  update_syntax_styles()
  local text = self.doc:get_utf8_line(idx)
  local line = strip_newline(text)
  local tokens = {}

  if is_comment(text) then
    local marker, body = split_comment(line)
    local indent, status, rest = split_indented_status(body or "")
    if marker and indent and status then
      tokens = {
        "comment", marker .. indent,
        "keyword", status,
        "literal", rest .. (text:sub(-1) == "\n" and "\n" or "")
      }
    elseif marker and body and body:match("^[^%s].*:$") then
      tokens = {
        "comment", marker,
        "function", body .. (text:sub(-1) == "\n" and "\n" or "")
      }
    else
      tokens = { "comment", text }
    end
  else
    local limit = idx == 1 and TITLE_LIMIT or BODY_LIMIT
    local base_token = idx == 1 and "string" or "normal"
    if #line > limit then
      tokens = {
        base_token, line:sub(1, limit),
        ERROR_TOKEN, line:sub(limit + 1) .. (text:sub(-1) == "\n" and "\n" or "")
      }
    else
      tokens = { base_token, text }
    end
  end

  return {
    init_state = nil,
    state = nil,
    text = text,
    tokens = tokens
  }
end

--------------------------------------------------------------------------------
-- Commit Message Document
--------------------------------------------------------------------------------

---@class plugins.scm.ui.commitmessagedoc : core.doc
---@field project_dir string
---@field view plugins.scm.ui.commitmessageview?
---@overload fun(project_dir:string,status?:string,message?:string):plugins.scm.ui.commitmessagedoc
local CommitMessageDoc = Doc:extend()

function CommitMessageDoc:new(project_dir, status, message)
  CommitMessageDoc.super.new(self, "COMMIT_EDITMSG", nil, true)
  self.project_dir = project_dir
  self.highlighter = CommitMessageHighlighter(self)
  self:set_text(build_initial_text(status, message))
  self:set_selection(1, 1)
  self:clean()
end

---@param text string
function CommitMessageDoc:set_text(text)
  self.lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(self.lines, line .. "\n")
  end
  if #self.lines == 0 then
    table.insert(self.lines, "\n")
  end
  self.highlighter:reset()
  self:clear_undo_redo()
end

---@param text string
---@return string
function CommitMessageDoc.strip_comments(text)
  local lines = {}
  for _, line in ipairs(split_lines(text)) do
    if not line:match("^%s*" .. COMMENT_CHAR) then
      table.insert(lines, rtrim(line))
    end
  end
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

---@return string
function CommitMessageDoc:get_commit_message()
  return CommitMessageDoc.strip_comments(table.concat(self.lines))
end

function CommitMessageDoc:on_text_change(type)
  if self.wrapping then return end
  self.wrapping = true

  local i = 2
  while i <= #self.lines do
    local line = self.lines[i]
    if not is_comment(line) then
      local wrapped, first_break_at, first_trimmed_spaces = wrap_text_line(line, BODY_LIMIT)
      if wrapped then
        local line1, col1, line2, col2 = self:get_selection()
        local restore_cursor = line1 == i and line2 == i and col1 == col2
        local indent = line:match("^(%s*)") or ""
        self:remove(i, 1, i, #line)
        self:insert(i, 1, wrapped)
        if restore_cursor then
          if col1 >= first_break_at then
            local new_col = #indent + math.max(1, col1 - first_break_at - first_trimmed_spaces)
            self:set_selection(i + 1, new_col)
          else
            self:set_selection(i, col1)
          end
        end
        i = i + #split_lines(wrapped) - 1
      end
    end
    i = i + 1
  end

  self.wrapping = false
end

function CommitMessageDoc:save()
  if self.view then
    local view = self.view
    core.add_thread(function()
      view:confirm_commit()
    end)
  end
end

--------------------------------------------------------------------------------
-- Commit Message Document View
--------------------------------------------------------------------------------

---@class plugins.scm.ui.commitmessageview : core.docview
---@field project_dir string
---@field backend plugins.scm.backend
---@field mode "commit"|"amend"
---@field commit string?
---@overload fun(project_dir:string,backend:plugins.scm.backend,status?:string,mode?:"commit"|"amend",commit?:string,message?:string):plugins.scm.ui.commitmessageview
local CommitMessageView = DocView:extend()

function CommitMessageView:new(project_dir, backend, status, mode, commit, message)
  local doc = CommitMessageDoc(project_dir, status, message)
  CommitMessageView.super.new(self, doc)
  self.project_dir = project_dir
  self.backend = backend
  self.mode = mode or "commit"
  self.commit = commit
  doc.view = self
end

function CommitMessageView:get_name()
  local name = self.mode == "amend" and "AMEND_EDITMSG" or "COMMIT_EDITMSG"
  return name .. (self.doc:is_dirty() and "*" or "")
end

function CommitMessageView:try_close(do_close)
  if not self.doc:is_dirty() then
    do_close()
    return
  end

  core.command_view:enter("Uncommitted Commit Message; Confirm Close", {
    submit = function(_, item)
      if item.text:match("^[cC]") then
        do_close()
      elseif item.text:match("^[sS]") then
        self.doc:save()
      end
    end,
    suggest = function(text)
      local items = {}
      if not text:find("^[^cC]") then
        table.insert(items, "Close Without Committing")
      end
      if not text:find("^[^sS]") then
        table.insert(items, self.mode == "amend" and "Save And Amend" or "Save And Commit")
      end
      return items
    end
  })
end

---@param force? boolean
function CommitMessageView:close(force)
  local parent = core.root_view.root_node:get_node_for_view(self)
  if parent then
    if force then
      parent:remove_view(core.root_view.root_node, self)
    else
      parent:close_view(core.root_view.root_node, self)
    end
  end
end

function CommitMessageView:confirm_commit()
  local message = self.doc:get_commit_message()
  if message == "" then
    MessageBox.error("SCM Commit", "Enter a commit message before saving.")
    return
  end

  local is_amend = self.mode == "amend"
  local title = is_amend and "SCM Amend Commit" or "SCM Commit"
  local action = is_amend and "Amend" or "Commit"
  core.nag_view:show(
    title,
    string.format("%s changes in %s?", action, common.basename(self.project_dir)),
    {
      { text = action, default_yes = true },
      { text = "Cancel", default_no = true }
    },
    function(item)
      if not item or item.text ~= action then return end
      local scm = require "plugins.scm"
      local function on_done(success)
        if success then
          self.doc.new_file = false
          self.doc:clean()
          self:close(true)
        end
      end
      if is_amend then
        scm.amend_commit(self.project_dir, self.commit, message, on_done)
      else
        scm.commit(self.project_dir, message, on_done)
      end
    end
  )
end

CommitMessageView.Doc = CommitMessageDoc
CommitMessageView.Highlighter = CommitMessageHighlighter
CommitMessageView.wrap_text_line = wrap_text_line

return CommitMessageView
