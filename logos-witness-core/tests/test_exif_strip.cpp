// SPEC §7.1 strip-pipeline unit tests.
//
// For each fixture under tests/fixtures/, run lib/exif_strip.cpp's
// strip_jpeg and assert:
//
//   1. The call succeeds and returns non-empty bytes.
//   2. Decoding the stripped output via libjpeg yields the byte-identical
//      pixel array that decoding the input does (SPEC §4 acceptance: pixel
//      content visually identical). We compare via SHA-256 over the
//      uncompressed pixel buffer rather than QImage::operator== to avoid
//      pulling Qt into the test target.
//   3. No JPEG metadata-bearing marker survives in the output. We scan
//      for APP1 (EXIF/XMP), APP2 (ICC), APP13 (Photoshop IRB / IPTC),
//      APP14 (Adobe), and COM. The JFIF APP0 marker IS allowed because
//      it is structural, not identifying.
//   4. Verification against `exiftool -a -G1` is enforced separately as a
//      CMake/CI gate (Phase 4.2); this binary does not shell out.
//
// Fail-closed paths exercise garbage input, truncated input, and a
// non-JPEG byte sequence — strip_jpeg must return ok=false with no
// partial bytes.
//
// Fixture paths are baked in at compile time via -DFIXTURE_DIR=... from
// CMakeLists.txt so the test binary can be invoked from any CWD.

#include "exif_strip.h"
#include "sha256.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

extern "C" {
#include <jpeglib.h>
#include <setjmp.h>
}

#ifndef FIXTURE_DIR
#error "FIXTURE_DIR must be defined by the build system"
#endif
#ifndef STRIPPED_OUTPUT_DIR
#error "STRIPPED_OUTPUT_DIR must be defined by the build system"
#endif

namespace {

std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::cerr << "cannot open " << path << "\n";
        std::exit(2);
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

void write_file(const std::string& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

// Pixel-level SHA-256 via libjpeg. Decodes the JPEG, concatenates RGB
// rows in raster order, hashes. setjmp/longjmp for clean failure on
// malformed input.
struct DecodeErr {
    struct jpeg_error_mgr pub;
    jmp_buf jmp;
};
void decode_error_exit(j_common_ptr cinfo) {
    auto* e = reinterpret_cast<DecodeErr*>(cinfo->err);
    longjmp(e->jmp, 1);
}

bool decode_pixel_sha256(const std::string& bytes,
                        std::array<std::uint8_t, 32>* out,
                        int* width_out = nullptr,
                        int* height_out = nullptr) {
    struct jpeg_decompress_struct cinfo{};
    DecodeErr err{};
    cinfo.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = decode_error_exit;
    if (setjmp(err.jmp)) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo,
                 reinterpret_cast<const unsigned char*>(bytes.data()),
                 bytes.size());
    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    cinfo.out_color_space = JCS_RGB;
    if (!jpeg_start_decompress(&cinfo)) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }

    if (width_out)  *width_out  = static_cast<int>(cinfo.output_width);
    if (height_out) *height_out = static_cast<int>(cinfo.output_height);

    const std::size_t row_bytes = static_cast<std::size_t>(cinfo.output_width)
                                  * cinfo.output_components;
    std::vector<std::uint8_t> pixels;
    pixels.reserve(row_bytes * cinfo.output_height);

    std::vector<std::uint8_t> row(row_bytes);
    while (cinfo.output_scanline < cinfo.output_height) {
        std::uint8_t* rowp = row.data();
        jpeg_read_scanlines(&cinfo, &rowp, 1);
        pixels.insert(pixels.end(), row.begin(), row.end());
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);

    *out = logos::witness::test::sha256(pixels.data(), pixels.size());
    return true;
}

