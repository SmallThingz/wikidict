#include "LibraryStore.hpp"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QLocale>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QStringDecoder>
#include <QTemporaryDir>
#include <QtEndian>
#include <algorithm>
#include <stdexcept>

namespace LibraryStorage {
namespace {
[[noreturn]] void fail(const QString &message) { throw std::runtime_error(message.toStdString()); }
void checkCancel(const std::atomic_bool &cancel) {
    if (cancel.load()) fail(QStringLiteral("Cancelled"));
}
const QStringList kinds = {QStringLiteral("language"), QStringLiteral("thesaurus"),
    QStringLiteral("citations"), QStringLiteral("reconstruction"), QStringLiteral("rhymes"),
    QStringLiteral("sign_gloss"), QStringLiteral("supplemental"), QStringLiteral("alias")};

QString featureName(const QString &kind) {
    if (kind == QStringLiteral("sign_gloss")) return QStringLiteral("sign-gloss.wikblb");
    if (kind == QStringLiteral("alias")) return QStringLiteral("aliases.wikblb");
    if (!kinds.contains(kind) || kind == QStringLiteral("language")) fail(QStringLiteral("Unknown dictionary kind."));
    return kind + QStringLiteral(".wikblb");
}
void ensureRoot(const QString &root) {
    if (root.isEmpty() || !QDir().mkpath(root)) fail(QStringLiteral("Cannot create the dictionary folder."));
    if (QFileInfo::exists(QDir(root).filePath(QStringLiteral(".incomplete"))))
        fail(QStringLiteral("This dictionary folder contains an unfinished build. Choose another folder or finish the build first."));
    const QFileInfo languages(QDir(root).filePath(QStringLiteral("languages")));
    if (languages.isSymLink()) fail(QStringLiteral("The languages folder is a symbolic link. Choose a regular dictionary folder."));
}
QByteArray readFile(const QString &path, qint64 limit) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) fail(QStringLiteral("Cannot read %1: %2").arg(QFileInfo(path).fileName(), file.errorString()));
    if (file.size() > limit) fail(QStringLiteral("%1 is too large.").arg(QFileInfo(path).fileName()));
    const auto data = file.readAll();
    if (file.error() != QFileDevice::NoError) fail(file.errorString());
    return data;
}
QString editionGroup(const QString &name) {
    const auto match = QRegularExpression(QStringLiteral("^([a-z][a-z0-9_-]*wiktionary-[0-9]{8})-(?:[0-9a-f]{64}|aliases|supplemental|thesaurus|citations|reconstruction|rhymes|sign-gloss)\\.wikblb(?:\\.xz)?$")).match(QFileInfo(name).fileName());
    if (!match.hasMatch()) return {};
    const QString group = match.captured(1);
    const QString date = group.right(8);
    if (QDate::fromString(date, QStringLiteral("yyyyMMdd")).toString(QStringLiteral("yyyyMMdd")) != date)
        fail(QStringLiteral("The release filename contains an invalid snapshot date."));
    return group;
}
QString installedEditionGroup(const QString &root) {
    const QString path = QDir(root).filePath(QStringLiteral(".desktop-edition"));
    QByteArray bytes;
    if (QFileInfo::exists(path)) bytes = readFile(path, 256);
    else {
        const QString completePath = QDir(root).filePath(QStringLiteral("complete.json"));
        if (!QFileInfo::exists(completePath)) return {};
        const auto complete = QJsonDocument::fromJson(readFile(completePath, 4 * 1024 * 1024)).object();
        bytes = (complete.value(QStringLiteral("edition")).toString() + QChar('-') + complete.value(QStringLiteral("date")).toString()).toUtf8();
    }
    const QString group = QString::fromUtf8(bytes).trimmed();
    if (!bytes.isValidUtf8() || !QRegularExpression(QStringLiteral("^[a-z][a-z0-9_-]*wiktionary-[0-9]{8}$")).match(group).hasMatch() ||
        QDate::fromString(group.right(8), QStringLiteral("yyyyMMdd")).toString(QStringLiteral("yyyyMMdd")) != group.right(8))
        fail(QStringLiteral("This dictionary folder has an invalid edition marker."));
    return group;
}
void checkEditionGroup(const QString &root, const QString &incoming) {
    const QString current = installedEditionGroup(root);
    if (!current.isEmpty() && current != incoming)
        fail(QStringLiteral("This folder belongs to %1. Choose a separate folder for another edition or unlabelled files.").arg(current));
    if (current.isEmpty() && !incoming.isEmpty()) {
        for (const QString &directory : {root, QDir(root).filePath(QStringLiteral("languages"))})
            if (!QDir(directory).entryList({QStringLiteral("*.wikblb"), QStringLiteral("*.wikblb.xz")}, QDir::Files).isEmpty())
                fail(QStringLiteral("The existing files have no edition identity. Import this release into an empty folder."));
    }
}
QStringList headings(const QString &root) {
    const QString path = QDir(root).filePath(QStringLiteral("languages.tsv"));
    if (!QFileInfo::exists(path)) return {};
    const QByteArray bytes = readFile(path, 16 * 1024 * 1024);
    if (!bytes.isValidUtf8()) fail(QStringLiteral("The language list is not valid UTF-8."));
    QStringList lines = QString::fromUtf8(bytes).split(QLatin1Char('\n'));
    if (!lines.isEmpty() && lines.last().isEmpty()) lines.removeLast();
    if (lines.isEmpty() || lines.takeFirst() != QStringLiteral("heading"))
        fail(QStringLiteral("This folder has an invalid languages.tsv file."));
    QSet<QString> seen;
    for (const QString &line : lines) {
        if (line.isEmpty() || seen.contains(line)) fail(QStringLiteral("The language list contains an empty or duplicate heading."));
        seen.insert(line);
    }
    return lines;
}
QByteArray manifest(const QStringList &entries) {
    return QStringLiteral("heading\n").toUtf8() + (entries.isEmpty() ? QByteArray() : entries.join(QLatin1Char('\n')).toUtf8() + '\n');
}
QJsonObject metadata(const QString &root) {
    QFile file(QDir(root).filePath(QStringLiteral(".desktop-library.json")));
    if (!file.open(QIODevice::ReadOnly) || file.size() > 4 * 1024 * 1024) return {};
    return QJsonDocument::fromJson(file.readAll()).object();
}
void saveMetadata(const QString &root, QJsonObject object) {
    QSaveFile file(QDir(root).filePath(QStringLiteral(".desktop-library.json")));
    if (!file.open(QIODevice::WriteOnly)) return; // This cache is disposable.
    const QByteArray bytes = QJsonDocument(object).toJson(QJsonDocument::Compact);
    if (file.write(bytes) == bytes.size()) file.commit();
}
void restoreBackups(const QList<QPair<QString, QString>> &backups, QTemporaryDir &directory) {
    bool restored = true;
    for (const auto &backup : backups) {
        if (!QFile::rename(backup.second, backup.first)) restored = false;
    }
    if (!restored) {
        directory.setAutoRemove(false);
        fail(QStringLiteral("The operation failed and an existing dictionary could not be restored. Its files are preserved in %1.").arg(directory.path()));
    }
}
void clearDerivedIndex(const QString &path) {
    const QDir folder(QFileInfo(path).absolutePath());
    const QFileInfo cache(folder.filePath(QStringLiteral(".dict-cache")));
    if (!cache.isDir() || cache.isSymLink()) return;
    QFile::remove(QDir(cache.filePath()).filePath(QFileInfo(path).fileName() + QStringLiteral(".idx")));
}
QByteArray nulField(QFile &file) {
    QByteArray result;
    char ch = 0;
    while (file.getChar(&ch)) {
        if (ch == '\0') {
            if (!result.isValidUtf8()) fail(QStringLiteral("The dictionary contains invalid UTF-8 text."));
            return result;
        }
        if (result.size() >= 1024 * 1024) fail(QStringLiteral("The dictionary contains an oversized text field."));
        result.append(ch);
    }
    fail(QStringLiteral("The dictionary is truncated."));
}
quint64 varuint(QIODevice &file) {
    quint64 value = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        char ch;
        if (!file.getChar(&ch)) fail(QStringLiteral("The dictionary is truncated."));
        const auto byte = static_cast<unsigned char>(ch);
        if (shift == 63 && byte > 1) fail(QStringLiteral("The dictionary contains an invalid record length."));
        value |= quint64(byte & 127) << shift;
        if (!(byte & 128)) {
            if (shift != 0 && byte == 0) fail(QStringLiteral("The dictionary contains an invalid record length."));
            return value;
        }
    }
    fail(QStringLiteral("The dictionary contains an invalid record length."));
}
void validateAlias(const QByteArray &payload, const QByteArray &key) {
    const auto invalid = [] { fail(QStringLiteral("The dictionary contains an invalid redirect record.")); };
    if (payload.size() < 15 || !payload.startsWith("DAL1")) invalid();
    const auto sourceNamespace = qFromLittleEndian<quint32>(payload.constData() + 4);
    const auto sourceKind = static_cast<unsigned char>(payload[8]);
    const auto hasNamespace = static_cast<unsigned char>(payload[9]);
    const auto targetNamespace = qFromLittleEndian<quint32>(payload.constData() + 10);
    const auto targetKind = static_cast<unsigned char>(payload[14]);
    if (sourceKind < 1 || sourceKind > 7 || hasNamespace > 1 || targetKind > 7 ||
        (sourceKind == 1) != (sourceNamespace == 0) || (!hasNamespace && targetNamespace != 0) ||
        (targetKind && (!hasNamespace || (targetKind == 1) != (targetNamespace == 0)))) invalid();
    QBuffer input;
    input.setData(payload);
    input.open(QIODevice::ReadOnly);
    input.seek(15);
    QList<QByteArray> fields;
    for (int i = 0; i < 7; ++i) {
        const quint64 length = varuint(input);
        if (length > quint64(input.bytesAvailable())) invalid();
        fields.append(input.read(qint64(length)));
        if (i < 6 && (!fields.last().isValidUtf8() || fields.last().contains('\0') || (i < 4 && fields.last().isEmpty()))) invalid();
    }
    if (!input.atEnd() || fields[5].size() > 255 || !(fields[6].startsWith("DPR2") || fields[6].startsWith("DPR3"))) invalid();
    const auto lookupKey = [&](const QByteArray &title, unsigned char kind) {
        if (kind == 1 || kind == 7) return title;
        const qsizetype colon = title.indexOf(':');
        if (colon < 0) invalid();
        return title.mid(colon + 1);
    };
    if (fields[1] != lookupKey(fields[0], sourceKind) ||
        (targetKind ? fields[4].isEmpty() || fields[4] != lookupKey(fields[3], targetKind) : !fields[4].isEmpty()) ||
        key != QByteArray(1, char('0' + sourceKind)) + '\t' + fields[1]) invalid();
}
Dictionary validate(const QString &path, const std::atomic_bool &cancel, const Progress &progress) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) fail(file.errorString());
    if (file.read(8) != QByteArrayLiteral("WIKBLB08")) fail(QStringLiteral("Choose a WIKBLB08 dictionary containing compiled entries."));
    char ch;
    if (!file.getChar(&ch)) fail(QStringLiteral("The dictionary has an invalid kind."));
    const auto kindTag = static_cast<unsigned char>(ch);
    if (kindTag < 1 || kindTag > kinds.size()) fail(QStringLiteral("The dictionary has an invalid kind."));
    Dictionary result;
    result.kind = kinds.at(kindTag - 1);
    if (kindTag == 1) {
        nulField(file); // The reader obtains the language code from the dictionary itself.
        result.heading = QStringDecoder(QStringDecoder::Utf8, QStringConverter::Flag::ConvertInitialBom)(nulField(file));
        if (result.heading.isEmpty() || result.heading.contains(QLatin1Char('\n')))
            fail(QStringLiteral("The dictionary has an invalid language heading."));
    } else {
        result.heading = result.kind;
        result.heading.replace(QLatin1Char('_'), QLatin1Char(' '));
        result.heading[0] = result.heading[0].toUpper();
    }
    QByteArray previous;
    result.words = 0;
    qint64 lastProgress = 0;
    while (file.pos() < file.size()) {
        checkCancel(cancel);
        const QByteArray title = nulField(file);
        if (title.isEmpty() || (!previous.isEmpty() && previous.compare(title) >= 0))
            fail(QStringLiteral("Dictionary titles must be nonempty, unique and sorted."));
        previous = title;
        const quint64 length = varuint(file);
        if (length < 4 || length > 64 * 1024 * 1024 || length > quint64(file.size() - file.pos()))
            fail(QStringLiteral("The dictionary contains an invalid or truncated record."));
        const qint64 end = file.pos() + qint64(length);
        if (result.kind == QStringLiteral("alias")) validateAlias(file.read(qint64(length)), title);
        else {
            const QByteArray presentationMagic = file.read(4);
            if (presentationMagic != QByteArrayLiteral("DPR2") && presentationMagic != QByteArrayLiteral("DPR3"))
                fail(QStringLiteral("The dictionary contains entries that are not compiled presentation data."));
        }
        if (!file.seek(end)) fail(file.errorString());
        ++result.words;
        if (file.pos() - lastProgress > 1024 * 1024) {
            lastProgress = file.pos();
            progress(QStringLiteral("Checking dictionary"), file.pos(), file.size());
        }
    }
    if (result.words == 0 && result.kind == QStringLiteral("language")) fail(QStringLiteral("This dictionary has no entries."));
    return result;
}
qint64 availableBytes(const QString &root) {
    const QStorageInfo storage(root);
    return storage.isValid() && storage.bytesAvailable() >= 0
        ? std::min(MaxDownloadBytes, storage.bytesAvailable() - SpaceReserve) : MaxDownloadBytes;
}
void decompress(const QString &source, const QString &destination, const QString &root,
                const std::atomic_bool &cancel, const Progress &progress) {
    const QString executable = QStandardPaths::findExecutable(QStringLiteral("xz"));
    if (executable.isEmpty()) fail(QStringLiteral("Compressed import needs xz. Install xz or choose an uncompressed .wikblb file."));
    QFile output(destination);
    if (!output.open(QIODevice::WriteOnly)) fail(output.errorString());
    QProcess process;
    process.setProgram(executable);
    process.setArguments({QStringLiteral("--decompress"), QStringLiteral("--stdout"), QStringLiteral("--"), source});
    process.start(QIODevice::ReadOnly);
    if (!process.waitForStarted(5000)) fail(QStringLiteral("Could not start xz: %1").arg(process.errorString()));
    qint64 size = 0;
    const qint64 maximum = availableBytes(root);
    try {
        do {
            checkCancel(cancel);
            process.waitForReadyRead(50);
            const QByteArray bytes = process.readAllStandardOutput();
            size += bytes.size();
            if (size > maximum) fail(QStringLiteral("There is not enough free space to unpack this dictionary."));
            if (output.write(bytes) != bytes.size()) fail(output.errorString());
            process.readAllStandardError();
            progress(QStringLiteral("Unpacking dictionary"), size, -1);
        } while (process.state() != QProcess::NotRunning);
        if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
            fail(QStringLiteral("The compressed dictionary is damaged or incomplete."));
    } catch (...) {
        process.kill();
        process.waitForFinished(5000);
        throw;
    }
}
}

