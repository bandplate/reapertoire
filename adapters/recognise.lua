-- adapters/recognise.lua
-- Runs the song-recognition sidecar.
--
-- Out of process on purpose: the numeric work needs librosa and numpy, which do
-- not belong in REAPER's embedded Lua, and a crash in that stack must not take
-- the DAW down with it. The two talk JSON over temporary files.

local json = require("lib.util.json")
local probes = require("lib.probes")
local background = require("adapters.background")

local M = {}

M.REFERENCES = ".reapertoire-references.json"

local function python(repo_dir)
  return repo_dir .. "/.venv/bin/python"
end

function M.available(repo_dir)
  local f = io.open(python(repo_dir), "r")
  if not f then return false end
  f:close()
  return true
end

-- stderr is folded into the output rather than discarded: a swallowed error
-- here is indistinguishable from the recogniser simply finding nothing, which
-- is the least useful failure mode available.
local function run(command)
  local pipe = io.popen(command .. " 2>&1")
  if not pipe then return nil, "io.popen is unavailable" end
  local out = pipe:read("*a")
  pipe:close()
  return out
end

local function temp_dir()
  return os.getenv("TMPDIR") or "/tmp"
end

-- Where probes are kept between openings of the naming panel.
--
-- `/tmp` itself, not `$TMPDIR`: on macOS `$TMPDIR` is a per-user directory
-- under /var/folders that survives a reboot, while /tmp is emptied at every
-- boot. Probes for regions deleted or re-tuned since therefore pile up only
-- until the next restart, with no eviction to get wrong.
M.PROBE_CACHE = "/tmp/reapertoire-probes"

-- Renders a probe for each region that has no usable one cached, and returns
-- paths for all of them.
--
-- `rows` are { key, guid, start, stop }. Returns
--   paths      { key = path }, cached and fresh alike
--   failures   list of reasons
--   meta       { key = { duration, fileSeconds } }
--   elapsed    seconds spent rendering
--   info       { reused = n, disposable = { path, ... } }
--
-- `disposable` are probes that can never be reused -- regions REAPER reports
-- no GUID for -- which the caller deletes once it has matched them.
function M.render_probes(render, rows, seconds, format, cache_dir)
  cache_dir = cache_dir or M.PROBE_CACHE
  reaper.RecursiveCreateDirectory(cache_dir, 0)

  -- Indexed by stem: REAPER appends whatever extension the format uses, so a
  -- probe is found by its key, not by a name guessed in advance.
  local cached, index = {}, 0
  while true do
    local name = reaper.EnumerateFiles(cache_dir, index)
    if not name then break end
    local stem = name:match("^(.*)%.[^.]+$")
    if stem then cached[stem] = cache_dir .. "/" .. name end
    index = index + 1
  end

  local paths, jobs, meta = {}, {}, {}
  local info = { reused = 0, disposable = {} }
  local fresh = {}   -- keys whose render leaves nothing worth keeping

  for _, row in ipairs(rows) do
    -- The whole region, not a slice of it. This is the single largest factor
    -- in whether the guess is right: measured over held-out takes, a
    -- twenty-five second excerpt ranks the right song first 74% of the time
    -- and the whole take 97%. A rehearsal take is not homogeneous, and a short
    -- window can land entirely inside one vamp -- every song has a bar of A
    -- minor somewhere. `seconds` is now only a ceiling against a pathological
    -- region; probes render far faster than realtime at 11 kHz mono.
    local length = row.stop - row.start
    local window = math.min(seconds or 600, length)
    local from = row.start + math.max(0, (length - window) / 2)
    -- The take's own length, not the excerpt's: it is what the duration
    -- feature compares against the references.
    meta[row.key] = { duration = length, fileSeconds = window }

    local key = probes.key(row.guid, from, from + window, format)
    if key and cached[key] then
      paths[row.key] = cached[key]
      info.reused = info.reused + 1
    else
      -- A region with no GUID gets a one-off name: unique to this opening, so
      -- REAPER never stops to ask about overwriting, and deleted after use
      -- since nothing could ever find it again.
      local name = key or string.format("once-%d-%s", os.time(), tostring(row.key))
      if not key then fresh[row.key] = true end
      jobs[#jobs + 1] = {
        key = row.key, dir = cache_dir, name = name,
        start = from, stop = from + window,
      }
    end
  end

  local started = reaper.time_precise()
  if #jobs > 0 then
    local rendered, failures = render.probe_batch(jobs, format)
    for k, path in pairs(rendered) do
      paths[k] = path
      if fresh[k] then info.disposable[#info.disposable + 1] = path end
    end
    return paths, failures, meta, reaper.time_precise() - started, info
  end
  return paths, {}, meta, 0, info
end

-- Ranks the reference library against each probe. Returns { key = { {song, score} } }.
function M.match(repo_dir, references_path, paths, meta)
  local takes = {}
  for key, path in pairs(paths) do
    local info = meta and meta[key] or {}
    takes[#takes + 1] = {
      id = tostring(key), path = path,
      duration = info.duration, fileSeconds = info.fileSeconds,
    }
  end
  if #takes == 0 then return {} end

  local input_path = string.format("%s/reapertoire-match-%d.json", temp_dir(), os.time())
  local f = io.open(input_path, "w")
  if not f then return {}, "could not write " .. input_path end
  f:write(json.encode({ takes = takes }))
  f:close()

  local command = string.format(
    "%q %q match --refs %q --input %q",
    python(repo_dir), repo_dir .. "/tools/recognise/recognise.py",
    references_path, input_path)
  local out, popen_error = run(command)
  os.remove(input_path)

  if not out or out == "" then
    return {}, popen_error or "the recogniser produced no output"
  end

  -- The result is the last line: anything the interpreter or ffmpeg printed
  -- along the way comes first and is not JSON.
  local last = out:match("[^\r\n]+%s*$") or out
  local parsed = json.decode(last)
  if type(parsed) ~= "table" or type(parsed.results) ~= "table" then
    return {}, out:gsub("%s+$", ""):sub(-200)
  end

  local results = {}
  for key, ranked in pairs(parsed.results) do
    results[tonumber(key) or key] = ranked
  end
  return results
end

-- Rebuilds the reference library from every named take already rendered.
-- Returns a short summary line, or nil and a reason.
-- The command that rebuilds the reference library, for a caller to run.
--
-- Handed back rather than run here because indexing reads every rendered take
-- in the archive and takes minutes: run down a pipe it freezes REAPER for the
-- duration. `adapters/background` runs it detached; `-u` keeps Python from
-- buffering its progress lines into one lump at the end.
function M.index_command(repo_dir, sessions_root, references_path)
  local q = background.quote
  return string.format("%s -u %s index --sessions-root %s --out %s",
    q(python(repo_dir)), q(repo_dir .. "/tools/recognise/recognise.py"),
    q(sessions_root), q(references_path))
end

-- The JSON summary the indexer prints last, out of the whole output.
--
-- Last line, as in match: the tool reports progress before its summary.
function M.parse_index_summary(out)
  if not out or out == "" then return nil, "the recogniser produced no output" end
  local last = out:match("[^\r\n]+%s*$") or out
  local parsed = json.decode(last)
  if type(parsed) ~= "table" then
    return nil, "unexpected output: " .. out:gsub("%s+$", ""):sub(-160)
  end
  return parsed
end

return M
