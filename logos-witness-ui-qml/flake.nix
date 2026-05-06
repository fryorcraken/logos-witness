{
  description = "Logos Witness UI module (QML)";

  inputs = {
    # Pinned to tutorial-v1 — master ships an older parseModuleYaml that
    # silently drops nested `nix.packages` from this metadata.json.
    logos-module-builder.url = "github:logos-co/logos-module-builder/tutorial-v1";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
