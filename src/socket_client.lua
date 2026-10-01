local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local Client = {}
Client.__index = Client

function Client.new(name, on_packet_cb)
  local self = setmetatable({}, Client)
  self.name = name
  self.ip = nil
  self.port = nil
  self.on_packet_cb = on_packet_cb
  self.running = false
  self.sock = nil
  return self
end

local function is_valid_ip(ip)
  if type(ip) ~= "string" or ip == "" then return false end
  local chunks = { ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
  if #chunks ~= 4 then return false end
  for _, v in pairs(chunks) do
    local n = tonumber(v)
    if not n or n < 0 or n > 255 then return false end
  end
  return true
end

function Client:update_endpoint(ip, port)
  self.ip = ip
  self.port = tonumber(port)
end

function Client:start()
  self.running = true
  cosock.spawn(function()
    while self.running do
      if not is_valid_ip(self.ip) or not self.port then
        socket.sleep(5)
      else
        local s, err = socket.tcp()
        if not s then
          log.error(string.format("[%s] TCP 소켓 생성 실패: %s", self.name, tostring(err)))
          socket.sleep(5)
        else
          s:settimeout(5)
          log.info(string.format("[%s] EW11 연결 시도 -> %s:%d", self.name, self.ip, self.port))
          local res, conn_err = s:connect(self.ip, self.port)
          if res then
            s:setoption("tcp-nodelay", true)
            log.info(string.format("[%s] EW11 (%s:%d) 연결 성공!", self.name, self.ip, self.port))
            self.sock = s
            self:listen_loop()
          else
            log.warn(string.format("[%s] 연결 실패: %s (5초 후 재시도)", self.name, tostring(conn_err)))
          end
          if self.sock then
            pcall(function() self.sock:close() end)
            self.sock = nil
          end
        end
        socket.sleep(3)
      end
    end
  end, "rx_" .. self.name)
end

function Client:listen_loop()
  local buffer = ""
  while self.running and self.sock do
    self.sock:settimeout(2)
    local chunk, err, partial = self.sock:receive(512)
    local data = chunk or partial

    if data and #data > 0 then
      buffer = buffer .. data
      while #buffer > 0 do
        local head_pos = buffer:find("\x02")
        if not head_pos then
          buffer = ""
          break
        end
        if head_pos > 1 then
          buffer = buffer:sub(head_pos)
        end
        if #buffer < 3 then break end

        local pkt_len = buffer:byte(3)
        if pkt_len < 4 or pkt_len > 64 then
          buffer = buffer:sub(2)
        elseif #buffer < pkt_len then
          break
        else
          local packet_bytes = buffer:sub(1, pkt_len)
          buffer = buffer:sub(pkt_len + 1)
          local ok, p_err = pcall(self.on_packet_cb, packet_bytes)
          if not ok then
            log.error(string.format("[%s] 패킷 콜백 예외: %s", self.name, tostring(p_err)))
          end
        end
      end
    end

    if err and err ~= "timeout" then
      log.error(string.format("[%s] 소켓 오류 발생: %s", self.name, tostring(err)))
      break
    end
  end
end

function Client:send(payload)
  if self.sock then
    self.sock:settimeout(2)
    local res, err = self.sock:send(payload)
    if not res then
      log.error(string.format("[%s] 송신 실패: %s", self.name, tostring(err)))
      pcall(function() self.sock:close() end)
      self.sock = nil
    end
    return res, err
  end
  return nil, "소켓 미연결"
end

function Client:stop()
  self.running = false
  if self.sock then
    pcall(function() self.sock:close() end)
    self.sock = nil
  end
end

return Client