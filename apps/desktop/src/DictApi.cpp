#include "DictApi.hpp"

#include <QByteArray>
#include <QString>
#include <string_view>

namespace {
std::string errorText(dict_handle *handle, dict_status status, const char *operation) {
    size_t length = 0;
    const char *detail = dict_last_error(handle, &length);
    std::string message(operation);
    message += ": ";
    if (detail != nullptr && length != 0) {
        message.append(detail, length);
    } else {
        message += dict_status_name(status);
    }
    return message;
}
}

DictApi::DictApi(const QString &root) : root_(root) {
    static_assert(DICT_ABI_VERSION == 8, "Qt typed image-border semantics require Dict ABI 8");
    if (dict_abi_version() != DICT_ABI_VERSION) throw DictApiError("incompatible Dict C ABI");
    const QByteArray bytes = root.toUtf8();
    dict_status status = dict_open(bytes.constData(), static_cast<size_t>(bytes.size()), &handle_);
    if (status != DICT_OK) throw DictApiError(errorText(handle_, status, "open"), status);
}

DictApi::~DictApi() {
    dict_close(handle_);
}
void DictApi::check(dict_status status, const char *operation, bool allowNotFound) {
    if (status == DICT_OK || (allowNotFound && status == DICT_NOT_FOUND)) return;
    throw DictApiError(errorText(handle_, status, operation), status);
}

QByteArray DictApi::take(dict_buffer &buffer) {
    QByteArray result;
    if (buffer.data != nullptr && buffer.len != 0) {
        result = QByteArray(reinterpret_cast<const char *>(buffer.data), static_cast<qsizetype>(buffer.len));
    }
    dict_buffer_free(handle_, &buffer);
    // Qt's JSON string conversion drops a leading raw U+FEFF. Core responses
    // are valid JSON objects; escaping this code point preserves exact keys.
    result.replace(QByteArray::fromHex("efbbbf"), QByteArrayLiteral("\\ufeff"));
    return result;
}

void DictApi::validateRecord(const QByteArray &header, const QByteArray &title, const QByteArray &payload) {
    const auto status = static_cast<dict_status>(dict_validate_record(
        handle_, reinterpret_cast<const uint8_t *>(header.constData()), static_cast<size_t>(header.size()),
        title.constData(), static_cast<size_t>(title.size()),
        reinterpret_cast<const uint8_t *>(payload.constData()), static_cast<size_t>(payload.size())));
    if (status == DICT_OK) return;
    size_t length = 0;
    const char *detail = dict_last_error(handle_, &length);
    // ABI2 shares an internal-error status across several causes. Only this
    // exact validator diagnostic identifies malformed compiled presentation.
    const bool invalidEntryData = status == DICT_INTERNAL_ERROR && detail != nullptr
        && std::string_view(detail, length) == "validate record: InvalidPresentation";
    throw DictApiError(errorText(handle_, status, "validate compiled entry"), status, invalidEntryData);
}

void DictApi::select(const QString &language, const QString &kind) {
    const QByteArray lang = language.toUtf8();
    const QByteArray category = kind.toUtf8();
    const auto status = static_cast<dict_status>(dict_select(
        handle_, lang.constData(), static_cast<size_t>(lang.size()),
        category.constData(), static_cast<size_t>(category.size())));
    check(status, "select");
    language_ = language;
    kind_ = kind;
}
QByteArray DictApi::search(const QString &query, qsizetype limit, qsizetype offset) {
    const QByteArray text = query.toUtf8();
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_search_json(
        handle_, text.constData(), static_cast<size_t>(text.size()),
        static_cast<size_t>(limit), static_cast<size_t>(offset), &buffer));
    check(status, "search");
    return take(buffer);
}

QByteArray DictApi::lookup(const QString &query) {
    const QByteArray text = query.toUtf8();
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_lookup_json(
        handle_, text.constData(), static_cast<size_t>(text.size()), &buffer));
    check(status, "lookup", true);
    return take(buffer);
}
QByteArray DictApi::random() {
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_random_json(handle_, &buffer));
    check(status, "random", true);
    return take(buffer);
}

QByteArray DictApi::languages() {
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_languages_json(handle_, &buffer));
    check(status, "languages");
    return take(buffer);
}

QByteArray DictApi::stats() {
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_stats_json(handle_, &buffer));
    check(status, "stats");
    return take(buffer);
}