PreparedImport::~PreparedImport() = default;
QString defaultSource() {
    return QStringLiteral("https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list");
}
bool isHttpsUrl(const QUrl &url) {
    return url.isValid() && url.scheme() == QStringLiteral("https") && !url.host().isEmpty()
        && url.userInfo().isEmpty() && !url.hasFragment();
}
QList<CatalogItem> parseCatalog(const QByteArray &data) {
    if (data.size() > 2 * 1024 * 1024 || !data.isValidUtf8())
        fail(QStringLiteral("The catalogue is too large or is not valid UTF-8."));
    QList<CatalogItem> result;
    QSet<QUrl> seen;
    const auto lines = QString::fromUtf8(data).split(QLatin1Char('\n'));
    for (const auto &raw : lines) {
        const QString line = raw.trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
        const auto fields = line.split(QLatin1Char('\t'));
        if (fields.size() > 4) fail(QStringLiteral("The catalogue contains an invalid row."));
        CatalogItem item;
        item.url = QUrl(fields[0], QUrl::StrictMode);
        if (!isHttpsUrl(item.url)) fail(QStringLiteral("Catalogue links must use HTTPS without credentials or fragments."));
        if (seen.contains(item.url)) fail(QStringLiteral("The catalogue contains duplicate dictionary links."));
        seen.insert(item.url);
        item.label = fields.size() > 1 ? fields[1] : QString();
        if (item.label.isEmpty()) {
            item.label = QFileInfo(item.url.path()).fileName();
            if (item.label.endsWith(QStringLiteral(".wikblb.xz"))) item.label.chop(10);
            else if (item.label.endsWith(QStringLiteral(".wikblb"))) item.label.chop(7);
            if (item.label.isEmpty()) item.label = item.url.host();
        }
        if (fields.size() > 2 && !fields[2].isEmpty()) {
            bool ok = false;
            item.bytes = fields[2].toLongLong(&ok);
            if (!ok || item.bytes <= 0 || item.bytes > MaxDownloadBytes) fail(QStringLiteral("The catalogue contains an invalid dictionary size."));
        }
        if (fields.size() > 3 && !fields[3].isEmpty()) {
            const QString hash = fields[3].toLower();
            if (!QRegularExpression(QStringLiteral("^[0-9a-f]{64}$")).match(hash).hasMatch())
                fail(QStringLiteral("The catalogue contains an invalid SHA-256 checksum."));
            item.sha256 = hash.toLatin1();
        }
        result.append(item);
        if (result.size() > 10000) fail(QStringLiteral("The catalogue contains too many dictionaries."));
    }
    return result;
}
bool catalogItemInstalled(const CatalogItem &item, const QString &installedEdition,
        const QSet<QByteArray> &installedHashes) {
    if (item.sha256.isEmpty() || !installedHashes.contains(item.sha256)) return false;
    try {
        return editionGroup(item.url.path()) == installedEdition;
    } catch (const std::exception &) {
        return false;
    }
}
QString editionIdentity(const QString &root) {
    return installedEditionGroup(root);
}
QString sourceHost(const QString &root) {
    QString group = installedEditionGroup(root);
    if (group.isEmpty()) return {};
    group.chop(9); // The separator and snapshot date.
    group.chop(10); // The Wikimedia database suffix "wiktionary".
    return group.replace(QChar('_'), QChar('-')) + QStringLiteral(".wiktionary.org");
}
QString dictionaryPath(const QString &root, const Dictionary &dictionary) {
    if (dictionary.kind != QStringLiteral("language")) return QDir(root).filePath(featureName(dictionary.kind));
    const QByteArray hash = QCryptographicHash::hash(dictionary.heading.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QDir(root).filePath(QStringLiteral("languages/") + QString::fromLatin1(hash) + QStringLiteral(".wikblb"));
}
QString formatBytes(qint64 bytes) {
    if (bytes < 0) return QStringLiteral("Size unknown");
    if (bytes < 1024) return QStringLiteral("%1 B").arg(bytes);
    if (bytes < 1024 * 1024) return QStringLiteral("%1 KiB").arg(bytes / 1024.0, 0, 'f', 1);
    if (bytes < 1024LL * 1024 * 1024) return QStringLiteral("%1 MiB").arg(bytes / (1024.0 * 1024), 0, 'f', 1);
    return QStringLiteral("%1 GiB").arg(bytes / (1024.0 * 1024 * 1024), 0, 'f', 2);
}
QList<Dictionary> installed(const QString &root) {
    QList<Dictionary> result;
    if (root.isEmpty() || !QDir(root).exists()) return result;
    const auto cache = metadata(root);
    auto append = [&](Dictionary dictionary) {
        const QString raw = dictionaryPath(root, dictionary);
        dictionary.path = QFileInfo::exists(raw) ? raw : raw + QStringLiteral(".xz");
        const QFileInfo info(dictionary.path);
        if (!info.isFile()) return;
        dictionary.bytes = info.size();
        const auto entry = cache.value(QDir(root).relativeFilePath(dictionary.path)).toObject();
        if (entry.value(QStringLiteral("bytes")).toDouble(-1) == dictionary.bytes
            && entry.value(QStringLiteral("modified")).toString() == QString::number(info.lastModified().toMSecsSinceEpoch())) {
            dictionary.words = qint64(entry.value(QStringLiteral("words")).toDouble(-1));
            dictionary.sha256 = entry.value(QStringLiteral("sha256")).toString().toLatin1();
        }
        result.append(dictionary);
    };
    for (const auto &heading : headings(root)) append({heading, QStringLiteral("language"), {}, 0, -1, {}});
    for (qsizetype i = 1; i < kinds.size(); ++i) {
        QString label = kinds[i];
        label.replace(QLatin1Char('_'), QLatin1Char(' '));
        label[0] = label[0].toUpper();
        append({label, kinds[i], {}, 0, -1, {}});
    }
    std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) { return a.heading.localeAwareCompare(b.heading) < 0; });
    return result;
}
bool containsDictionary(const QString &root, const Dictionary &dictionary) {
    const QString path = dictionaryPath(root, dictionary);
    return QFileInfo::exists(path) || QFileInfo::exists(path + QStringLiteral(".xz"));
}
std::shared_ptr<PreparedImport> prepareImport(const QString &root, const QString &source,
        const QByteArray &expectedHash, qint64 expectedBytes, const std::atomic_bool &cancel, const Progress &progress, const QString &sourceName) {
    ensureRoot(root);
    auto prepared = std::make_shared<PreparedImport>();
    prepared->directory = std::make_unique<QTemporaryDir>(QDir(root).filePath(QStringLiteral(".import-XXXXXX")));
    if (!prepared->directory->isValid()) fail(QStringLiteral("Cannot create a temporary dictionary file in this folder."));
    QFile input(source);
    if (!input.open(QIODevice::ReadOnly)) fail(QStringLiteral("Cannot read the selected file: %1").arg(input.errorString()));
    if (expectedBytes >= 0 && input.size() != expectedBytes) fail(QStringLiteral("The download size does not match the catalogue. Refresh the catalogue and try again."));
    const qint64 maximum = availableBytes(root);
    if (input.size() > maximum) fail(QStringLiteral("There is not enough free space to import this dictionary."));
    const bool compressed = input.peek(6) == QByteArray::fromHex("fd377a585a00");
    const QString copied = prepared->directory->filePath(compressed ? QStringLiteral("dictionary.wikblb.xz") : QStringLiteral("dictionary.wikblb"));
    QFile output(copied);
    if (!output.open(QIODevice::WriteOnly)) fail(output.errorString());
    QCryptographicHash hash(QCryptographicHash::Sha256);
    qint64 total = 0;
    while (!input.atEnd()) {
        checkCancel(cancel);
        const QByteArray bytes = input.read(256 * 1024);
        if (bytes.isEmpty() && input.error() != QFileDevice::NoError) fail(input.errorString());
        total += bytes.size();
        if (total > maximum) fail(QStringLiteral("There is not enough free space to import this dictionary."));
        if (output.write(bytes) != bytes.size()) fail(output.errorString());
        hash.addData(bytes);
        progress(QStringLiteral("Copying dictionary"), total, input.size());
    }
    output.close();
    if (output.error() != QFileDevice::NoError) fail(output.errorString());
    const QByteArray actualHash = hash.result().toHex();
    if (!expectedHash.isEmpty() && actualHash != expectedHash.toLower())
        fail(QStringLiteral("The dictionary checksum does not match. Refresh the catalogue and try again."));
    QString validationPath = copied;
    if (compressed) {
        validationPath = prepared->directory->filePath(QStringLiteral("unpacked.wikblb"));
        decompress(copied, validationPath, root, cancel, progress);
    }
    prepared->dictionary = validate(validationPath, cancel, progress);
    const QString originalName = sourceName.isEmpty() ? QFileInfo(source).fileName() : QFileInfo(sourceName).fileName();
    prepared->editionGroup = editionGroup(originalName);
    if (!prepared->editionGroup.isEmpty() && originalName != prepared->editionGroup + QChar('-') +
            QFileInfo(dictionaryPath(root, prepared->dictionary)).fileName() + (compressed ? QStringLiteral(".xz") : QString()))
        fail(QStringLiteral("The release filename does not match the dictionary it contains."));
    checkEditionGroup(root, prepared->editionGroup);
    if (compressed) QFile::remove(validationPath);
    prepared->dictionary.sha256 = actualHash;
    prepared->dictionary.bytes = total;
    prepared->dictionary.path = dictionaryPath(root, prepared->dictionary) + (compressed ? QStringLiteral(".xz") : QString());
    prepared->stagedFile = copied;
    checkCancel(cancel);
    return prepared;
}
void commitImport(const QString &root, PreparedImport &prepared) {
    ensureRoot(root);
    QLockFile lock(QDir(root).filePath(QStringLiteral(".library.lock")));
    if (!lock.tryLock()) fail(QStringLiteral("Another dictionary operation is using this folder. Try again when it finishes."));
    checkEditionGroup(root, prepared.editionGroup);
    QStringList languages = headings(root);
    const auto &dictionary = prepared.dictionary;
    if (dictionary.kind == QStringLiteral("language") && !languages.contains(dictionary.heading)) languages.append(dictionary.heading);
    const QString raw = dictionaryPath(root, dictionary);
    if (!QDir().mkpath(QFileInfo(raw).absolutePath())) fail(QStringLiteral("Cannot create the language folder."));
    QSaveFile index(QDir(root).filePath(QStringLiteral("languages.tsv")));
    const QByteArray content = manifest(languages);
    if (!index.open(QIODevice::WriteOnly) || index.write(content) != content.size()) fail(QStringLiteral("Cannot update the dictionary list: %1").arg(index.errorString()));
    const QString markerPath = QDir(root).filePath(QStringLiteral(".desktop-edition"));
    const bool needsMarker = !prepared.editionGroup.isEmpty() && installedEditionGroup(root).isEmpty();
    QSaveFile marker(markerPath);
    if (needsMarker) {
        const QByteArray bytes = prepared.editionGroup.toUtf8() + '\n';
        if (!marker.open(QIODevice::WriteOnly) || marker.write(bytes) != bytes.size()) fail(QStringLiteral("Cannot save the dictionary edition."));
    }
    QList<QPair<QString, QString>> backups;
    bool published = false;
    bool markerCommitted = false;
    try {
        for (const QString &old : {raw, raw + QStringLiteral(".xz")}) {
            if (!QFileInfo::exists(old)) continue;
            if (QFileInfo(old).isSymLink()) fail(QStringLiteral("Cannot replace a dictionary that is a symbolic link."));
            const QString backup = prepared.directory->filePath(QStringLiteral("previous-%1").arg(backups.size()));
            if (!QFile::rename(old, backup)) fail(QStringLiteral("Cannot replace the existing dictionary. Check folder permissions."));
            backups.append({old, backup});
        }
        if (!QFile::rename(prepared.stagedFile, dictionary.path)) fail(QStringLiteral("Cannot finish installing the dictionary. Check folder permissions."));
        published = true;
        if (needsMarker) {
            if (!marker.commit()) fail(QStringLiteral("Cannot finish saving the dictionary edition."));
            markerCommitted = true;
        }
        if (!index.commit()) fail(QStringLiteral("Cannot finish updating the dictionary list: %1").arg(index.errorString()));
    } catch (...) {
        if (published && !QFile::rename(dictionary.path, prepared.stagedFile)) {
            prepared.directory->setAutoRemove(false);
            fail(QStringLiteral("The import could not be rolled back. Recovery files remain in %1.").arg(prepared.directory->path()));
        }
        const bool markerRestored = !markerCommitted || QFile::remove(markerPath);
        restoreBackups(backups, *prepared.directory);
        if (!markerRestored) fail(QStringLiteral("The dictionary was restored, but its edition marker could not be rolled back."));
        throw;
    }
    auto cache = metadata(root);
    for (const auto &backup : backups) {
        cache.remove(QDir(root).relativeFilePath(backup.first));
        clearDerivedIndex(backup.first);
    }
    QJsonObject entry;
    entry.insert(QStringLiteral("bytes"), double(dictionary.bytes));
    entry.insert(QStringLiteral("words"), double(dictionary.words));
    entry.insert(QStringLiteral("sha256"), QString::fromLatin1(dictionary.sha256));
    entry.insert(QStringLiteral("modified"), QString::number(QFileInfo(dictionary.path).lastModified().toMSecsSinceEpoch()));
    cache.insert(QDir(root).relativeFilePath(dictionary.path), entry);
    saveMetadata(root, cache);
}
void removeDictionary(const QString &root, const Dictionary &dictionary) {
    ensureRoot(root);
    QLockFile lock(QDir(root).filePath(QStringLiteral(".library.lock")));
    if (!lock.tryLock()) fail(QStringLiteral("Another dictionary operation is using this folder. Try again when it finishes."));
    QStringList languages = headings(root);
    if (dictionary.kind == QStringLiteral("language")) languages.removeAll(dictionary.heading);
    QTemporaryDir removed(QDir(root).filePath(QStringLiteral(".remove-XXXXXX")));
    if (!removed.isValid()) fail(QStringLiteral("Cannot prepare removal. Check folder permissions."));
    const QString raw = dictionaryPath(root, dictionary);
    QSaveFile index(QDir(root).filePath(QStringLiteral("languages.tsv")));
    const QByteArray content = manifest(languages);
    if (!index.open(QIODevice::WriteOnly) || index.write(content) != content.size()) fail(QStringLiteral("Cannot update the dictionary list."));
    QList<QPair<QString, QString>> backups;
    try {
        for (const QString &old : {raw, raw + QStringLiteral(".xz")}) {
            if (!QFileInfo::exists(old)) continue;
            if (QFileInfo(old).isSymLink()) fail(QStringLiteral("Cannot remove a dictionary that is a symbolic link."));
            const QString backup = removed.filePath(QStringLiteral("dictionary-%1").arg(backups.size()));
            if (!QFile::rename(old, backup)) fail(QStringLiteral("Cannot remove this dictionary. Check folder permissions."));
            backups.append({old, backup});
        }
        if (!index.commit()) fail(QStringLiteral("Cannot finish updating the dictionary list."));
    } catch (...) {
        restoreBackups(backups, removed);
        throw;
    }
    auto cache = metadata(root);
    for (const auto &backup : backups) {
        cache.remove(QDir(root).relativeFilePath(backup.first));
        clearDerivedIndex(backup.first);
    }
    saveMetadata(root, cache);
}
}
