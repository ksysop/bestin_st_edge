local parser = {}

-- 베스틴 패킷 체크섬 계산 (마지막 바이트 직전까지 누적)
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

-- 조명 제어 패킷 (HA 실측 패킷 구조 100% 일치)
-- 5번째: 0x00 고정
-- 7번째: ON(0x81) / OFF(0x01)
-- 12번째: ON(0x04) / OFF(0x00)
-- 13번째: 체크섬
function parser.build_light_command(room_idx, light_idx, is_on)
  local cmd_byte7 = is_on and 0x81 or 0x01
  local cmd_byte12 = is_on and 0x04 or 0x00

  local pkt = {
    0x02,
    0x31,
    0x0D,
    0x01,
    0x00,            -- 5번째: 0x00 고정
    room_idx & 0x0F, -- 6번째: 방 번호
    cmd_byte7,       -- 7번째: ON(0x81) / OFF(0x01)
    0x00,            -- 8
    0x00,            -- 9
    0x00,            -- 10
    0x00,            -- 11
    cmd_byte12,      -- 12번째: ON(0x04) / OFF(0x00)
    0x00             -- 13번째: 체크섬 자리
  }

  pkt[13] = parser.calculate_checksum({table.unpack(pkt, 1, 12)})
  return string.char(table.unpack(pkt))
end

-- 콘센트 제어 패킷
function parser.build_outlet_command(room_idx, outlet_idx, is_on)
  local cmd_byte7 = is_on and 0x81 or 0x01
  local cmd_byte12 = is_on and 0x04 or 0x00

  local pkt = {
    0x02,
    0x32,
    0x0D,
    0x01,
    0x00,
    room_idx & 0x0F,
    cmd_byte7,
    0x00,
    0x00,
    0x00,
    0x00,
    cmd_byte12,
    0x00
  }

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
  -- 맨 끝 바이트(len)가 체크섬
  if parser.calculate_checksum({table.unpack(bytes, 1, len - 1)}) ~= bytes[len] then
    return nil
  end

  local cmd = bytes[4]

  -- [조명 상태 응답 처리 (0x31)]
  if header == 0x31 and (cmd == 0x91 or cmd == 0x81 or cmd == 0x92) then
    local room = bytes[6] & 0x0F
    local states = {}

    if len >= 30 then
      -- 30바이트 패킷: 7번째 바이트(bytes[7]) 하위 비트가 조명 상태 (0x30: OFF, 0x31: ON)
      local mask = bytes[7] & 0x0F
      for i = 1, 4 do
        states[i] = ((mask >> (i - 1)) & 0x01) == 1
      end
    elseif len >= 8 then
      local mask = bytes[8] or 0
      for i = 1, 4 do
        states[i] = ((mask >> (i - 1)) & 0x01) == 1
      end
    end

    if #states > 0 then
      return { kind = "light", room = room, states = states }
    end
  end

  -- [콘센트 상태 응답 처리 (0x32)]
  if header == 0x32 and (cmd == 0x91 or cmd == 0x81 or cmd == 0x92) and len >= 8 then
    local room = bytes[6] & 0x0F
    local mask = bytes[8] or 0
    local states = {}
    for i = 1, 2 do
      states[i] = ((mask >> (i - 1)) & 0x01) == 1
    end
    local power = 0.0
    if len >= 11 and bytes[10] and bytes[11] then
      power = ((bytes[10] << 8) | bytes[11]) / 10.0
    end
    return { kind = "outlet", room = room, states = states, power = power }
  end

  return nil
end

-- ========================================================
-- [Control 버스] 난방
-- ========================================================

function parser.build_thermostat_command(room_idx, is_on, target_temp)
  local t_int = math.floor(target_temp or 22)
  local t_dec = math.floor(((target_temp or 22) % 1) * 10)

  local pkt = {
    0x02, 0x28, 0x0E, 0x12,
    0x00,            -- 5번째: 0x00 고정
    room_idx & 0x0F,
    is_on and 0x01 or 0x02,
    t_int,
    t_dec,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00             -- 14번째: 체크섬 자리
  }
  pkt[14] = parser.calculate_checksum({table.unpack(pkt, 1, 13)})
  return string.char(table.unpack(pkt))
end

function parser.parse_control_packet(raw_bytes)
  if #raw_bytes < 4 or raw_bytes:byte(1) ~= 0x02 then return nil end
  local header = raw_bytes:byte(2)
  local len = raw_bytes:byte(3)
  if #raw_bytes < len then return nil end

  local bytes = {raw_bytes:byte(1, len)}
  if parser.calculate_checksum({table.unpack(bytes, 1, len - 1)}) ~= bytes[len] then
    return nil
  end

  if header == 0x28 and len >= 8 then
    local room = bytes[6] & 0x0F
    local is_on = (bytes[7] == 0x01)
    local cur_int = bytes[8] or 20
    local cur_dec = bytes[9] or 0
    local target_int = bytes[10] or 22
    local target_dec = bytes[11] or 0

    local cur_temp = cur_int + (cur_dec / 10.0)
    local target_temp = target_int + (target_dec / 10.0)

    if cur_temp < 5 or cur_temp > 45 then cur_temp = 20.0 end
    if target_temp < 10 or target_temp > 35 then target_temp = 22.0 end

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