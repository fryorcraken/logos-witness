#include "exif_strip.h"

#include <csetjmp>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" {
#include <jpeglib.h>
}

namespace logos::witness {

namespace {

// libjpeg's default error_exit calls exit(); replace with a longjmp so a
// malformed input becomes a clean StripResult{ok=false, ...} rather than
// killing the process. We also count corruption warnings (msg_level < 0)
// so we can fail closed on truncated / mid-stream-corrupted inputs that
// libjpeg would otherwise paper over with "premature end of data
// segment" recovery.
//
// Note: msg_level < 0 covers every libjpeg warning, not just corruption
// (e.g. JWRN_JFIF_MAJOR fires for an unfamiliar JFIF revision number
// without any silent zero-fill). Treating all warnings as fail-closed
// is intentional — for a privacy trust boundary, "when in doubt reject"
// is the right posture; the upstream UI re-prompts the user for a
// different file. Renaming `corruption_warnings` to `warnings_seen`
// would be more accurate; left as-is for diff readability.
struct ErrMgr {
    struct jpeg_error_mgr pub;
    std::jmp_buf jmp;
    char message[JMSG_LENGTH_MAX];
    int corruption_warnings;
    char first_warning[JMSG_LENGTH_MAX];
};

void error_exit_longjmp(j_common_ptr cinfo) {
    auto* err = reinterpret_cast<ErrMgr*>(cinfo->err);
    (*cinfo->err->format_message)(cinfo, err->message);
    std::longjmp(err->jmp, 1);
}

void emit_message_record(j_common_ptr cinfo, int msg_level) {
    auto* err = reinterpret_cast<ErrMgr*>(cinfo->err);
    if (msg_level < 0) {
        if (err->corruption_warnings == 0) {
            (*cinfo->err->format_message)(cinfo, err->first_warning);
        }
        ++err->corruption_warnings;
    }
    // Suppress trace messages (msg_level >= 0); we have no use for them.
}

} // namespace

StripResult strip_jpeg(const std::string& input) {
    StripResult result;

    if (input.size() < 4) {
        result.error = "input too short to be a JPEG";
        return result;
    }
    // Cheap up-front SOI check. libjpeg would catch this too, but the
    // error message is less obvious and the cost here is two bytes.
    const auto* in = reinterpret_cast<const unsigned char*>(input.data());
    if (in[0] != 0xFF || in[1] != 0xD8) {
        result.error = "missing JPEG SOI marker";
        return result;
    }

    struct jpeg_decompress_struct srcinfo{};
    struct jpeg_compress_struct dstinfo{};
    ErrMgr src_err{};
    ErrMgr dst_err{};

    unsigned char* outbuf = nullptr;
    unsigned long outsize = 0;

    srcinfo.err = jpeg_std_error(&src_err.pub);
    src_err.pub.error_exit = error_exit_longjmp;
    src_err.pub.emit_message = emit_message_record;
    src_err.corruption_warnings = 0;
    src_err.first_warning[0] = '\0';

    dstinfo.err = jpeg_std_error(&dst_err.pub);
    dst_err.pub.error_exit = error_exit_longjmp;
    dst_err.pub.emit_message = emit_message_record;
    dst_err.corruption_warnings = 0;
    dst_err.first_warning[0] = '\0';

    // setjmp must happen before any libjpeg call that might error out.
    // Both decompress and compress structs share the same recovery path.
    //
    // C++/setjmp interaction: `result` (which owns std::string members)
    // lives on the calling stack frame and is destroyed by the function's
    // normal return path. No non-trivial-destructor C++ object is
    // constructed between setjmp and the longjmp sites below, so the
    // conditional-support rule in [csetjmp.syn] is satisfied. libjpeg's
    // internal state lives in cinfo's mem allocator and is released by
    // the explicit jpeg_destroy_* calls in the recovery blocks.
    if (setjmp(src_err.jmp)) {
        result.ok = false;
        result.error = std::string("libjpeg read error: ") + src_err.message;
        jpeg_destroy_compress(&dstinfo);
        jpeg_destroy_decompress(&srcinfo);
        if (outbuf) std::free(outbuf);
        result.bytes.clear();
        return result;
    }
    if (setjmp(dst_err.jmp)) {
        result.ok = false;
        result.error = std::string("libjpeg write error: ") + dst_err.message;
        jpeg_destroy_compress(&dstinfo);
        jpeg_destroy_decompress(&srcinfo);
        if (outbuf) std::free(outbuf);
        result.bytes.clear();
        return result;
    }

    jpeg_create_decompress(&srcinfo);
    jpeg_create_compress(&dstinfo);

    // We deliberately do NOT call jpeg_save_markers, so APP0..APP15 and
    // COM payloads are dropped at read time and never make it to the
    // copy path.

    jpeg_mem_src(&srcinfo,
                 reinterpret_cast<const unsigned char*>(input.data()),
                 input.size());

    int header_status = jpeg_read_header(&srcinfo, TRUE);
    if (header_status != JPEG_HEADER_OK) {
        result.ok = false;
        result.error = "jpeg_read_header did not return JPEG_HEADER_OK";
        jpeg_destroy_compress(&dstinfo);
        jpeg_destroy_decompress(&srcinfo);
        return result;
    }

    jvirt_barray_ptr* coef_arrays = jpeg_read_coefficients(&srcinfo);
    if (!coef_arrays) {
        result.ok = false;
        result.error = "jpeg_read_coefficients returned null";
        jpeg_destroy_compress(&dstinfo);
        jpeg_destroy_decompress(&srcinfo);
        return result;
    }

    jpeg_mem_dest(&dstinfo, &outbuf, &outsize);
    jpeg_copy_critical_parameters(&srcinfo, &dstinfo);

    // Force a JFIF APP0 header even if the source was Exif-only — most
    // viewers tolerate either, but a Reference will eventually round-trip
    // through Storage and downstream consumers and JFIF is the safer
    // structural default.
    dstinfo.write_JFIF_header = TRUE;
    // Defense-in-depth beyond SPEC §7.1: jpeg_copy_critical_parameters
    // propagates the source's JFIF density tuple (density_unit,
    // X_density, Y_density). An unusual triple (e.g. 350/350 from
    // certain phones) is a weak fingerprint. Reset to the JFIF default
    // "no aspect ratio info" tuple so every stripped output reports
    // the same density. SPEC §7.1 lists EXIF/XMP/ICC/maker-notes/
    // thumbnail explicitly; density is not in the call-out but is
    // structurally identifying enough to zero out for free.
    dstinfo.density_unit = 0;  // 0 = no units, X/Y_density form aspect ratio only
    dstinfo.X_density = 1;
    dstinfo.Y_density = 1;
    dstinfo.write_Adobe_marker = FALSE;

    jpeg_write_coefficients(&dstinfo, coef_arrays);
    jpeg_finish_compress(&dstinfo);
    jpeg_finish_decompress(&srcinfo);

    if (src_err.corruption_warnings > 0) {
        // libjpeg emits "Premature end of data segment" / "Corrupt JPEG
        // data" via emit_message rather than error_exit, then papers
        // over the missing data with zeros. That's silent partial
        // output, which SPEC §7.1 forbids — fail closed instead.
        result.ok = false;
        result.error = std::string("malformed JPEG input: ")
                       + src_err.first_warning;
    } else if (outbuf && outsize > 0) {
        result.bytes.assign(reinterpret_cast<const char*>(outbuf),
                            static_cast<std::size_t>(outsize));
        result.ok = true;
    } else {
        result.error = "libjpeg produced empty output";
    }

    jpeg_destroy_compress(&dstinfo);
    jpeg_destroy_decompress(&srcinfo);
    if (outbuf) std::free(outbuf);
    return result;
}

} // namespace logos::witness
