// SPEC §7.1 strip pipeline. Takes a JPEG byte buffer, returns a buffer
// with every metadata marker dropped: EXIF (APP1 with Exif\0\0 prefix),
// XMP (APP1 with http://ns.adobe.com/xap/1.0/), ICC profile (APP2 with
// ICC_PROFILE\0), Photoshop / Adobe / JFXX / generic APPn markers,
// COM comment segments, and the embedded thumbnail that lives inside
// the EXIF IFD1 (gone by virtue of dropping APP1 wholesale). The
// JFIF APP0 marker is retained — it is structural, contains no PII,
// and stripping it makes some decoders unhappy.
//
// Implementation copies DCT coefficients losslessly via libjpeg-turbo's
// jpeg_read_coefficients / jpeg_write_coefficients path. The decoded
// pixel content is byte-identical to the input.
//
// On malformed input the function fails closed: `ok == false`, `bytes`
// empty, `error` populated. There is no partial-output path.

#pragma once

#include <string>

namespace logos::witness {

struct StripResult {
    bool ok = false;
    std::string bytes;
    std::string error;
};

StripResult strip_jpeg(const std::string& input);

} // namespace logos::witness
