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
-- [Energy 버스] 조명 / 콘센트 제어 및 상태 파싱
-- ========================================================

-- 조명 제어 패킷
function parser.build_light_command(room_idx, light_idx, is_on)
  local mask = 1 << (light_idx - 1)
  local cmd_byte7 = is_on and (0x80 | mask) or (0x00 | mask)
  local cmd_byte12 = is_on and 0x04 or 0x00

  local pkt = {
    0x02,
    0x31,
    0x0D,
    0x01,
    0x00,            -- 5: 0x00 고정
    room_idx & 0x0F, -- 6: 방 번호
    cmd_byte7,       -- 7: 조명 제어 바이트
    0x00,            -- 8
    0x00,            -- 9
    0x00,            -- 10
    0x00,            -- 11
    cmd_byte12,      -- 12: ON(0x04) / OFF(0x00)
    0x00             -- 13: 체크섬 자리
  }

  pkt[13] = parser.calculate_checksum({table.unpack(pkt, 1, 12)})
  return string.char(table.unpack(pkt))
end

-- 콘센트 제어 패킷
function parser.build_outlet_command(room_idx, outlet_idx, is_on)
  local mask = 1 << (outlet_idx - 1)
  local cmd_byte8 = is_on and (0x80 | mask) or (0x00 | mask)
  local cmd_byte12 = is_on and 0x09 or 0x00

  local pkt = {
    0x02,
    0x31,
    0x0D,
    0x01,
    0x00,            -- 5: 0x00 고정
    room_idx & 0x0F, -- 6: 방 번호
    0x00,            -- 7
    cmd_byte8,       -- 8: 콘센트 제어 바이트
    0x00,            -- 9
    0x00,            -- 10
    0x00,            -- 11
    cmd_byte12,      -- 12: ON(0x09) / OFF(0x00)
    0x00             -- 13: 체크섬 자리
  }

  pkt[13] = parser.calculate_checksum({table.unpack(pkt, 1, 12)})
  return string.char(table.unpack(pkt))
end

-- Energy 라인 수신 패킷 파싱 (소비전력: bytes[15]~[18], /10.0 W)
function parser.parse_energy_packet(raw_bytes)
  if #raw_bytes < 4 or raw_bytes:byte(1) ~= 0x02 then return nil end
  local header = raw_bytes:byte(2)
  local len = raw_bytes:byte(3)
  if #raw_bytes < len then return nil end

  local bytes = {raw_bytes:byte(1, len)}
  if parser.calculate_checksum({table.unpack(bytes, 1, len - 1)}) ~= bytes[len] then
    return nil
  end

  local cmd = bytes[4]

  -- 30바이트 통합 에너지 패킷
  if header == 0x31 and (cmd == 0x91 or cmd == 0x81 or cmd == 0x92) and len >= 30 then
    local room = bytes[6] & 0x0F

    -- [조명 상태] 1 = ON, 0 = OFF
    local l1_on = ((bytes[7] & 0x01) == 0x01)
    local l2_on = (((bytes[7] >> 1) & 0x01) == 0x01)

    -- [콘센트 상태]
    local o1_on = ((bytes[8] & 0x01) == 0x01)
    local o2_on = (((bytes[8] >> 1) & 0x01) == 0x01)
    if bytes[9] and bytes[9] > 0 then
      o2_on = ((bytes[9] & 0x01) == 0x01)
    end

    -- [실시간 소비전력: bytes[15]~[18], / 10.0 W]
    -- 1번 콘센트 실시간 소비전력: bytes[15], bytes[16]
    local p1 = 0.0
    if bytes[15] and bytes[16] then
      local raw_p1 = (bytes[15] << 8) | bytes[16]
      p1 = raw_p1 / 10.0
    end

    -- 2번 콘센트 실시간 소비전력: bytes[17], bytes[18]
    local p2 = 0.0
    if bytes[17] and bytes[18] then
      local raw_p2 = (bytes[17] << 8) | bytes[18]
      p2 = raw_p2 / 10.0
    end

    return {
      kind = "energy_combined",
      room = room,
      lights = { l1_on, l2_on },
      outlets = { o1_on, o2_on },
      powers = { p1, p2 }
    }
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
    0x00,
    room_idx & 0x0F,
    is_on and 0x01 or 0x02,
    t_int,
    t_dec,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00
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