#pragma once

#include <QByteArray>
#include <QList>
#include <QSet>
#include <QString>
#include <QUrl>
#include <atomic>
#include <functional>
#include <memory>
#include <stdexcept>

class QTemporaryDir;

namespace LibraryStorage {
// A failed rollback left the installed root different from its prior state.
class UnrestoredMutation final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};
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

// Restore an interrupted library mutation before opening its installed records.
void recoverPendingMutation(const QString &root);
QString defaultSource();
QString sourceHost(const QString &root);
QString editionIdentity(const QString &root);
bool isHttpsUrl(const QUrl &url);
QList<CatalogItem> parseCatalog(const QByteArray &data);
bool catalogItemInstalled(const CatalogItem &item, const QString &installedEdition,
    const QSet<QByteArray> &installedHashes);
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
