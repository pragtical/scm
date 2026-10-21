---@type core.doc
local Doc = require "core.doc"
---@type core.docview
local DocView = require "core.docview"

--------------------------------------------------------------------------------
-- Read Only Document
--------------------------------------------------------------------------------

---A readonly core.doc.
---@class plugins.scm.ui.readdoc : core.doc
---@overload fun(title?:string, text?:string):plugins.scm.ui.readdoc
local ReadDoc = Doc:extend()

function ReadDoc:new(title, text)
  ReadDoc.super.new(self, title, title)
  self:set_text(text or "")
end

---Set the text.
---@param text string
function ReadDoc:set_text(text)
  self.lines = {}
  local i = 1
  for text_line in text:gmatch("([^\n]*)\n?") do
    local value = text_line
    if value:byte(-1) == 13 then
      value = value:sub(1, -2)
      self.crlf = true
    end
    table.insert(self.lines, value .. "\n")
    self.highlighter.lines[i] = false
    i = i + 1
  end
  self:reset_syntax()
end

function ReadDoc:raw_insert(...) end
function ReadDoc:raw_remove(...) end
function ReadDoc:load(...) end
function ReadDoc:reload() end
function ReadDoc:save(...) end

--------------------------------------------------------------------------------
-- Read Only Document View
--------------------------------------------------------------------------------

---A readonly core.docview
---@class plugins.scm.ui.readdocview : core.docview
---@overload fun(title:string, text:string):plugins.scm.ui.readdocview
local ReadDocView = DocView:extend()

---Constructor
---@param title string
---@param text string
function ReadDocView:new(title, text)
  ReadDocView.super.new(self, ReadDoc(title, text))
end

function ReadDocView:get_state() return nil end

return ReadDocView
