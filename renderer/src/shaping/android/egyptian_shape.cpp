#include <jni.h>
#include <cstdint>
#include <memory>
#include "hb.h"
#include "hb-ot.h"

namespace {
constexpr jsize kMaxTextUnits = 32768;
constexpr unsigned kMaxGlyphs = 262144;
constexpr jlong kMaxFontBytes = 16 * 1024 * 1024;
constexpr jsize kHeader = 7;
constexpr jsize kStride = 4;

void fail(JNIEnv* env, const char* type, const char* message) {
    if (env->ExceptionCheck()) return;
    jclass cls = env->FindClass(type);
    if (cls != nullptr) env->ThrowNew(cls, message);
}

template <typename T, void (*Destroy)(T*)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;

struct Utf16 {
    JNIEnv* env;
    jstring text;
    const jchar* chars;
    ~Utf16() { if (chars != nullptr) env->ReleaseStringChars(text, chars); }
};

bool valid_utf16(const jchar* text, jsize length) {
    for (jsize i = 0; i < length; ++i) {
        const uint16_t c = text[i];
        if (c >= 0xD800 && c <= 0xDBFF) {
            if (++i >= length || text[i] < 0xDC00 || text[i] > 0xDFFF) return false;
        } else if (c >= 0xDC00 && c <= 0xDFFF) return false;
    }
    return true;
}
} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_app_smallthingz_dict_EgyptianNative_version(JNIEnv* env, jobject) {
    return env->NewStringUTF(hb_version_string());
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_app_smallthingz_dict_EgyptianNative_shape(JNIEnv* env, jobject, jobject bytes, jstring text) {
    if (bytes == nullptr || text == nullptr) {
        fail(env, "java/lang/IllegalArgumentException", "Missing Egyptian shaping input");
        return nullptr;
    }
    const jlong byte_count = env->GetDirectBufferCapacity(bytes);
    const auto* font_bytes = static_cast<const char*>(env->GetDirectBufferAddress(bytes));
    const jsize length = env->GetStringLength(text);
    if (font_bytes == nullptr || byte_count <= 0 || byte_count > kMaxFontBytes ||
        length <= 0 || length > kMaxTextUnits) {
        fail(env, "java/lang/IllegalArgumentException", "Egyptian shaping input exceeds its supported bounds");
        return nullptr;
    }
    Utf16 input{env, text, env->GetStringChars(text, nullptr)};
    if (input.chars == nullptr) return nullptr; // Pending JVM allocation exception.
    if (!valid_utf16(input.chars, length)) {
        fail(env, "java/lang/IllegalArgumentException", "Malformed UTF-16 Egyptian text");
        return nullptr;
    }
    // The direct buffer remains strongly reachable for this entire JNI call. Every
    // HB object is per-call; its read-only blob never outlives the borrowed bytes.
    Owned<hb_blob_t, hb_blob_destroy> blob(
        hb_blob_create(font_bytes, static_cast<unsigned>(byte_count), HB_MEMORY_MODE_READONLY, nullptr, nullptr),
        hb_blob_destroy);
    Owned<hb_face_t, hb_face_destroy> face(hb_face_create(blob.get(), 0), hb_face_destroy);
    const unsigned upem = hb_face_get_upem(face.get());
    if (hb_blob_get_length(blob.get()) != static_cast<unsigned>(byte_count) ||
        hb_face_get_glyph_count(face.get()) == 0 || upem == 0 || upem > 65536) {
        fail(env, "java/lang/IllegalArgumentException", "Invalid Egyptian font data");
        return nullptr;
    }
    Owned<hb_font_t, hb_font_destroy> font(hb_font_create(face.get()), hb_font_destroy);
    Owned<hb_buffer_t, hb_buffer_destroy> buffer(hb_buffer_create(), hb_buffer_destroy);
    hb_ot_font_set_funcs(font.get());
    hb_font_set_scale(font.get(), static_cast<int>(upem), static_cast<int>(upem));
    hb_buffer_add_utf16(buffer.get(), input.chars, length, 0, length);
    hb_buffer_set_direction(buffer.get(), HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer.get(), HB_SCRIPT_EGYPTIAN_HIEROGLYPHS);
    hb_buffer_set_language(buffer.get(), hb_language_from_string("egy", 3));
    const char* shapers[] = {"ot", nullptr};
    if (!hb_shape_full(font.get(), buffer.get(), nullptr, 0, shapers) ||
        !hb_buffer_allocation_successful(buffer.get())) {
        fail(env, "java/lang/IllegalStateException", "Egyptian shaping failed");
        return nullptr;
    }
    unsigned count = 0, position_count = 0;
    const auto* info = hb_buffer_get_glyph_infos(buffer.get(), &count);
    const auto* positions = hb_buffer_get_glyph_positions(buffer.get(), &position_count);
    hb_font_extents_t extents{};
    if (count == 0 || count > kMaxGlyphs || position_count != count ||
        info == nullptr || positions == nullptr || !hb_font_get_h_extents(font.get(), &extents)) {
        fail(env, "java/lang/IllegalStateException", "Egyptian shaping produced invalid output");
        return nullptr;
    }
    // Bounded before multiplication: at most 1,048,583 floats (about 4 MiB).
    const jsize result_length = kHeader + kStride * static_cast<jsize>(count);
    jfloatArray result = env->NewFloatArray(result_length);
    if (result == nullptr) return nullptr;
    jfloat* out = env->GetFloatArrayElements(result, nullptr);
    if (out == nullptr) return nullptr;
    int64_t x = 0, y = 0;
    bool valid = true;
    for (unsigned i = 0; i < count; ++i) {
        if (info[i].codepoint == 0 || info[i].codepoint >= hb_face_get_glyph_count(face.get()) ||
            info[i].cluster >= static_cast<unsigned>(length)) { valid = false; break; }
        const jsize at = kHeader + kStride * static_cast<jsize>(i);
        out[at] = static_cast<float>(info[i].codepoint);
        out[at + 1] = static_cast<float>(x + positions[i].x_offset);
        out[at + 2] = static_cast<float>(-(y + positions[i].y_offset)); // Android y is down.
        out[at + 3] = static_cast<float>(info[i].cluster); // Original UTF-16 offset.
        x += positions[i].x_advance;
        y += positions[i].y_advance;
    }
    out[0] = static_cast<float>(upem);
    out[1] = static_cast<float>(x);
    out[2] = static_cast<float>(-y);
    out[3] = static_cast<float>(-extents.ascender);
    out[4] = static_cast<float>(-extents.descender);
    out[5] = static_cast<float>(extents.line_gap);
    out[6] = static_cast<float>(count);
    env->ReleaseFloatArrayElements(result, out, valid ? 0 : JNI_ABORT);
    if (!valid || x <= 0 || y != 0) {
        fail(env, "java/lang/IllegalStateException", "Egyptian shaping produced missing glyphs or invalid advance");
        return nullptr;
    }
    return result;
}
