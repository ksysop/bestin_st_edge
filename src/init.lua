local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local Client = require "socket_client"
local parser = require "packet_parser"

local ctrl_client = nil
local energy_client = nil

-- [1. 장치 고속 인덱싱 맵: O(1) 접근]
-- device_map[room] = { lights = { [1] = dev, [2] = dev }, outlets = { [1] = dev, [2] = dev }, thermo = dev }
local device_map = {}
local last_state_cache = {}

local function to_hex(raw_bytes)
  local hex = {}
  for i = 1, #raw_bytes do
    table.insert(hex, string.format("%02X", raw_bytes:byte(i)))
  end
  return table.concat(hex, " ")
end

-- [장치 등록 및 인덱싱 캐시 갱신]
local function register_device_to_map(device)
  local dni = device.device_network_id

  local l_room, l_idx = dni:match("bestin%-light%-v2%-r(%d+)%-c(%d+)")
  if l_room and l_idx then
    local r, idx = tonumber(l_room), tonumber(l_idx)
    device_map[r] = device_map[r] or { lights = {}, outlets = {} }
    device_map[r].lights[idx] = device
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-v2%-r(%d+)%-c(%d+)")
  if o_room and o_idx then
    local r, idx = tonumber(o_room), tonumber(o_idx)
    device_map[r] = device_map[r] or { lights = {}, outlets = {} }
    device_map[r].outlets[idx] = device
    return
  end

  local t_room = dni:match("bestin%-thermo%-(%d+)")
  if t_room then
    local r = tonumber(t_room)
    device_map[r] = device_map[r] or { lights = {}, outlets = {} }
    device_map[r].thermo = device
    return
  end
end

-- [기기 자동 생성 보조]
local function find_or_create_device(driver, dni, label, profile)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == dni then
      register_device_to_map(d)
      return d
    end
  end

  log.info(string.format("새 장치 등록 시도: [%s] %s", dni, label))
  driver:try_create_device({
    type = "LAN",
    device_network_id = dni,
    label = label,
    profile = profile,
    manufacturer = "Bestin",
    model = "Bestin-SubDevice"
  })
  return nil
end

-- [경량 Burst 송신]
local function burst_send(client, pkt)
  if not client then return end
  cosock.spawn(function()
    for i = 1, 3 do
      client:send(pkt)
      if i < 3 then cosock.socket.sleep(0.03) end
    end
  end, "burst_tx")
end

-- [Control 패킷 수신: 난방]
local function on_ctrl_packet(driver, raw_pkt)
  local res = parser.parse_control_packet(raw_pkt)
  if not res then return end

  if res.kind == "thermostat" then
    local r = res.room
    local dev = device_map[r] and device_map[r].thermo
    if not dev then
      dev = find_or_create_device(driver, string.format("bestin-thermo-%d", r), string.format("난방 %d번방", r), "bestin-thermostat")
    end

    if dev and dev.emit_event then
      local dni = dev.device_network_id
      last_state_cache[dni] = last_state_cache[dni] or {}
      local c = last_state_cache[dni]

      if c.temp ~= res.current_temp then
        c.temp = res.current_temp
        dev:emit_event(capabilities.temperatureMeasurement.temperature({ value = res.current_temp, unit = "C" }))
      end
      if c.setpoint ~= res.target_temp then
        c.setpoint = res.target_temp
        dev:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = res.target_temp, unit = "C" }))
      end
      if c.is_on ~= res.is_on then
        c.is_on = res.is_on
        dev:emit_event(capabilities.thermostatMode.supportedThermostatModes({ "heat", "off" }))
        dev:emit_event(res.is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off())
      end
    end
  end
end

