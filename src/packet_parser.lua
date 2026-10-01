local parser = {}

-- 테이블 할당 없는 체크섬 계산
function parser.calculate_checksum_raw(str, start_idx, end_idx)
  local sum = 3
  for i = start_idx, end_idx do
    sum = ((str:byte(i) ~ sum) + 1) & 0xFF
  end
  return sum
end

function parser.calculate_checksum_tbl(tbl, len)
  local sum = 3
  for i = 1, len do
    sum = ((tbl[i] ~ sum) + 1) & 0xFF
  end
  return sum
end

-- ========================================================
-- [Energy 버스]
-- ========================================================

function parser.build_light_command(room_idx, light_idx, is_on)
  local mask = 1 << (light_idx - 1)
  local cmd_byte7 = is_on and (0x80 | mask) or (0x00 | mask)
  local cmd_byte12 = is_on and 0x04 or 0x00

  local pkt = {
    0x02, 0x31, 0x0D, 0x01,
    0x00, room_idx & 0x0F, cmd_byte7,
    0x00, 0x00, 0x00, 0x00, cmd_byte12, 0x00
  }
  pkt[13] = parser.calculate_checksum_tbl(pkt, 12)
  return string.char(table.unpack(pkt))
end

function parser.build_outlet_command(room_idx, outlet_idx, is_on)
  local mask = 1 << (outlet_idx - 1)
  local cmd_byte8 = is_on and (0x80 | mask) or (0x00 | mask)
  local cmd_byte12 = is_on and 0x09 or 0x00

  local pkt = {
    0x02, 0x31, 0x0D, 0x01,
    0x00, room_idx & 0x0F, 0x00, cmd_byte8,
    0x00, 0x00, 0x00, cmd_byte12, 0x00
  }
  pkt[13] = parser.calculate_checksum_tbl(pkt, 12)
  return string.char(table.unpack(pkt))
end

function parser.parse_energy_packet(raw_bytes)
  local len = #raw_bytes
  if len < 30 or raw_bytes:byte(1) ~= 0x02 then return nil end

  local header = raw_bytes:byte(2)
  local pkt_len = raw_bytes:byte(3)
  if len < pkt_len or pkt_len < 30 then return nil end

  -- 임시 테이블 생성 없이 직접 바이트 비교
  if parser.calculate_checksum_raw(raw_bytes, 1, pkt_len - 1) ~= raw_bytes:byte(pkt_len) then
    return nil
  end

  local cmd = raw_bytes:byte(4)
  if header == 0x31 and (cmd == 0x91 or cmd == 0x81 or cmd == 0x92) then
    local room = raw_bytes:byte(6) & 0x0F

    local b7 = raw_bytes:byte(7)
    local l1_on = ((b7 & 0x01) == 0x01)
    local l2_on = (((b7 >> 1) & 0x01) == 0x01)

    local b8 = raw_bytes:byte(8)
    local b9 = raw_bytes:byte(9)
    local o1_on = ((b8 & 0x01) == 0x01)
    local o2_on = (((b8 >> 1) & 0x01) == 0x01)
    if b9 and b9 > 0 then
      o2_on = ((b9 & 0x01) == 0x01)
    end

    -- 소비전력: bytes[15..18], / 10.0
    local p1 = ((raw_bytes:byte(15) << 8) | raw_bytes:byte(16)) / 10.0
    local p2 = ((raw_bytes:byte(17) << 8) | raw_bytes:byte(18)) / 10.0

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
-- [Control 버스]
-- ========================================================

function parser.build_thermostat_command(room_idx, is_on, target_temp)
  local t_int = math.floor(target_temp or 22)
  local t_dec = math.floor(((target_temp or 22) % 1) * 10)

  local pkt = {
    0x02, 0x28, 0x0E, 0x12,
    0x00, room_idx & 0x0F,
    is_on and 0x01 or 0x02,
    t_int, t_dec,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  }
  pkt[14] = parser.calculate_checksum_tbl(pkt, 13)
  return string.char(table.unpack(pkt))
end

function parser.parse_control_packet(raw_bytes)
  local len = #raw_bytes
  if len < 8 or raw_bytes:byte(1) ~= 0x02 then return nil end

  local header = raw_bytes:byte(2)
  local pkt_len = raw_bytes:byte(3)
  if len < pkt_len or pkt_len < 8 then return nil end

  if parser.calculate_checksum_raw(raw_bytes, 1, pkt_len - 1) ~= raw_bytes:byte(pkt_len) then
    return nil
  end

  if header == 0x28 then
    local room = raw_bytes:byte(6) & 0x0F
    local is_on = (raw_bytes:byte(7) == 0x01)
    local cur_int = raw_bytes:byte(8) or 20
    local cur_dec = raw_bytes:byte(9) or 0
    local target_int = raw_bytes:byte(10) or 22
    local target_dec = raw_bytes:byte(11) or 0

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