{
  description = "Logos Witness UI module (QML + C++ backend hybrid)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/5e196e2769";
    # Hybrid ui_qml builds need each declared module dependency wired
    # as a flake input so the upstream codegen can emit its typed
    # accessor header (e.g. logos_witness_core_api.h) into the
    # generated_code/ tree the C++ backend includes. Without this the
    # build fails with: fatal error: logos_witness_core_api.h: No such
    # file or directory.
    logos_witness_core.url = "path:../logos-witness-core";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
