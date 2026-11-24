#include "LibraryStore.hpp"
#include "DictApi.hpp"
#include "LibraryStoreRecovery_p.hpp"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDate>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
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
// Canonical local publication members use content-kind names, while release
// downloads carry their edition in the asset name. Bind a local date only to
// the precise bytes listed for the validated member in the adjacent manifest.
QString localPublicationEdition(const QString &source, const Dictionary &dictionary, bool compressed,
                                const QByteArray &digest, qint64 bytes) {
    const QFileInfo member(source);
    if (member.isSymLink()) return {};
    QDir publication = member.absoluteDir();
    if (dictionary.kind == QStringLiteral("language")) {
        if (publication.dirName() != QStringLiteral("languages") || !publication.cdUp()) return {};
    }
    const QString expected = dictionaryPath(publication.absolutePath(), dictionary)
        + (compressed ? QStringLiteral(".xz") : QString());
    if (member.absoluteFilePath() != expected) return {};
    const QFileInfo manifest(publication.filePath(QStringLiteral("complete.json")));
    if (!manifest.isFile() || manifest.isSymLink() || manifest.size() > 4 * 1024 * 1024) return {};
    QFile metadataFile(manifest.filePath());
    if (!metadataFile.open(QIODevice::ReadOnly)) return {};
    const auto manifestBytes = metadataFile.read(4 * 1024 * 1024 + 1);
    if (!metadataFile.atEnd() || metadataFile.error() != QFileDevice::NoError || manifestBytes.size() > 4 * 1024 * 1024) return {};
    const auto complete = QJsonDocument::fromJson(manifestBytes).object();
    if (complete.value(QStringLiteral("status")) != QStringLiteral("built")) return {};
    const auto files = complete.value(QStringLiteral("publication_files")).toObject();
    const auto metadata = files.value(publication.relativeFilePath(expected)).toObject();
    if (metadata.isEmpty()) return {};
    if (metadata.value(QStringLiteral("size")).toInteger(-1) != bytes
        || metadata.value(QStringLiteral("sha256")).toString().toLatin1() != digest)
        return {};
    const auto identity = complete.value(QStringLiteral("edition")).toString() + QChar('-')
        + complete.value(QStringLiteral("date")).toString();
    const QString date = complete.value(QStringLiteral("date")).toString();
    if (date.size() != 8 || QDate::fromString(date, QStringLiteral("yyyyMMdd")).toString(QStringLiteral("yyyyMMdd")) != date) return {};
    static const QRegularExpression validIdentity(QStringLiteral("^[a-z][a-z0-9_-]*wiktionary-[0-9]{8}$"));
    return validIdentity.match(identity).hasMatch() ? identity : QString();
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
QByteArray validateAlias(const QByteArray &payload, const QByteArray &key) {
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
    // Presentation versions and bodies are checked by the native record decoder below.
    if (!input.atEnd() || fields[5].size() > 255) invalid();
    const auto lookupKey = [&](const QByteArray &title, unsigned char kind) {
        if (kind == 1 || kind == 7) return title;
        const qsizetype colon = title.indexOf(':');
        if (colon < 0) invalid();
        return title.mid(colon + 1);
    };
    if (fields[1] != lookupKey(fields[0], sourceKind) ||
        (targetKind ? fields[4].isEmpty() || fields[4] != lookupKey(fields[3], targetKind) : !fields[4].isEmpty()) ||
        key != QByteArray(1, char('0' + sourceKind)) + '\t' + fields[1]) invalid();
    return fields[6];
}
Dictionary validate(const QString &path, const std::atomic_bool &cancel, const Progress &progress) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) fail(file.errorString());
    if (file.read(8) != QByteArrayLiteral("WIKBLB08")) fail(QStringLiteral("This file is not a WikiDict dictionary. Choose a .wikblb or .wikblb.xz file."));
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
    // This handle and its error buffer live entirely in the import worker.
    const qint64 headerEnd = file.pos();
    if (!file.seek(0)) fail(file.errorString());
    const QByteArray header = file.read(headerEnd);
    if (header.size() != headerEnd) fail(file.errorString());
    DictApi validator(QFileInfo(path).absolutePath());
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
        const QByteArray payload = file.read(qint64(length));
        if (quint64(payload.size()) != length) fail(QStringLiteral("The dictionary contains an invalid or truncated record."));
        const QByteArray presentation = result.kind == QStringLiteral("alias")
            ? validateAlias(payload, title) : payload;
        validator.requirePresentationCapability(presentation);
        validator.validateRecord(header, title, payload);
        checkCancel(cancel);
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

