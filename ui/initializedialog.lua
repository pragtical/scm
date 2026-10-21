local common = require "core.common"
local FormDialog = require "plugins.scm.ui.formdialog"
local MessageBox = require "widget.messagebox"
local tools = require "plugins.scm.backend.tools"

---Select a backend, then collect its optional initialization inputs.
return function(backends, directory, finished)
  local options = {}
  for name, backend in pairs(backends) do
    if backend.command and backend:get_capabilities().initialize then
      options[#options + 1] = { name, backend }
    end
  end
  table.sort(options, function(a, b)
    return a[1] < b[1]
  end)
  if #options == 0 then
    MessageBox.error(
      "SCM Initialize",
      "No supported SCM executable is available."
    )
    return
  end
  local dialog = FormDialog("SCM Initialize Repository", {
    {
      id = "backend",
      label = "Source control system",
      options = options,
      value = backends.Git,
      required = true,
    },
    {
      id = "directory",
      label = "Directory",
      kind = "directory",
      value = directory,
      required = true,
    },
  }, function(values, done)
    local path = common.home_expand(values.directory)
    if not common.is_absolute_path(path) then
      path = common.normalize_path(directory .. PATHSEP .. path)
    end
    local ok, errmsg = tools.can_initialize(path, backends)
    if not ok then
      done(false, errmsg)
      return
    end
    local backend = values.backend
    local fields = backend:get_init_options(path)
    done(true)
    FormDialog(
      "SCM Initialize " .. backend.name,
      fields,
      function(settings, complete)
        local valid, err = tools.can_initialize(path, backends)
        if not valid then
          complete(false, err)
          return
        end
        if settings.repository then
          settings.repository = common.home_expand(settings.repository)
          if not common.is_absolute_path(settings.repository) then
            settings.repository =
              common.normalize_path(path .. PATHSEP .. settings.repository)
          end
        end
        backend:init_repository(path, function(ok, errmsg)
          complete(ok, errmsg)
          if ok then
            finished(path, backend)
          end
        end, settings)
      end,
      "Initialize"
    ):show()
  end, "Continue")
  dialog:show()
  return dialog
end
