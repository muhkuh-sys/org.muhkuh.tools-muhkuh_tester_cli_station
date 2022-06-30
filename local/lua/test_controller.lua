local class = require 'pl.class'
local TestController = class()

function TestController:_init(tLog, tLogTest, tLogKafka, tLogLocal, atTestFolder)
  self.tLog = tLog
  self.tLogTest = tLogTest

  self.atTestFolder = atTestFolder

  self.I2C = require('periphery').I2C
  self.json = require 'dkjson'
  self.pl = require'pl.import_into'()
  self.ProcessZmq = require 'process_zmq'
  self.uv = require 'lluv'

  self.ucI2CAddr_Out = 32
  self.ucI2CAddr_In = 56

  -- Poll the insert signal every 250ms.
  self.uiPollInsertInterval = 250

  -- The bit values for the input signals.
  self.I2C_Input = {
    INSERT = 0x01
  }
  -- The bit values for the output signals.
  self.I2C_Output = {
    STATION_READY      = 0x01,
    STATION_ERROR      = 0x02,
    TEST_RUNNING       = 0x04,
    TEST_RESULT_OK     = 0x08,
    TEST_RESULT_ERROR  = 0x10,
    ACTIVATE_DUT_POWER = 0x80
  }
  self.tLastTestResult = nil

  self.m_testProcess = nil

  self.m_logKafka = tLogKafka
  self.m_logLocal = tLogLocal
  self.m_logConsumer = { tLogLocal }

  self.m_zmqContext = nil
  self.m_zmqSocket = nil
  self.m_zmqPort = nil
  self.m_zmqServerAddress = nil
  self.m_zmqPoll = nil

  self.STATE_IDLE = 0
  self.STATE_RUNNING = 1
  self.STATE_FINISHED = 2
  self.STATE_DUT_REMOVED = 3
  self.STATE_ERROR = 4
  self.m_tState = self.STATE_IDLE
end



function TestController:__startTest(tMessage)
  local tLog = self.tLog
  local pl = self.pl
  local uv = self.uv

  local tStartResult
  -- Get the test ID.
  local strTestID = tMessage.testid
  if strTestID==nil then
    tLog.error('The command has no "testid" attribute.')
  else
    local strTestPath = self.atTestFolder[strTestID]
    if strTestPath==nil then
      tLog.error('The request has an unknown test ID.')
    else
      local strTestXmlFile = pl.path.join(strTestPath, 'tests.xml')

      local TestDescription = require 'test_description'
      local tTestDescription = TestDescription(tLog)
      local tResult = tTestDescription:parse(strTestXmlFile)
      if tResult~=true then
        tLog.error('Test "%s" has an invalid test description.', tostring(strTestXmlFile))
      else
        -- Set the new system attributes.
        local tSystemAttributes = {
          hostname = uv.os_gethostname(),
          test = {
            title = tTestDescription:getTitle(),
            subtitle = tTestDescription:getSubtitle()
          }
        }
        self.m_logKafka:setSystemAttributes(tSystemAttributes)

        -- Detect the LUA interpreter. Try LUA5.4 first, then fallback to LUA5.1 .
        local strExeSuffix = ''
        if pl.path.is_windows then
          strExeSuffix = '.exe'
        end
        local strInterpreterPath = pl.path.abspath(pl.path.join(strTestPath, 'lua5.4'..strExeSuffix))
        tLog.debug('Looking for the LUA5.4 interpreter in "%s".', strInterpreterPath)
        if pl.path.exists(strInterpreterPath)~=strInterpreterPath then
          strInterpreterPath = pl.path.abspath(pl.path.join(strTestPath, 'lua5.1'..strExeSuffix))
          tLog.debug('Looking for the LUA5.1 interpreter in "%s".', strInterpreterPath)
          if pl.path.exists(strInterpreterPath)~=strInterpreterPath then
            tLog.error('No LUA interpreter found in the test folder "%s".', strTestPath)
            strInterpreterPath = nil
          end
        end
        if strInterpreterPath~=nil then
          -- Create the command.
          local astrCmd = {'system.lua', '--server-port', '${ZMQPORT}'}
          local tParameter = tMessage.parameter
          if tParameter~=nil then
            if type(tParameter)=='table' then
              for _, strParameter in ipairs(tParameter) do
                table.insert(astrCmd, strParameter)
              end
            else
              table.insert(astrCmd, tostring(tParameter))
            end
          end

          -- Create a new ZMQ process.
          local tTestProc = self.ProcessZmq(tLog, self.tLogTest, strInterpreterPath, astrCmd, strTestPath)
          -- Set the current log consumer.
          for _, tLogConsumer in ipairs(self.m_logConsumer) do
            tTestProc:addLogConsumer(tLogConsumer)
          end

          -- Run the test and set this as the consumer for the terminate message.
          tTestProc:run(self.onTestTerminate, self)

          self.m_testProcess = tTestProc

          tStartResult = true
        end
      end
    end
  end

  return tStartResult
end



function TestController:addLogConsumer(tLogConsumer)
  table.insert(self.m_logConsumer, tLogConsumer)
end



function TestController:onCancelAll()
  local tLog = self.tLog

  tLog.info('Cancel!')

  -- Swith all LEDs off.
  self.tI2c:transfer(self.ucI2CAddr_Out, {{0xff}})

  -- Stop the poll timer.
  local tTimer = self.tPollSwitchTimer
  if tTimer~=nil then
    tTimer:stop()
  end

  -- Stop the signal handler.
  local tHandler = self.tSignalHandler
  if tHandler~=nil then
    tHandler:stop()
  end