// Scans the JPEG byte stream for any APPn (n != 0) or COM marker.
// JPEG marker rules: every marker is 0xFF followed by a non-zero byte
// (0xFF 0x00 is a data byte-stuff). SOI/EOI/RSTn are markerless;
// everything else has a big-endian length following.
struct MarkerScan {
    bool has_app1 = false;       // EXIF or XMP
    bool has_app2 = false;       // ICC
    bool has_app13 = false;      // Photoshop IRB / IPTC
    bool has_app14 = false;      // Adobe color
    bool has_other_appn = false; // APP3..APP12, APP15
    bool has_com = false;        // 0xFFFE
};

MarkerScan scan_markers(const std::string& bytes) {
    MarkerScan s;
    const auto* p = reinterpret_cast<const std::uint8_t*>(bytes.data());
    const std::size_t n = bytes.size();
    if (n < 2 || p[0] != 0xFF || p[1] != 0xD8) return s;
    std::size_t i = 2;
    while (i + 1 < n) {
        if (p[i] != 0xFF) { ++i; continue; }
        // Skip fill bytes.
        while (i + 1 < n && p[i + 1] == 0xFF) ++i;
        if (i + 1 >= n) break;
        std::uint8_t m = p[i + 1];
        i += 2;
        if (m == 0xD8 || m == 0xD9 || (m >= 0xD0 && m <= 0xD7)) continue;
        // SOS (0xDA) begins entropy-coded data which is not byte-stuffed
        // in the marker sense; scan for the next non-RST marker as the
        // segment end. Simpler: trust the segment length to skip past
        // SOS's header, then keep scanning — within entropy data the
        // 0xFF byte-stuff rule means 0xFF 0x00 is data, and the next
        // real marker will be EOI or a restart we can ignore.
        if (i + 1 >= n) break;
        std::size_t seg_len = (std::size_t(p[i]) << 8) | p[i + 1];
        if (seg_len < 2 || i + seg_len > n) break;
        if (m == 0xFE) s.has_com = true;
        else if (m == 0xE1) s.has_app1 = true;
        else if (m == 0xE2) s.has_app2 = true;
        else if (m == 0xED) s.has_app13 = true;
        else if (m == 0xEE) s.has_app14 = true;
        else if (m >= 0xE3 && m <= 0xEC) s.has_other_appn = true;
        else if (m == 0xEF)              s.has_other_appn = true;
        i += seg_len;
    }
    return s;
}

bool no_metadata_markers(const MarkerScan& s) {
    return !(s.has_app1 || s.has_app2 || s.has_app13 ||
             s.has_app14 || s.has_other_appn || s.has_com);
}

struct FixtureCase {
    const char* name;
    const char* input_filename;
};

bool run_round_trip_case(const FixtureCase& fc) {
    const std::string in_path = std::string(FIXTURE_DIR) + "/" + fc.input_filename;
    const std::string in_bytes = read_file(in_path);
    std::cout << "[" << fc.name << "] input=" << in_bytes.size() << "B "
              << fc.input_filename << "\n";

    const auto r = logos::witness::strip_jpeg(in_bytes);
    if (!r.ok) {
        std::cerr << "[" << fc.name << "] strip_jpeg FAILED: " << r.error << "\n";
        return false;
    }
    if (r.bytes.empty()) {
        std::cerr << "[" << fc.name << "] strip output is empty\n";
        return false;
    }

    std::array<std::uint8_t, 32> in_pix{}, out_pix{};
    int in_w = 0, in_h = 0, out_w = 0, out_h = 0;
    if (!decode_pixel_sha256(in_bytes, &in_pix, &in_w, &in_h)) {
        std::cerr << "[" << fc.name << "] could not decode input pixels\n";
        return false;
    }
    if (!decode_pixel_sha256(r.bytes, &out_pix, &out_w, &out_h)) {
        std::cerr << "[" << fc.name << "] could not decode stripped pixels\n";
        return false;
    }
    if (in_w != out_w || in_h != out_h) {
        std::cerr << "[" << fc.name << "] dim mismatch: "
                  << in_w << "x" << in_h << " vs "
                  << out_w << "x" << out_h << "\n";
        return false;
    }
    if (in_pix != out_pix) {
        std::cerr << "[" << fc.name << "] pixel SHA-256 differs:\n"
                  << "  in : " << logos::witness::test::hex(in_pix) << "\n"
                  << "  out: " << logos::witness::test::hex(out_pix) << "\n";
        return false;
    }

    const MarkerScan markers = scan_markers(r.bytes);
    if (!no_metadata_markers(markers)) {
        std::cerr << "[" << fc.name << "] stripped output retains markers:"
                  << " APP1=" << markers.has_app1
                  << " APP2=" << markers.has_app2
                  << " APP13=" << markers.has_app13
                  << " APP14=" << markers.has_app14
                  << " otherAPPn=" << markers.has_other_appn
                  << " COM=" << markers.has_com << "\n";
        return false;
    }

    // Dump to the build dir for the Phase 4.2 exiftool gate to pick up.
    const std::string out_path = std::string(STRIPPED_OUTPUT_DIR) + "/"
        + fc.input_filename + ".stripped.jpg";
    write_file(out_path, r.bytes);
    std::cout << "[" << fc.name << "] OK output=" << r.bytes.size()
              << "B → " << out_path << "\n";
    return true;
}

