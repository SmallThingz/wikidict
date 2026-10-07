#include "MediaPanel.hpp"

#include <QApplication>
#include <QAudioDevice>
#include <QBuffer>
#include <QCheckBox>
#include <QComboBox>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGroupBox>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QMediaDevices>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QProgressBar>
#include <QPushButton>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QTimer>
#include <algorithm>
#include <cstring>

struct Response {
    QByteArray body;
    qint64 declared = -1;
    int delay = 0;
};

class Reply final : public QNetworkReply {
public:
    Reply(const QNetworkRequest &request, Response response, int *cancelled, QObject *parent)
        : QNetworkReply(parent), bytes_(response.body), cancelled_(cancelled) {
        setRequest(request);
        setUrl(request.url());
        setOperation(QNetworkAccessManager::GetOperation);
        setHeader(QNetworkRequest::ContentLengthHeader, response.declared < 0 ? bytes_.size() : response.declared);
        open(QIODevice::ReadOnly);
        QTimer::singleShot(response.delay, this, [this] {
            if (isFinished()) return;
            emit metaDataChanged();
            if (isFinished()) return;
            emit readyRead();
            if (isFinished()) return;
            emit downloadProgress(bytes_.size(), bytes_.size());
            setFinished(true);
            emit finished();
        });
    }
    void abort() override {
        if (isFinished()) return;
        ++*cancelled_;
        setError(OperationCanceledError, QStringLiteral("Cancelled"));
        setFinished(true);
        emit finished();
    }
    qint64 bytesAvailable() const override { return bytes_.size() - offset_ + QNetworkReply::bytesAvailable(); }
protected:
    qint64 readData(char *data, qint64 maximum) override {
        const qint64 amount = std::min(maximum, qint64(bytes_.size()) - offset_);
        if (amount <= 0) return -1;
        std::memcpy(data, bytes_.constData() + offset_, size_t(amount));
        offset_ += amount;
        return amount;
    }
private:
    QByteArray bytes_;
    qint64 offset_ = 0;
    int *cancelled_;
};

class Network final : public QNetworkAccessManager {
public:
    QList<QUrl> urls;
    QList<Response> responses;
    int cancelled = 0;
protected:
    QNetworkReply *createRequest(Operation, const QNetworkRequest &request, QIODevice *) override {
        urls.append(request.url());
        return new Reply(request, responses.isEmpty() ? Response{"{}"} : responses.takeFirst(), &cancelled, this);
    }
};

namespace {
QJsonObject entry(const QString &title = QStringLiteral("cat")) {
    return {{QStringLiteral("title"), title}, {QStringLiteral("language_code"), QStringLiteral("en")},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
                {QStringLiteral("file"), QStringLiteral("File:Cat.jpg")}, {QStringLiteral("caption"), QStringLiteral("A cat")}}}}};
}

QByteArray metadata(const QString &url = QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg")) {
    const QJsonObject credit{
        {QStringLiteral("Artist"), QJsonObject{{QStringLiteral("value"), QStringLiteral("<b>Example artist</b>")}}},
        {QStringLiteral("LicenseShortName"), QJsonObject{{QStringLiteral("value"), QStringLiteral("CC BY-SA 4.0")}}}
    };
    const QJsonObject info{{QStringLiteral("url"), url},
        {QStringLiteral("descriptionurl"), QStringLiteral("https://commons.wikimedia.org/wiki/File:Cat.jpg")},
        {QStringLiteral("extmetadata"), credit}};
    const QJsonObject page{{QStringLiteral("imageinfo"), QJsonArray{info}}};
    const QJsonObject query{{QStringLiteral("pages"), QJsonArray{page}}};
    return QJsonDocument(QJsonObject{{QStringLiteral("query"), query}}).toJson(QJsonDocument::Compact);
}

