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
        log.info(string.format("[%s] IP/Port 미설정 상태. 앱 설정(Preferences) 입력을 대기합니다.", self.name))
        socket.sleep(5)
      else
        local s, err = socket.tcp()
        if not s then
          log.error(string.format("[%s] TCP 소켓 초기화 실패: %s", self.name, tostring(err)))
          socket.sleep(5)
        else
          s:settimeout(5)
          log.info(string.format("[%s] EW11 연결 시도 -> %s:%d", self.name, self.ip, self.port))
          local res, conn_err = s:connect(self.ip, self.port)
          if res then
            log.info(string.format("[%s] EW11 (%s:%d) 연결 성공!", self.name, self.ip, self.port))
            self.sock = s
            self:listen_loop()
          else
            log.warn(string.format("[%s] 연결 실패 (%s), 5초 후 재시도", self.name, tostring(conn_err)))
          end
          if self.sock then self.sock:close() end
          self.sock = nil
        end
        socket.sleep(5)
      end
    end
  end, "rx_" .. self.name)
end

function Client:listen_loop()
  local buffer = ""
  while self.running do
    self.sock:settimeout(1)
    local chunk, err, partial = self.sock:receive("*a")
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
        if #buffer < pkt_len then break end

        local packet_bytes = buffer:sub(1, pkt_len)
        buffer = buffer:sub(pkt_len + 1)
        self.on_packet_cb(packet_bytes)
      end
    end
    if err and err ~= "timeout" then
      log.error(string.format("[%s] 통신 세션 종료: %s", self.name, tostring(err)))
      break
    end
  end
end

function Client:send(payload)
  if self.sock then
    return self.sock:send(payload)
  end
  return nil, string.format("[%s] EW11 소켓이 연결되어 있지 않습니다.", self.name)
end

function Client:stop()
  self.running = false
  if self.sock then
    self.sock:close()
    self.sock = nil
  end
end

return Client