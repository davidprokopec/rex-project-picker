local M = {}

local SHELL = "com.superlogical.terminal.shell"
local MAX_ITEMS = 2000
local DIRECTORY_LIST_SCRIPT = [[
history() {
  if command -v sesh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    json=$(sesh list --json --zoxide --config 2>/dev/null) &&
      printf '%s\n' "$json" | jq -r '.[]?.Path // empty' 2>/dev/null && return 0
  fi
  if command -v zoxide >/dev/null 2>&1; then zoxide query --list 2>/dev/null || :; fi
}
{
  history
  printf '%s\n' "$1" "$2"
} | while IFS= read -r path; do
  [ -n "$path" ] || continue
  home=$2
  tilde='~'
  case "$path" in
    "$tilde") path=$home ;;
    "$tilde/"*) path=$home/${path#"$tilde"/} ;;
  esac
  canonical=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || continue
  [ "$canonical" != / ] || continue
  printf '%s\n' "$canonical"
done
]]
local RESOLVE_DIRECTORY_SCRIPT = [[
canonical=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || exit 1
[ "$canonical" != / ] || exit 1
printf '%s\n' "$canonical"
]]

local function run(argv)
  local result = rex.exec(argv)
  if result and result.ok then return result.stdout end
  return nil
end

local function history(work_dir)
  local output = run({ "sh", "-c", DIRECTORY_LIST_SCRIPT, "rex-project-picker", work_dir, os.getenv("HOME") or "" })
  local paths, seen = {}, {}
  for path in (output or ""):gmatch("[^\r\n]+") do
    if path ~= "" and path ~= "/" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  return paths
end

local function sessions()
  local result = rex.call("session.list")
  return result and result.sessions or {}
end

local function basename(path)
  return path:gsub("/+$", ""):match("([^/]+)$") or path
end

local function normalize(path, work_dir)
  if type(path) ~= "string" or path == "" then return nil end
  if path == "~" then
    path = os.getenv("HOME")
  elseif path:sub(1, 2) == "~/" then
    path = os.getenv("HOME") .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = (work_dir == "/" and "/" or work_dir .. "/") .. path
  end
  local result = rex.exec({ "sh", "-c", RESOLVE_DIRECTORY_SCRIPT, "rex-project-picker", path })
  if not result or not result.ok then return nil end
  local canonical = (result.stdout or ""):gsub("\n$", ""):gsub("\r$", "")
  return canonical ~= "" and canonical ~= "/" and canonical or nil
end

local function picker_items(ctx, work_dir)
  local rows, seen_sessions, seen_paths = {}, {}, {}
  for _, session in ipairs(sessions()) do
    local id = session.session_id
    if type(id) == "string" and id ~= "" and not seen_sessions[id] and #rows < MAX_ITEMS then
      seen_sessions[id] = true
      rows[#rows + 1] = {
        id = "session:" .. id,
        title = tostring(session.label or "Untitled session"):gsub("[\r\n\t]", " "),
        subtitle = "Open session",
        detail = id == ctx.session_id and "Current" or nil,
        icon = "terminal",
      }
    end
  end
  for _, path in ipairs(history(work_dir)) do
    if #rows >= MAX_ITEMS then break end
    if not seen_paths[path] then
      seen_paths[path] = true
      rows[#rows + 1] = {
        id = "folder:" .. path,
        title = basename(path),
        subtitle = path,
        icon = "folder",
      }
    end
  end
  return rows
end

local function go(ctx, path)
  local existing = sessions()
  local name = basename(path)
  for _, session in ipairs(existing) do
    if session.label == name then
      rex.client.queue("session.select", { session_id = session.session_id })
      return { session_id = session.session_id, path = path, created = false }
    end
  end
  local created, err = rex.call("session.create", {
    label = name,
    initial_windows = { {
      layout = rex.layout.block{
        flavor = SHELL,
        options = { cwd = path },
      },
    } },
  })
  if not created then error("rex-project-picker: " .. tostring(err), 0) end
  rex.client.queue("session.select", { session_id = created.session_id })
  return { session_id = created.session_id, path = path, created = true }
end

function M.setup(options)
  options = options or {}
  local work_dir = options.work_dir or os.getenv("HOME")
  if work_dir == "~" then work_dir = os.getenv("HOME") end
  if work_dir:sub(1, 2) == "~/" then work_dir = os.getenv("HOME") .. work_dir:sub(2) end
  if work_dir ~= "/" then work_dir = work_dir:gsub("/+$", "") end
  local action = options.action or "rex_project_picker"
  rex.action{
    name = action,
    title = options.title or "Switch Project…",
    category = "Session",
    run = function(ctx)
      local message, query
      while true do
        local selected, reason, detail = rex.ui.pick{
          title = message or (options.title or "Switch project"),
          placeholder = "Filter sessions and folders, or type a path",
          value = message and query or nil,
          items = picker_items(ctx, work_dir),
          allow_other = true,
        }
        if selected == nil then
          if reason ~= "cancelled" then
            rex.log("warn", "rex-project-picker: picker unavailable (" ..
              tostring(reason) .. ")" .. (detail and ": " .. detail or ""))
          end
          return
        end
        if type(selected) == "table" then
          local path = normalize(selected.text, work_dir)
          if path then
            go(ctx, path)
            return
          end
          message = "Not an existing directory — try again"
          query = selected.text
        elseif selected:sub(1, 8) == "session:" then
          rex.client.queue("session.select", { session_id = selected:sub(9) })
          return
        elseif selected:sub(1, 7) == "folder:" then
          local path = normalize(selected:sub(8), work_dir)
          if path then
            go(ctx, path)
            return
          end
          message = "Folder no longer exists — try again"
        end
      end
    end,
  }
  if options.key ~= false then rex.bind(options.key or "ctrl+space>f", action) end
  return M
end

return M
