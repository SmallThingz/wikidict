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
QByteArray blob(const QByteArray &heading, const QList<QByteArray> &titles, unsigned char kind = 1) {
    QByteArray bytes("WIKBLB08", 8);
    bytes.append(char(kind));
    if (kind == 1) { bytes.append("en", 2); bytes.append(char(0)); bytes.append(heading); bytes.append(char(0)); }
    for (const auto &title : titles) {
        bytes.append(title); bytes.append(char(0)); bytes.append(char(4)); bytes.append("DPR2", 4);
    }
    return bytes;
}
void appendLength(QByteArray &bytes, quint64 value) {
    do {
        const auto byte = static_cast<unsigned char>(value & 127);
        value >>= 7;
        bytes.append(char(byte | (value ? 128 : 0)));
    } while (value);
}
QByteArray aliasRecord(const QByteArray &source = "Cats", const QByteArray &target = "cat") {
    const QByteArray fixture = read(QStringLiteral("tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
    qsizetype at = 9;
    for (int field = 0; field < 3; ++field) { at = fixture.indexOf('\0', at) + 1; require(at > 0, "fixture framing"); }
    quint64 length = 0;
    for (int shift = 0; ; shift += 7) {
        require(at < fixture.size() && shift < 64, "fixture payload length");
        const auto byte = static_cast<unsigned char>(fixture[at++]);
        length |= quint64(byte & 127) << shift;
        if (!(byte & 128)) break;
    }
    require(length <= quint64(fixture.size() - at), "fixture payload extent");
    const QByteArray presentation = fixture.mid(at, qsizetype(length));
    QByteArray payload("DAL1", 4);
    payload.append(QByteArray(4, '\0'));
    payload.append(char(1)); payload.append(char(1));
    payload.append(QByteArray(4, '\0')); payload.append(char(1));
    for (const auto &field : {source, source, target, target, target, QByteArray("Noun"), presentation}) {
        appendLength(payload, quint64(field.size())); payload.append(field);
    }
    return payload;
}
QByteArray aliasBlob(const QByteArray &payload, const QByteArray &key = "1\tCats") {
    QByteArray bytes("WIKBLB08", 8); bytes.append(char(8)); bytes.append(key); bytes.append('\0');
    appendLength(bytes, quint64(payload.size())); bytes.append(payload);
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


        const QByteArray supplemental = blob("", {QStringLiteral("Annexe:école").toUtf8(), QStringLiteral("Appendix:école").toUtf8()}, 7);
        write(source, supplemental);
        auto extra = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
        require(extra->dictionary.kind == QStringLiteral("supplemental") && extra->dictionary.words == 2, "supplemental import metadata");
        require(extra->dictionary.heading == QStringLiteral("Supplemental"), "supplemental heading");
        require(extra->dictionary.path.endsWith(QStringLiteral("/supplemental.wikblb")), "supplemental filename");
        LibraryStorage::commitImport(root, *extra);
        require(LibraryStorage::installed(root).size() == 1, "supplemental-only installation");
        require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == QByteArrayLiteral("heading\n"), "supplemental is not a language");
        for (unsigned char tag : {0, 9, 255}) {
            QByteArray bad = supplemental; bad[8] = char(tag); write(source, bad);
            rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject invalid kind tags");
            require(read(extra->dictionary.path) == supplemental && LibraryStorage::installed(root).size() == 1, "invalid tag preserves supplemental");
        }
        if (!xz.isEmpty()) {
            write(source, supplemental);
            const QString compressed = temporary.filePath(QStringLiteral("supplemental.wikblb.xz"));
            QProcess process; process.setStandardOutputFile(compressed);
            process.start(xz, {QStringLiteral("--compress"), QStringLiteral("--stdout"), QStringLiteral("--"), source});
            require(process.waitForFinished(10000) && process.exitCode() == 0, "compress supplemental fixture");
            auto packed = LibraryStorage::prepareImport(root, compressed, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *packed);
            require(!QFileInfo::exists(extra->dictionary.path) && QFileInfo::exists(extra->dictionary.path + QStringLiteral(".xz")), "compressed supplemental retires raw");
            require(LibraryStorage::installed(root)[0].kind == QStringLiteral("supplemental"), "compressed supplemental metadata");
        }
        LibraryStorage::removeDictionary(root, LibraryStorage::installed(root)[0]);
        require(LibraryStorage::installed(root).isEmpty(), "remove supplemental");

        const QByteArray redirect = aliasRecord();
        const QByteArray aliases = aliasBlob(redirect);
        write(source, aliases);
        auto redirects = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
        require(redirects->dictionary.kind == QStringLiteral("alias") && redirects->dictionary.words == 1, "alias import metadata");
        require(redirects->dictionary.path.endsWith(QStringLiteral("/aliases.wikblb")), "alias sidecar filename");
        LibraryStorage::commitImport(root, *redirects);
        require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == QByteArrayLiteral("heading\n"), "aliases are not a language");
        require(LibraryStorage::installed(root).size() == 1, "alias sidecar installed");
        for (qsizetype end = 0; end < redirect.size(); ++end) {
            write(source, aliasBlob(redirect.left(end)));
            rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject truncated alias fields");
        }
        for (const QByteArray &bad : {aliasBlob(redirect, "1\tOther"), aliasBlob(redirect, "2\tCats"),
                aliasBlob(redirect + 'x'), aliasBlob("DPR2"), aliasBlob(aliasRecord(QByteArray("\xff", 1)))}) {
            write(source, bad);
            rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject malformed alias identity or framing");
        }
        for (const auto &mutation : QList<QPair<qsizetype, char>>{{4, 1}, {8, 8}, {9, 2}, {10, 1}, {14, 8}}) {
            QByteArray bad = redirect; bad[mutation.first] = mutation.second; write(source, aliasBlob(bad));
            rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject invalid alias kinds or namespaces");
        }
        require(read(redirects->dictionary.path) == aliases, "malformed alias import preserves installed sidecar");
        if (!xz.isEmpty()) {
            write(source, aliases);
            const QString compressed = temporary.filePath(QStringLiteral("aliases.wikblb.xz"));
            QProcess process; process.setStandardOutputFile(compressed);
            process.start(xz, {QStringLiteral("--compress"), QStringLiteral("--stdout"), QStringLiteral("--"), source});
            require(process.waitForFinished(10000) && process.exitCode() == 0, "compress alias fixture");
            auto packed = LibraryStorage::prepareImport(root, compressed, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *packed);
            require(!QFileInfo::exists(redirects->dictionary.path) && QFileInfo::exists(redirects->dictionary.path + QStringLiteral(".xz")), "compressed aliases retire raw");
            require(LibraryStorage::installed(root)[0].kind == QStringLiteral("alias"), "compressed alias metadata");
        }
        LibraryStorage::removeDictionary(root, LibraryStorage::installed(root)[0]);
        require(LibraryStorage::installed(root).isEmpty(), "remove alias sidecar");
        for (unsigned char kind = 2; kind <= 8; ++kind) {
            write(source, blob("", {}, kind));
            auto empty = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
            require(empty->dictionary.words == 0, "empty non-language collection accepted");
            LibraryStorage::commitImport(root, *empty);
            LibraryStorage::removeDictionary(root, LibraryStorage::installed(root)[0]);
        }

        const QByteArray bomHeading = QByteArray::fromHex("efbbbf") + "English";
        const QString bomRoot = temporary.filePath(QStringLiteral("bom-heading"));
        const QString bomHash = QString::fromLatin1(QCryptographicHash::hash(bomHeading, QCryptographicHash::Sha256).toHex());
        write(source, blob(bomHeading, {"apple"}));
        auto bom = LibraryStorage::prepareImport(bomRoot, source, {}, -1, cancelled, progress,
            QStringLiteral("enwiktionary-20261001-") + bomHash + QStringLiteral(".wikblb"));
        require(bom->dictionary.heading == QChar(0xfeff) + QStringLiteral("English"), "binary heading preserves initial BOM");
        require(bom->dictionary.path.endsWith(bomHash + QStringLiteral(".wikblb")), "heading filename hashes exact bytes including BOM");
        LibraryStorage::commitImport(bomRoot, *bom);
        require(read(QDir(bomRoot).filePath(QStringLiteral("languages.tsv"))) == "heading\n" + bomHeading + '\n', "manifest preserves initial heading BOM");
        require(LibraryStorage::installed(bomRoot)[0].heading.toUtf8() == bomHeading, "installed heading preserves exact UTF-8");

        const QString scoped = temporary.filePath(QStringLiteral("scoped"));
        const QString canonicalLanguage = QStringLiteral("enwiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb");
        const QString canonicalAlias = QStringLiteral("enwiktionary-20261001-aliases.wikblb");
        const QString editionMarker = QDir(scoped).filePath(QStringLiteral(".desktop-edition"));
        write(source, original);
        auto scopedLanguage = LibraryStorage::prepareImport(scoped, source, {}, -1, cancelled, progress, canonicalLanguage);
        require(!QFileInfo::exists(editionMarker), "prepare does not bind an edition");
        cancelled = true;
        rejects([&] { LibraryStorage::prepareImport(scoped, source, {}, -1, cancelled, progress, canonicalLanguage); }, "cancel canonical import");
        cancelled = false;
        require(!QFileInfo::exists(editionMarker), "cancellation preserves unbound edition");
        LibraryStorage::commitImport(scoped, *scopedLanguage);
        require(read(editionMarker) == QByteArrayLiteral("enwiktionary-20261001\n"), "successful import binds exact edition and date");
        require(LibraryStorage::sourceHost(scoped) == QStringLiteral("en.wiktionary.org"), "source host comes from edition identity");
        require(LibraryStorage::sourceHost(root).isEmpty(), "unlabelled source has no inferred English host");
        write(source, aliases);
        auto scopedAliases = LibraryStorage::prepareImport(scoped, source, {}, -1, cancelled, progress, canonicalAlias);
        LibraryStorage::commitImport(scoped, *scopedAliases);
        for (const QString &name : {QStringLiteral("afwiktionary-20261001-aliases.wikblb"),
                QStringLiteral("enwiktionary-20261101-aliases.wikblb"), QStringLiteral("aliases.wikblb"),
                QStringLiteral("enwiktionary-20261001-supplemental.wikblb")})
            rejects([&] { LibraryStorage::prepareImport(scoped, source, {}, -1, cancelled, progress, name); }, "reject mixed or mislabelled editions");
        const QString invalidDateRoot = temporary.filePath(QStringLiteral("invalid-date"));
        for (const QString &name : {QStringLiteral("enwiktionary-20260230-aliases.wikblb"), QStringLiteral("enwiktionary-00000000-aliases.wikblb")})
            rejects([&] { LibraryStorage::prepareImport(invalidDateRoot, source, {}, -1, cancelled, progress, name); }, "reject impossible snapshot dates in an empty library");
        require(read(editionMarker) == QByteArrayLiteral("enwiktionary-20261001\n") && read(scopedAliases->dictionary.path) == aliases, "failed association preserves edition and aliases");
        write(source, original);
        auto unknown = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress);
        LibraryStorage::commitImport(root, *unknown);
        write(source, aliases);
        rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress, canonicalAlias); }, "canonical aliases cannot bless unscoped dictionaries");
        require(!QFileInfo::exists(QDir(root).filePath(QStringLiteral(".desktop-edition"))), "rejected association has no marker");
        LibraryStorage::removeDictionary(root, LibraryStorage::installed(root)[0]);

        const QString published = temporary.filePath(QStringLiteral("published-root"));
        require(QDir().mkpath(published), "published fixture root");
        write(QDir(published).filePath(QStringLiteral("complete.json")), QByteArrayLiteral("{\"edition\":\"arwiktionary\",\"date\":\"20261001\"}"));
        require(LibraryStorage::sourceHost(published) == QStringLiteral("ar.wiktionary.org"), "published source metadata preserves Arabic edition");

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