bool run_malformed_cases() {
    // 1. Empty input.
    {
        auto r = logos::witness::strip_jpeg("");
        if (r.ok || !r.bytes.empty()) {
            std::cerr << "[malformed/empty] expected failure, got ok="
                      << r.ok << " bytes=" << r.bytes.size() << "\n";
            return false;
        }
    }
    // 2. Wrong magic.
    {
        std::string garbage = "this is not a jpeg file at all";
        auto r = logos::witness::strip_jpeg(garbage);
        if (r.ok || !r.bytes.empty()) {
            std::cerr << "[malformed/garbage] expected failure, got ok="
                      << r.ok << " bytes=" << r.bytes.size() << "\n";
            return false;
        }
    }
    // 3. Truncated JPEG: SOI marker only, nothing after.
    {
        std::string trunc("\xFF\xD8", 2);
        auto r = logos::witness::strip_jpeg(trunc);
        if (r.ok || !r.bytes.empty()) {
            std::cerr << "[malformed/truncated] expected failure, got ok="
                      << r.ok << " bytes=" << r.bytes.size() << "\n";
            return false;
        }
    }
    // 4. Truncated mid-stream: take a valid JPEG, chop it in half.
    {
        const std::string full = read_file(std::string(FIXTURE_DIR) + "/clean.jpg");
        std::string half = full.substr(0, full.size() / 2);
        auto r = logos::witness::strip_jpeg(half);
        if (r.ok) {
            std::cerr << "[malformed/halved] expected failure, got ok=true"
                      << " bytes=" << r.bytes.size() << "\n";
            return false;
        }
        // Even if libjpeg recovers some output, fail-closed means we must
        // not leak partial bytes back to the caller.
        if (!r.bytes.empty()) {
            std::cerr << "[malformed/halved] partial output leaked ("
                      << r.bytes.size() << " bytes)\n";
            return false;
        }
    }
    return true;
}

} // namespace

int main() {
    const FixtureCase cases[] = {
        {"clean",        "clean.jpg"},
        {"exif_rich",    "exif_rich.jpg"},
        {"xmp_rich",     "xmp_rich.jpg"},
        {"icc_tagged",   "icc_tagged.jpg"},
        {"thumbnail",    "thumbnail.jpg"},
        {"jfif_comment", "jfif_comment.jpg"},
    };

    bool all_ok = true;
    for (const auto& c : cases) {
        if (!run_round_trip_case(c)) all_ok = false;
    }
    if (!run_malformed_cases()) {
        std::cerr << "malformed input test cases FAILED\n";
        all_ok = false;
    } else {
        std::cout << "[malformed] all fail-closed cases OK\n";
    }
    return all_ok ? 0 : 1;
}
