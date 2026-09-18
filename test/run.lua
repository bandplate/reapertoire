package.path = "./?.lua;./?/init.lua;" .. package.path

local SUITES = {
  "test.timeline_test",
  "test.frames_test",
  "test.liveness_test",
  "test.detect_test",
  "test.presence_test",
  "test.config_test",
  "test.pipeline_test",
  "test.fixtures_test",
  "test.text_test",
  "test.time_test",
  "test.naming_test",
  "test.songs_test",
  "test.session_test",
  "test.manifest_test",
  "test.peaks_test",
  "test.peaks_test",
  "test.report_test",
  "test.probes_test",
}

local passed, failed = 0, 0

for _, suite_name in ipairs(SUITES) do
  local suite = require(suite_name)
  local names = {}
  for name in pairs(suite) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, err = pcall(suite[name])
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print(string.format("FAIL %s.%s\n     %s", suite_name, name, tostring(err)))
    end
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
