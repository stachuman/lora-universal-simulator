-- examples/snr_probe.lua
-- Queries sim:link_snr(self.name, peer) for every peer in sim:nodes() at
-- on_init time and emits one `link_snr` event per peer carrying the SNR.
-- Use interactively to inspect the link matrix. (Its old driver scenario
-- test/t09_link_snr.json was retired 2026-07-25 with the legacy corpus.)

function on_init(self, config)
  for _, n in ipairs(sim:nodes()) do
    if n.name ~= self.name then
      local s = sim:link_snr(self.name, n.name)
      if s ~= nil then
        self:emit("link_snr", { peer = n.name, snr_db = s })
      end
    end
  end
end
