{
  description = "Logos Witness UI module (QML + C++ backend hybrid)";

  inputs = {
    # tutorial-v2 (= basecamp 0.1.2). Pinned to the resolved commit, not
    # the `tutorial-v2` tag, because the tag moved during #150 fixes —
    # this sha is the tag's position as of 2026-06-02. Keep in lockstep
    # with logos-witness-core/flake.nix.
    logos-module-builder.url = "github:logos-co/logos-module-builder/ea7f4bdebe89ef91c2c25501cc8e8e60fe85b449";
    # logos_witness_core declared as a dependency in metadata.json;
    # module-builder's codegen needs the matching flake input to
    # emit the typed accessor `m_logos->logos_witness_core.X(...)`
    # that the UI plugin's backend uses. github:?dir= form because
    # the dep lives in the same monorepo as the UI module.
    logos_witness_core.url = "github:fryorcraken/logos-witness?dir=logos-witness-core";
    # Keep the dep's transitive module-builder on our pin too, so the
    # whole closure resolves to one builder version (no mixed-version
    # trap — #150). Note: this input tracks a *pushed* sha, so it lags
    # local edits to logos-witness-core until those are pushed.
    logos_witness_core.inputs.logos-module-builder.follows = "logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
