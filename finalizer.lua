local t = ...
local strDistId = t:get_platform()

-- Copy all additional files.
t:install{
  ['local/cli_station.lua']              = '${install_base}/',
  ['local/server.cfg.template']          = '${install_base}/',
  ['local/server.cfg.btm8']              = '${install_base}/',

  ['local/lua/configuration_file.lua']  = '${install_lua_path}/',
  ['local/lua/log-kafka.lua']           = '${install_lua_path}/',
  ['local/lua/log-local.lua']           = '${install_lua_path}/',
  ['local/lua/process.lua']             = '${install_lua_path}/',
  ['local/lua/process_zmq.lua']         = '${install_lua_path}/',
  ['local/lua/test_controller.lua']     = '${install_lua_path}/',
  ['local/lua/test_description.lua']    = '${install_lua_path}/',

  ['local/linux/run_server']            = '${install_base}/',
  ['local/linux/systemd/muhkuh_cli_station.service'] = '${install_base}/systemd/',

  ['${report_path}']                    = '${install_base}/.jonchki/'
}

t:createPackageFile()
t:createHashFile()
t:createArchive('${install_base}/../../../${default_archive_name}', 'native')

return true