QByteArray picture() {
    QImage image(480, 320, QImage::Format_RGB32);
    image.fill(QColor(65, 139, 115));
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

QPushButton *loadButton(MediaPanel &panel) { return panel.findChild<QPushButton *>(QStringLiteral("mediaLoad")); }
QLabel *status(MediaPanel &panel) { return panel.findChild<QLabel *>(QStringLiteral("mediaStatus")); }
void enableImages(MediaPanel &panel) { QTest::mouseClick(panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowImages")), Qt::LeftButton); }
QString cacheRoot() { return QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/media-v1"); }

void isolateSettings(const QString &root) {
    qputenv("XDG_CACHE_HOME", (root + QStringLiteral("/cache")).toUtf8());
    qputenv("XDG_CONFIG_HOME", (root + QStringLiteral("/config")).toUtf8());
    qputenv("XDG_DATA_HOME", (root + QStringLiteral("/data")).toUtf8());
    for (const auto format : {QSettings::NativeFormat, QSettings::IniFormat}) {
        const QString formatRoot = root + (format == QSettings::NativeFormat ? QStringLiteral("/native") : QStringLiteral("/ini"));
        QSettings::setPath(format, QSettings::UserScope, formatRoot + QStringLiteral("/user"));
        QSettings::setPath(format, QSettings::SystemScope, formatRoot + QStringLiteral("/system"));
    }
    QSettings::setDefaultFormat(QSettings::IniFormat);
}

bool settingsPathsAreIsolated(const QString &root) {
    const auto inside = [&root](const QString &file) {
        return QDir::cleanPath(QFileInfo(file).absoluteFilePath()).startsWith(root + QChar('/'));
    };
    if (!inside(QSettings().fileName()) || !inside(QSettings(QStringLiteral("SmallThingz"), QStringLiteral("Dict")).fileName())) return false;
    for (const auto format : {QSettings::NativeFormat, QSettings::IniFormat})
        for (const auto scope : {QSettings::UserScope, QSettings::SystemScope})
            if (!inside(QSettings(format, scope, QStringLiteral("SmallThingz"), QStringLiteral("Dict")).fileName())) return false;
    return true;
}
}

class MediaPanelTest : public QObject {
    Q_OBJECT
private slots:
    void init() {
        QSettings().clear();
        QDir(cacheRoot()).removeRecursively();
    }

    void requiresExplicitPermissionAndRequest() {
        Network network;
        network.responses = {{metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network);
        panel.resize(540, 700);
        panel.setEntry(entry());
        panel.show();
        QTest::qWait(10);
        QCOMPARE(network.urls.size(), 0);
        QVERIFY(!loadButton(panel)->isEnabled());
        enableImages(panel);
        QVERIFY(loadButton(panel)->isEnabled());
        QCOMPARE(network.urls.size(), 0);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(network.urls.size(), 2);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QVERIFY(panel.findChild<QProgressBar *>()->isHidden());
        QVERIFY(panel.findChild<QPushButton *>(QStringLiteral("mediaClearCache"))->isEnabled());
        bool attribution = false;
        for (auto *label : panel.findChildren<QLabel *>())
            attribution |= label->text() == QStringLiteral("Example artist / CC BY-SA 4.0");
        QVERIFY(attribution);
        panel.grab().save(QStringLiteral(".tmp/media-panel-wide.png"));
        panel.resize(360, 700);
        QTest::qWait(10);
        panel.grab().save(QStringLiteral(".tmp/media-panel-narrow.png"));
        QVERIFY(panel.minimumSizeHint().width() <= 360);
    }

    void reusesDiskCacheAndOffDeletesIt() {
        Network network;
        network.responses = {{metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 2);
        panel.setEntry(entry());
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(status(panel)->text(), QStringLiteral("Loaded from this device."));
        QCOMPARE(network.urls.size(), 2);
        panel.findChild<QComboBox *>(QStringLiteral("mediaCacheLimit"))->setCurrentIndex(0);
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 0);
        QCOMPARE(QSettings().value(QStringLiteral("media/cacheMb")).toInt(), 0);
    }

    void navigationCancelsRequestAndPermissionCancelsRequest() {
        Network network;
        network.responses = {{metadata(), -1, 200}, {metadata(), -1, 200}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(network.urls.size(), 1);
        panel.setEntry(entry(QStringLiteral("dog")));
        QCOMPARE(network.cancelled, 1);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(network.urls.size(), 2);
        enableImages(panel);
        QCOMPARE(network.cancelled, 2);
        QVERIFY(!loadButton(panel)->isEnabled());
        QVERIFY(status(panel)->text().contains(QStringLiteral("Enable online images")));
        QTest::qWait(250);
        QCOMPARE(network.urls.size(), 2);
    }

    void fallsBackToWiktionaryAndRejectsUnsafeAddress() {
        Network network;
        network.responses = {{QByteArrayLiteral("{\"query\":{\"pages\":[{\"missing\":true}]}}")},
                             {metadata(QStringLiteral("http://example.org/unsafe.png"))}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry(), QStringLiteral("ar.wiktionary.org"));
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(network.urls.size(), 2);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("unsupported address")));
        QCOMPARE(network.urls[0].host(), QStringLiteral("commons.wikimedia.org"));
        QCOMPARE(network.urls[1].host(), QStringLiteral("ar.wiktionary.org"));
        QCOMPARE(loadButton(panel)->text(), QStringLiteral("Retry"));
        QVERIFY(loadButton(panel)->isEnabled());
    }

    void unknownEditionDoesNotGuessAMediaWiki() {
        Network network;
        network.responses = {{QByteArrayLiteral("{\"query\":{\"pages\":[{\"missing\":true}]}}")}};
        MediaPanel panel(nullptr, &network); panel.setEntry(entry()); panel.show();
        enableImages(panel); QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("no longer available")));
        QCOMPARE(network.urls.size(), 1);
        QCOMPARE(network.urls[0].host(), QStringLiteral("commons.wikimedia.org"));
    }

    void mediaCacheDoesNotCrossEditionContexts() {
        Network network;
        network.responses = {{metadata()}, {picture()}, {metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network); panel.setEntry(entry(), QStringLiteral("af.wiktionary.org")); panel.show();
        enableImages(panel); QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(network.urls.size(), 2);
        panel.setEntry(entry(), QStringLiteral("ar.wiktionary.org"));
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(network.urls.size(), 4);
    }

    void rejectsOversizedDownloadAndRetryRecovers() {
        Network network;
        network.responses = {{metadata()}, {QByteArrayLiteral("x"), 50 * 1024 * 1024 + 1},
                             {metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("too large")));
        QCOMPARE(loadButton(panel)->text(), QStringLiteral("Retry"));
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 0);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(network.urls.size(), 4);
    }

    void boundsDownloadsWithoutContentLength() {
        Network network;
        network.responses = {{QByteArray(2 * 1024 * 1024 + 1, 'x'), 0}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("too large")));
        QCOMPARE(network.urls.size(), 1);
        QCOMPARE(network.cancelled, 1);
    }

    void reducingCacheLimitEvictsOldestFiles() {
        QDir().mkpath(cacheRoot());
        QFile old(cacheRoot() + QStringLiteral("/old.bin"));
        QVERIFY(old.open(QIODevice::WriteOnly));
        QVERIFY(old.resize(26 * 1024 * 1024));
        old.setFileTime(QDateTime::fromSecsSinceEpoch(1), QFileDevice::FileModificationTime);
        old.close();
        Network network;
        network.responses = {{metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.show();
        enableImages(panel);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QVERIFY(old.exists());
        panel.findChild<QComboBox *>(QStringLiteral("mediaCacheLimit"))->setCurrentIndex(1);
        QVERIFY(!old.exists());
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 2);
    }

    void installedVoiceUsesMatchingLanguageAndLiteralText() {
        QTemporaryDir directory(QStringLiteral(".tmp/media-voice-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString executable = QFileInfo(directory.path()).absoluteFilePath() + QStringLiteral("/espeak-ng");
        QVERIFY(QFile::link(QCoreApplication::applicationFilePath(), executable));
        const QByteArray previousPath = qgetenv("PATH");
        const QString capture = QFileInfo(directory.path()).absoluteFilePath() + QStringLiteral("/spoken.txt");
        qputenv("PATH", QFileInfo(directory.path()).absoluteFilePath().toUtf8());
        qputenv("WIKIDICT_TEST_SPEECH_CAPTURE", capture.toUtf8());
        const auto restore = qScopeGuard([previousPath] {
            qputenv("PATH", previousPath);
            qunsetenv("WIKIDICT_TEST_SPEECH_CAPTURE");
        });
        Network network;
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.sayWord(QStringLiteral("-v de <literal>"), QStringLiteral("en"));
        QTRY_COMPARE(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text(), QStringLiteral("Finished."));
        QFile result(capture);
        QVERIFY(result.open(QIODevice::ReadOnly));
        QCOMPARE(result.readAll(), QByteArrayLiteral("en-gb\n-v de <literal>\n"));
        result.close();
        QVERIFY(result.remove());
        panel.sayWord(QStringLiteral("cat"), QStringLiteral("de"));
        QTRY_VERIFY(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text().contains(QStringLiteral("No installed offline voice supports German")));
        QVERIFY(!result.exists());
        QJsonObject ipaEntry = entry();
        QJsonArray spans;
        for (const QString &text : {QStringLiteral("/k\u00e6t/"), QStringLiteral("/k\u00e6t/"),
                QStringLiteral("/k\u02b0\u00e6t/"), QStringLiteral("/<speak>/"), QStringLiteral("/./")})
            spans.append(QJsonObject{{QStringLiteral("role"), QStringLiteral("pronunciation")}, {QStringLiteral("text"), text}});
        const QJsonObject block{{QStringLiteral("spans"), spans}};
        ipaEntry[QStringLiteral("sections")] = QJsonArray{QJsonObject{{QStringLiteral("blocks"), QJsonArray{block}}}};
        panel.setEntry(ipaEntry);
        const auto phonemes = panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation"));
        QCOMPARE(phonemes.size(), 1);
        QTest::mouseClick(phonemes.first(), Qt::LeftButton);
        QTRY_COMPARE(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text(), QStringLiteral("Finished."));
        QVERIFY(result.open(QIODevice::ReadOnly));
        QCOMPARE(result.readAll(), QByteArrayLiteral("en-gb\n<speak><phoneme alphabet=\"espeak\" ph=\"kat\"/></speak>\n"));
        result.close();
        QVERIFY(result.remove());
        ipaEntry[QStringLiteral("language_code")] = QStringLiteral("fr");
        panel.setEntry(ipaEntry);
        QVERIFY(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).isEmpty());
        panel.sayWord(QStringLiteral("hold"), QStringLiteral("en"));
        QTRY_VERIFY(result.exists());
        panel.stopPlayback();
        QCOMPARE(panel.findChild<QPushButton *>(QStringLiteral("mediaListen"))->text(), QStringLiteral("Listen offline"));
        QCOMPARE(network.urls.size(), 0);
    }

    void invalidLanguageNeverFallsBackToEnglish() {
        Network network;
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry());
        panel.sayWord(QStringLiteral("test"), QStringLiteral("unknown-language"));
        const auto text = panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text();
        QVERIFY(text.contains(QStringLiteral("does not identify a language")));
        QCOMPARE(panel.findChild<QPushButton *>(QStringLiteral("mediaListen"))->text(), QStringLiteral("Listen offline"));
        QCOMPARE(network.urls.size(), 0);
    }

    void missingAudioOutputShowsRecovery() {
        if (!QMediaDevices::audioOutputs().isEmpty()) QSKIP("This case needs a host without audio outputs.");
        Network network;
        network.responses = {{metadata()}, {QByteArrayLiteral("recording")}};
        MediaPanel panel(nullptr, &network);
        QJsonObject word = entry();
        QJsonArray media = word.value(QStringLiteral("media")).toArray();
        QJsonObject recording = media.first().toObject();
        recording[QStringLiteral("kind")] = QStringLiteral("audio");
        word[QStringLiteral("media")] = QJsonArray{recording};
        panel.setEntry(word);
        panel.show();
        QTest::mouseClick(panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowAudio")), Qt::LeftButton);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("No sound output")));
        QCOMPARE(loadButton(panel)->text(), QStringLiteral("Retry"));
        QVERIFY(loadButton(panel)->isEnabled());
    }
};

int main(int argc, char **argv) {
    const bool voiceFixture = (argc == 2 && QByteArray(argv[1]) == "--voices") ||
        ((argc == 4 || (argc == 5 && QByteArray(argv[4]) == "-m")) && QByteArray(argv[1]) == "-v" && QByteArray(argv[3]) == "--stdin");
    if (voiceFixture) {
        // QProcess inherits these roots; verify them before the fixture touches any file.
        const QString inheritedRoot = QString::fromUtf8(qgetenv("WIKIDICT_MEDIA_TEST_ROOT"));
        if (inheritedRoot.isEmpty() || qgetenv("XDG_CACHE_HOME") != (inheritedRoot + QStringLiteral("/cache")).toUtf8() ||
            qgetenv("XDG_CONFIG_HOME") != (inheritedRoot + QStringLiteral("/config")).toUtf8() ||
            qgetenv("XDG_DATA_HOME") != (inheritedRoot + QStringLiteral("/data")).toUtf8()) return 2;
        isolateSettings(inheritedRoot);
    }
    if (argc == 2 && QByteArray(argv[1]) == "--voices") {
        std::fputs("Pty Language Age/Gender VoiceName File Other Languages\n 2 en-gb M English gmw/en\n 5 fr-fr M French roa/fr\n", stdout);
        return 0;
    }
    if ((argc == 4 || (argc == 5 && QByteArray(argv[4]) == "-m")) && QByteArray(argv[1]) == "-v" && QByteArray(argv[3]) == "--stdin") {
        QFile input;
        if (!input.open(stdin, QIODevice::ReadOnly)) return 2;
        const QByteArray words = input.readAll();
        QFile output(QString::fromUtf8(qgetenv("WIKIDICT_TEST_SPEECH_CAPTURE")));
        if (!output.open(QIODevice::WriteOnly)) return 2;
        output.write(QByteArray(argv[2]) + '\n' + words);
        output.close();
        if (words.startsWith("hold")) QThread::msleep(1000);
        return 0;
    }
    QDir().mkpath(QStringLiteral(".tmp"));
    QTemporaryDir directory(QStringLiteral(".tmp/media-tests-XXXXXX"));
    if (!directory.isValid()) return 2;
    const QString path = QDir::cleanPath(QFileInfo(directory.path()).absoluteFilePath());
    qputenv("WIKIDICT_MEDIA_TEST_ROOT", path.toUtf8());
    isolateSettings(path);
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("WikidictTests"));
    QCoreApplication::setApplicationName(QStringLiteral("MediaPanel"));
    if (!settingsPathsAreIsolated(path)) {
        std::fputs("Settings paths escaped the temporary media test directory.\n", stderr);
        return 2;
    }
    MediaPanelTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "MediaPanelTest.moc"
