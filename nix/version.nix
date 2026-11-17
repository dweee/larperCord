# The version compiled into the binary (src/core/version.zig).
builtins.head (
  builtins.match ''.*pub const number = "([^"]+)".*'' (builtins.readFile ../src/core/version.zig)
)
