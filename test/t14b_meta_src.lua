-- test/t14b_meta_src.lua
-- Verifies meta.src is exposed to on_recv with the sender's node id.
-- Flow: alice tx's a single byte to bob. bob emits "src_observed" carrying
-- meta.src, the test asserts that emit data contains alice's id (which is 0
-- in the order alice/bob in the JSON — first node = id 0).

function on_init(self, config)
  self.id_to_name = {}
  for _, n in ipairs(sim:nodes()) do
    self.id_to_name[n.id] = n.name
  end
end

function on_command(self, cmd)
  if cmd == "ping" then
    self:tx("X", { label = "PING" })
    return "ok"
  end
  return "ERROR: unknown cmd"
end

function on_recv(self, frame, meta)
  self:emit("src_observed", {
    src     = meta.src,
    src_name = self.id_to_name[meta.src] or "?",
    snr     = meta.snr,
    bytes   = #frame,
  })
end
