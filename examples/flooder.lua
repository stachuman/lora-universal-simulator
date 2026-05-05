-- examples/flooder.lua
-- Simple flooded broadcast. Each packet has a (originator_id, seq) tuple as
-- its identity; receivers forward once and never again.

function on_init(self, config)
  self.role = config.role or "forwarder"
  self.seq = 0
  self.seen = {}                 -- key: id .. ":" .. seq, value: true
  self:log("init role=" .. self.role)
end

local function packet_key(originator_id, seq)
  return string.format("%d:%d", originator_id, seq)
end

local function serialize(originator_id, seq, text)
  -- 1-byte originator id, 1-byte seq, text bytes (no length prefix; consume to EOF)
  return string.char(originator_id) .. string.char(seq % 256) .. text
end

local function parse(frame)
  if #frame < 2 then return nil end
  local oid  = frame:byte(1)
  local seq  = frame:byte(2)
  local text = frame:sub(3)
  return { oid = oid, seq = seq, text = text }
end

function on_recv(self, frame, meta)
  local p = parse(frame)
  if not p then return end
  local key = packet_key(p.oid, p.seq)
  if self.seen[key] then return end                  -- dedupe
  self.seen[key] = true
  self:log(string.format("recv from=%d seq=%d text=%q", p.oid, p.seq, p.text))
  self:emit("recv", { oid = p.oid, seq = p.seq, text = p.text })
  -- Forward unless I'm the originator (avoid bouncing back).
  if p.oid ~= self.id then
    self:tx(frame)
  end
end

function on_command(self, cmd_str)
  local text = cmd_str:match("^send (.+)$")
  if not text then return "ERROR: usage: send <text>" end
  if self.role ~= "originator" then return "ERROR: I'm not an originator" end
  self.seq = self.seq + 1
  local frame = serialize(self.id, self.seq, text)
  local key = packet_key(self.id, self.seq)
  self.seen[key] = true                              -- don't accept our own back
  self:tx(frame)
  return string.format("sent seq=%d to flood", self.seq)
end
