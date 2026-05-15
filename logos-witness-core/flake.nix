{
  description = "Logos Witness core module";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/5e196e2769";
    # storage_module is declared as a dependency in metadata.json; the
    # module-builder filters inputs by config.dependencies and copies
    # the dep's include/ into our generated_code/ so we can call
    # m_logos->storage_module.uploadUrl(...) with a typed accessor.
    storage_module.url = "github:logos-co/logos-storage-module";
    # delivery_module: same wiring as storage_module, used for the
    # live cross-instance feed on /logos-witness/1/inscriptions/proto.
    delivery_module.url = "github:logos-co/logos-delivery-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
