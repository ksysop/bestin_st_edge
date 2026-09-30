local parser = {}

-- 베스틴 패킷 체크섬 계산
function parser.calculate_checksum(bytes)
  local sum = 3
  for i = 1, #bytes do
    sum = ((bytes[i] ~ sum) + 1) & 0xFF
  end
  return sum
end

-- ========================================================
-- [Energy 버스] 조명 / 콘센트
-- ========================================================

-- 조명 제어 패킷 생성 (헤더 0x31)
function parser.build_light_command(room_idx, light_idx, is_on, spin)
  spin = spin or 0
  local pkt = {
    0x02, 0x31, 0x0D, 0x01,
    spin & 0xFF,
    room_idx & 0x0F,
    0x81, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00
  }
  pkt[11] = is_on and (1 << (light_idx - 1)) or 0x00
  pkt[12] = 0x04
  pkt[13] = parser.calculate_checksum({table.unpack(pkt, 1, 12)})
  return string.char(table.unpack(pkt))
end

-- 콘센트 제어 패킷 생성 (헤더 0x32)
function parser.build_outlet_command(room_idx, outlet_idx, is_on, spin)
  spin = spin or 0
  local pkt = {
    0x02, 0x32, 0x0D, 0x01,
    spin & 0xFF,
    room_idx & 0x0F,
    0x81, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00
  }
  pkt[11] = is_on and (1 << (outlet_idx - 1)) or 0x00
  pkt[12] = 0x04
  pkt[13] = parser.calculate_checksum({table.unpack(pkt, 1, 12)})
  return string.char(table.unpack(pkt))
end

-- Energy 라인 수신 패킷 파싱
function parser.parse_energy_packet(raw_bytes)
  if #raw_bytes < 4 or raw_bytes:byte(1) ~= 0x02 then return nil end
  local header = raw_bytes:byte(2)
  local len = raw_bytes:byte(3)
  if #raw_bytes < len then return nil end

  local bytes = {raw_bytes:byte(1, len)}
  if parser.calculate_checksum({table.unpack(bytes, 1, len - 1)}) ~= bytes[len] then
    return nil
  end

  -- 조명 상태 수신 (0x31)
  if header == 0x31 and len >= 10 then
    local room = bytes[6] & 0x0F
    local mask = bytes[8] or 0
    local states = {}
    for i = 1, 4 do
      states[i] = ((mask >> (i - 1)) & 0x01) == 1
    end
    return { kind = "light", room = room, states = states }
  end

  -- 콘센트 상태 & 소비전력 수신 (0x32)
  if header == 0x32 and len >= 12 then
    local room = bytes[6] & 0x0F
    local mask = bytes[8] or 0
    local states = {}
    for i = 1, 2 do
      states[i] = ((mask >> (i - 1)) & 0x01) == 1
    end
    local power = ((bytes[10] << 8) | bytes[11]) / 10.0
    return { kind = "outlet", room = room, states = states, power = power }
  end

  return nil
end

-- ========================================================
-- [Control 버스] 난방
-- ========================================================

-- 난방 제어 패킷 생성 (헤더 0x28)
function parser.build_thermostat_command(room_idx, is_on, target_temp, spin)
  spin = spin or 0
  local pkt = {
    0x02, 0x28, 0x0E, 0x12,
    spin & 0xFF,
    room_idx & 0x0F,
    is_on and 0x01 or 0x02,
    math.floor(target_temp),
    math.floor((target_temp % 1) * 10),
    0x00, 0x00, 0x00, 0x00, 0x00
  }
  pkt[14] = parser.calculate_checksum({table.unpack(pkt, 1, 13)})
  return string.char(table.unpack(pkt))
end

-- Control 라인 수신 패킷 파싱
function parser.parse_control_packet(raw_bytes)
  if #raw_bytes < 4 or raw_bytes:byte(1) ~= 0x02 then return nil end
  local header = raw_bytes:byte(2)
  local len = raw_bytes:byte(3)
  if #raw_bytes < len then return nil end

  local bytes = {raw_bytes:byte(1, len)}
  if parser.calculate_checksum({table.unpack(bytes, 1, len - 1)}) ~= bytes[len] then
    return nil
  end

  -- 난방 상태 수신 (0x28)
  if header == 0x28 and len >= 10 then
    local room = bytes[6] & 0x0F
    local is_on = (bytes[7] == 0x01)
    local cur_temp = bytes[8] + (bytes[9] / 10.0)
    local target_temp = bytes[10] + (bytes[11] / 10.0)
    return {
      kind = "thermostat",
      room = room,
      is_on = is_on,
      current_temp = cur_temp,
      target_temp = target_temp
    }
  end

  return nil
end

return parser