-- examples/quiet.lua -- minimal node that does nothing.
-- For performance benchmarking: measures pure runtime overhead.
function on_init(self, config)
  -- nothing to set up
end
function on_recv(self, frame, meta)
  -- nothing to do
end
