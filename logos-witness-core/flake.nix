{
  description = "Logos Witness core module";

  inputs = {
    # Pin to tutorial-v1 branch: the template ships with metadata.json in the
    # `nix` nested-key shape that the parseMetadata.nix on this branch
    # understands. Master still ships the older parseModuleYaml.nix which
    # silently ignores those fields, so the protobuf dep would never reach
    # the build sandbox.
    logos-module-builder.url = "github:logos-co/logos-module-builder/tutorial-v1";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
