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
    #
    # Both deps are pinned to an EXPLICIT rev (not a moving branch).
    # `mkLogosModule` builds each dep at codegen time to extract its
    # `*_api.h` typed-accessor headers, which transitively compiles the
    # dep's full Nim/Rust chain. Leaving the URL on the default branch
    # lets `nix flake update` silently drag in a newer dep whose vendor
    # step may be un-buildable in CI's cold sandbox (e.g. v0.1.2's
    # zerokit fetches `criterion` from crates.io and gets a 403). These
    # revs are the ones the last green build used.
    storage_module.url = "github:logos-co/logos-storage-module/b1d82a32c1ba27e20d07b7ed8555fd45b02adb4e";
    # delivery_module: same wiring as storage_module, used for the
    # live cross-instance feed on /logos-witness/1/inscriptions/proto.
    delivery_module.url = "github:logos-co/logos-delivery-module/e0b913ca80ff8db807b21c89162311e9fe319038";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
