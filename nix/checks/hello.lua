-- @name Hello from Nix
-- @description /hello sends a greeting. Installed by the Home Manager module check.
-- @version 1.0.0
-- @capabilities send

larper.command("/hello", function(args)
  larper.send(larper.channel(), "hello from Nix " .. args)
end)
