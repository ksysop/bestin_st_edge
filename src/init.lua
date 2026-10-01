local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local socket = require "cosock.socket"
local Client = require "socket_client"
local parser = require "packet_parser"

local ctrl_client = nil
local energy_client = nil

-- 제어 명령 대기 큐 (동기화 전송용)
local pending_energy_cmd = nil
local pending_ctrl_cmd = nil

-- [기기 탐색 및 생성]
local function find_or_create_device(driver, dni, label, profile)
  for _, dev in ipairs(driver:get_devices()) do
    if dev.device_network_id == dni then
      return dev
    end
  end

  log.info(string.format("새 장치 등록 요청: [%s] %s", dni, label))
  local metadata = {
    type = "LAN",
    device_network_id = dni,
    label = label,
    profile = profile,
    manufacturer = "Bestin",
    model = "Bestin-SubDevice"
  }
  driver:try_create_device(metadata)
  return nil
end

-- [Control 패킷 수신: 난방]
local function on_ctrl_packet(driver, raw_pkt)
  -- 1. 대기 중인 난방 제어 명령이 있으면 라인 트래픽 감지 직후 즉시 송신
  if pending_ctrl_cmd and ctrl_client then
    local pkt = pending_ctrl_cmd
    pending_ctrl_cmd = nil
    ctrl_client:send(pkt)
    log.info("⚡ [Control 슬롯 동기화 전송 완료]")
  end

  local res = parser.parse_control_packet(raw_pkt)
  if not res then return end

  if res.kind == "thermostat" then
    local dni = string.format("bestin-thermo-%d", res.room)
    local dev = find_or_create_device(driver, dni, string.format("난방 %d번방", res.room), "bestin-thermostat")

    if dev and dev.emit_event then
      dev:emit_event(capabilities.thermostatMode.supportedThermostatModes({ "heat", "off" }))
      dev:emit_event(capabilities.temperatureMeasurement.temperature({ value = res.current_temp, unit = "C" }))
      dev:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = res.target_temp, unit = "C" }))
      local mode = res.is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off()
      dev:emit_event(mode)
    end
  end
end

-- [Energy 패킷 수신: 조명 및 콘센트]
local function on_energy_packet(driver, raw_pkt)
  -- 1. HA 동기화 방식: 조명 라인 패킷이 들어온 직후(월패드 쿼리 사이 빈 슬롯)에 대기 중인 제어 패킷 즉시 발출
  if pending_energy_cmd and energy_client then
    local pkt = pending_energy_cmd
    pending_energy_cmd = nil
    energy_client:send(pkt)
    log.info("⚡ [Energy 슬롯 동기화 전송 완료]")
  end

  local res = parser.parse_energy_packet(raw_pkt)
  if not res then return end

  if res.kind == "light" then
    for l_idx, state in ipairs(res.states) do
      local dni = string.format("bestin-light-%d-%d", res.room, l_idx)
      local dev = find_or_create_device(driver, dni, string.format("조명 %d-%d", res.room, l_idx), "bestin-light")

      if dev and dev.emit_event then
        dev:emit_event(state and capabilities.switch.switch.on() or capabilities.switch.switch.off())
      end
    end

  elseif res.kind == "outlet" then
    for o_idx, state in ipairs(res.states) do
      local dni = string.format("bestin-outlet-%d-%d", res.room, o_idx)
      local dev = find_or_create_device(driver, dni, string.format("콘센트 %d-%d", res.room, o_idx), "bestin-outlet")

      if dev and dev.emit_event then
        dev:emit_event(state and capabilities.switch.switch.on() or capabilities.switch.switch.off())
        if res.power then
          dev:emit_event(capabilities.powerMeter.power({ value = res.power, unit = "W" }))
        end
      end
    end
  end
end

