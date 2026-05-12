// Unit tests for the Niemeyer-2008 geohash decoder in lib/geohash.h.
//
// Pinned to the same canonical vectors that tst_submit_helpers.qml uses
// for the encoder, so encode and decode stay in lockstep. Vectors are
// from the Wikipedia "Geohash" article ("Worked example" + table).

#include "geohash.h"

#include <cassert>
#include <cmath>
#include <iostream>
#include <string>

namespace gh = logos::witness::geohash;

namespace {

// Tolerance: an N-char geohash has a longitude precision of
// 360 / 2^(ceil(N*5/2)) and a latitude precision of 180 / 2^(floor(N*5/2)).
// The centroid lands inside the cell, so any reference point inside the
// cell sits within half-cell of the centroid in each axis. For N=8, cell
// width is ~0.00017° lat and ~0.00017° lon — half is ~9e-5. Use 2e-4 to
// absorb single-step accumulated FP error without being so loose the
// test becomes meaningless.
constexpr double kTol = 2e-4;

bool near(double a, double b, double tol = kTol) {
    return std::fabs(a - b) <= tol;
}

bool decode_u4pruydqqvj() {
    // Wikipedia worked example: "u4pruydqqvj" maps to
    // (57.64911°N, 10.40744°E). We only need the 8-char prefix.
    const auto r = gh::decode("u4pruydq");
    if (!r.ok) { std::cerr << "expected ok\n"; return false; }
    if (!near(r.latitude,  57.64911)) {
        std::cerr << "lat off: got " << r.latitude << "\n"; return false;
    }
    if (!near(r.longitude, 10.40744)) {
        std::cerr << "lon off: got " << r.longitude << "\n"; return false;
    }
    return true;
}

bool decode_wikipedia_ezs42() {
    // Wikipedia "Geohash" worked example: "ezs42" decodes to
    // (42.605°, -5.603°) (their stated table value).
    const auto r = gh::decode("ezs42");
    if (!r.ok) return false;
    if (!near(r.latitude,   42.605, 0.01)) {
        std::cerr << "ezs42 lat off: got " << r.latitude << "\n"; return false;
    }
    if (!near(r.longitude, -5.603, 0.01)) {
        std::cerr << "ezs42 lon off: got " << r.longitude << "\n"; return false;
    }
    return true;
}

bool decode_case_insensitive() {
    const auto lower = gh::decode("u4pruydq");
    const auto upper = gh::decode("U4PRUYDQ");
    if (!lower.ok || !upper.ok) return false;
    if (lower.latitude  != upper.latitude)  return false;
    if (lower.longitude != upper.longitude) return false;
    return true;
}

bool reject_empty() {
    const auto r = gh::decode("");
    return !r.ok;
}

bool reject_invalid_char() {
    // 'a' is excluded from the Niemeyer alphabet ("0123456789bcdefghjkmnpqrstuvwxyz").
    const auto r = gh::decode("u4apruyd");
    if (r.ok) return false;
    return r.errorIndex == 2;
}

bool decode_origin() {
    // "s00000000" lands very close to (lat ~ 0, lon ~ 0). It's the SE
    // quadrant cell adjacent to the equator/prime meridian corner.
    const auto r = gh::decode("s00000000");
    if (!r.ok) return false;
    if (r.latitude  < 0.0 || r.latitude  > 1.0) return false;
    if (r.longitude < 0.0 || r.longitude > 1.0) return false;
    return true;
}

}  // namespace

int main() {
    int failures = 0;
    if (!decode_u4pruydqqvj())    { std::cerr << "FAIL: decode_u4pruydqqvj\n"; ++failures; }
    if (!decode_wikipedia_ezs42()){ std::cerr << "FAIL: decode_wikipedia_ezs42\n"; ++failures; }
    if (!decode_case_insensitive()){std::cerr << "FAIL: decode_case_insensitive\n";++failures;}
    if (!reject_empty())          { std::cerr << "FAIL: reject_empty\n"; ++failures; }
    if (!reject_invalid_char())   { std::cerr << "FAIL: reject_invalid_char\n"; ++failures; }
    if (!decode_origin())         { std::cerr << "FAIL: decode_origin\n"; ++failures; }
    if (failures == 0) std::cout << "OK: geohash decode\n";
    return failures == 0 ? 0 : 1;
}