-- [Energy 패킷 수신: 조명, 콘센트 및 소비전력 (고속 인덱싱)]
local function on_energy_packet(driver, raw_pkt)
  local res = parser.parse_energy_packet(raw_pkt)
  if not res then return end

  if res.kind == "energy_combined" then
    local r = res.room
    local r_devices = device_map[r]

    -- 1. 조명 상태 처리 ($O(1)$)
    for idx, is_on in ipairs(res.lights) do
      local dev = r_devices and r_devices.lights and r_devices.lights[idx]
      if not dev then
        local dni = string.format("bestin-light-v2-r%d-c%d", r, idx)
        dev = find_or_create_device(driver, dni, string.format("조명 %d번방 %d", r, idx), "bestin-light")
      end

      if dev and dev.emit_event then
        local dni = dev.device_network_id
        last_state_cache[dni] = last_state_cache[dni] or {}
        if last_state_cache[dni].switch ~= is_on then
          last_state_cache[dni].switch = is_on
          dev:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
        end
      end
    end

    -- 2. 콘센트 상태 및 실시간 소비전력 처리 ($O(1)$)
    for idx, is_on in ipairs(res.outlets) do
      local dev = r_devices and r_devices.outlets and r_devices.outlets[idx]
      if not dev then
        local dni = string.format("bestin-outlet-v2-r%d-c%d", r, idx)
        dev = find_or_create_device(driver, dni, string.format("콘센트 %d번방 %d", r, idx), "bestin-outlet")
      end

      if dev and dev.emit_event then
        local dni = dev.device_network_id
        last_state_cache[dni] = last_state_cache[dni] or {}
        local c = last_state_cache[dni]

        if c.switch ~= is_on then
          c.switch = is_on
          dev:emit_event(is_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
        end

        local p = (res.powers and res.powers[idx]) or 0.0
        if not c.power or math.abs(c.power - p) >= 0.2 then
          c.power = p
          dev:emit_event(capabilities.powerMeter.power({ value = p, unit = "W" }))
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

  device:emit_event(capabilities.switch.switch.on())

  local l_room, l_idx = dni:match("bestin%-light%-v2%-r(%d+)%-c(%d+)")
  if not l_room then l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)") end
  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), true)
    burst_send(energy_client, pkt)
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-v2%-r(%d+)%-c(%d+)")
  if not o_room then o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)") end
  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), true)
    burst_send(energy_client, pkt)
    return
  end
end

-- [스위치 제어: OFF]
local function handle_switch_off(driver, device, command)
  local dni = device.device_network_id
  log.info(string.format("👉 [제어: OFF 요청] %s (%s)", device.label, dni))

  device:emit_event(capabilities.switch.switch.off())

  local l_room, l_idx = dni:match("bestin%-light%-v2%-r(%d+)%-c(%d+)")
  if not l_room then l_room, l_idx = dni:match("bestin%-light%-(%d+)%-(%d+)") end
  if l_room and l_idx and energy_client then
    local pkt = parser.build_light_command(tonumber(l_room), tonumber(l_idx), false)
    burst_send(energy_client, pkt)
    return
  end

  local o_room, o_idx = dni:match("bestin%-outlet%-v2%-r(%d+)%-c(%d+)")
  if not o_room then o_room, o_idx = dni:match("bestin%-outlet%-(%d+)%-(%d+)") end
  if o_room and o_idx and energy_client then
    local pkt = parser.build_outlet_command(tonumber(o_room), tonumber(o_idx), false)
    burst_send(energy_client, pkt)
    return
  end
end

-- [난방 제어]
local function handle_setpoint(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local target_temp = command.args.setpoint
  log.info(string.format("👉 [난방 온도] %s -> %.1f°C", device.label, target_temp))

  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = target_temp, unit = "C" }))
  if room and ctrl_client then
    local cur_mode = device:get_latest_state("main", capabilities.thermostatMode.ID, capabilities.thermostatMode.thermostatMode.NAME)
    local is_on = (cur_mode == "heat")
    local pkt = parser.build_thermostat_command(tonumber(room), is_on, target_temp)
    burst_send(ctrl_client, pkt)
  end
end

local function handle_thermostat_mode(driver, device, command)
  local room = device.device_network_id:match("bestin%-thermo%-(%d+)")
  local mode = command.args.mode
  local is_on = (mode == "heat")
  log.info(string.format("👉 [난방 모드] %s -> %s", device.label, mode))

  device:emit_event(is_on and capabilities.thermostatMode.thermostatMode.heat() or capabilities.thermostatMode.thermostatMode.off())
  if room and ctrl_client then
    local cur_setpoint = device:get_latest_state("main", capabilities.thermostatHeatingSetpoint.ID, capabilities.thermostatHeatingSetpoint.heatingSetpoint.NAME) or 22
    local pkt = parser.build_thermostat_command(tonumber(room), is_on, cur_setpoint)
    burst_send(ctrl_client, pkt)
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
      register_device_to_map(device)
      if device.device_network_id:find("bestin%-thermo") then
        device:emit_event(capabilities.thermostatMode.supportedThermostatModes({ "heat", "off" }))
      end
      if device.device_network_id == "bestin-bridge-device" then
        apply_preferences(driver, device)
      end
    end,
    removed = function(driver, device)
      last_state_cache[device.device_network_id] = nil
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