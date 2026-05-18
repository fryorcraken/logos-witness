{
  description = "Logos Witness UI module (QML + C++ backend hybrid)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/5e196e2769";
    # NOTE: metadata.json currently declares dependencies=[]. When task
    # #27 migrates call sites onto a typed `logos_witness_core` accessor
    # via the hybrid backend, re-add `logos_witness_core` here AND in
    # metadata.json's dependencies array so the upstream codegen can
    # emit the typed-accessor header. Using a `path:../logos-witness-core`
    # input is rejected by stricter nix builds (CI) as "unlocked";
    # switch to a `github:` URL pinned to the relevant core commit.
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