end



function TestController:onPollSwitchTimer(tTimer)
  -- Prepare a message for the read operation.
  local tMsgR = {{ 0x00, flags = self.I2C.I2C_M_RD }}

  self.tI2c:transfer(self.ucI2CAddr_In, tMsgR)
  local ucData = tMsgR[1][1] ~ 0xff
  -- A DUT is inserted if the "INSERT" bit is set.
  local fIsInserted = ((ucData & self.I2C_Input.INSERT)~=0)

  local tState = self.m_tState
  if tState==self.STATE_IDLE then
    -- The station is idle. If a module is inserted, start a new test.
    if fIsInserted==true then
      -- Clear the last test result.
      self.tLastTestResult = nil

      -- Set the state to "running" and turn on DUT power.
      self.m_tState = self.STATE_RUNNING
      self:setState{'TEST_RUNNING', 'ACTIVATE_DUT_POWER'}
      local tResult = self:__startTest{
        testid='19110003',
        parameter={
          '-v', 'debug',
          '--parameter', 'system:manufacturer=1',
          '--parameter', 'system:devicenr=1911000',
          '--parameter', 'system:serial=0',
          '--parameter', 'system:hwrev=3'
        }
      }
      if tResult~=true then
        self.m_tState = self.STATE_ERROR
        self:setState('STATION_ERROR')
      end
    end

  elseif tState==self.STATE_RUNNING then
    -- If the test is running and the module is removed, cancel the test.
    if fIsInserted~=true then
      self.m_tState = self.STATE_DUT_REMOVED
      -- Switch off the power, the test will finish soon.
      -- NOTE: Do not show an error yet, stay in the "running" state until the test terminates.
      self:setState('TEST_RUNNING')
    end

  elseif tState==self.STATE_FINISHED then
    -- If the test is finished and the module is removed, return to "idle" state.
    if fIsInserted~=true then
      self.m_tState = self.STATE_IDLE
      self:setState{'STATION_READY', self.tLastTestResult}
    end
  end

  tTimer:again(self.uiPollInsertInterval)
end



function TestController:setState(tState)
  local tLog = self.tLog

  if type(tState)~='table' then
    tState = { tostring(tState) }
  end

  local ucState = 0
  local I2C_Output = self.I2C_Output
  for _, strState in ipairs(tState) do
    local ucBit = I2C_Output[strState]
    if ucBit==nil then
      ucState = nil
      break
    else
      ucState = ucState | ucBit
    end
  end
  -- Get the requested state.
  if ucState==nil then
    tLog.error('setState called with invalid state: %s', table.concat(tState, ','))
  else
    local ucInv = ucState ~ 0xff
    self.tI2c:transfer(self.ucI2CAddr_Out, {{ucInv}} )
  end
end



function TestController:run()
  local I2C = self.I2C
  local tLog = self.tLog
  local uv  = require 'lluv'

  -- Open i2c-1 controller
  local strI2cDevice = '/dev/i2c-1'
  local tOpenResult, tI2c = pcall(I2C, strI2cDevice)
  if tOpenResult~=true then
    tLog.error('Failed to open I2C device %s: %s', strI2cDevice, tostring(tI2c))
  else
    self.tI2c = tI2c

    -- Set the state to "STATION_READY".
    self:setState('STATION_READY')

    local this = self
    -- Register a signal handler to clean up.
    self.tSignalHandler = uv.signal():start(uv.SIGINT, function()
      this:onCancelAll()
    end)
    -- Start a timer to poll the state of the "inserted" signal.
    self.tPollSwitchTimer = uv.timer():start(self.uiPollInsertInterval, function(tTimer)
      this:onPollSwitchTimer(tTimer)
    end)
  end
end



function TestController:onTestTerminate()
  local tLog = self.tLog
  local tLogLocal = self.m_logLocal

  tLog.info('onTestTerminate')

  -- The process has terminated.
  self.m_testProcess = nil

  local tTestResult
  local tState = self.m_tState
  -- Did the tester process terminate in "STATE_RUNNING"?
  -- -> This is a normal termination of the test.
  if tState==self.STATE_RUNNING then
    -- Get the test result.
    tTestResult = tLogLocal:getResult()

  -- Did the tester process terminate in "STATE_DUT_REMOVED"?
  -- -> The DUT was removed before the test finished. The DUT power was switched off as a result.
  elseif tState==self.STATE_DUT_REMOVED then
    -- A removed DUT always results in an error.
    tTestResult = false
  end

  -- The test is not running anymore.
  self.m_tState = self.STATE_FINISHED

  local strState
  if tTestResult==true then
    strState = 'TEST_RESULT_OK'
  else
    strState = 'TEST_RESULT_ERROR'
  end
  self:setState(strState)
  self.tLastTestResult = strState

  -- Run a complete garbage collection.
  collectgarbage('collect')
end


function TestController:onCancel()
  local tLog = self.tLog

  tLog.info('Cancel: no test running.')
end


function TestController:shutdown()
  local tTestProcess = self.m_testProcess
  if tTestProcess~=nil then
    tTestProcess:shutdown()
  end
end


return TestController
