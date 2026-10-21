local FormDialog = require "plugins.scm.ui.formdialog"
local MessageBox = require "widget.messagebox"

---@class plugins.scm.ui.PushDialog : plugins.scm.ui.FormDialog
local PushDialog = FormDialog:extend()

---@param project_dir string
---@param backend plugins.scm.backend
---@param targets plugins.scm.backend.pushtargets
---@param submit fun(options:plugins.scm.backend.pushoptions,done:function)
---@param finished? fun(success:boolean,errmsg?:string)
function PushDialog:new(project_dir, backend, targets, submit, finished)
  local remotes, branches, indexed = {}, {}, {}
  for _, remote in ipairs(targets.remotes) do
    remotes[#remotes + 1] = { remote.name, remote.name }
  end
  for _, branch in ipairs(targets.branches) do
    branches[#branches + 1] = { branch.name, branch.name }
    indexed[branch.name] = branch
  end
  local current = indexed[targets.branch]
  self.finished = finished
  PushDialog.super.new(self, "SCM Push", {
    { id = "remote", label = "Remote", options = remotes,
      value = current and current.remote or "", required = true },
    { id = "branch", label = "Local branch", options = branches,
      value = targets.branch or "", required = true },
    { id = "target", label = "Destination branch",
      value = current and current.target or "", required = true },
    { id = "upstream", label = "Set upstream tracking", kind = "check",
      value = current ~= nil and current.upstream == nil },
    { id = "lease", label = "Force with lease", kind = "check" },
  }, function(values, done)
    self:set_busy(true)
    local function push()
      submit(values, function(ok, errmsg)
        if ok then self.completed = true end
        self.last_error = errmsg
        self:set_busy(false)
        done(ok, errmsg)
        if ok and self.finished then self.finished(true, errmsg) end
      end)
    end
    if not values.lease then
      push()
      return
    end
    backend:get_remote_ref_tip(project_dir, values.remote, values.target,
      "branch", function(expected, errmsg)
        if expected == nil then
          self.last_error = errmsg
          self:set_busy(false)
          done(false, errmsg)
          return
        end
        values.expected = expected
        MessageBox.warning("SCM Force Push",
          "Project: " .. project_dir .. "\n\n"
            .. "Replace '" .. values.remote .. "/" .. values.target
            .. "' with local branch '" .. values.branch .. "'?\n\n"
            .. "Expected remote tip: "
            .. (expected ~= "" and expected or "absent"),
          function(_, id)
            if id == 1 then push() else self:set_busy(false) end
          end, MessageBox.BUTTONS_YES_NO)
      end)
  end, "Push")
  self:set_floating(true, { dismiss_on_escape = true })
  self.controls.remote.on_change = function()
    local branch = indexed[self.controls.branch:get_selected_data()]
    if branch and self.controls.target:get_text() == self.default_target then
      self.default_target = self.controls.remote:get_selected_data()
          == branch.remote and branch.target or branch.name
      self.controls.target:set_text(self.default_target)
    end
  end
  self.controls.branch.on_change = function()
    local branch = indexed[self.controls.branch:get_selected_data()]
    if not branch then return end
    self.default_target = branch.target
    self.controls.target:set_text(branch.target)
    self.controls.upstream:set_checked(branch.upstream == nil)
    local selected = 0
    for i, remote in ipairs(targets.remotes) do
      if remote.name == branch.remote then selected = i end
    end
    self.controls.remote:set_selected(selected)
  end
  self.default_target = current and current.target or ""
end

---@param busy boolean
function PushDialog:set_busy(busy)
  self.busy = busy
  self:set_floating(true, { dismiss_on_escape = not busy })
end

function PushDialog:on_close()
  if self.busy or self.closed then return end
  self.closed = true
  PushDialog.super.on_close(self)
  self:destroy()
  if not self.completed and self.finished then
    self.finished(false, self.last_error or "Push cancelled.")
  end
end

function PushDialog:on_floating_dismiss(reason)
  self:on_close()
end

return PushDialog
