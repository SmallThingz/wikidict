#include "DictApi.hpp"

#include <QByteArray>
#include <QString>

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
    const QByteArray bytes = root.toUtf8();
    dict_status status = dict_open(bytes.constData(), static_cast<size_t>(bytes.size()), &handle_);
    if (status != DICT_OK) throw DictApiError(errorText(handle_, status, "open"));
    select(language_, kind_);
}

DictApi::~DictApi() {
    dict_close(handle_);
}
void DictApi::check(dict_status status, const char *operation, bool allowNotFound) {
    if (status == DICT_OK || (allowNotFound && status == DICT_NOT_FOUND)) return;
    throw DictApiError(errorText(handle_, status, operation));
}

QByteArray DictApi::take(dict_buffer &buffer) {
    QByteArray result;
    if (buffer.data != nullptr && buffer.len != 0) {
        result = QByteArray(reinterpret_cast<const char *>(buffer.data), static_cast<qsizetype>(buffer.len));
    }
    dict_buffer_free(handle_, &buffer);
    return result;
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

QByteArray DictApi::lookup(const QString &query, bool withSource, bool coreOnly) {
    const QByteArray text = query.toUtf8();
    uint32_t flags = 0;
    if (withSource) flags |= DICT_LOOKUP_WITH_SOURCE;
    if (coreOnly) flags |= DICT_LOOKUP_CORE_ONLY;
    dict_buffer buffer{};
    const auto status = static_cast<dict_status>(dict_lookup_json(
        handle_, text.constData(), static_cast<size_t>(text.size()), flags, &buffer));
    check(status, "lookup", true);
    return take(buffer);
}
QByteArray DictApi::random(bool withSource) {
    dict_buffer buffer{};
    const uint32_t flags = withSource ? DICT_LOOKUP_WITH_SOURCE : 0;
    const auto status = static_cast<dict_status>(dict_random_json(handle_, flags, &buffer));
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