namespace {
QString mutationJournal(const QString &root) {
    return QDir(root).filePath(QStringLiteral(".desktop-mutation.json"));
}
QByteArray payloadHash(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) fail(QStringLiteral("Cannot read the installed dictionary for recovery."));
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file)) fail(QStringLiteral("Cannot read the installed dictionary for recovery."));
    return hash.result().toHex();
}
void atomicBytes(const QString &path, const QByteArray &bytes) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit())
        fail(QStringLiteral("Cannot save dictionary recovery metadata."));
}
// Called only with .library.lock held. Repeating this after another interruption
// restores the same prior state; a backup is never discarded before restoration.
void recoverMutationLocked(const QString &root) {
    try {
    const QString journalPath = mutationJournal(root);
    if (!QFileInfo::exists(journalPath)) return;
    const auto document = QJsonDocument::fromJson(readFile(journalPath, 8 * 1024 * 1024));
    const auto journal = document.object();
    const QString directory = journal.value(QStringLiteral("directory")).toString();
    const QFileInfo folder(directory);
    if (journal.value(QStringLiteral("version")).toInt() != 1 || folder.absolutePath() != QDir(root).absolutePath()
        || !(folder.fileName().startsWith(QStringLiteral(".import-")) || folder.fileName().startsWith(QStringLiteral(".remove-"))))
        fail(QStringLiteral("Dictionary recovery metadata is incomplete. Recovery files have been retained."));
    const QString state = journal.value(QStringLiteral("state")).toString();
    if (state != QStringLiteral("pending") && state != QStringLiteral("committed"))
        fail(QStringLiteral("Dictionary recovery state is incomplete. Recovery files have been retained."));
    if (state == QStringLiteral("committed")) {
        if (QDir(directory).exists() && !QDir(directory).removeRecursively())
            fail(QStringLiteral("Cannot retire completed dictionary staging. Recovery metadata has been retained."));
        if (!QFile::remove(journalPath)) fail(QStringLiteral("Cannot finish dictionary cleanup."));
        return;
    }
    QString failure;
    auto attempt = [&](const auto &restore) {
        try { restore(); }
        catch (const std::exception &error) {
            if (failure.isEmpty()) failure = QString::fromUtf8(error.what());
        }
    };
    for (const auto &value : journal.value(QStringLiteral("payloads")).toArray()) {
        attempt([&] {
        const auto item = value.toObject();
        const QString path = QDir(root).filePath(item.value(QStringLiteral("path")).toString());
        const QString backup = QDir(directory).filePath(item.value(QStringLiteral("backup")).toString());
        if (QFileInfo::exists(backup)) {
            if (payloadHash(backup) != item.value(QStringLiteral("sha256")).toString().toLatin1())
                fail(QStringLiteral("Dictionary recovery copy has changed. Recovery files have been retained."));
            if ((QFileInfo::exists(path) && !QFile::remove(path)) || !QFile::rename(backup, path))
                fail(QStringLiteral("Cannot restore the installed dictionary. Recovery files have been retained."));
        } else if (item.value(QStringLiteral("existed")).toBool()) {
            if (!QFileInfo::exists(path) || payloadHash(path) != item.value(QStringLiteral("sha256")).toString().toLatin1())
                fail(QStringLiteral("Dictionary recovery is incomplete. Recovery files have been retained."));
        } else if (QFileInfo::exists(path) && !QFile::remove(path)) {
            fail(QStringLiteral("Cannot restore the dictionary folder. Recovery files have been retained."));
        }
        });
    }
    for (const auto &value : journal.value(QStringLiteral("metadata")).toArray()) {
        attempt([&] {
        const auto item = value.toObject();
        const QString path = QDir(root).filePath(item.value(QStringLiteral("path")).toString());
        if (item.value(QStringLiteral("existed")).toBool())
            atomicBytes(path, QByteArray::fromBase64(item.value(QStringLiteral("bytes")).toString().toLatin1()));
        else if (QFileInfo::exists(path) && !QFile::remove(path))
            fail(QStringLiteral("Cannot restore dictionary metadata. Recovery files have been retained."));
        });
    }
    if (!failure.isEmpty()) fail(failure);
    if (QDir(directory).exists() && !QDir(directory).removeRecursively())
        fail(QStringLiteral("Cannot retire dictionary recovery staging. Recovery metadata has been retained."));
    if (!QFile::remove(journalPath)) fail(QStringLiteral("Cannot finish dictionary recovery."));
    } catch (const std::exception &error) {
        throw UnrestoredMutation(error.what());
    }
}
void finishMutationLocked(const QString &root) {
    const QString path = mutationJournal(root);
    auto journal = QJsonDocument::fromJson(readFile(path, 8 * 1024 * 1024)).object();
    journal.insert(QStringLiteral("state"), QStringLiteral("committed"));
    atomicBytes(path, QJsonDocument(journal).toJson());
    recoverMutationLocked(root);
}
}
void detail::beginMutation(const QString &root, QTemporaryDir &directory, const QStringList &paths) {
    QJsonArray payloads, metadata;
    for (qsizetype i = 0; i < paths.size(); ++i) {
        const bool existed = QFileInfo::exists(paths[i]);
        if (QFileInfo(paths[i]).isSymLink()) fail(QStringLiteral("Cannot change a dictionary that is a symbolic link."));
        payloads.append(QJsonObject{{QStringLiteral("path"), QDir(root).relativeFilePath(paths[i])},
            {QStringLiteral("backup"), QStringLiteral("previous-%1").arg(i)},
            {QStringLiteral("existed"), existed},
            {QStringLiteral("sha256"), existed ? QString::fromLatin1(payloadHash(paths[i])) : QString()}});
    }
    for (const auto &name : {QStringLiteral("languages.tsv"), QStringLiteral(".desktop-edition")}) {
        const QString path = QDir(root).filePath(name);
        const bool existed = QFileInfo::exists(path);
        metadata.append(QJsonObject{{QStringLiteral("path"), name}, {QStringLiteral("existed"), existed},
            {QStringLiteral("bytes"), existed ? QString::fromLatin1(readFile(path, 2 * 1024 * 1024).toBase64()) : QString()}});
    }
    if (QFileInfo::exists(mutationJournal(root))) fail(QStringLiteral("A dictionary operation needs recovery first."));
    atomicBytes(mutationJournal(root), QJsonDocument(QJsonObject{{QStringLiteral("version"), 1},
        {QStringLiteral("state"), QStringLiteral("pending")},
        {QStringLiteral("directory"), directory.path()}, {QStringLiteral("payloads"), payloads},
        {QStringLiteral("metadata"), metadata}}).toJson());
    directory.setAutoRemove(false); // Survives caught errors and ordinary process termination.
}
void recoverPendingMutation(const QString &root) {
    if (root.isEmpty() || !QFileInfo::exists(mutationJournal(root))) return;
    QLockFile lock(QDir(root).filePath(QStringLiteral(".library.lock")));
    if (!lock.tryLock()) fail(QStringLiteral("Another dictionary operation is using this folder. Try again when it finishes."));
    recoverMutationLocked(root);
}

