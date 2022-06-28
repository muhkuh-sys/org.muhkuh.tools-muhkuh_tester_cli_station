local t = ...

-- Filter the testcase XML with the VCS ID.
t:filterVcsId('../..', '../../muhkuh_tester_cli_station.xml', 'muhkuh_tester_cli_station.xml')

return true
