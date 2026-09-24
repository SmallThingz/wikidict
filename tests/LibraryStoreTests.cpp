#include "LibraryStore.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
void write(const QString &path, const QByteArray &bytes) {
    QFile file(path);
    require(file.open(QIODevice::WriteOnly), "open fixture");
    require(file.write(bytes) == bytes.size(), "write fixture");
}
QByteArray read(const QString &path) {
    QFile file(path);
    require(file.open(QIODevice::ReadOnly), "open result");
    return file.readAll();
}
void rejects(const std::function<void()> &action, const char *message) {
    try { action(); } catch (const std::exception &) { return; }
    throw std::runtime_error(message);
}
QByteArray blob(const QByteArray &heading, const QList<QByteArray> &titles) {
    QByteArray bytes("WIKBLB08", 8);
    bytes.append(char(1));
    bytes.append("en", 2); bytes.append(char(0));
    bytes.append(heading); bytes.append(char(0));
    for (const auto &title : titles) {
        bytes.append(title); bytes.append(char(0)); bytes.append(char(4)); bytes.append("DPR2", 4);
    }
    return bytes;
}
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        require(QDir().mkpath(QStringLiteral(".tmp")), "temporary parent directory");
        QTemporaryDir temporary(QDir::current().filePath(QStringLiteral(".tmp/library-tests-XXXXXX")));
        require(temporary.isValid(), "temporary directory");
        const QString root = temporary.filePath(QStringLiteral("library"));
        const QString source = temporary.filePath(QStringLiteral("source.wikblb"));
        std::atomic_bool cancelled = false;
        qint64 events = 0;
        const auto progress = [&](const QString &, qint64, qint64) { ++events; };
        const QByteArray original = blob("English", {"apple", "banana"});
        write(source, original);
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
        require(prepared->dictionary.words == 2, "word count");
        require(prepared->dictionary.path.endsWith(QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")), "core SHA-256 heading filename");
        require(!LibraryStorage::containsDictionary(root, prepared->dictionary), "prepare must not publish");
        LibraryStorage::commitImport(root, *prepared);
        const QString installedPath = prepared->dictionary.path;
        require(read(installedPath) == original, "installed file");
        require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == QByteArrayLiteral("heading\nEnglish\n"), "core language manifest");
        auto installed = LibraryStorage::installed(root);
        require(installed.size() == 1 && installed[0].words == 2, "installed metadata");
        require(installed[0].sha256 == QCryptographicHash::hash(original, QCryptographicHash::Sha256).toHex(), "installed hash");
        require(events > 0, "progress");
        write(source, blob("English", {"banana", "apple"}));
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject unsorted titles");
        require(read(installedPath) == original, "bad import preserves installed dictionary");
        write(source, blob("English", {"apple", "apple"}));
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject duplicates");
        write(source, blob("English", {}));
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject empty dictionary");
        write(source, original.left(original.size() - 1));
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject truncation");
        write(source, original);
        rejects([&] { LibraryStorage::prepareImport(root, source, QByteArray(64, '0'), -1, cancelled, progress); }, "reject checksum mismatch");
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, original.size() + 1, cancelled, progress); }, "reject advertised size mismatch");
        cancelled = true;
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "honor cancellation");
        cancelled = false;
        require(read(installedPath) == original, "cancel preserves installed dictionary");
        const QString marker = QDir(root).filePath(QStringLiteral(".incomplete"));
        write(marker, {});
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject unfinished build");
        QFile::remove(marker);
        const QByteArray replacement = blob("English", {"cherry"});
        write(source, replacement);
        auto update = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
        LibraryStorage::commitImport(root, *update);
        require(read(installedPath) == replacement, "replace dictionary");
        require(LibraryStorage::installed(root)[0].words == 1, "refresh replacement metadata");
        require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == QByteArrayLiteral("heading\nEnglish\n"), "replacement does not duplicate headings");

        const QString xz = QStandardPaths::findExecutable(QStringLiteral("xz"));
        if (!xz.isEmpty()) {
            const QString compressed = temporary.filePath(QStringLiteral("compressed.wikblb.xz"));
            QProcess process;
            process.setStandardOutputFile(compressed);
            process.start(xz, {QStringLiteral("--compress"), QStringLiteral("--stdout"), QStringLiteral("--"), source});
            require(process.waitForFinished(10000) && process.exitCode() == 0, "compress fixture");
            auto packed = LibraryStorage::prepareImport(root, compressed, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *packed);
            require(!QFileInfo::exists(installedPath) && QFileInfo::exists(installedPath + QStringLiteral(".xz")), "compressed replacement retires raw file");
            require(LibraryStorage::installed(root)[0].words == 1, "compressed import metadata");
        }
        LibraryStorage::removeDictionary(root, LibraryStorage::installed(root)[0]);
        require(LibraryStorage::installed(root).isEmpty(), "remove dictionary");
        require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == QByteArrayLiteral("heading\n"), "remove heading");

        const auto catalog = LibraryStorage::parseCatalog(QByteArrayLiteral("# catalogue\nhttps://example.org/English.wikblb\tEnglish\t123\t") + QByteArray(64, 'a') + '\n');
        require(catalog.size() == 1 && catalog[0].bytes == 123 && catalog[0].label == QStringLiteral("English"), "parse catalogue");
        require(LibraryStorage::parseCatalog(QByteArrayLiteral("https://example.org/English.wikblb.xz"))[0].label == QStringLiteral("English"), "compressed default label");
        for (const auto &bad : {QByteArrayLiteral("http://example.org/a.wikblb"), QByteArrayLiteral("https://user:pass@example.org/a.wikblb"),
                QByteArrayLiteral("https://example.org/a.wikblb#fragment"), QByteArrayLiteral("https://example.org/a.wikblb\ta\t0"),
                QByteArrayLiteral("https://example.org/a.wikblb\ta\t1\tbad"), QByteArrayLiteral("https://example.org/a.wikblb\nhttps://example.org/a.wikblb")}) {
            rejects([&] { LibraryStorage::parseCatalog(bad); }, "reject malformed catalogue");
        }
        rejects([&] { LibraryStorage::parseCatalog(QByteArray(2 * 1024 * 1024 + 1, 'a')); }, "catalogue byte limit");
        require(!LibraryStorage::isHttpsUrl(QUrl(QStringLiteral("file:///tmp/dictionary"))), "HTTPS only");
        if (argc > 1) {
            auto real = LibraryStorage::prepareImport(root, QString::fromLocal8Bit(argv[1]), {}, -1, cancelled, progress);
            require(real->dictionary.words > 0, "real dictionary word count");
            LibraryStorage::commitImport(root, *real);
            require(LibraryStorage::installed(root).size() == 1, "real dictionary installed");
            std::cout << "Real dictionary: " << real->dictionary.heading.toStdString() << ", " << real->dictionary.words << " words\n";
        }
        std::cout << "Library storage: import, replace, compressed import, removal, cancellation, validation and catalogue checks passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
