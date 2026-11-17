# Full license texts for vendored header-only libraries whose headers carry
# only a copyright line and an SPDX identifier or a reference to the license.
{ fetchurl }:
{
  # third_party/nlohmann/json.hpp, version 3.11.3.
  nlohmann-json = fetchurl {
    url = "https://raw.githubusercontent.com/nlohmann/json/v3.11.3/LICENSE.MIT";
    hash = "sha256-hrmYx5KJTMuRGhy3mU96llKJTnoJTAteRb4vVT9FzxQ=";
  };
  # third_party/mlspp/third_party/variant.hpp (MPark.Variant).
  mpark-variant = fetchurl {
    url = "https://raw.githubusercontent.com/mpark/variant/v1.4.0/LICENSE.md";
    hash = "sha256-yb/3VziSIZPmf6cm+iJVNYcNKqEFn5FFLEEXNihK1WY=";
  };
}
