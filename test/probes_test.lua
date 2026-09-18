-- test/probes_test.lua
local h = require("test.helpers")
local probes = require("lib.probes")

local T = {}

local GUID = "{9C6799CD-AACF-2B42-8AB8-7D869CAF5F2A}"

function T.the_same_region_span_and_format_always_give_the_same_key()
  h.assert_eq(probes.key(GUID, 10.5, 200.25, "ZXZhdxgAAA=="),
              probes.key(GUID, 10.5, 200.25, "ZXZhdxgAAA=="))
end

function T.the_key_is_safe_to_use_as_a_filename()
  local key = probes.key(GUID, 10.5, 200.25, "ZXZhdxgAAA==")
  h.assert_eq(key:match("^[%w_]+$") ~= nil, true, key)
end

function T.moving_an_edge_invalidates_the_probe()
  -- Re-tuning a region changes the audio the probe stands for.
  h.assert_eq(probes.key(GUID, 10.5, 200.25, "f") ~= probes.key(GUID, 10.5, 201.0, "f"), true)
  h.assert_eq(probes.key(GUID, 10.5, 200.25, "f") ~= probes.key(GUID, 10.0, 200.25, "f"), true)
end

function T.a_sub_millisecond_wobble_does_not()
  -- Floats round-trip through REAPER; a take must not re-render over noise.
  h.assert_eq(probes.key(GUID, 10.5, 200.25, "f"), probes.key(GUID, 10.5000001, 200.2500002, "f"))
end

function T.a_different_probe_format_invalidates_the_probe()
  h.assert_eq(probes.key(GUID, 1, 2, "ZXZhdxgAAA==") ~= probes.key(GUID, 1, 2, "bXAzIAAAAA=="), true)
end

function T.another_region_at_the_same_span_gets_its_own_key()
  h.assert_eq(probes.key(GUID, 1, 2, "f")
    ~= probes.key("{D5E2FF98-BB7C-744F-9C78-0FAF43AC35E0}", 1, 2, "f"), true)
end

function T.no_guid_means_no_key_rather_than_a_shared_one()
  h.assert_eq(probes.key(nil, 1, 2, "f"), nil)
  h.assert_eq(probes.key("", 1, 2, "f"), nil)
end

return T
