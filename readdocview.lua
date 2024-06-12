local core = require "core"
---@type core.doc
local Doc = require "core.doc"
---@type core.docview
local DocView = require "core.docview"

--------------------------------------------------------------------------------
-- Read Only Document
--------------------------------------------------------------------------------

---A readonly core.doc.
---@class plugins.scm.readdoc : core.doc
---@overload fun(title?:string, text?:string):plugins.scm.readdoc
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
  for line in text:gmatch("([^\n]*)\n?") do
    if line:byte(-1) == 13 then
      line = line:sub(1, -2)
      self.crlf = true
    end
    table.insert(self.lines, line .. "\n")
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
---@class plugins.scm.readdocview : core.docview
---@overload fun(title?:string, text?:string):plugins.scm.readdocview
local ReadDocView = DocView:extend()

---Constructor
---@param title? string
---@param text? string
function ReadDocView:new(title, text)
  self.visible = false

  -- close when automatically loaded from workspace plugin
  if not title or not text then
    ReadDocView.super.new(self, Doc())
    core.add_thread(function()
      -- core should offer a function to easily close a view...
      local parent = core.root_view.root_node:get_node_for_view(self)
      if parent then
        parent:close_view(core.root_view.root_node, self)
      end
    end)
    return
  end
  
  ReadDocView.super.new(self, ReadDoc(title, text))
  self.visible = true
end

function ReadDocView:draw()
  if not self.visible then return end
  ReadDocView.super.draw(self)
end

function ReadDocView:update()
  if not self.visible then return end
  ReadDocView.super.update(self)
end

function ReadDocView:get_name()
  if not self.visible then return end
  return ReadDocView.super.get_name(self)
end


return ReadDocView