PreparedImport::~PreparedImport() = default;
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
QString EmptyRelease::summary() const {
    return QStringLiteral("Completed %1 release (%2): %3 source pages processed, no published dictionaries.")
        .arg(edition, QDate::fromString(date, QStringLiteral("yyyyMMdd")).toString(Qt::ISODate),
            QLocale().toString(inputPages));
}
std::optional<EmptyRelease> completedEmptyRelease(const QString &root) {
    const QDir directory(root);
    const QFileInfo completeFile(directory.filePath(QStringLiteral("complete.json")));
    if (!completeFile.exists() && !completeFile.isSymLink()) return std::nullopt;
    if (!directory.exists() || !directory.isReadable() || !completeFile.isFile() || completeFile.isSymLink())
        fail(QStringLiteral("Cannot read the completed release metadata."));
    QJsonParseError parseError;
    const auto document = QJsonDocument::fromJson(readFile(completeFile.filePath(), 4 * 1024 * 1024), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject())
        fail(QStringLiteral("The completed release metadata is invalid."));
    const auto complete = document.object();
    if (complete.value(QStringLiteral("status")).toString() != QStringLiteral("empty")) return std::nullopt;
    EmptyRelease release{complete.value(QStringLiteral("edition")).toString(),
        complete.value(QStringLiteral("date")).toString(),
        complete.value(QStringLiteral("input_pages")).toInteger(-1)};
    const auto pages = complete.value(QStringLiteral("input_pages"));
    const auto blobs = complete.value(QStringLiteral("blobs"));
    if (!QRegularExpression(QStringLiteral("^[a-z][a-z0-9_-]*wiktionary$")).match(release.edition).hasMatch()
        || QDate::fromString(release.date, QStringLiteral("yyyyMMdd")).toString(QStringLiteral("yyyyMMdd")) != release.date
        || release.date.size() != 8 || !pages.isDouble() || release.inputPages < 0
        || pages.toDouble() != double(release.inputPages) || !blobs.isDouble() || blobs.toDouble() != 0
        || installedEditionGroup(root) != release.edition + QChar('-') + release.date)
        fail(QStringLiteral("The completed empty release metadata is inconsistent."));
    const QFileInfo incomplete(directory.filePath(QStringLiteral(".incomplete")));
    const QFileInfo index(directory.filePath(QStringLiteral("languages.tsv")));
    const QFileInfo languages(directory.filePath(QStringLiteral("languages")));
    const QDir languageDirectory(languages.filePath());
    const QStringList blobNames{QStringLiteral("*.wikblb"), QStringLiteral("*.wikblb.xz")};
    const auto entries = QDir::AllEntries | QDir::Hidden | QDir::System | QDir::NoDotAndDotDot;
    if (incomplete.exists() || incomplete.isSymLink() || !index.isFile() || index.isSymLink()
        || readFile(index.filePath(), 16) != QByteArrayLiteral("heading\n")
        || !directory.entryList(blobNames, entries).isEmpty() || languages.isSymLink()
        || (languages.exists() && (!languages.isDir() || !languageDirectory.isReadable()
            || !languageDirectory.entryList(blobNames, entries).isEmpty())))
        fail(QStringLiteral("The completed empty release does not match this dictionary folder."));
    return release;
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
    recoverPendingMutation(root);
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
    recoverPendingMutation(root);
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
    if (prepared->editionGroup.isEmpty() && sourceName.isEmpty())
        prepared->editionGroup = localPublicationEdition(source, prepared->dictionary, compressed, actualHash, total);
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
    recoverPendingMutation(root);
    ensureRoot(root);
    QLockFile lock(QDir(root).filePath(QStringLiteral(".library.lock")));
    if (!lock.tryLock()) fail(QStringLiteral("Another dictionary operation is using this folder. Try again when it finishes."));
    recoverMutationLocked(root);
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
    detail::beginMutation(root, *prepared.directory, {raw, raw + QStringLiteral(".xz")});
    QList<QPair<QString, QString>> backups;
    try {
        qsizetype position = 0;
        for (const QString &old : {raw, raw + QStringLiteral(".xz")}) {
            const QString backupName = QStringLiteral("previous-%1").arg(position++);
            if (!QFileInfo::exists(old)) continue;
            if (QFileInfo(old).isSymLink()) fail(QStringLiteral("Cannot replace a dictionary that is a symbolic link."));
            const QString backup = prepared.directory->filePath(backupName);
            if (!QFile::rename(old, backup)) fail(QStringLiteral("Cannot replace the existing dictionary. Check folder permissions."));
            backups.append({old, backup});
        }
        if (!QFile::rename(prepared.stagedFile, dictionary.path)) fail(QStringLiteral("Cannot finish installing the dictionary. Check folder permissions."));
        if (needsMarker) {
            if (!marker.commit()) fail(QStringLiteral("Cannot finish saving the dictionary edition."));
        }
        if (!index.commit()) fail(QStringLiteral("Cannot finish updating the dictionary list: %1").arg(index.errorString()));
        finishMutationLocked(root);
        prepared.directory->setAutoRemove(true);
    } catch (...) {
        recoverMutationLocked(root);
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
    recoverPendingMutation(root);
    ensureRoot(root);
    QLockFile lock(QDir(root).filePath(QStringLiteral(".library.lock")));
    if (!lock.tryLock()) fail(QStringLiteral("Another dictionary operation is using this folder. Try again when it finishes."));
    recoverMutationLocked(root);
    QStringList languages = headings(root);
    if (dictionary.kind == QStringLiteral("language")) languages.removeAll(dictionary.heading);
    QTemporaryDir removed(QDir(root).filePath(QStringLiteral(".remove-XXXXXX")));
    if (!removed.isValid()) fail(QStringLiteral("Cannot prepare removal. Check folder permissions."));
    const QString raw = dictionaryPath(root, dictionary);
    QSaveFile index(QDir(root).filePath(QStringLiteral("languages.tsv")));
    const QByteArray content = manifest(languages);
    if (!index.open(QIODevice::WriteOnly) || index.write(content) != content.size()) fail(QStringLiteral("Cannot update the dictionary list."));
    detail::beginMutation(root, removed, {raw, raw + QStringLiteral(".xz")});
    QList<QPair<QString, QString>> backups;
    try {
        qsizetype position = 0;
        for (const QString &old : {raw, raw + QStringLiteral(".xz")}) {
            const QString backupName = QStringLiteral("previous-%1").arg(position++);
            if (!QFileInfo::exists(old)) continue;
            if (QFileInfo(old).isSymLink()) fail(QStringLiteral("Cannot remove a dictionary that is a symbolic link."));
            const QString backup = removed.filePath(backupName);
            if (!QFile::rename(old, backup)) fail(QStringLiteral("Cannot remove this dictionary. Check folder permissions."));
            backups.append({old, backup});
        }
        if (!index.commit()) fail(QStringLiteral("Cannot finish updating the dictionary list."));
        finishMutationLocked(root);
        removed.setAutoRemove(true);
    } catch (...) {
        recoverMutationLocked(root);
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
