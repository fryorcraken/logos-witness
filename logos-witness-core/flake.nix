{
  description = "Logos Witness core module";

  inputs = {
    # tutorial-v2 (= basecamp 0.1.2). Pinned to the resolved commit, not
    # the `tutorial-v2` tag, because dlipicar re-pointed that tag twice
    # while fixing the example modules (logos-basecamp#150) — this sha is
    # the tag's position as of 2026-06-02.
    logos-module-builder.url = "github:logos-co/logos-module-builder/ea7f4bdebe89ef91c2c25501cc8e8e60fe85b449";
    # storage_module is declared as a dependency in metadata.json; the
    # module-builder filters inputs by config.dependencies and copies
    # the dep's include/ into our generated_code/ so we can call
    # m_logos->storage_module.uploadUrl(...) with a typed accessor.
    #
    # NOTE: we deliberately do NOT `follows`-pin these deps' own
    # logos-module-builder. Their master/tagged sources include
    # generated headers (e.g. `logos_module_context.h`) that only
    # their natively-pinned builder's SDK provides; forcing them onto
    # our tutorial-v2 builder fails to compile the dep outright. The
    # versions that must line up are the *runtime ABI* of the generated
    # accessors our plugins call, which the SDK keeps stable across these
    # builder revs — not the build-time builder of the dep itself.
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
