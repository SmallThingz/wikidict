#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QUrl>
#include <atomic>
#include <functional>
#include <memory>

class QTemporaryDir;

namespace LibraryStorage {
inline constexpr qint64 MaxDownloadBytes = 32LL * 1024 * 1024 * 1024;
inline constexpr qint64 SpaceReserve = 32LL * 1024 * 1024;

struct Dictionary {
    QString heading;
    QString kind;
    QString path;
    qint64 bytes = 0;
    qint64 words = -1;
    QByteArray sha256;
};
struct CatalogItem {
    QUrl url;
    QString label;
    qint64 bytes = -1;
    QByteArray sha256;
};
struct PreparedImport {
    std::unique_ptr<QTemporaryDir> directory;
    Dictionary dictionary;
    QString stagedFile;
    QString editionGroup;
    ~PreparedImport();
};
using Progress = std::function<void(const QString &, qint64, qint64)>;

QString defaultSource();
QString sourceHost(const QString &root);
bool isHttpsUrl(const QUrl &url);
QList<CatalogItem> parseCatalog(const QByteArray &data);
QList<Dictionary> installed(const QString &root);
QString dictionaryPath(const QString &root, const Dictionary &dictionary);
QString formatBytes(qint64 bytes);
bool containsDictionary(const QString &root, const Dictionary &dictionary);
std::shared_ptr<PreparedImport> prepareImport(const QString &root, const QString &source,
    const QByteArray &expectedHash, qint64 expectedBytes, const std::atomic_bool &cancel,
    const Progress &progress, const QString &sourceName = {});
void commitImport(const QString &root, PreparedImport &prepared);
void removeDictionary(const QString &root, const Dictionary &dictionary);
}
