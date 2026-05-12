{
  description = "Logos Witness UI module (QML)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/5e196e2769";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
