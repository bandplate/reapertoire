-- scripts/Reapertoire_Name_takes.lua
-- Names the regions in the project: pick a song per take, a few keystrokes each.
--
-- Works off regions rather than detection output, so naming survives closing
-- the project. Reopening parses the existing names back apart and carries on
-- from wherever it stopped.

if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local script_path = ({ reaper.get_action_context() })[2]
-- REAPERTOIRE_DIR is set when this runs via the launcher, which dofiles
-- us and would otherwise have us derive the path from ITS location.
local repo_dir = REAPERTOIRE_DIR or script_path:match("^(.*)[/\\]scripts[/\\][^/\\]*$")
package.path = repo_dir .. "/?.lua;" .. repo_dir .. "/?/init.lua;" .. package.path

local adapter = require("adapters.reaper_api")
local regions = require("adapters.regions")
local render = require("adapters.render")
local recognise = require("adapters.recognise")
local config = require("lib.config")
local songs_lib = require("lib.songs")
local naming = require("lib.naming")
local text = require("lib.util.text")
local time = require("lib.util.time")

local mmss = time.hms


local ImGui
do
  if reaper.ImGui_GetBuiltinPath then
    local ok, mod = pcall(function()
      package.path = package.path .. ";" .. reaper.ImGui_GetBuiltinPath() .. "/?.lua"
      return require("imgui")("0.10")
    end)
    if ok then ImGui = mod end
  end
  if not ImGui and reaper.ImGui_CreateContext then
    ImGui = setmetatable({}, {
      __index = function(_, k) return reaper["ImGui_" .. k] end,
    })
  end
  if not ImGui then
    reaper.MB("ReaImGui is not installed.", "Reapertoire", 0)
    return
  end
end

-- ReaImGui exposes enum values as accessor functions in some versions and as
-- plain numbers in others. Resolve once rather than assuming either.
local ENUM = setmetatable({}, {
  __index = function(t, name)
    local v = ImGui[name]
    if type(v) == "function" then v = v() end
    rawset(t, name, v)
    return v
  end,
})

local ok, cfg = pcall(config.load, repo_dir, adapter.read_file)
if not ok then
  reaper.MB("Configuration problem:\n\n" .. tostring(cfg), "Reapertoire", 0)
  return
end

local songs = songs_lib.load(cfg)

-- ----------------------------------------------------------------- the rows

local rows = {}          -- every region in the project
local view = {}          -- the filtered subset actually shown
local selected = 1       -- indexes `view`, not `rows`
local limit_to_selection = true
local only_ours = false

-- Recognition runs once when the panel opens, blocking. The message is drawn a
-- frame first so the window does not simply appear frozen.
local recognising = nil        -- nil = not started, true = due, false = done
local recognise_note = ""
local query = ""
local status = ""
local focus_filter = false

-- Reads every region in the project into a row, parsing any name this tool
-- could have written back into song and label.
local function load_rows()
  rows = {}
  for _, r in ipairs(regions.all()) do
    local song, label = naming.parse(r.name, songs)
    local note = nil
    if label and naming.take_number(label) == nil then note = label end
    rows[#rows + 1] = {
      guid = r.guid,
      num = r.num,
      start = r.start,
      stop = r.stop,
      original = r.name,
      owned = r.owned,
      song = song,
      note = note,
    }
  end
  table.sort(rows, function(a, b) return a.start < b.start end)
end

load_rows()

