local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local Client = require "socket_client"
local parser = require "packet_parser"

local ctrl_client = nil
local energy_client = nil
local spin_code = 0

local function get_next_spin()
  spin_code = (spin_code + 1) & 0xFF
  return spin_code
end

-- [Control 패킷 수신 처리]
local function on_ctrl_packet(driver, raw_pkt)
  local res = parser.parse_control_packet(raw_pkt)
  if not res then return end

  if res.kind == "thermostat" then
    local dni = string.format("bestin-thermo-%d", res.room)
    local dev = driver:get_device_by_dni(dni)
    if dev then
      dev:emit_event(capabilities.temperatureMeasurement.temperature({ value = res.current_temp, unit = "C" }))
      dev:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = res.target_temp, unit = "C" }))
      local mode = res.is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off()
      dev:emit_event(mode)
    end
  end
end

-- [Energy 패킷 수신 처리]
local function on_energy_packet(driver, raw_pkt)
  local res = parser.parse_energy_packet(raw_pkt)
  if not res then return end

  if res.kind == "light" then
    for l_idx, state in ipairs(res.states) do
      local dni = string.format("bestin-light-%d-%d", res.room, l_idx)
      local dev = driver:get_device_by_dni(dni)
      if dev then
        dev:emit_event(state and capabilities.switch.switch.on() or capabilities.switch.switch.off())
      end
    end
  elseif res.kind == "outlet" then
    for o_idx, state in ipairs(res.states) do
      local dni = string.format("bestin-outlet-%d-%d", res.room, o_idx)
      local dev = driver:get_device_by_dni(dni)
      if dev then
        dev:emit_event(state and capabilities.switch.switch.on() or capabilities.switch.switch.off())
        if res.power then
          dev:emit_event(capabilities.powerMeter.power({ value = res.power, unit = "W" }))
        end
      end
    end
  end
end

-- [장치 설정(Preferences) 반영 및 소켓 연결/갱신]
local function apply_preferences(driver, device)
  local prefs = device.preferences or {}
  local ctrl_ip = prefs.ctrlIp
  local ctrl_port = prefs.ctrlPort or 8899
  local energy_ip = prefs.energyIp
  local energy_port = prefs.energyPort or 8899

  log.info(string.format("새 설정 반영: Control(%s:%s), Energy(%s:%s)",
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

-- [명령 핸들러: 조명/콘센트]
local function handle_switch(driver, device, command)
  local is_on = (command.command == "on")
  local dni = device.device_network_id

  local l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)")
  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), is_on, get_next_spin())
    energy_client:send(pkt)
    device:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)")
  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), is_on, get_next_spin())
    energy_client:send(pkt)
    device:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
    return
  end
end

-- [명령 핸들러: 난방 희망온도]
local function handle_setpoint(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local target_temp = command.args.setpoint
  if room and ctrl_client then
    local pkt = parser.build_thermostat_command(tonumber(room), true, target_temp, get_next_spin())
    ctrl_client:send(pkt)
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = target_temp, unit = "C" }))
  end
end

-- [명령 핸들러: 난방 모드 (heat/off)]
local function handle_thermostat_mode(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local is_on = (command.args.mode == "heat")
  if room and ctrl_client then
    local cur_setpoint = device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) or 22
    local pkt = parser.build_thermostat_command(tonumber(room), is_on, cur_setpoint, get_next_spin())
    ctrl_client:send(pkt)
    device:emit_event(is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off())
  end
end

local function device_init(driver, device)
  if device.device_network_id == "bestin-bridge-device" then
    apply_preferences(driver, device)
  end
end

local function info_changed(driver, device, event, args)
  if device.device_network_id == "bestin-bridge-device" then
    apply_preferences(driver, device)
  end
end

-- [Discovery Handler]
local function discovery_handler(driver, should_continue)
  log.info("Bestin Bridge 검색 시작 (Discovery Started)...")
  
  -- 브릿지 디바이스 메타데이터
  local bridge_metadata = {
    type = "LAN",
    device_network_id = "bestin-bridge-device",
    label = "Bestin Bridge",
    profile = "bestin-bridge",
    manufacturer = "Local",
    model = "Bestin-Dual-EW11",
    vendor_provided_label = "Bestin Bridge"
  }

  local dev, err = driver:try_create_device(bridge_metadata)
  if dev then
    log.info("Bestin Bridge 디바이스 생성 성공!")
  else
    log.warn("Bestin Bridge 생성 결과: " .. tostring(err))
  end
end

local bestin_driver = Driver("bestin-wallpad", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
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