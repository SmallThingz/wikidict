#pragma once

#include <QByteArray>
#include <QString>
#include <stdexcept>

#include "dict.h"

class DictApiError final : public std::runtime_error {
public:
    explicit DictApiError(const std::string &message, dict_status status = DICT_INTERNAL_ERROR,
                          bool invalidEntryData = false)
        : std::runtime_error(message), status_(status), invalidEntryData_(invalidEntryData) {}
    [[nodiscard]] dict_status status() const { return status_; }
    [[nodiscard]] bool isInvalidEntryData() const { return invalidEntryData_; }
private:
    dict_status status_;
    bool invalidEntryData_;
};

class DictApi final {
public:
    explicit DictApi(const QString &root);
    ~DictApi();

    DictApi(const DictApi &) = delete;
    DictApi &operator=(const DictApi &) = delete;

    void validateRecord(const QByteArray &header, const QByteArray &title, const QByteArray &payload);
    void select(const QString &language, const QString &kind);
    QByteArray search(const QString &query, qsizetype limit = 40, qsizetype offset = 0);
    QByteArray lookup(const QString &query);
    QByteArray random();
    QByteArray languages();
    QByteArray stats();

    [[nodiscard]] const QString &language() const { return language_; }
    [[nodiscard]] const QString &kind() const { return kind_; }
    [[nodiscard]] const QString &root() const { return root_; }

private:
    QByteArray take(dict_buffer &buffer);
    void check(dict_status status, const char *operation, bool allowNotFound = false);

    dict_handle *handle_ = nullptr;
    QString root_;
    QString language_ = QStringLiteral("English");
    QString kind_ = QStringLiteral("language");
};