-- A project holds many rehearsals, so the default is the regions inside the
-- current time selection. Without a selection the limit is inert rather than
-- hiding everything.
local function rebuild_view()
  local sel_start, sel_stop = adapter.time_selection()
  view = {}
  for _, row in ipairs(rows) do
    local in_selection = true
    if limit_to_selection and sel_start then
      in_selection = row.start < sel_stop and sel_start < row.stop
    end
    if in_selection and (not only_ours or row.owned) then
      view[#view + 1] = row
    end
  end
  if selected > #view then selected = #view end
  if selected < 1 then selected = 1 end

  -- Take numbers count within a session, not across the project. One project
  -- holds many rehearsals, so numbering over everything would give the same
  -- song a take number in the forties.
  naming.renumber(view)
end

local function unnamed_after(from)
  for i = from, #view do
    if not view[i].song then return i end
  end
  for i = 1, #view do
    if not view[i].song then return i end
  end
  return nil
end

local function seek_and_play(row)
  reaper.SetEditCurPos(row.start, true, true)
  local playing = reaper.GetPlayState() & 1 == 1
  if not playing then reaper.OnPlayButton() end
end

-- Clearing is explicit rather than implied by an absent song: a region the
-- tuner named "Take 3" and nobody has touched should keep that name, while one
-- the operator deliberately cleared should lose it.
local function clear_row(row)
  row.song = nil
  row.note = nil
  row.auto = nil
  row.cleared = true
  naming.renumber(view)
end

-- What the tuner calls a region before anyone names it. Clearing restores this
-- rather than blanking the region: an unnamed region still needs to be
-- identifiable in the region manager, and a nameless one is not.
local function placeholder_name(index)
  return string.format("Take %d", index)
end

-- How far clear of the runner-up a guess must be before it is trusted, as a
-- fraction of the runner-up rather than an absolute gap. See the note at the
-- suggestion list for why the ratio and not the score.
-- `or` cannot express a configured zero, so the absence is tested.
local function min_margin()
  if cfg.recognition and cfg.recognition.minMargin ~= nil then
    return cfg.recognition.minMargin
  end
  return 0.10
end

-- Ranks the repertoire against every take that has no song yet, hangs the
-- guesses on the rows, and fills in the ones it is confident about.
--
-- Automatic naming used to be refused outright here, on the grounds that a
-- wrong label is worse than no label: it gets rendered, indexed, and becomes a
-- reference that poisons future matching. What changed is that the confidence
-- is now measured rather than assumed -- over forty-four held-out takes every
-- guess this far clear of its runner-up was right forty-three times. That is
-- worth a keystroke each, provided the fill is easy to see and undo, which is
-- what the `auto` flag is for: filled names are marked in the list until the
-- operator confirms or changes them.
local function run_recognition()
  if not recognise.available(repo_dir) then
    recognise_note = "Recognition is not set up. Run ./bin/setup-recognise."
    return
  end

  local pending = {}
  for i, row in ipairs(view) do
    if not row.song then
      pending[#pending + 1] = { key = i, guid = row.guid, start = row.start, stop = row.stop }
    end
  end
  if #pending == 0 then
    recognise_note = ""
    return
  end

  local references = config.expand_path(cfg.sessionsRoot) .. "/" .. recognise.REFERENCES
  if not adapter.read_file(references) then
    recognise_note = "No reference library yet at " .. references
      .. " -- name and render a session first, then re-index."
    return
  end

  -- Whole takes, ceilinged at ten minutes; see `render_probes`. Cached in
  -- /tmp between openings, so only takes whose region is new or re-tuned since
  -- the last reboot pay for a render.
  local paths, failures, meta, elapsed, probe_info = recognise.render_probes(
    render, pending, 600, cfg.recognition and cfg.recognition.probeFormat)

  local rendered = 0
  for _ in pairs(paths) do rendered = rendered + 1 end

  local ranked, match_error = recognise.match(repo_dir, references, paths, meta)
  -- Only probes nothing could ever find again; the rest stay for next time.
  for _, path in ipairs(probe_info.disposable) do os.remove(path) end

  local guessed, filled = 0, 0
  local threshold = min_margin()
  for key, results in pairs(ranked) do
    local row = view[key]
    if row and #results > 0 then
      row.guesses = results
      guessed = guessed + 1
      -- Only rows with no song were probed, so this cannot overwrite a name
      -- anybody chose. `cleared` is dropped because a filled name is a name.
      if results[1].margin and results[1].margin >= threshold then
        row.song = results[1].song
        row.auto = true
        row.cleared = nil
        filled = filled + 1
      end
    end
  end
  if filled > 0 then naming.renumber(view) end

  if rendered == 0 then
    recognise_note = "No probes rendered"
      .. (failures[1] and (": " .. failures[1]) or "")
  elseif guessed == 0 then
    recognise_note = string.format(
      "Rendered %d probes, no match: %s", rendered,
      match_error or "the library returned no candidates")
  else
    local fresh = rendered - probe_info.reused
    local probes_note
    if fresh == 0 then
      probes_note = string.format("all %d probes reused", probe_info.reused)
    elseif probe_info.reused == 0 then
      probes_note = string.format("%.1fs to render probes", elapsed or 0)
    else
      probes_note = string.format("%d probes reused, %d rendered in %.1fs",
        probe_info.reused, fresh, elapsed or 0)
    end
    recognise_note = string.format(
      "Suggested songs for %d of %d unnamed takes, %d filled in automatically"
      .. " (marked *, %s)", guessed, #pending, filled, probes_note)
  end
end

local function apply_names()
  local written, failed = 0, {}
  for i, row in ipairs(view) do
    local name = naming.region_name(row)
    if row.cleared and not name then name = placeholder_name(i) end
    if name and name ~= row.original then
      if regions.rename(row, name) then
        row.original = name
        row.cleared = nil
        row.auto = nil
        written = written + 1
      else
        -- Silently not incrementing left the operator believing a rename
        -- landed when the region could not be found.
        failed[#failed + 1] = row.song or "take"
      end
    end
  end
  if #failed > 0 then
    status = string.format("Renamed %d, FAILED %d (%s) -- those regions could not be found",
      written, #failed, table.concat(failed, ", "))
  elseif written == 0 then
    status = "Nothing to write - no name differed from what the region already has"
  else
    status = string.format("Renamed %d region%s", written, written == 1 and "" or "s")
  end
end

load_rows()
rebuild_view()

local guids_ok = regions.guids_available()

-- ---------------------------------------------------------------------- loop

local ctx = ImGui.CreateContext("Reapertoire naming")

-- The arrow keys belong to the take list. ImGui's own keyboard navigation
-- claims them too, and with both live one press moved two cursors: the take on
-- the left and, independently, a highlight walking the suggestions on the
-- right. Nothing here needs nav -- the filter box is focused explicitly and
-- Enter is handled by hand -- so it goes rather than the take list losing the
-- arrows.
ImGui.SetConfigVar(ctx, ENUM.ConfigVar_Flags,
  ImGui.GetConfigVar(ctx, ENUM.ConfigVar_Flags) & ~ENUM.ConfigFlags_NavEnableKeyboard)

local function frame()
  -- FirstUseEver, so the size is a starting point and not re-imposed every
  -- frame; resizing the window has to stick.
  ImGui.SetNextWindowSize(ctx, 1000, 560, ENUM.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Reapertoire - name takes", true)
  if visible then
    rebuild_view()

    if recognising == true then
      recognising = false
      run_recognition()
    end

    local named = 0
    for _, r in ipairs(view) do if r.song then named = named + 1 end end
    ImGui.Text(ctx, string.format("%d of %d regions shown - %d named, %d to go",
      #view, #rows, named, #view - named))

    local c1, v1 = ImGui.Checkbox(ctx, "limit to time selection", limit_to_selection)
    if c1 then limit_to_selection = v1; selected = 1 end
    ImGui.SameLine(ctx)
    local c2, v2 = ImGui.Checkbox(ctx, "only regions I created", only_ours)
    if c2 then only_ours = v2; selected = 1 end
    if not guids_ok then
      ImGui.Text(ctx,
        'This project does not answer region GUID lookups, so "only regions I '
        .. 'created" cannot tell them apart. Renaming is unaffected.')
    end

    if status ~= "" then ImGui.Text(ctx, status) end
    if recognise_note ~= "" then ImGui.Text(ctx, recognise_note) end

    if recognising == nil then
      local unnamed = 0
      for _, r in ipairs(view) do if not r.song then unnamed = unnamed + 1 end end
      if unnamed > 0 then
        ImGui.Text(ctx, string.format("Recognising %d takes...", unnamed))
        recognising = true
      else
        recognising = false
      end
    end

    ImGui.Separator(ctx)

    -- Arrow keys move the selection wherever focus is, so the hands never have
    -- to leave the filter box.
    if ImGui.IsKeyPressed(ctx, ENUM.Key_DownArrow) then
      selected = math.min(#view, selected + 1); query = ""
      if view[selected] then seek_and_play(view[selected]) end
    elseif ImGui.IsKeyPressed(ctx, ENUM.Key_UpArrow) then
      selected = math.max(1, selected - 1); query = ""
      if view[selected] then seek_and_play(view[selected]) end
    end

    local row = view[selected]

    -- Left: the takes. Right: what to do with the selected one. Reserving the
    -- bottom strip keeps the action buttons on screen however long the list is.
    ImGui.BeginGroup(ctx)
    if ImGui.BeginChild(ctx, "takes", -360, -60) then
      for i, r in ipairs(view) do
        local marker = (i == selected) and ">" or " "
        local shown
        if r.song then
          -- A star flags a name nobody has looked at yet. The fill is right far
          -- more often than not, so the mark is a prompt to skim rather than a
          -- warning -- but an unreviewed name should never be indistinguishable
          -- from one somebody chose.
          shown = (r.auto and "* " or "") .. naming.region_name(r)
        elseif r.cleared then
          shown = "-> " .. placeholder_name(i)
        elseif r.original and r.original ~= "" then
          -- A region carrying the tuner's "Take 3" placeholder has a name but
          -- no song. Show it, but never let it read as named.
          shown = "? " .. r.original
        else
          shown = "? (unnamed)"
        end
        if ImGui.Selectable(ctx, string.format("%s %2d  %9s  %5.0fs  %s",
          marker, i, mmss(r.start), r.stop - r.start, shown), i == selected) then
          selected = i
          query = ""
          seek_and_play(r)
        end
      end
      ImGui.EndChild(ctx)
    end
    if row then
      if ImGui.Button(ctx, "Clear this name") then clear_row(row) end
      ImGui.SameLine(ctx)
    end
    -- Scoped to what is shown, like everything else here: with many rehearsals
    -- in one project, clearing every region in the file is never the intent.
    if ImGui.Button(ctx, "Clear all shown") then
      local n = 0
      for _, r in ipairs(view) do
        if r.song or (r.original and r.original ~= "") then
          clear_row(r)
          n = n + 1
        end
      end
      status = string.format(
        "%d name%s staged for reset to Take N - Apply to write, Reload to discard",
        n, n == 1 and "" or "s")
    end
    if row and row.cleared then
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "(cleared on Apply)")
    end
    ImGui.EndGroup(ctx)

    ImGui.SameLine(ctx)

    ImGui.BeginGroup(ctx)
    if ImGui.BeginChild(ctx, "detail", 0, -34) then
      if row then
        ImGui.Text(ctx, string.format("Take %d of %d", selected, #view))
        if row.auto then
          ImGui.Text(ctx, string.format(
            "* filled in automatically as \"%s\" -- Enter or click to confirm",
            row.song))
        end
        ImGui.Text(ctx, string.format("%s   %.0f s", mmss(row.start), row.stop - row.start))
        ImGui.Text(ctx, row.song or "(no song yet)")
        ImGui.Separator(ctx)

        if focus_filter then ImGui.SetKeyboardFocusHere(ctx); focus_filter = false end
        local changed, q = ImGui.InputText(ctx, "filter", query)
        if changed then query = q end

        -- With no filter typed, offer the recogniser's ranking instead of the
        -- whole repertoire. Typing anything overrides it -- the guess is a
        -- starting point, never a decision.
        local hits, from_guess = songs_lib.filter(songs, query), false
        if query == "" and row.guesses and #row.guesses > 0 then
          local ranked = {}
          for _, guess in ipairs(row.guesses) do
            ranked[#ranked + 1] =
              { title = guess.song, score = guess.score, margin = guess.margin }
          end
          hits, from_guess = ranked, true
        end

        -- Confidence is how far the winner is clear of the runner-up, as a
        -- FRACTION of the runner-up rather than an absolute gap. Scores all sit
        -- high and close together -- 0.96 against 0.94 is a rout, 0.99 against
        -- 0.99 a coin toss -- so an absolute floor pre-selects wrong answers as
        -- readily as right ones. The recogniser computes the ratio and sends it
        -- as `margin`; over held-out takes every correct call led by at least
        -- 11%, and the default sits just under that.
        --
        -- The same threshold that decides whether recognition fills the name in
        -- by itself. Below it nothing is pre-selected at all: a blank field is
        -- quicker to deal with than a plausible wrong answer somebody has to
        -- notice and undo.
        local confident = false
        if from_guess and hits[1] and hits[1].margin then
          confident = hits[1].margin >= min_margin()
        end

        -- Enter accepts the top match and jumps to the next unnamed take: type
        -- two letters, press Enter, repeat.
        if ImGui.IsKeyPressed(ctx, ENUM.Key_Enter)
          or ImGui.IsKeyPressed(ctx, ENUM.Key_KeypadEnter) then
          -- Enter takes the top match only when it is either typed or
          -- confident. An unconfident guess needs a deliberate click.
          --
          -- Testing the query rather than `not from_guess` matters: with an
          -- empty filter the hit list is the WHOLE repertoire, and a take the
          -- recogniser never saw carries no guess to make `from_guess` true --
          -- so the old condition held, and Enter silently named the take
          -- whatever song happened to sort first.
          if hits[1] and (query ~= "" or (from_guess and confident)) then
            row.song = hits[1].title
            row.cleared = nil
            row.auto = nil
            naming.renumber(view)
            query = ""
            local next_row = unnamed_after(selected + 1)
            if next_row then
              selected = next_row
              seek_and_play(view[selected])
            end
            focus_filter = true
          end
        end

        -- No cap: the pane scrolls, and a fixed limit silently hid every song
        -- past the tenth whenever the filter was empty.
        if from_guess then
          ImGui.Text(ctx, confident and "Suggested:" or "Suggested (low confidence):")
        end

        for i, song in ipairs(hits) do
          local marker = (i == 1 and (not from_guess or confident)) and "> " or "  "
          -- Scores cluster near the top of their range and say little on their
          -- own, so the lead over the runner-up is shown instead of leaving the
          -- reader to subtract two numbers that differ in the third decimal.
          local shown
          if song.margin then
            shown = string.format("%s%s  %d%% clear", marker, song.title,
              math.floor(song.margin * 100 + 0.5))
          elseif song.score then
            shown = string.format("%s%s  %.2f", marker, song.title, song.score)
          else
            shown = marker .. song.title
          end
          if ImGui.Selectable(ctx, shown, i == 1 and (not from_guess or confident)) then
            row.song = song.title
            row.cleared = nil
            row.auto = nil
            naming.renumber(view)
            query = ""
          end
        end

        if query ~= "" and #hits == 0 then
          if ImGui.Button(ctx, 'Add "' .. query .. '" as a new song') then
            local added = songs_lib.add(songs, query)
            row.song = added.title
            row.auto = nil
            row.cleared = nil
            naming.renumber(view)
            query = ""
          end
        end

        ImGui.Separator(ctx)

        local note_changed, note = ImGui.InputText(ctx, "note", row.note or "")
        if note_changed then
          row.note = note ~= "" and note or nil
          naming.renumber(view)
        end
        ImGui.Text(ctx, "blank = take number")
      elseif #rows == 0 then
        ImGui.Text(ctx, "No regions in this project.")
        ImGui.Text(ctx, "Create some with the tuning panel.")
      else
        ImGui.Text(ctx, "No regions match the current filters.")
      end
      ImGui.EndChild(ctx)
    end
    ImGui.EndGroup(ctx)

    -- Clear sits with the list because it acts on the selected row. These act
    -- on the whole panel, so they get their own bar across the bottom.
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Apply names to regions") then apply_names() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reload") then
      load_rows(); rebuild_view(); status = "Reloaded"
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Stop") then reaper.OnStopButton() end

    ImGui.End(ctx)
  end

  if open then reaper.defer(frame) end
end

reaper.defer(frame)
