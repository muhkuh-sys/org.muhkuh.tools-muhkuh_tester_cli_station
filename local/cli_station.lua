local uv  = require"lluv"
uv.poll_zmq = require "lluv.poll_zmq"

-- Set the logger level from the command line options.
local strLogLevel = 'debug'
local cLogWriter = require 'log.writer.filter'.new(
  strLogLevel,
  require 'log.writer.console'.new()
)
local cLogWriterSystem = require 'log.writer.prefix'.new('[System] ', cLogWriter)
local tLog = require "log".new(
  -- maximum log level
  "trace",
  cLogWriterSystem,
  -- Formatter
  require "log.formatter.format".new()
)
tLog.info('Start')


------------------------------------------------------------------------------
--
--  Try to read the configuration file.
--
local cConfigurationFile = require 'configuration_file'
local tConfiguration = cConfigurationFile.read(tLog)


local tLogKafka = require 'log-kafka'(tLog, tConfiguration.kafka_debugging)
-- Connect the log consumer to a broker.
local strKafkaBroker = tConfiguration.kafka_broker
if strKafkaBroker~=nil and strKafkaBroker~='' then
  local atKafkaOptions = {}
  local astrKafkaOptions = tConfiguration.kafka_options
  if astrKafkaOptions==nil then
    astrKafkaOptions = {}
  elseif type(astrKafkaOptions)=='string' then
    astrKafkaOptions = { astrKafkaOptions }
  end
  for _, strOption in ipairs(astrKafkaOptions) do
    local strKey, strValue = string.match(strOption, '([^=]+)=(.+)')
    if strKey==nil then
      tLog.error('Ignoring invalid Kafka option: %s', strOption)
    else
      local strOldValue = atKafkaOptions[strKey]
      if strOldValue~=nil then
        if strKey=='sasl.password' then
          tLog.warning('Not overwriting Kafka option "%s".', strKey)
        else
          tLog.warning(
            'Not overwriting Kafka option "%s" with the value "%s". Keeping the value "%s".',
            strKey,
            strValue,
            strOldValue
          )
        end
      else
        if strKey=='sasl.password' then
          tLog.debug('Setting Kafka option "%s" to ***hidden***.', strKey)
        else
          tLog.debug('Setting Kafka option "%s" to "%s".', strKey, strValue)
        end
        atKafkaOptions[strKey] = strValue
      end
    end
  end
  tLog.info('Connecting to kafka brokers: %s', strKafkaBroker)
  tLogKafka:connect(strKafkaBroker, atKafkaOptions)
else
  tLog.warning('Not connecting to any kafka brokers. The logs will not be saved.')
end

-- Create the local logger.
local tLogLocal = require 'log-local'()

-- Create a new log target for the test output.
local astrLogMessages = {}
local tLogTest = require "log".new(
  -- maximum log level
  'debug',
  function(fnFormat, strMessage, uiLevel, tDate)
    table.insert(astrLogMessages, string.format('%d,%s', uiLevel, fnFormat(strMessage, uiLevel, tDate)))
  end
)

-- Create a new test controller.
local TestController = require 'test_controller'
local tTestController = TestController(tLog, tLogTest, tLogKafka, tLogLocal, tConfiguration.atFolder)
tTestController:addLogConsumer(tLogKafka)

tTestController:run()

--[[
local function OnCancelAll()
  print('Cancel pressed!')
  tTestController:shutdown()
end
uv.signal():start(uv.SIGINT, OnCancelAll)
--]]

uv.run(debug.traceback)
