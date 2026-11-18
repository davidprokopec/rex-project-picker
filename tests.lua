package.path = "./?.lua;" .. package.path

local action, sessions, history, queued, creates, logs
local answers, prompts
sessions, history = {}, nil
queued, creates, logs, prompts = {}, {}, {}, {}
local cwd_arg
local list_calls, listed_work_dirs, resolve_args = 0, {}, {}
local history_env

rex = {
  action = function(spec) action = spec end,
  bind = function(key, name)
    if key ~= "ctrl+space>f" then return end
    assert(name == "rex_project_picker")
  end,
  exec = function(argv, options)
    if argv[1] == "sh" and argv[3]:find("history()", 1, true) then
      history_env = options and options.env
      list_calls = list_calls + 1
      listed_work_dirs[#listed_work_dirs + 1] = argv[5]
      local output = history or ""
      if argv[5] ~= "" then output = output .. argv[5] .. "\n" end
      if argv[6] ~= "" then output = output .. argv[6] .. "\n" end
      return { ok = true, stdout = output }
    end
    if argv[1] == "sh" and argv[3]:find("CDPATH='' cd -P --", 1, true) then
      resolve_args[#resolve_args + 1] = argv[5]
      local canonical = ({
        ["/history first"] = "/history first",
        ["/work/project space"] = "/work/project space",
        ["/work/symlink/../project space"] = "/real/project space",
        ["/real/project space"] = "/real/project space",
      })[argv[5]]
      if canonical then return { ok = true, stdout = canonical .. "\n" } end
      return { ok = false }
    end
    error("unexpected exec " .. tostring(argv[1]))
  end,
  call = function(name, args)
    if name == "session.list" then return { sessions = sessions } end
    if name == "session.create" then
      creates[#creates + 1] = args
      cwd_arg = args.initial_windows[1].layout.block.options.cwd
      return { session_id = "created-id" }
    end
    error("unexpected call " .. name)
  end,
  layout = { block = function(spec) return { block = spec } end },
  client = { queue = function(name, args) queued[#queued + 1] = { name, args } end },
  log = function(level, message) logs[#logs + 1] = { level, message } end,
  ui = { pick = function(spec)
    prompts[#prompts + 1] = spec
    return table.remove(answers, 1)
  end },
}

local plugin = require("init")
plugin.setup{ work_dir = "/work", key = "ctrl+space>f" }
assert(action.name == "rex_project_picker")

-- Session rows have unique IDs even for duplicate labels and expose no opaque
-- identifiers in the subtitle. Session picks queue the exact ID.
sessions = {
  { session_id = "opaque-1", label = "same" },
  { session_id = "opaque-2", label = "same" },
}
history = "/history first\n/history first\n/history second\n"
answers = { "session:opaque-2" }
action.run({ session_id = "opaque-1" })
assert(queued[1][1] == "session.select" and queued[1][2].session_id == "opaque-2")
local rows = prompts[1].items
assert(rows[1].id == "session:opaque-1" and rows[1].detail == "Current")
assert(rows[1].subtitle == "Open session" and rows[1].id ~= rows[2].id)
assert(rows[3].subtitle == "/history first" and rows[4].subtitle == "/history second")
assert(rows[5].subtitle == "/work")
assert(list_calls == 1 and listed_work_dirs[1] == "/work")
assert(history_env and history_env.PATH:find("/opt/homebrew/bin", 1, true))
assert(history_env.PATH:find("/usr/local/bin", 1, true))
assert(history_env.PATH:find((os.getenv("HOME") or "") .. "/.local/bin", 1, true))
answers = { "folder:/history first" }
action.run({ session_id = "none" })
assert(cwd_arg == "/history first" and creates[1].label == "history first")

-- Typed paths are normalized and checked through argv; creation uses the
-- resolved cwd. Invalid submissions retry with their text retained.
answers = { { text = "project space" } }
action.run({ session_id = "none" })
assert(cwd_arg == "/work/project space" and creates[2].label == "project space")
answers = { { text = "/work/project space" } }
action.run({ session_id = "none" })
assert(creates[3].initial_windows[1].layout.block.options.cwd == "/work/project space")
answers = { { text = "/missing folder" }, { text = "/work/project space" } }
action.run({ session_id = "none" })
assert(prompts[#prompts].value == "/missing folder")

-- Preserve kernel symlink + .. traversal semantics and pass paths as argv,
-- never as shell code.
answers = { { text = "/work/symlink/../project space" } }
action.run({ session_id = "none" })
assert(resolve_args[#resolve_args] == "/work/symlink/../project space")
assert(cwd_arg == "/real/project space")

-- Existing basename session is reused, and root / traversal above root fail.
sessions[#sessions + 1] = { session_id = "reuse-id", label = "project space" }
answers = { { text = "/work/project space" } }
action.run({ session_id = "none" })
assert(queued[#queued][2].session_id == "reuse-id" and #creates == 5)
answers = { { text = "/../../" }, "session:opaque-1" }
action.run({ session_id = "none" })
assert(prompts[#prompts].value == "/../../")
assert(queued[#queued][2].session_id == "opaque-1")

-- Missing history tools still yields work-dir/HOME fallback; cancellation is quiet.
history = nil
rex.ui.pick = function(spec) prompts[#prompts + 1] = spec; return nil, "cancelled" end
local log_count = #logs
action.run({ session_id = "none" })
assert(#logs == log_count)

-- Unsupported UI logs one useful warning and returns without retrying.
rex.ui.pick = function() return nil, "unsupported" end
action.run({ session_id = "none" })
assert(#logs == log_count + 1 and logs[#logs][2]:find("unsupported"))

-- Session priority and hard cap are deterministic.
rex.ui.pick = function(spec) prompts[#prompts + 1] = spec; return nil, "cancelled" end
sessions = {}
for i = 1, 1999 do sessions[i] = { session_id = string.format("id-%04d", i), label = "Duplicate" } end
local history_rows = {}
for i = 1, 272 do history_rows[i] = "/rank " .. string.format("%03d", i) end
history = table.concat(history_rows, "\n") .. "\n"
local before_listing = list_calls
action.run({ session_id = "none" })
rows = prompts[#prompts].items
assert(#rows == 2000 and rows[1].id == "session:id-0001")
assert(rows[1999].id == "session:id-1999" and rows[2000].subtitle == "/rank 001")
assert(list_calls == before_listing + 1, "272 folders must cost one history exec")

local root_action
rex.action = function(spec) root_action = spec end
plugin.setup{ work_dir = "/", key = false, action = "root_picker" }
root_action.run({ session_id = "none" })
assert(listed_work_dirs[#listed_work_dirs] == "/", "root work_dir must not normalize to empty")

-- Execute the exact embedded shell snippets against real filesystem fixtures.
local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end
local source_file = assert(io.open("init.lua", "r"))
local source = source_file:read("*a")
source_file:close()
local function embedded_script(name)
  local marker = "local " .. name .. " = [["
  local start = assert(source:find(marker, 1, true)) + #marker
  local finish = assert(source:find("\n]]", start, true))
  return source:sub(start, finish - 1)
end
local root = os.tmpname() .. " rex fixture"
os.remove(root)
local home, work, physical = root .. "/home", root .. "/work", root .. "/physical"
local hacked, literal = root .. "/HACKED", root .. "/work/$(touch " .. root .. "/HACKED)"
local function shell(command)
  local ok, _, code = os.execute(command)
  assert(ok == true or ok == 0 or code == 0, "fixture command failed: " .. command)
end
shell("mkdir -p " .. quote(home .. "/sub dir") .. " " .. quote(work) ..
  " " .. quote(physical .. "/child") .. " " .. quote(literal))
shell("ln -s " .. quote(physical .. "/child") .. " " .. quote(work .. "/link"))
local bin, empty_bin = root .. "/bin", root .. "/empty-bin"
shell("mkdir -p " .. quote(bin) .. " " .. quote(empty_bin))
local zoxide = assert(io.open(bin .. "/zoxide", "w"))
zoxide:write("#!/bin/sh\nprintf '%s\\n' '~' '~/sub dir' ",
  quote(work .. "/link/.."), " ", quote(literal), " ", quote(work .. "/link/.."), "\n")
zoxide:close()
shell("chmod +x " .. quote(bin .. "/zoxide"))
local function run_embedded(script, path_env, first, second)
  local command = "PATH=" .. quote(path_env) .. " /bin/sh -c " .. quote(script) ..
    " rex-project-picker " .. quote(first) .. " " .. quote(second)
  local pipe = assert(io.popen(command, "r"))
  local output = pipe:read("*a")
  assert(pipe:close())
  return output
end
local listing = run_embedded(embedded_script("DIRECTORY_LIST_SCRIPT"), bin, work, home)
assert(listing:find(home .. "\n", 1, true), "literal ~ must expand to HOME")
assert(listing:find(home .. "/sub dir\n", 1, true), "~/ with spaces must expand")
assert(listing:find(physical .. "\n", 1, true), "symlink/.. must use physical traversal")
assert(listing:find(literal .. "\n", 1, true), "metacharacter directory should remain literal")
assert(not io.open(hacked, "r"), "path text must not execute shell substitutions")
local fallback = run_embedded(embedded_script("DIRECTORY_LIST_SCRIPT"), empty_bin, work, home)
local canonical_work = run_embedded(embedded_script("RESOLVE_DIRECTORY_SCRIPT"), empty_bin, work, "")
local canonical_home = run_embedded(embedded_script("RESOLVE_DIRECTORY_SCRIPT"), empty_bin, home, "")
assert(fallback == canonical_work .. canonical_home, "missing sesh/zoxide must retain work-dir and HOME")
local resolved = run_embedded(embedded_script("RESOLVE_DIRECTORY_SCRIPT"), empty_bin, work .. "/link/..", "")
local canonical_physical = run_embedded(embedded_script("RESOLVE_DIRECTORY_SCRIPT"), empty_bin, physical, "")
assert(resolved == canonical_physical, "typed symlink/.. path must be resolved by the filesystem")
os.remove(hacked)
shell("rm -rf " .. quote(root))

print("rex-project-picker tests passed")
