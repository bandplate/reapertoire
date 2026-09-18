-- lib/probes.lua
-- Names for cached recognition probes.
--
-- Rendering a probe per take every time the naming panel opens cost tens of
-- seconds for audio that had not changed. A probe is reusable exactly as long
-- as the key below is: the same region, the same span, the same format. FX are
-- not part of it because probes render with FX bypassed.
--
-- What the key cannot see is the audio under an unmoved region being edited --
-- a re-recorded or nudged item. The probe would be stale until the cache is
-- cleared, which on /tmp is the next reboot. It only feeds a suggestion that a
-- person confirms, so that is accepted rather than engineered around.

local M = {}

-- 32-bit FNV-1a, for folding the render format blob -- base64, so full of
-- characters a filename should not carry -- into eight hex digits.
local function fnv1a(s)
  local hash = 0x811c9dc5
  for i = 1, #s do
    hash = hash ~ s:byte(i)
    hash = (hash * 0x01000193) & 0xffffffff
  end
  return hash
end

local function ms(seconds)
  return math.floor(seconds * 1000 + 0.5)
end

-- A filename-safe key, or nil when there is nothing stable to key on. A region
-- without a GUID -- some REAPER builds will not report one -- is rendered every
-- time rather than cached under a key that could be shared by accident.
function M.key(guid, start, stop, format)
  local hex = tostring(guid or ""):gsub("[{}%-]", ""):lower()
  if not hex:match("^%x+$") or not start or not stop then return nil end
  return string.format("%s_%d_%d_%08x", hex, ms(start), ms(stop), fnv1a(format or ""))
end

return M
