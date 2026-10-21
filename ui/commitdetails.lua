local core = require "core"
local style = require "core.style"
local Widget = require "widget"
local Label = require "widget.label"
local Button = require "widget.button"

---Commit subject/body shared by standalone and embedded diff viewers.
---@class plugins.scm.ui.CommitDetails : widget
local CommitDetails = Widget:extend()

local function caption(text, width, font)
  if width < font:get_width("...") then return "" end
  if font:get_width(text) <= width then return text end
  local first, last = 0, text:ulen()
  while first < last do
    local middle = math.ceil((first + last) / 2)
    if font:get_width(text:usub(1, middle) .. "...") <= width then
      first = middle
    else
      last = middle - 1
    end
  end
  return text:usub(1, first) .. "..."
end

function CommitDetails:new(parent)
  CommitDetails.super.new(self, parent)
  self.border.width = 0
  self.expanded = false
  self.toggle = Button(self, "")
  self.toggle.border.width = 0
  self.toggle.padding.x, self.toggle.padding.y = 2 * SCALE, 2 * SCALE
  self.toggle:toggle_background(false)
  self.toggle.on_click = function() self:set_expanded(not self.expanded) end
  self.meta = Label(self, "")
  self.meta.scrollable, self.meta.clickable = true, true
  self.meta.foreground_color = style.dim
  self.subject = Label(self, "")
  self.subject.foreground_color = style.accent
  self.subject.clickable = true
  self.subject.on_click = function(_, button)
    if button == "left" then self:set_expanded(not self.expanded) end
  end
  self.body = Label(self, "", true)
  self.body.scrollable, self.body.clickable = true, true
  self.generation = 0
  self.visible = false
  self:set_expanded(false)
end

function CommitDetails:set_expanded(expanded)
  self.expanded = expanded
  self.meta.visible = expanded
  self.body.visible = expanded and self.commit ~= nil
    and self.commit.message ~= nil and self.commit.message ~= ""
  self.toggle:set_icon(expanded and "-" or "+", style.accent)
  self.toggle.tooltip = expanded and "Collapse commit details"
    or "Expand commit details"
  self:schedule_update()
end

---@param commit? plugins.scm.backend.commit
function CommitDetails:set_commit(commit)
  self.commit, self.visible = commit, commit ~= nil
  self.meta:set_label(commit and table.concat({
    commit.hash or "", commit.author or "", commit.date or "",
  }, "  ") or "")
  self.full_subject = commit and commit.summary or ""
  self.subject:set_label(self.full_subject)
  self.subject.tooltip = self.full_subject
  self.caption_width = nil
  self.body:set_label(commit and commit.message or "")
  self:set_expanded(self.expanded)
  core.redraw = true
end

function CommitDetails:clear()
  self.generation = self.generation + 1
  self.key = nil
  self.loading = false
  self:set_commit(nil)
end

---Retain the same commit across refreshes; ignore late selection results.
function CommitDetails:load(backend, directory, hash, initial)
  local key = directory .. "\0" .. hash
  local same = self.key == key and self.backend == backend
  if same and self.loading then return end
  local previous = same and self.commit or initial
  if not same then self:clear() end
  self.key, self.backend = key, backend
  local generation = self.generation
  local info = {}
  for name, value in pairs(previous or {}) do info[name] = value end
  info.hash = info.hash or hash
  self:set_commit(info)
  if not backend.get_commit_info then return end
  self.loading = true
  backend:get_commit_info(hash, directory, function(commit, cached, errmsg)
    if self.generation ~= generation then return end
    self.loading = false
    if commit then
      info.message = commit.message
      for name, value in pairs(commit) do info[name] = value end
    else
      info.message = "Commit details unavailable: "
        .. (errmsg or type(cached) == "string" and cached or "Unknown error")
    end
    self:set_commit(info)
  end)
end

---Return the header height, bounding long bodies independently of the diff.
function CommitDetails:layout(x, y, width, limit)
  if not self.visible then return 0 end
  local row, gap = style.font:get_height(), style.padding.y / 2
  self:set_position(x, y)
  local height = math.min(self.toggle:get_height(), math.max(0, limit))
  self.toggle:set_position(0, 0)
  local left = self.toggle:get_width() + gap
  local subject_width = math.max(0, width - left)
  if self.caption_width ~= subject_width or self.caption_scale ~= SCALE then
    self.subject:set_label(caption(
      self.full_subject, subject_width, self.subject:get_font()
    ))
    self.caption_width, self.caption_scale = subject_width, SCALE
  end
  self.subject:set_position(left, math.max(0, (height - row) / 2))
  self.subject:set_size(subject_width, math.min(row, height))
  if not self.expanded then
    self:set_size(width, height)
    return height
  end
  self.meta:set_position(0, height + gap)
  local meta_height = math.min(row, math.max(0, limit - height - gap))
  self.meta:set_size(width, meta_height)
  height = math.min(limit, height + gap + meta_height)
  if self.body.visible then
    self.body:set_position(0, height + gap)
    self.body:set_size(width, 1)
    self.body:wrap_text()
    local _, body_height = self.body:get_content_size()
    height = math.min(limit, height + gap)
    body_height = math.min(body_height, math.max(0, limit - height))
    self.body:set_size(width, body_height)
    height = height + body_height
  end
  self:set_size(width, height)
  return height
end

---@param commit? plugins.scm.backend.commit
---@return string
function CommitDetails.text(commit)
  if not commit then return "" end
  return "commit " .. (commit.hash or "")
    .. "\nAuthor: " .. (commit.author or "")
    .. "\nDate: " .. (commit.date or "") .. "\n\n"
    .. (commit.summary or "")
    .. (commit.message and commit.message ~= ""
      and "\n\n" .. commit.message or "")
end

return CommitDetails
