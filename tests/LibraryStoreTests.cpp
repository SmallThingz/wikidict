#include "LibraryStore.hpp"
#include "LibraryStoreRecovery_p.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
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
void appendLength(QByteArray &bytes, quint64 value);
// Seven empty u32 lists: display, sections, preamble, two layout lists, references, media.
QByteArray emptyPresentation() { return QByteArrayLiteral("DPR2") + QByteArray(28, '\0'); }
void appendU32(QByteArray &bytes, quint32 value) {
    for (int shift = 0; shift < 32; shift += 8) bytes.append(char((value >> shift) & 255));
}
void appendString(QByteArray &bytes, const QByteArray &value) {
    appendU32(bytes, quint32(value.size())); bytes.append(value);
}
QByteArray cellBlock(unsigned char kind, const QByteArray &table = QByteArray(1, '\0'),
                     const QByteArray &anchor = {}, const QByteArray &fallback = {}) {
    QByteArray bytes; bytes.append(char(kind)); bytes.append(char(0)); bytes.append(char(kind == 9 ? 3 : 0));
    appendU32(bytes, kind == 12 || kind == 11 ? 0 : 1);
    if (kind != 12 && kind != 11) {
        bytes.append(QByteArray(3, '\0')); // text span, ordinary role, no flags
        appendString(bytes, kind == 9 ? QByteArray("Cell heading") : QByteArray("Cell body"));
        for (int field = 0; field < 6; ++field) appendString(bytes, {});
        bytes.append(QByteArray(2, '\0')); // inherited foreground and background
    }
    bytes.append(char(0)); // feature
    appendString(bytes, {}); appendString(bytes, {}); bytes.append(table);
    appendString(bytes, anchor); appendString(bytes, fallback);
    return bytes;
}
QByteArray orderedCellTable(const QList<QByteArray> &blocks) {
    QByteArray bytes = QByteArray::fromHex("0100"); // table present, default geometry
    appendU32(bytes, 0); appendU32(bytes, 1); appendU32(bytes, 1); // caption, rows, cells
    bytes.append(QByteArray::fromHex("0101000100010700000023666666666530")); // header, extents, background
    appendU32(bytes, 0); bytes.append(char(0)); // legacy spans and child table
    bytes.append(char(1)); appendU32(bytes, quint32(blocks.size()));
    for (const auto &block : blocks) bytes.append(block);
    return bytes;
}
QByteArray orderedPresentation(const QList<QByteArray> &blocks) {
    QByteArray bytes("DPR8"); appendU32(bytes, 0); appendU32(bytes, 1); // display, sections
    bytes.append(char(2)); appendString(bytes, "Noun");
    appendString(bytes, {}); appendString(bytes, {}); // section anchors
    appendU32(bytes, 1); bytes.append(cellBlock(12, orderedCellTable(blocks)));
    bytes.append(QByteArray(20, '\0')); // preamble, layout, references, media
    return bytes;
}
QByteArray blob(const QByteArray &heading, const QList<QByteArray> &titles, unsigned char kind = 1,
                const QByteArray &presentation = emptyPresentation()) {
    QByteArray bytes("WIKBLB08", 8);
    bytes.append(char(kind));
    if (kind == 1) { bytes.append("en", 2); bytes.append(char(0)); bytes.append(heading); bytes.append(char(0)); }
    for (const auto &title : titles) {
        bytes.append(title); bytes.append(char(0)); appendLength(bytes, quint64(presentation.size())); bytes.append(presentation);
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
QByteArray aliasRecord(const QByteArray &source = "Cats", const QByteArray &target = "cat", const QByteArray &presentationOverride = {}) {
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
    const QByteArray presentation = presentationOverride.isEmpty() ? fixture.mid(at, qsizetype(length)) : presentationOverride;
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
        // A blocked first restore must not prevent independent payload/metadata
        // recovery. The remaining journal is retried after the obstruction clears.
        {
            QTemporaryDir restart(temporary.filePath(QStringLiteral("blocked-recovery-XXXXXX")));
            const QString raw = restart.filePath(QStringLiteral("dictionary.wikblb"));
            const QString packed = raw + QStringLiteral(".xz");
            const QString list = restart.filePath(QStringLiteral("languages.tsv"));
            const QString marker = restart.filePath(QStringLiteral(".desktop-edition"));
            write(raw, QByteArrayLiteral("prior raw")); write(packed, QByteArrayLiteral("prior xz"));
            write(list, QByteArrayLiteral("prior list"));
            QTemporaryDir staging(restart.filePath(QStringLiteral(".import-XXXXXX")));
            LibraryStorage::detail::beginMutation(restart.path(), staging, {raw, packed});
            require(QFile::rename(raw, staging.filePath(QStringLiteral("previous-0"))), "blocked first backup");
            require(QFile::rename(packed, staging.filePath(QStringLiteral("previous-1"))), "blocked second backup");
            require(QDir().mkdir(raw), "ordinary occupied restore destination");
            write(list, QByteArrayLiteral("new list")); write(marker, QByteArrayLiteral("new edition"));
            bool unrestored = false;
            try { LibraryStorage::recoverPendingMutation(restart.path()); }
            catch (const LibraryStorage::UnrestoredMutation &) { unrestored = true; }
            require(unrestored && !staging.autoRemove(), "incomplete recovery typed and staging retained");
            require(read(staging.filePath(QStringLiteral("previous-0"))) == QByteArrayLiteral("prior raw"), "blocked prior payload retained exactly");
            require(read(packed) == QByteArrayLiteral("prior xz") && read(list) == QByteArrayLiteral("prior list") && !QFileInfo::exists(marker), "independent second payload and metadata still restored");
            require(QFileInfo::exists(restart.filePath(QStringLiteral(".desktop-mutation.json"))), "incomplete journal retained");
            require(QDir().rmdir(raw), "remove only synthetic obstruction");
            LibraryStorage::recoverPendingMutation(restart.path());
            require(read(raw) == QByteArrayLiteral("prior raw") && read(packed) == QByteArrayLiteral("prior xz"), "retry completes exact restoration");
        }
        // Simulate ordinary process termination at actual mutation boundaries.
        // No user root, subprocess kill, or fault-injection production hook.
        for (const bool removal : {false, true}) {
            for (int boundary = 0; boundary <= 4; ++boundary) {
                QTemporaryDir restart(temporary.filePath(QStringLiteral("restart-XXXXXX")));
                const QString folder = restart.path();
                require(QDir(folder).mkpath(QStringLiteral("languages")), "restart payload directory");
                const QString raw = QDir(folder).filePath(QStringLiteral("languages/entry.wikblb"));
                const QString packed = raw + QStringLiteral(".xz");
                const QString list = QDir(folder).filePath(QStringLiteral("languages.tsv"));
                const QString marker = QDir(folder).filePath(QStringLiteral(".desktop-edition"));
                const QByteArray previous = QByteArrayLiteral("prior installed payload");
                const QByteArray compressed = QByteArrayLiteral("prior compressed payload");
                const QByteArray manifest = QByteArrayLiteral("heading\nEnglish\n");
                write(raw, previous); write(packed, compressed); write(list, manifest);
                // No prior edition marker: an interrupted initial binding must disappear.
                QTemporaryDir staging(QDir(folder).filePath(removal ? QStringLiteral(".remove-XXXXXX") : QStringLiteral(".import-XXXXXX")));
                require(staging.isValid(), "restart staging");
                LibraryStorage::detail::beginMutation(folder, staging, {raw, packed});
                require(!staging.autoRemove(), "journal protects staging until commit");
                if (boundary >= 1) require(QFile::rename(raw, staging.filePath(QStringLiteral("previous-0"))), "first payload move");
                if (boundary >= 2) require(QFile::rename(packed, staging.filePath(QStringLiteral("previous-1"))), "second payload move");
                if (boundary >= 3) {
                    if (!removal) write(packed, QByteArrayLiteral("new published payload"));
                    write(marker, QByteArrayLiteral("new edition"));
                }
                if (boundary >= 4) write(list, QByteArrayLiteral("heading\nNew heading\n"));
                LibraryStorage::recoverPendingMutation(folder);
                require(read(raw) == previous && read(packed) == compressed, "restart restores both exact prior payloads");
                require(read(list) == manifest && !QFileInfo::exists(marker), "restart restores manifest and prior unbound edition");
                require(!QFileInfo::exists(staging.path()), "only completed recovery staging retired");
                LibraryStorage::recoverPendingMutation(folder);
                require(read(raw) == previous && read(list) == manifest, "repeated restart recovery is idempotent");
            }
        }
        // A recovery interrupted after one payload was restored resumes safely;
        // committed transactions finish cleanup instead of rolling back.
        {
            QTemporaryDir restart(temporary.filePath(QStringLiteral("repeat-recovery-XXXXXX")));
            const QString raw = restart.filePath(QStringLiteral("dictionary.wikblb"));
            const QString packed = raw + QStringLiteral(".xz");
            const QString list = restart.filePath(QStringLiteral("languages.tsv"));
            const QString marker = restart.filePath(QStringLiteral(".desktop-edition"));
            write(raw, QByteArrayLiteral("old raw")); write(packed, QByteArrayLiteral("old xz"));
            write(list, QByteArrayLiteral("old list")); write(marker, QByteArrayLiteral("old edition"));
            QTemporaryDir staging(restart.filePath(QStringLiteral(".import-XXXXXX")));
            LibraryStorage::detail::beginMutation(restart.path(), staging, {raw, packed});
            require(QFile::rename(raw, staging.filePath(QStringLiteral("previous-0"))), "recovery first backup");
            require(QFile::rename(packed, staging.filePath(QStringLiteral("previous-1"))), "recovery second backup");
            require(QFile::rename(staging.filePath(QStringLiteral("previous-0")), raw), "simulate first completed recovery move");
            write(list, QByteArrayLiteral("new list")); write(marker, QByteArrayLiteral("new edition"));
            LibraryStorage::recoverPendingMutation(restart.path());
            require(read(raw) == QByteArrayLiteral("old raw") && read(packed) == QByteArrayLiteral("old xz"), "partial recovery resumes");
            require(read(list) == QByteArrayLiteral("old list") && read(marker) == QByteArrayLiteral("old edition"), "existing metadata restored exactly");
            QTemporaryDir completed(restart.filePath(QStringLiteral(".import-XXXXXX")));
            LibraryStorage::detail::beginMutation(restart.path(), completed, {raw, packed});
            require(QFile::rename(raw, completed.filePath(QStringLiteral("previous-0"))), "completed old payload backup");
            write(raw, QByteArrayLiteral("completed new payload"));
            const QString journalPath = restart.filePath(QStringLiteral(".desktop-mutation.json"));
            auto committedJournal = QJsonDocument::fromJson(read(journalPath)).object();
            committedJournal.insert(QStringLiteral("state"), QStringLiteral("committed"));
            write(journalPath, QJsonDocument(committedJournal).toJson()); // termination after committed state, before staging cleanup
            LibraryStorage::recoverPendingMutation(restart.path());
            require(read(raw) == QByteArrayLiteral("completed new payload"), "completed import is not rolled back on restart");
            require(!QFileInfo::exists(completed.path()) && !QFileInfo::exists(journalPath), "committed restart retires old staging and journal");
            LibraryStorage::recoverPendingMutation(restart.path());
            require(read(raw) == QByteArrayLiteral("completed new payload"), "completed cleanup remains idempotent");
            completed.setAutoRemove(true);
        }
        {
            QTemporaryDir first(temporary.filePath(QStringLiteral("first-recovery-XXXXXX")));
            const QString destination = first.filePath(QStringLiteral("supplemental.wikblb"));
            QTemporaryDir staging(first.filePath(QStringLiteral(".import-XXXXXX")));
            LibraryStorage::detail::beginMutation(first.path(), staging, {destination, destination + QStringLiteral(".xz")});
            write(destination, QByteArrayLiteral("not yet committed first import"));
            write(first.filePath(QStringLiteral("languages.tsv")), QByteArrayLiteral("new manifest"));
            LibraryStorage::recoverPendingMutation(first.path());
            require(!QFileInfo::exists(destination) && !QFileInfo::exists(first.filePath(QStringLiteral("languages.tsv"))), "interrupted first import restores genuinely empty root");
        }
        // Both ordinary and DAL1 records use the ABI4 full native DPR2-8 decoder.
        const QByteArray coloredPresentation = QByteArray::fromHex("445052340100000000000005000000636f6c6f72000000000000000000000000000000000000000000000000010700000023316333396262000000000000000000000000000000000000000000000000");
        QByteArray paintedPresentation = coloredPresentation;
        paintedPresentation.replace(0, 4, "DPR6");
        const qsizetype foregroundEnd = paintedPresentation.indexOf("#1c39bb") + 7;
        require(foregroundEnd >= 7, "painted fixture contains its canonical foreground");
        paintedPresentation.insert(foregroundEnd, QByteArray::fromHex("010700000023666666666530"));
        const QList<QByteArray> supportedPresentations{
            QByteArray("DPR2") + QByteArray(28, '\0'),
            QByteArray("DPR3") + QByteArray(28, '\0'),
            QByteArray("DPR4") + QByteArray(28, '\0'),
            QByteArray("DPR5") + QByteArray(28, '\0'),
            QByteArray("DPR6") + QByteArray(28, '\0'),
            QByteArray("DPR7") + QByteArray(28, '\0'),
            QByteArray("DPR8") + QByteArray(28, '\0'),
            orderedPresentation({}),
            orderedPresentation({cellBlock(0), cellBlock(9, QByteArray(1, '\0'), "Cell_heading", "cell-heading"),
                                 cellBlock(5), cellBlock(11), cellBlock(12, orderedCellTable({cellBlock(0)})), cellBlock(0)}),
            coloredPresentation, paintedPresentation,
        };
        for (qsizetype version = 0; version < supportedPresentations.size(); ++version) {
            const auto &presentation = supportedPresentations[version];
            const QString gateRoot = temporary.filePath(QStringLiteral("gate-%1").arg(version));
            const QByteArray ordinary = blob("English", {"annotation"}, 1, presentation);
            write(source, ordinary);
            auto accepted = LibraryStorage::prepareImport(gateRoot, source, {}, -1, cancelled, progress);
            require(accepted->dictionary.words == 1, "accept complete ordinary DPR2-8 including ordered painted cells and headings");
            LibraryStorage::commitImport(gateRoot, *accepted);
            auto installed = LibraryStorage::installed(gateRoot);
            require(installed.size() == 1 && read(installed.first().path) == ordinary,
                    "ordinary import roundtrips exact supported presentation bytes");
            LibraryStorage::removeDictionary(gateRoot, installed.first());
            const QByteArray alias = aliasBlob(aliasRecord("Cats", "cat", presentation));
            write(source, alias);
            accepted = LibraryStorage::prepareImport(gateRoot, source, {}, -1, cancelled, progress);
            require(accepted->dictionary.kind == QStringLiteral("alias") && accepted->dictionary.words == 1,
                    "accept complete DPR2-8 DAL1 including ordered painted cells and headings");
            LibraryStorage::commitImport(gateRoot, *accepted);
            installed = LibraryStorage::installed(gateRoot);
            require(installed.size() == 1 && read(installed.first().path) == alias,
                    "alias import roundtrips exact envelope and supported presentation bytes");
            LibraryStorage::removeDictionary(gateRoot, installed.first());
        }
        QByteArray invalidRgb = coloredPresentation;
        const qsizetype rgbAt = invalidRgb.indexOf("#1c39bb");
        require(rgbAt >= 0, "RGB fixture contains its canonical source color");
        invalidRgb[rgbAt + 1] = 'G';
        QByteArray invalidBackground = paintedPresentation;
        const qsizetype backgroundAt = invalidBackground.indexOf("#ffffe0");
        require(backgroundAt >= 0, "painted fixture contains its canonical background");
        invalidBackground[backgroundAt + 1] = 'G';
        QByteArray invalidBackgroundPresence = paintedPresentation;
        invalidBackgroundPresence[foregroundEnd] = char(2);
        for (const QByteArray &presentation : {
                QByteArray("DPR9") + QByteArray(28, '\0'),
                coloredPresentation.chopped(1), coloredPresentation + QByteArray(1, '\0'), invalidRgb,
                invalidBackground, invalidBackgroundPresence}) {
            const QString gateRoot = temporary.filePath(QStringLiteral("invalid-version-gate"));
            write(source, blob("English", {"annotation"}, 1, presentation));
            rejects([&] { LibraryStorage::prepareImport(gateRoot, source, {}, -1, cancelled, progress); },
                    "reject unknown or malformed ordinary presentation");
            write(source, aliasBlob(aliasRecord("Cats", "cat", presentation)));
            rejects([&] { LibraryStorage::prepareImport(gateRoot, source, {}, -1, cancelled, progress); },
                    "reject unknown or malformed DAL1 presentation through full native decoder");
            require(LibraryStorage::installed(gateRoot).isEmpty(), "failed presentation validation publishes no dictionary");
        }
        // Preserve compact legacy spans and explained DPR3 fields, not just their magic.
        for (const QByteArray &presentation : {
                QByteArray::fromHex("4450523208000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
                QByteArray::fromHex("445052330100000000000001000000610000000000000000000000000000000000000000040000006e6f7465000000000000000000000000000000000000000000000000")}) {
            write(source, blob("English", {"annotation"}, 1, presentation));
            auto accepted = LibraryStorage::prepareImport(temporary.filePath(QStringLiteral("legacy-valid")), source, {}, -1, cancelled, progress);
            require(accepted->dictionary.words == 1, "full decoder accepts legacy and explained spans");
        }
        // Empty nonlanguage documents and empty alias presentation remain legitimate.
        for (unsigned char kind = 2; kind <= 7; ++kind) {
            write(source, blob({}, {"entry"}, kind));
            auto accepted = LibraryStorage::prepareImport(temporary.filePath(QStringLiteral("empty-document")), source, {}, -1, cancelled, progress);
            require(accepted->dictionary.words == 1, "empty feature document is valid");
        }
        write(source, aliasBlob(aliasRecord("Cats", "not-installed", emptyPresentation())));
        auto emptyAlias = LibraryStorage::prepareImport(temporary.filePath(QStringLiteral("empty-alias")), source, {}, -1, cancelled, progress);
        require(emptyAlias->dictionary.words == 1, "empty alias document needs no target resolution");
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
        const QByteArray manifestBefore = read(QDir(root).filePath(QStringLiteral("languages.tsv")));
        // Well-framed later records with incomplete/trailing semantic bodies must fail
        // during prepare, before commitImport is ever called on the candidate.
        for (const QByteArray &invalid : {QByteArray("DPR2"), emptyPresentation().chopped(1), emptyPresentation() + 'x'}) {
            QByteArray later = blob("English", {"apple"});
            later.append("banana", 6); later.append('\0'); appendLength(later, quint64(invalid.size())); later.append(invalid);
            for (const QByteArray &candidate : {later, aliasBlob(aliasRecord("Cats", "cat", invalid))}) {
                write(source, candidate);
                const auto stagingBefore = QDir(root).entryList({QStringLiteral(".import-*")}, QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot);
                rejects([&] { LibraryStorage::prepareImport(root, source, {}, -1, cancelled, progress); }, "reject complete framing with invalid semantic body before publication");
                require(read(installedPath) == original, "semantic refusal preserves exact installed payload");
                require(read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == manifestBefore, "semantic refusal preserves manifest");
                require(LibraryStorage::installed(root).size() == 1, "semantic refusal preserves registration");
                require(QDir(root).entryList({QStringLiteral(".import-*")}, QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot) == stagingBefore, "semantic refusal removes only owned staging");
            }
        }

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
        if (xz.isEmpty())
            std::cout << "WIKIDICT_XZ_IMPORT_SKIPPED\tmissing-xz\n";
        else
            std::cout << "WIKIDICT_XZ_EXECUTABLE\t" << xz.toStdString() << '\n';
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
            std::cout << "WIKIDICT_XZ_IMPORT_PASSED\tlanguage\n";
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
            std::cout << "WIKIDICT_XZ_IMPORT_PASSED\tsupplemental\n";
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
            std::cout << "WIKIDICT_XZ_IMPORT_PASSED\talias\n";
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

        // Identical transport bytes do not make different source editions/snapshots installed.
        const QByteArray realFixture = read(QStringLiteral("tests/fixtures/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        const QByteArray realHash = QCryptographicHash::hash(realFixture, QCryptographicHash::Sha256).toHex();
        const QString identityRoot = temporary.filePath(QStringLiteral("catalogue-identity"));
        write(source, realFixture);
        auto identityImport = LibraryStorage::prepareImport(identityRoot, source, realHash, realFixture.size(), cancelled, progress, canonicalLanguage);
        LibraryStorage::commitImport(identityRoot, *identityImport);
        QSet<QByteArray> installedHashes;
        for (const auto &dictionary : LibraryStorage::installed(identityRoot)) installedHashes.insert(dictionary.sha256);
        const QString identity = LibraryStorage::editionIdentity(identityRoot);
        const QString otherEdition = QString(canonicalLanguage).replace(QStringLiteral("enwiktionary"), QStringLiteral("afwiktionary"));
        const QString otherDate = QString(canonicalLanguage).replace(QStringLiteral("20261001"), QStringLiteral("20261101"));
        const QString invalidDate = QString(canonicalLanguage).replace(QStringLiteral("20261001"), QStringLiteral("20260230"));
        QByteArray identityCatalog;
        for (const QString &name : {canonicalLanguage, otherEdition, otherDate, QStringLiteral("English.wikblb"), invalidDate}) {
            identityCatalog += "https://example.org/" + name.toUtf8() + "\tEnglish\t" + QByteArray::number(realFixture.size()) + '\t' + realHash + '\n';
        }
        const auto identicalRows = LibraryStorage::parseCatalog(identityCatalog);
        require(LibraryStorage::catalogItemInstalled(identicalRows[0], identity, installedHashes), "same bytes and exact edition/date are installed");
        require(!LibraryStorage::catalogItemInstalled(identicalRows[1], identity, installedHashes), "same bytes from another edition remain available");
        require(!LibraryStorage::catalogItemInstalled(identicalRows[2], identity, installedHashes), "same bytes from another snapshot remain available");
        require(!LibraryStorage::catalogItemInstalled(identicalRows[3], identity, installedHashes), "unscoped catalogue row cannot match a scoped import");
        require(!LibraryStorage::catalogItemInstalled(identicalRows[4], identity, installedHashes), "invalid canonical date cannot be installed");
        auto unverifiedRow = identicalRows[0];
        unverifiedRow.sha256.clear();
        require(!LibraryStorage::catalogItemInstalled(unverifiedRow, identity, installedHashes), "catalogue row without checksum cannot claim installed");
        unverifiedRow.sha256 = QByteArray(64, '0');
        require(!LibraryStorage::catalogItemInstalled(unverifiedRow, identity, installedHashes), "matching edition alone cannot claim installed");
        for (const QString &name : {otherEdition, otherDate, QStringLiteral("English.wikblb")})
            rejects([&] { LibraryStorage::prepareImport(identityRoot, source, realHash, realFixture.size(), cancelled, progress, name); }, "identical bytes do not bypass import source conflicts");
        require(read(identityImport->dictionary.path) == realFixture &&
            read(QDir(identityRoot).filePath(QStringLiteral(".desktop-edition"))) == QByteArrayLiteral("enwiktionary-20261001\n"),
            "conflicting catalogue identity preserves installed bytes and marker");
        const QString legacyRoot = temporary.filePath(QStringLiteral("catalogue-unscoped"));
        auto legacyImport = LibraryStorage::prepareImport(legacyRoot, source, realHash, realFixture.size(), cancelled, progress);
        LibraryStorage::commitImport(legacyRoot, *legacyImport);
        const QString legacyIdentity = LibraryStorage::editionIdentity(legacyRoot);
        QSet<QByteArray> legacyHashes;
        for (const auto &dictionary : LibraryStorage::installed(legacyRoot)) legacyHashes.insert(dictionary.sha256);
        require(legacyIdentity.isEmpty() && LibraryStorage::catalogItemInstalled(identicalRows[3], legacyIdentity, legacyHashes),
            "legacy unscoped bytes retain unscoped Installed status");
        require(!LibraryStorage::catalogItemInstalled(identicalRows[0], legacyIdentity, legacyHashes),
            "legacy unscoped bytes cannot claim a canonical source identity");

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
