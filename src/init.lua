local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local Client = require "socket_client"
local parser = require "packet_parser"

local ctrl_client = nil
local energy_client = nil

local pending_energy_cmd = nil
local pending_ctrl_cmd = nil

-- 바이트 배열을 16진수 문자열로 변환 (공백 구분)
local function to_hex(raw_bytes)
  local hex = {}
  for i = 1, #raw_bytes do
    table.insert(hex, string.format("%02X", raw_bytes:byte(i)))
  end
  return table.concat(hex, " ")
end

-- [기기 탐색 및 생성]
local function find_or_create_device(driver, dni, label, profile)
  for _, dev in ipairs(driver:get_devices()) do
    if dev.device_network_id == dni then
      return dev
    end
  end

  log.info(string.format("새 장치 등록 시도: [%s] %s (Profile: %s)", dni, label, profile))
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

-- [Energy 패킷 수신: 조명, 콘센트 및 소비전력 원본 로그 출력]
local function on_energy_packet(driver, raw_pkt)
  if pending_energy_cmd and energy_client then
    local pkt = pending_energy_cmd
    pending_energy_cmd = nil
    energy_client:send(pkt)
    log.info("⚡ [Energy 슬롯 동기화 전송 완료]")
  end

  local res = parser.parse_energy_packet(raw_pkt)
  if not res then return end

  local hex_str = to_hex(raw_pkt)

  if res.kind == "energy_combined" then
    -- 1. 조명 상태 반영 + 원본 패킷 출력
    for idx, is_on in ipairs(res.lights) do
      local light_dni = string.format("bestin-light-v2-r%d-c%d", res.room, idx)
      local label = string.format("조명 %d번방 %d", res.room, idx)
      local dev = find_or_create_device(driver, light_dni, label, "bestin-light")
      if dev and dev.emit_event then
        dev:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
      end
    end

    -- 2. 콘센트 상태 및 전력 반영 + 원본 패킷 로그 매핑
    for idx, is_on in ipairs(res.outlets) do
      local outlet_dni = string.format("bestin-outlet-v2-r%d-c%d", res.room, idx)
      local label = string.format("콘센트 %d번방 %d", res.room, idx)
      local dev = find_or_create_device(driver, outlet_dni, label, "bestin-outlet")
      if dev and dev.emit_event then
        dev:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())

        local p = res.powers and res.powers[idx] or 0.0
        dev:emit_event(capabilities.powerMeter.power({ value = p, unit = "W" }))

        -- 콘센트 1번 로그에 30바이트 원본 패킷을 바로 확인 가능하도록 인포 출력
        if idx == 1 then
          log.info(string.format("📡 [%d번방 콘센트 상태수신] Raw: %s", res.room, hex_str))
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

-- [스위치 제어: ON]
local function handle_switch_on(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("👉 [제어: ON 요청] %s (%s)", device.label, dni))

  local l_room, l_idx = dni:match("bestin%-light%-v2%-r(%d+)%-c(%d+)")
  if not l_room then l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)") end

  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), true)
    log.warn(string.format("🚀 [조명 ON 송신] %s", to_hex(pkt)))
    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.on())
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-v2%-r(%d+)%-c(%d+)")
  if not o_room then o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)") end

  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), true)
    log.warn(string.format("🚀 [콘센트 ON 송신] %s", to_hex(pkt)))
    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.on())
    return
  end
end

-- [스위치 제어: OFF]
local function handle_switch_off(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("👉 [제어: OFF 요청] %s (%s)", device.label, dni))

  local l_room, l_idx = dni:match("bestin%-light%-v2%-r(%d+)%-c(%d+)")
  if not l_room then l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)") end

  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), false)
    log.warn(string.format("🚀 [조명 OFF 송신] %s", to_hex(pkt)))
    pending_energy_cmd = pkt
    energy_client:send(pkt)
    device:emit_event(capabilities.switch.switch.off())
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-v2%-r(%d+)%-c(%d+)")
  if not o_room then o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)") end

  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), false)
    log.warn(string.format("🚀 [콘센트 OFF 송신] %s", to_hex(pkt)))
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