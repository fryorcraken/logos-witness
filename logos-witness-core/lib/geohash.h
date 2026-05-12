// Niemeyer-2008 base32 geohash decoder. Header-only so the unit-test
// target can pull it in without dragging Qt or the plugin into the
// compile unit. The encoder lives in QML (MapView.qml + SubmitHelpers.js)
// — the canonical encoded values pinned by tst_submit_helpers.qml are
// the ground truth this decoder is verified against.

#ifndef LOGOS_WITNESS_CORE_GEOHASH_H
#define LOGOS_WITNESS_CORE_GEOHASH_H

#include <cstring>
#include <string>

namespace logos::witness::geohash {

inline constexpr const char* kAlphabet = "0123456789bcdefghjkmnpqrstuvwxyz";

struct DecodeResult {
    bool ok;
    double latitude;
    double longitude;
    int errorIndex;  // 0-based index of the invalid char when ok=false;
                     // -1 when ok, OR when ok=false because the input
                     // was empty (no char to point at).
};

inline DecodeResult decode(const std::string& geohash) {
    if (geohash.empty()) return {false, 0.0, 0.0, -1};

    double latLo = -90.0,  latHi = 90.0;
    double lonLo = -180.0, lonHi = 180.0;
    bool even = true;

    for (size_t i = 0; i < geohash.size(); ++i) {
        char c = geohash[i];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        const char* hit = std::strchr(kAlphabet, c);
        if (!hit) return {false, 0.0, 0.0, static_cast<int>(i)};
        const int idx = static_cast<int>(hit - kAlphabet);
        for (int bit = 4; bit >= 0; --bit) {
            const int b = (idx >> bit) & 1;
            if (even) {
                const double mid = (lonLo + lonHi) / 2.0;
                if (b) lonLo = mid; else lonHi = mid;
            } else {
                const double mid = (latLo + latHi) / 2.0;
                if (b) latLo = mid; else latHi = mid;
            }
            even = !even;
        }
    }

    return {true, (latLo + latHi) / 2.0, (lonLo + lonHi) / 2.0, -1};
}

}  // namespace logos::witness::geohash

#endif
