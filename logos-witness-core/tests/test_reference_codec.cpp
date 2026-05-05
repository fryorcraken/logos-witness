// Round-trip smoke test for the protobuf Reference / ReferenceBatch schema.
// Exercises encode → decode → field equality for every v0 field and confirms
// proto3 forward-compat semantics (decoding a payload from an encoder that
// added an unknown field still preserves the v0 fields). Run via:
//
//   nix develop --command bash -c 'cmake -B build -GNinja && \
//     cmake --build build && ctest --test-dir build --output-on-failure'
//
// SPEC §2 / §6 / §7.3.

#include "reference.pb.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

namespace {

bool round_trip_single() {
    logos::witness::v1::Reference r;
    r.set_schema_version(1);
    r.set_content_hash(std::string(32, '\x42'));
    r.set_timestamp(static_cast<std::uint64_t>(1714867200));
    r.set_geohash("u4pruydq");

    std::string buf;
    if (!r.SerializeToString(&buf)) {
        std::cerr << "SerializeToString failed\n";
        return false;
    }

    logos::witness::v1::Reference r2;
    if (!r2.ParseFromString(buf)) {
        std::cerr << "ParseFromString failed\n";
        return false;
    }

    if (r2.schema_version() != 1) return false;
    if (r2.content_hash() != std::string(32, '\x42')) return false;
    if (r2.timestamp() != 1714867200u) return false;
    if (r2.geohash() != "u4pruydq") return false;

    // Canonical-encoding determinism: same input → byte-equal output.
    std::string buf2;
    if (!r2.SerializeToString(&buf2)) return false;
    if (buf != buf2) {
        std::cerr << "non-deterministic encode\n";
        return false;
    }

    return true;
}

bool round_trip_batch() {
    logos::witness::v1::ReferenceBatch batch;
    for (int i = 0; i < 3; ++i) {
        auto* r = batch.add_refs();
        r->set_schema_version(1);
        r->set_content_hash(std::string(32, static_cast<char>(i)));
        r->set_timestamp(1714867200u + static_cast<std::uint64_t>(i));
        r->set_geohash("u4pruydq");
    }

    std::string buf;
    if (!batch.SerializeToString(&buf)) return false;

    logos::witness::v1::ReferenceBatch out;
    if (!out.ParseFromString(buf)) return false;

    if (out.refs_size() != 3) return false;
    for (int i = 0; i < 3; ++i) {
        const auto& r = out.refs(i);
        if (r.schema_version() != 1) return false;
        if (r.content_hash() != std::string(32, static_cast<char>(i))) return false;
        if (r.timestamp() != 1714867200u + static_cast<std::uint64_t>(i)) return false;
    }
    return true;
}

bool unknown_field_tolerance() {
    // Encode a Reference with an extra unknown field number 99 by hand-crafting
    // the wire bytes. proto3 must preserve / ignore unknown fields without
    // error.
    //
    // Wire format: field 99 (varint), value 7. Tag = (99 << 3) | 0 = 792.
    // Varint encoding of 792 = 0x88 0x06. Then varint value 7 = 0x07.
    logos::witness::v1::Reference r;
    r.set_schema_version(1);
    r.set_geohash("u4pruydq");
    std::string buf;
    if (!r.SerializeToString(&buf)) return false;
    buf.push_back(static_cast<char>(0x88));
    buf.push_back(static_cast<char>(0x06));
    buf.push_back(static_cast<char>(0x07));

    logos::witness::v1::Reference out;
    if (!out.ParseFromString(buf)) {
        std::cerr << "decode of payload-with-unknown-field failed\n";
        return false;
    }
    if (out.schema_version() != 1) return false;
    if (out.geohash() != "u4pruydq") return false;
    return true;
}

}  // namespace

int main() {
    int failures = 0;
    if (!round_trip_single())        { std::cerr << "FAIL: round_trip_single\n";        ++failures; }
    if (!round_trip_batch())         { std::cerr << "FAIL: round_trip_batch\n";         ++failures; }
    if (!unknown_field_tolerance())  { std::cerr << "FAIL: unknown_field_tolerance\n";  ++failures; }
    if (failures == 0) std::cout << "OK: reference codec round-trip + forward-compat\n";
    return failures == 0 ? 0 : 1;
}