-- [설정 변경 및 소켓 연결]
local function apply_preferences(driver, device)
  local prefs = device.preferences or {}
  local ctrl_ip = prefs.ctrlIp
  local ctrl_port = prefs.ctrlPort or 8899
  local energy_ip = prefs.energyIp
  local energy_port = prefs.energyPort or 8899

  log.info(string.format("설정 갱신: Control(%s:%s), Energy(%s:%s)",
    tostring(ctrl_ip), tostring(ctrl_port), tostring(energy_ip), tostring(energy_port)))

  if ctrl_client then ctrl_client:stop() end
  if energy_client then energy_client:stop() end

  ctrl_client = Client.new("Control", function(raw) on_ctrl_packet(driver, raw) end)
  ctrl_client:update_endpoint(ctrl_ip, ctrl_port)
  ctrl_client:start()

  energy_client = Client.new("Energy", function(raw) on_energy_packet(driver, raw) end)
  energy_client:update_endpoint(energy_ip, energy_port)
  energy_client:start()
end

-- [스위치 제어 핸들러: ON]
local function handle_switch_on(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("👉 [제어: ON 요청] %s (%s)", device.label, dni))

  local l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)")
  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), true)
    local hex = {}
    for i = 1, #pkt do table.insert(hex, string.format("%02X", pkt:byte(i))) end
    log.warn(string.format("🚀 [조명 ON 대기열 등록] %s", table.concat(hex, " ")))

    -- 즉시 무작정 쏘지 않고, 라인 패킷 감지 순간(수 ms 이내) 즉시 전송되도록 대기열 설정
    pending_energy_cmd = pkt
    energy_client:send(pkt) -- 즉시 1회 시도 + 다음 패킷 슬롯에서 확정 전송
    device:emit_event(capabilities.switch.switch.on())
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)")
  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), true)
    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.on())
    return
  end
end

-- [스위치 제어 핸들러: OFF]
local function handle_switch_off(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("👉 [제어: OFF 요청] %s (%s)", device.label, dni))

  local l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)")
  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), false)
    local hex = {}
    for i = 1, #pkt do table.insert(hex, string.format("%02X", pkt:byte(i))) end
    log.warn(string.format("🚀 [조명 OFF 대기열 등록] %s", table.concat(hex, " ")))

    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.off())
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)")
  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), false)
    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.off())
    return
  end
end

-- [난방 제어 핸들러]
local function handle_setpoint(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local target_temp = command.args.setpoint
  log.info(string.format("👉 [난방 온도] %s -> %.1f°C", device.label, target_temp))

  if room and ctrl_client then
    local cur_mode = device:get_latest_state("main", capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode.NAME)
    local is_on = (cur_mode == "heat")
    local pkt = parser.build_thermostat_command(tonumber(room), is_on, target_temp)
    pending_ctrl_cmd = pkt
    ctrl_client:send(pkt)
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = target_temp, unit = "C" }))
  end
end

local function handle_thermostat_mode(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local mode = command.args.mode
  local is_on = (mode == "heat")
  log.info(string.format("👉 [난방 모드] %s -> %s", device.label, mode))

  if room and ctrl_client then
    local cur_setpoint = device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) or 22
    local pkt = parser.build_thermostat_command(tonumber(room), is_on, cur_setpoint)
    pending_ctrl_cmd = pkt
    ctrl_client:send(pkt)
    device:emit_event(is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off())
  end
end

local function handle_refresh(driver, device, command)
  log.info(string.format("새로고침: %s", device.label))
end

local function discovery_handler(driver, should_continue)
  log.info("=== 주변 검색 실행 ===")
  local bridge_metadata = {
    type = "LAN",
    device_network_id = "bestin-bridge-device",
    label = "Bestin Bridge",
    profile = "bestin-bridge",
    manufacturer = "Local",
    model = "Bestin-Dual-EW11",
    vendor_provided_label = "Bestin Bridge"
  }
  driver:try_create_device(bridge_metadata)
end

local bestin_driver = Driver("bestin-wallpad", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = function(driver, device)
      if device.device_network_id:find("bestin%-thermo") then
        device:emit_event(capabilities.thermostatMode.supportedThermostatModes({ "heat", "off" }))
      end
      if device.device_network_id == "bestin-bridge-device" then
        apply_preferences(driver, device)
      end
    end,
    doConfigure = function(driver, device)
    end,
    infoChanged = function(driver, device, event, args)
      if device.device_network_id == "bestin-bridge-device" then
        apply_preferences(driver, device)
      end
    end
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handle_setpoint,
    },
    [capabilities.thermostatMode.ID] = {
      [capabilities.thermostatMode.commands.setThermostatMode.NAME] = handle_thermostat_mode,
    }
  }
})

bestin_driver:run()