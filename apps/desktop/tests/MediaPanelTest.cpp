#include "MediaPanel.hpp"
#include "SvgRasterIdentity.hpp"

#include <QApplication>
#include <QAccessible>
#include <QAudioDevice>
#include <QBuffer>
#include <QCheckBox>
#include <QCryptographicHash>
#include <QScopeGuard>
#include <QComboBox>
#include <QDir>
#include <QDataStream>
#include <QFile>
#include <QFileInfo>
#include <QGroupBox>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QMediaDevices>
#include <QMediaPlayer>
#include <QProcess>
#include <QProcessEnvironment>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QSettings>
#include <QStandardPaths>
#include <QSvgRenderer>
#include <QStringList>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QTimer>
#include <QUrlQuery>
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
    QList<QNetworkRequest> requests;
    QList<Response> responses;
    int cancelled = 0;
protected:
    QNetworkReply *createRequest(Operation, const QNetworkRequest &request, QIODevice *) override {
        urls.append(request.url());
        requests.append(request);
        return new Reply(request, responses.isEmpty() ? Response{"{}"} : responses.takeFirst(), &cancelled, this);
    }
};

namespace {
QJsonObject entry(const QString &title = QStringLiteral("cat")) {
    return {{QStringLiteral("title"), title}, {QStringLiteral("language_code"), QStringLiteral("en")},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
                {QStringLiteral("file"), QStringLiteral("File:Cat.jpg")}, {QStringLiteral("caption"), QStringLiteral("A cat")}}}}};
}

QByteArray metadata(const QString &url = QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg"),
        const QString &artist = QStringLiteral("<b>Example artist</b>"), const QString &licence = QStringLiteral("CC BY-SA 4.0"), const QString &thumbnail = {}) {
    const QJsonObject credit{
        {QStringLiteral("Artist"), QJsonObject{{QStringLiteral("value"), artist}}},
        {QStringLiteral("LicenseShortName"), QJsonObject{{QStringLiteral("value"), licence}}}
    };
    QJsonObject info{{QStringLiteral("url"), url},
        {QStringLiteral("descriptionurl"), QStringLiteral("https://commons.wikimedia.org/wiki/File:Cat.jpg")},
        {QStringLiteral("width"), 480}, {QStringLiteral("height"), 320}, {QStringLiteral("mime"), "image/png"},
        {QStringLiteral("extmetadata"), credit}};
    if (!thumbnail.isEmpty()) info.insert(QStringLiteral("thumburl"), thumbnail);
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
    void staticPosterUsesIdentityPngDemandAndClosedCacheVariant() {
        using State = MediaPanel::InlineImageState;
        const QJsonObject policy{{"policy", "three_d_stl_v1"}, {"label", "3D"},
            {"file_sha1", QString(40, QChar('a'))}, {"file_timestamp", "2020-02-29T07:26:20Z"}};
        const QJsonObject image{{"file", "Controlled.stl"}, {"width_px", 250}, {"height_px", 188}, {"static_poster", policy}};
        const QJsonObject value{{"title", "Poster"}, {"media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", "Controlled.stl"}}}},
            {"sections", QJsonArray{QJsonObject{{"blocks", QJsonArray{QJsonObject{{"kind", "paragraph"},
                {"spans", QJsonArray{QJsonObject{{"kind", "text"}, {"text", ""}, {"image", image}}}}}}}}}}};
        const auto info = [&](int width) {
            return QJsonObject{{"mime", "application/sla"}, {"mediatype", "3D"}, {"width", 5120}, {"height", 2880},
                {"sha1", policy.value("file_sha1")}, {"timestamp", policy.value("file_timestamp")},
                {"url", "https://upload.wikimedia.org/wikipedia/commons/a/a1/Controlled.stl"},
                {"descriptionurl", "https://commons.wikimedia.org/wiki/File:Controlled.stl"},
                {"thumburl", QStringLiteral("https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a1/Controlled.stl/%1px-Controlled.stl.png").arg(width)},
                {"thumbmime", "image/png"}, {"thumbwidth", width}, {"thumbheight", (width * 3 + 2) / 4}};
        };
        const auto response = [](const QJsonObject &info) {
            return QJsonDocument(QJsonObject{{"query", QJsonObject{{"pages", QJsonArray{QJsonObject{{"ns", 6},
                {"title", "File:Controlled.stl"}, {"missing", true}, {"known", true}, {"imageinfo", QJsonArray{info}}}}}}}}).toJson();
        };
        const auto pixels = [](int width, const char *type = "PNG") {
            QImage raster(width, (width * 3 + 2) / 4, QImage::Format_RGB32); raster.fill(QColor("#5a80c0"));
            QByteArray bytes; QBuffer buffer(&bytes); buffer.open(QIODevice::WriteOnly); raster.save(&buffer, type); return bytes;
        };
        Network network; network.responses = {{response(info(250))}, {pixels(250)}};
        MediaPanel panel(nullptr, &network); panel.setEntry(value); panel.show(); QObject owner;
        MediaPanel::InlineImageAsset last{State::Loading}; const auto changed = [&](const auto &asset) { last = asset; };
        QCOMPARE(panel.requestInlineImage(image, "requested_fit", 1, &owner, "poster", changed).state, State::Disabled);
        QVERIFY(network.urls.isEmpty()); enableImages(panel);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), 2);
        QCOMPARE(QUrlQuery(network.urls.first()).queryItemValue("iiurlwidth"), QStringLiteral("250"));
        const auto properties = QUrlQuery(network.urls.first()).queryItemValue("iiprop").split(QChar('|'));
        for (const QString &property : {QStringLiteral("sha1"), QStringLiteral("timestamp"), QStringLiteral("thumbmime")}) QVERIFY(properties.contains(property));
        QCOMPARE(last.image.size(), QSize(250, 188)); QCOMPARE(last.intrinsic, QSizeF(4, 3)); QVERIFY(!last.vector);
        auto generic = image; generic.remove("static_poster");
        QCOMPARE(panel.requestInlineImage(generic, "requested_fit", 1, &owner, "generic", changed).state, State::Error);
        auto wrong = image; auto otherPolicy = policy; otherPolicy.insert("file_sha1", QString(40, QChar('b'))); wrong.insert("static_poster", otherPolicy);
        QCOMPARE(panel.requestInlineImage(wrong, "requested_fit", 1, &owner, "wrong", changed).state, State::Error);
        network.responses = {{response(info(500))}, {pixels(500)}};
        last = panel.requestInlineImage(image, "requested_fit", 2, &owner, "poster", changed);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), 4); QCOMPARE(last.image.size(), QSize(500, 375));
        QCOMPARE(QUrlQuery(network.urls[2]).queryItemValue("iiurlwidth"), QStringLiteral("500"));
        const int count = network.urls.size(); panel.setEntry(value);
        last = panel.requestInlineImage(image, "requested_fit", 2, &owner, "cached", changed);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), count);
        for (const QString &kind : {QStringLiteral("sha1"), QStringLiteral("timestamp"), QStringLiteral("thumburl"),
                QStringLiteral("thumbmime"), QStringLiteral("thumbheight"), QStringLiteral("undersized"), QStringLiteral("payload")}) {
            panel.findChild<QPushButton *>("mediaClearCache")->click(); panel.setEntry(value);
            auto bad = info(kind == "undersized" ? 249 : 250);
            if (kind == "sha1") bad.insert("sha1", QString(40, QChar('b')));
            if (kind == "timestamp") bad.insert("timestamp", "2020-03-01T07:26:20Z");
            if (kind == "thumburl") bad.remove("thumburl");
            if (kind == "thumbmime") bad.insert("thumbmime", "image/jpeg");
            if (kind == "thumbheight") bad.insert("thumbheight", 187);
            network.responses = {{response(bad)}};
            if (kind == "payload") network.responses.append({pixels(250, "BMP")});
            const int before = network.urls.size();
            last = panel.requestInlineImage(image, "requested_fit", 1, &owner, kind, changed);
            QTRY_COMPARE(last.state, State::Error); QVERIFY(last.image.isNull());
            QCOMPARE(network.urls.size(), before + (kind == "payload" ? 2 : 1));
        }
        panel.setEntry(value); network.responses = {{response(info(250)), -1, 1000}};
        last = panel.requestInlineImage(image, "requested_fit", 1, &owner, "cancelled", changed);
        QCOMPARE(last.state, State::Loading); const int cancelled = network.cancelled;
        panel.setEntry(QJsonObject{{"title", "Replacement"}}); QCOMPARE(network.cancelled, cancelled + 1);
        QVERIFY(std::none_of(network.urls.cbegin(), network.urls.cend(), [](const QUrl &url) {
            return url.path().endsWith(QStringLiteral(".stl"), Qt::CaseInsensitive);
        }));
    }
    void svgLanguageIdentityRejectsWrongRenditionsAndKeepsOriginalAxes() {
        const QString file = QStringLiteral("Logo NIKE.svg");
        QJsonObject info{{"mime", "image/svg+xml"}, {"mediatype", "DRAWING"}, {"width", 800}, {"height", 400},
            {"sha1", QString(40, QChar('a'))}, {"timestamp", "2022-09-08T23:49:18Z"},
            {"url", "https://upload.wikimedia.org/wikipedia/commons/a/a6/Logo_NIKE.svg"},
            {"thumburl", "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a6/Logo_NIKE.svg/langru-250px-short.svg.png"},
            {"thumbwidth", 200}, {"thumbheight", 100}, {"thumbmime", "image/png"},
            {"thumbattribs", QJsonObject{{"width", 200}, {"height", 100}}}};
        const QJsonObject page{{"ns", 6}, {"title", "File:Logo NIKE.svg"}, {"missing", true}, {"known", true}};
        QVERIFY(SvgRasterIdentity::original(page, file, info)); // Shared file, absent local description.
        const auto original = info;
        QVERIFY(SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200).has_value());
        QCOMPARE(*SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200), quint32(250));
        QJsonObject image{{"file", file}, {"width_px", 200}, {"svg_language", "ru"}};
        QCOMPARE(*SvgRasterIdentity::demand(image, "requested_fit", 2, QSizeF(800, 400)), quint32(400));
        QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 400));
        const QString base = "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a6/Logo_NIKE.svg/";
        for (const QString &suffix : {"langko-250px-short.svg.png", "200px-short.svg.png", "langru-199px-short.svg.png"}) {
            info.insert("thumburl", base + suffix);
            QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200));
        }
        info = original; info.insert("thumburl", "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a6/Wrong.svg/langru-250px-short.svg.png");
        QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200));
        info = original; info.insert("thumburl", "https://untrusted.example/Logo_NIKE.svg/langru-250px-short.svg.png");
        QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200));
        info = original; info.insert("sha1", QString(40, QChar('a')) + QChar('\n'));
        QVERIFY(!SvgRasterIdentity::original(page, file, info));
        info = original; info.insert("thumburl", base + "langru-250px-short.svg.png%0A");
        QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200));
        info = original; info.insert("url", "https://upload.wikimedia.org/wikipedia/commons/b/b2/Logo_NIKE.svg");
        QVERIFY(SvgRasterIdentity::original(page, file, info));
        QVERIFY(!SvgRasterIdentity::sameOriginal(original, info));
        info = original; info.insert("thumbheight", 99);
        QVERIFY(!SvgRasterIdentity::rasterWidth(page, file, info, "ru", 200));
        info = original; info.insert("sha1", QString(40, QChar('b')));
        QVERIFY(!SvgRasterIdentity::sameOriginal(original, info));
        for (const QString &language : {QStringLiteral("en"), QStringLiteral("und"), QStringLiteral("ru"), QStringLiteral("zh-hant")}) {
            QVERIFY(SvgRasterIdentity::language(language));
            info = original; info.insert("thumburl", base + "lang" + language + "-250px-short.svg.png");
            QVERIFY(SvgRasterIdentity::rasterWidth(page, file, info, language, 200));
            QVERIFY(SvgRasterIdentity::cacheIdentity(file, language, info, 250) != SvgRasterIdentity::cacheIdentity(file, "ko", original, 250));
        }
        for (const QString &bad : {QString(), QStringLiteral("RU"), QStringLiteral("ru_ko"), QStringLiteral("ru--ko"), QStringLiteral("ru-1")})
            QVERIFY(!SvgRasterIdentity::language(bad));
        QCOMPARE(QSizeF(original.value("width").toDouble(), original.value("height").toDouble()), QSizeF(800, 400));
    }

    void languageSpecificSvgUsesPhysicalDemandCacheAndExactCatalogueOccurrence() {
        using State = MediaPanel::InlineImageState;
        const QString file = QStringLiteral("Controlled.svg");
        QJsonObject image{{"file", file}, {"width_px", 200}, {"svg_language", "ru"}};
        const QJsonObject value{{"title", "Language rendition"}, {"media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", file}}}},
            {"sections", QJsonArray{QJsonObject{{"blocks", QJsonArray{QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{}},
                {"flow", QJsonArray{QJsonObject{{"kind", "figure"}, {"figure", QJsonObject{
                    {"image_span", QJsonObject{{"kind", "text"}, {"text", ""}, {"image", image}}}, {"sizing", "requested_fit"}}}}}}}}}}}}};
        const auto response = [&](int requested, int bucket) {
            QJsonObject info{{"mime", "image/svg+xml"}, {"mediatype", "DRAWING"}, {"width", 800}, {"height", 400},
                {"sha1", QString(40, QChar('a'))}, {"timestamp", "2022-09-08T23:49:18Z"},
                {"url", "https://upload.wikimedia.org/wikipedia/commons/c/c1/Controlled.svg"}};
            if (requested) {
                info.insert("thumburl", QStringLiteral("https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c1/Controlled.svg/langru-%1px-Controlled.svg.png").arg(bucket));
                info.insert("thumbwidth", requested); info.insert("thumbheight", requested / 2); info.insert("thumbmime", "image/png");
                info.insert("thumbattribs", QJsonObject{{"width", requested}, {"height", requested / 2}});
            }
            return QJsonDocument(QJsonObject{{"query", QJsonObject{{"pages", QJsonArray{QJsonObject{
                {"ns", 6}, {"title", "File:Controlled.svg"}, {"missing", true}, {"known", true}, {"imageinfo", QJsonArray{info}}}}}}}}).toJson();
        };
        const auto pixels = [](int width) {
            QImage raster(width, width / 2, QImage::Format_ARGB32_Premultiplied); raster.fill(QColor("#af3678"));
            QByteArray bytes; QBuffer output(&bytes); output.open(QIODevice::WriteOnly); raster.save(&output, "PNG"); return bytes;
        };
        Network network; network.responses = {{response(0, 0)}, {response(200, 250)}, {pixels(250)}};
        MediaPanel panel(nullptr, &network); panel.setEntry(value); panel.show();
        QObject owner; MediaPanel::InlineImageAsset last{State::Loading};
        const auto changed = [&](const auto &asset) { last = asset; };
        QCOMPARE(panel.requestInlineImage(image, "requested_fit", 1, &owner, "resource", changed).state, State::Disabled);
        QVERIFY(network.urls.isEmpty()); enableImages(panel);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), 3);
        QCOMPARE(last.intrinsic, QSizeF(800, 400)); QVERIFY(last.originalVerified); QVERIFY(!last.vector);
        QCOMPARE(last.image.size(), QSize(250, 125));
        QCOMPARE(QUrlQuery(network.urls[1]).queryItemValue("iiurlparam"), QStringLiteral("langru-200px"));
        QCOMPARE(QUrlQuery(network.urls[1]).queryItemValue("iiurlwidth"), QStringLiteral("200"));
        QVERIFY(QUrlQuery(network.urls[1]).queryItemValue("iiprop").split(QChar('|')).contains("thumbmime"));
        QVERIFY(network.urls.last().path().contains("langru-250px-"));
        auto generic = image; generic.remove("svg_language");
        QCOMPARE(panel.requestInlineImage(generic, "requested_fit", 1, &owner, "generic", changed).state, State::Error);
        auto other = image; other.insert("svg_language", "ko");
        QCOMPARE(panel.requestInlineImage(other, "requested_fit", 1, &owner, "other", changed).state, State::Error);
        network.responses = {{response(0, 0)}, {response(400, 500)}, {pixels(500)}};
        last = panel.requestInlineImage(image, "requested_fit", 2, &owner, "resource", changed);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), 6);
        QCOMPARE(last.image.size(), QSize(500, 250)); QCOMPARE(last.intrinsic, QSizeF(800, 400));
        QCOMPARE(QUrlQuery(network.urls[4]).queryItemValue("iiurlparam"), QStringLiteral("langru-400px"));
        const int requests = network.urls.size(); panel.setEntry(value);
        last = panel.requestInlineImage(image, "requested_fit", 2, &owner, "cached", changed);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), requests);
        QCOMPARE(last.image.size(), QSize(500, 250));
        panel.findChild<QPushButton *>("mediaClearCache")->click(); panel.setEntry(value);
        network.responses = {{response(0, 0), -1, 1000}};
        last = panel.requestInlineImage(image, "requested_fit", 1, &owner, "cancelled", changed);
        QCOMPARE(last.state, State::Loading);
        const int cancelled = network.cancelled;
        enableImages(panel); QCOMPARE(last.state, State::Disabled);
        QCOMPARE(network.cancelled, cancelled + 1);
        network.responses = {{response(0, 0)}, {response(200, 250)}, {pixels(250)}};
        enableImages(panel);
        QTRY_COMPARE(last.state, State::Ready); QCOMPARE(last.image.size(), QSize(250, 125));
        panel.findChild<QPushButton *>("mediaClearCache")->click(); panel.setEntry(value);
        network.responses = {{response(0, 0)}, {response(400, 250)}};
        last = panel.requestInlineImage(image, "requested_fit", 2, &owner, "undersized", changed);
        QTRY_COMPARE(last.state, State::Error); QVERIFY(last.image.isNull());
        QVERIFY(std::none_of(network.urls.cbegin(), network.urls.cend(), [](const QUrl &url) { return url.path().endsWith("Controlled.svg"); }));
        for (const QString &failure : {QStringLiteral("error"), QStringLiteral("warnings")}) {
            auto bad = QJsonDocument::fromJson(response(0, 0)).object();
            bad.insert(failure, QJsonObject{{"code", "bad-svg-language"}});
            panel.setEntry(value); const int before = network.urls.size();
            network.responses = {{QJsonDocument(bad).toJson()}};
            last = panel.requestInlineImage(image, "requested_fit", 1, &owner, failure, changed);
            QTRY_COMPARE(last.state, State::Error); QCOMPARE(network.urls.size(), before + 1);
            QVERIFY(last.image.isNull());
        }
    }

    // Insert in the existing MediaPanelTest target, whose Network stub is owned.
    void pronunciationScopesDoNotConsumeUnsupportedDedupKeys() {
        QTemporaryDir directory(QStringLiteral(".tmp/media-scope-voice-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString directoryPath = QFileInfo(directory.path()).absoluteFilePath();
        QVERIFY(QFile::link(QString::fromUtf8(DICT_FAKE_VOICE_PATH), directoryPath + QStringLiteral("/espeak-ng")));
        const QByteArray previousPath = qgetenv("PATH");
        const QByteArray previousCapture = qgetenv("WIKIDICT_TEST_SPEECH_CAPTURE");
        const QString capture = directoryPath + QStringLiteral("/spoken.txt");
        qputenv("PATH", directoryPath.toUtf8());
        qputenv("WIKIDICT_TEST_SPEECH_CAPTURE", capture.toUtf8());
        const auto restore = qScopeGuard([previousPath, previousCapture] {
            qputenv("PATH", previousPath);
            if (previousCapture.isNull()) qunsetenv("WIKIDICT_TEST_SPEECH_CAPTURE");
            else qputenv("WIKIDICT_TEST_SPEECH_CAPTURE", previousCapture);
        });
        Network network;
        MediaPanel panel(nullptr, &network);
        const auto pronunciation = [](const QString &text, const QString &language = {}) {
            return QJsonObject{{"kind", "text"}, {"role", "pronunciation"},
                {"text", text}, {"language", language}};
        };
        const auto inlinePart = [](const QJsonArray &spans) {
            return QJsonObject{{"kind", "inline"}, {"spans", spans}};
        };
        const auto scopePart = [](const QJsonValue &language, const QJsonArray &parts) {
            return QJsonObject{{"kind", "scope"}, {"spans", QJsonArray{}}, {"scope", QJsonObject{
                {"mode", "isolate"}, {"authored_direction", QJsonValue::Null},
                {"resolved_direction", "ltr"}, {"language", language}, {"parts", parts}}}};
        };
        const QJsonArray flow{
            scopePart(QString{}, QJsonArray{inlinePart(QJsonArray{pronunciation("/mi/"), pronunciation("/vi/")}),
                scopePart(QJsonValue::Null, QJsonArray{inlinePart(QJsonArray{pronunciation("/wi/")})})}),
            scopePart("fr", QJsonArray{inlinePart(QJsonArray{pronunciation("/ti/"), pronunciation("/zi/")})}),
            scopePart(QJsonValue::Null, QJsonArray{inlinePart(QJsonArray{pronunciation("/mi/")})}),
            scopePart("en", QJsonArray{inlinePart(QJsonArray{pronunciation("/ti/")})}),
            scopePart(QString{}, QJsonArray{inlinePart(QJsonArray{pronunciation("/si/", "en")})}),
            inlinePart(QJsonArray{pronunciation("/mi/"), pronunciation("/ni/")})};
        QJsonObject value = entry(); value.insert("media", QJsonArray{});
        value.insert("language_code", "en");
        value.insert("sections", QJsonArray{QJsonObject{{"blocks", QJsonArray{QJsonObject{
            {"kind", "paragraph"}, {"depth", 0}, {"list_path", ""}, {"spans", QJsonArray{}}, {"flow", flow}}}}}});
        const QByteArray before = QJsonDocument(value).toJson(QJsonDocument::Compact);
        panel.setEntry(value);
        QStringList names;
        for (QPushButton *button : panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation"))) {
            QCOMPARE(button->text(), QStringLiteral("Listen"));
            auto *accessible = QAccessible::queryAccessibleInterface(button);
            QVERIFY(accessible);
            names.append(accessible->text(QAccessible::Name));
        }
        QStringList expected;
        for (const QString &ipa : {QStringLiteral("/mi/"), QStringLiteral("/ti/"),
                QStringLiteral("/si/"), QStringLiteral("/ni/")})
            expected.append(QStringLiteral("Listen to the transcription %1 offline").arg(ipa));
        QCOMPARE(names, expected);
        QCOMPARE(QJsonDocument(value).toJson(QJsonDocument::Compact), before);
        QVERIFY(network.urls.isEmpty());
        value.insert("language_code", "fr");
        panel.setEntry(value);
        const auto scopedButtons = panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation"));
        QCOMPARE(scopedButtons.size(), 2);
        QCOMPARE(scopedButtons.at(0)->accessibleName(), QStringLiteral("Listen to the transcription /ti/ offline"));
        QCOMPARE(scopedButtons.at(1)->accessibleName(), QStringLiteral("Listen to the transcription /si/ offline"));
        QTest::mouseClick(scopedButtons.at(0), Qt::LeftButton);
        QTRY_COMPARE_WITH_TIMEOUT(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text(), QStringLiteral("Finished."), 15000);
        QFile spoken(capture);
        QVERIFY(spoken.open(QIODevice::ReadOnly));
        QCOMPARE(spoken.readAll(), QByteArrayLiteral("en-gb\n<speak><phoneme alphabet=\"espeak\" ph=\"ti\"/></speak>\n"));
        QVERIFY(network.urls.isEmpty());
    }

    void init() {
        QSettings().clear();
        QDir(cacheRoot()).removeRecursively();
    }

    void originalSvgUsesSharedNativeVectorAndSurvivesOfflineCache() {
        using State = MediaPanel::InlineImageState;
        const QString original = QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/v/vector.svg");
        const QString thumbnail = QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/thumb/v/vector.svg/960px-vector.svg.png");
        const QJsonObject info{{"url", original}, {"thumburl", thumbnail}, {"mime", "image/svg+xml"},
            {"descriptionurl", "https://commons.wikimedia.org/wiki/File:Vector.svg"}, {"width", 20}, {"height", 40}};
        const QByteArray response = QJsonDocument(QJsonObject{{"query", QJsonObject{{"pages", QJsonArray{
            QJsonObject{{"imageinfo", QJsonArray{info}}}}}}}}).toJson();
        const QByteArray svg = R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="40"><rect width="20" height="40" fill="red"/></svg>)svg";
        QJsonObject value = entry(); value.insert("media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", "File:Vector.svg"}}});
        Network network; network.responses = {{response}, {svg}};
        MediaPanel panel(nullptr, &network); panel.setEntry(value); panel.show();
        // QtSvg is linked directly; this path must not depend on an imageformat plugin.
        const QStringList libraryPaths = QCoreApplication::libraryPaths();
        const auto restorePlugins = qScopeGuard([&] { QCoreApplication::setLibraryPaths(libraryPaths); });
        QCoreApplication::setLibraryPaths({});
        QObject owner; MediaPanel::InlineImageAsset last{State::Loading};
        const auto changed = [&](const auto &asset) { last = asset; };
        QCOMPARE(panel.requestInlineImage("Vector.svg", &owner, "first", changed).state, State::Disabled);
        QCOMPARE(network.urls.size(), 0); enableImages(panel);
        QTRY_COMPARE(last.state, State::Ready);
        QCOMPARE(network.urls.size(), 2); QCOMPARE(network.urls.last(), QUrl(original));
        QVERIFY(last.vector); QVERIFY(last.vector->isValid()); QCOMPARE(last.vector->thread(), QThread::currentThread());
        QCOMPARE(last.vector->framesPerSecond(), 0); QCOMPARE(last.intrinsic, QSizeF(20, 40));
        QVERIFY(last.image.width() <= 1280 && last.image.height() <= 800);
        const std::weak_ptr<QSvgRenderer> prior = last.vector;
        {
            const auto second = panel.requestInlineImage("Vector.svg", &owner, "second", changed);
            QVERIFY(second.vector == last.vector); QCOMPARE(network.urls.size(), 2);
        }
        enableImages(panel); QCOMPARE(last.state, State::Disabled); QVERIFY(!last.vector);
        enableImages(panel); QCOMPARE(last.state, State::Ready); QCOMPARE(network.urls.size(), 2);
        last = {State::Loading};
        panel.setEntry(value); // Same owned cache, no resolver or network reply remains.
        QVERIFY(prior.expired());
        last = panel.requestInlineImage("Vector.svg", &owner, "cached", changed);
        QTRY_COMPARE(last.state, State::Ready); QVERIFY(last.vector); QCOMPARE(network.urls.size(), 2);
        panel.findChild<QPushButton *>("mediaClearCache")->click(); panel.setEntry(value);
        network.responses = {{response}, {"not an SVG or raster"}};
        last = panel.requestInlineImage("Vector.svg", &owner, "failure", changed);
        QTRY_COMPARE(last.state, State::Error); QVERIFY(!last.vector); QVERIFY(last.image.isNull());
    }

    void cachedSvgThumbnailRemainsRasterWithoutImplicitNetworkUpgrade() {
        using State = MediaPanel::InlineImageState;
        const QString key = QString::fromLatin1(QCryptographicHash::hash(":image:Cat.jpg", QCryptographicHash::Sha256).toHex());
        const QJsonObject info{{"url", "https://upload.wikimedia.org/wikipedia/commons/thumb/v/vector.svg/960px-vector.svg.png"},
            {"original_mime", "image/svg+xml"}, {"source", "https://commons.wikimedia.org/wiki/File:Vector.svg"},
            {"intrinsic_width", 480}, {"intrinsic_height", 320}};
        Network network;
        MediaPanel panel(nullptr, &network); panel.setEntry(entry()); panel.show(); enableImages(panel);
        QFile payload(cacheRoot() + '/' + key + ".bin"); QVERIFY(payload.open(QIODevice::WriteOnly));
        const QByteArray pixels = picture(); QCOMPARE(payload.write(pixels), pixels.size()); payload.close();
        QFile cacheInfo(cacheRoot() + '/' + key + ".json"); QVERIFY(cacheInfo.open(QIODevice::WriteOnly));
        const QByteArray json = QJsonDocument(info).toJson(); QCOMPARE(cacheInfo.write(json), json.size()); cacheInfo.close();
        QObject owner; MediaPanel::InlineImageAsset last{State::Loading};
        const auto changed = [&](const auto &asset) { last = asset; };
        last = panel.requestInlineImage("Cat.jpg", &owner, "first", changed);
        QTRY_COMPARE(last.state, State::Ready); QVERIFY(!last.vector); QVERIFY(!last.image.isNull());
        QCOMPARE(last.originalMime, QStringLiteral("image/svg+xml")); QCOMPARE(network.urls.size(), 0);
        panel.setEntry(entry()); last = panel.requestInlineImage("Cat.jpg", &owner, "cached", changed);
        QTRY_COMPARE(last.state, State::Ready); QVERIFY(!last.vector); QVERIFY(!last.image.isNull());
        QCOMPARE(network.urls.size(), 0); // Offline PNG cache is not relabelled as parsed SVG.
    }

    void inlineImagesReusePassiveCachePermissionsAndFailureLifecycle() {
        using State = MediaPanel::InlineImageState;
        Network network; network.responses = {{metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network); panel.setEntry(entry()); panel.show();
        QObject owner; State last = State::Loading; QImage decoded; int calls = 0;
        const auto changed = [&](const MediaPanel::InlineImageAsset &asset) { last = asset.state; decoded = asset.image; ++calls; };
        QCOMPARE(panel.requestInlineImage("Cat.jpg", &owner, "document-image", changed).state, State::Disabled);
        QCOMPARE(network.urls.size(), 0);
        enableImages(panel);
        QTRY_COMPARE(last, State::Ready);
        QVERIFY(!decoded.isNull()); QVERIFY(qAbs(qreal(decoded.width()) / decoded.height() - 1.5) < 0.001);
        QCOMPARE(network.urls.size(), 2);
        QCOMPARE(panel.requestInlineImage("Cat.jpg", &owner, "second-occurrence", changed).state, State::Ready);
        QCOMPARE(network.urls.size(), 2);
        const auto buttons = panel.findChildren<QPushButton *>();
        QVERIFY(std::any_of(buttons.begin(), buttons.end(), [](const QPushButton *button) { return button->text() == QStringLiteral("Source and licence") && !button->isHidden(); }));
        enableImages(panel); // Disable: inline consumers get the same permission boundary.
        QCOMPARE(last, State::Disabled); QVERIFY(decoded.isNull());
        enableImages(panel); QCOMPARE(last, State::Ready); QCOMPARE(network.urls.size(), 2);
        QVERIFY(calls > 0);
        const int before = calls;
        panel.setEntry({}); QTest::qWait(5); QCOMPARE(calls, before);
        QCOMPARE(panel.requestInlineImage("Missing.svg", &owner, "missing", changed).state, State::Error);
        QCOMPARE(network.urls.size(), 2);
        panel.findChild<QPushButton *>("mediaClearCache")->click();
        panel.setEntry(entry("missing")); network.responses = {{"{}"}};
        panel.requestInlineImage("Cat.jpg", &owner, "failed-resource", changed);
        QTRY_COMPARE(last, State::Error); QVERIFY(decoded.isNull());
        QVERIFY(!status(panel)->text().isEmpty());
    }

    void typedInlineCanonicalColonFileIsNotLegacyPrefixStripped() {
        using State = MediaPanel::InlineImageState;
        Network network; network.responses = {{metadata()}, {picture()}};
        MediaPanel panel(nullptr, &network);
        QJsonObject value = entry();
        value.insert("media", QJsonArray{QJsonObject{{"kind", "image"}, {"file", "File:Opaque.svg"}}});
        value.insert("preamble_spans", QJsonArray{QJsonObject{{"kind", "link"}, {"text", ""}, {"target", "File:File:Opaque.svg"},
            {"image", QJsonObject{{"file", "File:Opaque.svg"}, {"width_px", 15}}}}});
        panel.setEntry(value, QStringLiteral("he.wiktionary.org")); panel.show();
        const QUrl expected("https://he.wiktionary.org/wiki/File%3AFile%3AOpaque.svg");
        QCOMPARE(panel.inlineImageSource("File:File:Opaque.svg"), expected);
        enableImages(panel);
        QObject owner; State last = State::Loading;
        panel.requestInlineImage("File:Opaque.svg", &owner, "opaque", [&](const MediaPanel::InlineImageAsset &asset) { last = asset.state; });
        QTRY_COMPARE(last, State::Ready);
        QCOMPARE(QUrlQuery(network.urls.first()).queryItemValue("titles"), QStringLiteral("File:File:Opaque.svg"));
        QCOMPARE(panel.inlineImageSource("File:File:Opaque.svg"), expected);
        panel.setEntry(value, {}); QVERIFY(panel.inlineImageSource("File:File:Opaque.svg").isEmpty());
        QCOMPARE(panel.requestInlineImage("Opaque.svg", &owner, "wrong-alias", [](const auto &) {}).state, State::Error);
    }

    void inlineImageSourcePreservesSeparateTitleAndFragment() {
        Network network;
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry(), QStringLiteral("de.wiktionary.org"));
        const QString target = QString::fromUtf8("File:Flag%23?x&Ω#literal.svg");
        const QUrl legacy = panel.inlineImageSource(target);
        QCOMPARE(legacy.path(QUrl::FullyDecoded), QString::fromUtf8("/wiki/File:Flag%23?x&Ω"));
        QCOMPARE(legacy.fragment(QUrl::FullyDecoded), QStringLiteral("literal.svg"));
        const QUrl whole = panel.inlineImageSource(target, QStringLiteral(""));
        QCOMPARE(whole.path(QUrl::FullyDecoded), QStringLiteral("/wiki/") + target);
        QVERIFY(!whole.hasFragment()); QVERIFY(!whole.hasQuery());
        const QString fragment = QString::fromUtf8("detail#%23?x&Ω");
        const QUrl separate = panel.inlineImageSource(target, fragment);
        QCOMPARE(separate.path(QUrl::FullyDecoded), QStringLiteral("/wiki/") + target);
        QCOMPARE(separate.fragment(QUrl::FullyDecoded), fragment);
        QVERIFY(!separate.hasQuery());
        QCOMPARE(separate.host(), QStringLiteral("de.wiktionary.org"));
        QVERIFY(network.urls.isEmpty());
        panel.setEntry(entry(), {});
        QVERIFY(panel.inlineImageSource(target, QStringLiteral("")).isEmpty());
    }

    void inlineImageQueueBoundsAndAdvancesAcrossCancelAndFailure() {
        using State = MediaPanel::InlineImageState;
        Network network;
        for (int i = 0; i < 4; ++i) network.responses.append({"{}", -1, 1000});
        MediaPanel panel(nullptr, &network); panel.show();
        const auto many = [](const QString &prefix) {
            QJsonArray media, spans;
            for (int i = 0; i < 5; ++i) {
                const QString file = prefix + QString::number(i) + ".png";
                media.append(QJsonObject{{"kind", "image"}, {"file", file}});
                spans.append(QJsonObject{{"kind", "text"}, {"text", ""}, {"image", QJsonObject{{"file", file}, {"width_px", 15}}}});
            }
            return QJsonObject{{"title", prefix}, {"media", media}, {"preamble_spans", spans}};
        };
        panel.setEntry(many("Cancel")); enableImages(panel);
        QObject owner; int oldCalls = 0;
        for (int i = 0; i < 5; ++i) panel.requestInlineImage("Cancel" + QString::number(i) + ".png", &owner, QString::number(i), [&](const auto &) { ++oldCalls; });
        QCOMPARE(network.urls.size(), 4); // Fifth is queued, not another reply/payload.
        const int before = oldCalls;
        panel.setEntry(entry("replacement")); QCOMPARE(network.cancelled, 4);
        network.responses = {{metadata()}, {picture()}};
        State last = State::Loading;
        panel.requestInlineImage("Cat.jpg", &owner, "replacement", [&](const auto &asset) { last = asset.state; });
        QTRY_COMPARE(last, State::Ready); QCOMPARE(network.urls.size(), 6);
        QCOMPARE(oldCalls, before);
        QCOMPARE(loadButton(panel)->text(), QStringLiteral("Reload image"));
        panel.setEntry(many("Fail")); network.responses.clear();
        for (int i = 0; i < 5; ++i) network.responses.append({"{}", -1, 1});
        QVector<State> states(5, State::Loading); const int previousRequests = network.urls.size();
        for (int i = 0; i < 5; ++i) panel.requestInlineImage("Fail" + QString::number(i) + ".png", &owner, QString::number(i), [&, i](const auto &asset) { states[i] = asset.state; });
        QCOMPARE(network.urls.size() - previousRequests, 4);
        QTRY_VERIFY(std::all_of(states.begin(), states.end(), [](State state) { return state == State::Error; }));
        QCOMPARE(network.urls.size() - previousRequests, 5);
    }

    void initialEmptyMediaRemainsReachableInShortPane() {
        Network network;
        MediaPanel panel(nullptr, &network);
        panel.resize(300, 140);
        panel.show();
        QTest::qWait(10);
        auto *scroll = panel.findChild<QScrollArea *>(QStringLiteral("mediaContentScroll"));
        auto *images = panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowImages"));
        auto *audio = panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowAudio"));
        auto *listen = panel.findChild<QPushButton *>(QStringLiteral("mediaListen"));
        QVERIFY(scroll && images && audio && listen);
        QCOMPARE(panel.size(), QSize(300, 140));
        QVERIFY(scroll->viewport()->height() > 0);
        QVERIFY(scroll->viewport()->height() <= 140);
        QVERIFY(scroll->widget()->height() > scroll->viewport()->height());
        QVERIFY(scroll->verticalScrollBar()->maximum() > 0);
        QVERIFY(!images->isChecked());
        QVERIFY(!audio->isChecked());
        QVERIFY(!listen->isEnabled());
        QLabel *empty = nullptr;
        for (auto *label : panel.findChildren<QLabel *>())
            if (label->text() == QStringLiteral("Media will appear here when you open a word.")) empty = label;
        QVERIFY(empty);
        // Logical visibility alone did not catch the collapsed preferences in
        // the main window's short Media tab. Each control must be reachable in
        // the real scroll viewport with its own painted rectangle intact.
        for (auto *target : {static_cast<QWidget *>(images), static_cast<QWidget *>(audio), static_cast<QWidget *>(empty)}) {
            scroll->ensureWidgetVisible(target, 0, 0);
            QTest::qWait(10);
            QCOMPARE(panel.size(), QSize(300, 140));
            const QRect rect(target->mapTo(scroll->viewport(), QPoint()), target->size());
            QVERIFY(scroll->viewport()->rect().intersects(rect));
            QVERIFY(scroll->viewport()->rect().contains(rect.center()));
            QVERIFY(target->parentWidget()->rect().contains(QRect(target->pos(), target->size())));
        }
        QCOMPARE(network.urls.size(), 0);
        panel.setEntry(entry());
        QVERIFY(loadButton(panel));
        panel.setEntry(QJsonObject{});
        QVERIFY(!loadButton(panel));
        QVERIFY(!listen->isEnabled());
        QCOMPARE(panel.size(), QSize(300, 140));
        QCOMPARE(network.urls.size(), 0);
    }

    void emptyMediaFitsActualNarrowViewportWithoutHorizontalScrolling() {
        Network network;
        MediaPanel panel(nullptr, &network);
        panel.resize(262, 135);
        panel.show();
        QTest::qWait(10);
        auto *scroll = panel.findChild<QScrollArea *>(QStringLiteral("mediaContentScroll"));
        auto *images = panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowImages"));
        auto *audio = panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowAudio"));
        auto *limit = panel.findChild<QComboBox *>(QStringLiteral("mediaCacheLimit"));
        auto *clear = panel.findChild<QPushButton *>(QStringLiteral("mediaClearCache"));
        QVERIFY(scroll && images && audio && limit && clear);
        QLabel *empty = nullptr;
        for (auto *label : panel.findChildren<QLabel *>())
            if (label->text() == QStringLiteral("Media will appear here when you open a word.")) empty = label;
        QVERIFY(empty);
        // Actual main-window Media pane: the previous cache row forced a
        // 288-pixel body into a 248-pixel viewport and clipped these controls.
        QCOMPARE(panel.size(), QSize(262, 135));
        QVERIFY(scroll->viewport()->width() > 0);
        QVERIFY(scroll->viewport()->height() > 0);
        QVERIFY(scroll->viewport()->height() <= 135);
        QVERIFY(scroll->widget()->height() > scroll->viewport()->height());
        QVERIFY(scroll->verticalScrollBar()->maximum() > 0);
        QCOMPARE(scroll->horizontalScrollBar()->maximum(), 0);
        QVERIFY(scroll->widget()->width() <= scroll->viewport()->width());
        QVERIFY(!images->isChecked());
        QVERIFY(!audio->isChecked());
        for (auto *target : {static_cast<QWidget *>(images), static_cast<QWidget *>(audio),
                            static_cast<QWidget *>(limit), static_cast<QWidget *>(clear),
                            static_cast<QWidget *>(empty)}) {
            scroll->ensureWidgetVisible(target, 0, 0);
            QTest::qWait(10);
            QCOMPARE(panel.size(), QSize(262, 135));
            QCOMPARE(scroll->horizontalScrollBar()->maximum(), 0);
            const QRect rect(target->mapTo(scroll->viewport(), QPoint()), target->size());
            QVERIFY(rect.left() >= 0);
            QVERIFY(rect.right() < scroll->viewport()->width());
            QVERIFY(scroll->viewport()->rect().contains(rect.center()));
            QVERIFY(target->parentWidget()->rect().contains(QRect(target->pos(), target->size())));
        }
        QCOMPARE(network.urls.size(), 0);
        panel.setEntry(entry());
        panel.setEntry(QJsonObject{});
        QTest::qWait(10);
        QCOMPARE(panel.size(), QSize(262, 135));
        QCOMPARE(scroll->horizontalScrollBar()->maximum(), 0);
        QVERIFY(scroll->widget()->width() <= scroll->viewport()->width());
        QVERIFY(!images->isChecked());
        QVERIFY(!audio->isChecked());
        QCOMPARE(network.urls.size(), 0);
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
        auto *action = QAccessible::queryAccessibleInterface(loadButton(panel));
        QVERIFY(action);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Load image: A cat"));
        enableImages(panel);
        QVERIFY(loadButton(panel)->isEnabled());
        QCOMPARE(network.urls.size(), 0);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Loading...: A cat"));
        QTRY_COMPARE(network.urls.size(), 2);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Reload image: A cat"));
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

    void imageOnlyCreditsPreserveAltText_data() {
        QTest::addColumn<QString>("artist");
        QTest::addColumn<QString>("expected");
        // Commons Example.jpg Artist HTML is an unknown-author pictogram with
        // no alt text. A filename or object placeholder is not an author name.
        QTest::newRow("commons-example-unknown-author")
            << QStringLiteral("<span typeof=\"mw:File\"><span><img src=\"https://thumb.wikimedia.org/wikipedia/commons/thumb/7/77/Pictogram-voting_question.svg/20px-Pictogram-voting_question.svg.png\" decoding=\"async\" loading=\"lazy\" width=\"15\" height=\"15\" class=\"mw-file-element\"></span></span>")
            << QStringLiteral("Public domain");
        QTest::newRow("image-alt-entities-and-unicode")
            << QStringLiteral("<span><img src='signature.png' alt='A &amp; É'></span>") << QStringLiteral("A & É / Public domain");
        QTest::newRow("image-alt-literal-angle-brackets")
            << QStringLiteral("<img src='signature.png' alt='&lt;Name&gt; &amp; <literal>'>") << QStringLiteral("<Name> & <literal> / Public domain");
        QTest::newRow("text-around-decorative-image")
            << QStringLiteral("<b>Known creator</b> <img src='icon.png' alt=''>") << QStringLiteral("Known creator / Public domain");
    }

    void imageOnlyCreditsPreserveAltText() {
        QFETCH(QString, artist);
        QFETCH(QString, expected);
        Network network;
        network.responses = {{metadata(QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg"), artist, QStringLiteral("Public domain"))}, {picture()}};
        MediaPanel panel(nullptr, &network); panel.setEntry(entry()); panel.show();
        enableImages(panel); QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        bool found = false;
        for (auto *label : panel.findChildren<QLabel *>()) {
            QVERIFY(!label->text().contains(QChar::ObjectReplacementCharacter));
            found |= label->text() == expected;
        }
        QVERIFY(found);
        bool source = false;
        for (auto *button : panel.findChildren<QPushButton *>())
            source |= button->text() == QStringLiteral("Source and licence") && button->isEnabled();
        QVERIFY(source);
        QCOMPARE(network.urls.size(), 2);
    }

    void metadataCreditsIgnoreHiddenSubtreesAndPreserveCache_data() {
        QTest::addColumn<QString>("artist");
        QTest::addColumn<QString>("licence");
        QTest::addColumn<QString>("expected");
        // Exact Artist value in the distinct 2026-11-12 Commons imageinfo
        // observation for the peili mirror. The original cached response only
        // retained its flattened credit, so it is not claimed as the raw source.
        QTest::newRow("observed-commons-hidden-author")
            << QStringLiteral("<div class=\"fn value\">\nUnknown author<span style=\"display: none;\">Unknown author</span></div>")
            << QStringLiteral("Public domain") << QStringLiteral("Unknown author / Public domain");
        QTest::newRow("nested-hidden-and-visible-sibling")
            << QStringLiteral("<span>A</span><span style='display:none'>hidden <span style='display:block'>child</span><img alt='hidden'></span> &amp; B")
            << QStringLiteral("CC BY 4.0") << QStringLiteral("A & B / CC BY 4.0");
        QTest::newRow("visible-repeated-author-is-not-deduplicated")
            << QStringLiteral("<span>Echo</span><span>Echo</span>")
            << QStringLiteral("Public domain") << QStringLiteral("EchoEcho / Public domain");
        QTest::newRow("hidden-void-image-keeps-following-alt")
            << QStringLiteral("<img style='display:none' alt='hidden'><img alt='A &amp; É'>")
            << QStringLiteral("Public domain") << QStringLiteral("A & É / Public domain");
        QTest::newRow("quoted-attribute-and-css-value-are-not-declarations")
            << QStringLiteral("<span title='display:none > ignored' style=\"font-family:'display:none;colon:value'\">Visible</span><!-- <span style='display:none'> -->")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("case-comments-entities-and-priority")
            << QStringLiteral("Visible<SPAN STYLE='DISPLAY&#58; /*why*/ NONE ! IMPORTANT; display:block'>hidden</SPAN>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("later-valid-display-overrides-none")
            << QStringLiteral("<span style='display:none;display:inline'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("multi-keyword-display-overrides-none")
            << QStringLiteral("<span style='display:none;display:inline flow'>Visible</span><span style='display:none;display:block flex'> author</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible author / Public domain");
        QTest::newRow("non-css-whitespace-is-not-none")
            << QStringLiteral("<span style='display:&nbsp;none'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("invalid-display-does-not-override-none")
            << QStringLiteral("Visible<span style='display:none;display:bogus'>hidden</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("variable-fallback-does-not-prove-hidden")
            << QStringLiteral("<span style='display:none;display:var(--visibility,inline)'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("important-none-beats-normal-variable")
            << QStringLiteral("Visible<span style='display:none!important;display:var(--visibility,inline)'>hidden</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("important-variable-beats-normal-none")
            << QStringLiteral("<span style='display:var(--visibility,inline)!important;display:none'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("later-none-beats-normal-variable")
            << QStringLiteral("Visible<span style='display:var(--visibility,inline);display:none'>hidden</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("quoted-variable-text-is-invalid-display")
            << QStringLiteral("Visible<span style=\"display:none;display:'var(--visibility,inline)'\">hidden</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("unknown-functional-display-conservatively-preserved")
            << QStringLiteral("<span style='display:none;display:bogus(none)'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("escaped-display-function-conservatively-preserved")
            << QStringLiteral("<span style='display:none;display:v\\61r(--visibility,inline)'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("environment-display-function-conservatively-preserved")
            << QStringLiteral("<span style='display:none;display:env(safe-area-inset-top,inline)'>Visible</span>")
            << QStringLiteral("Public domain") << QStringLiteral("Visible / Public domain");
        QTest::newRow("unclosed-hidden-markup-preserves-remainder")
            << QStringLiteral("Visible <span style='display:none'>unfinished author")
            << QStringLiteral("Public domain") << QStringLiteral("Visible unfinished author / Public domain");
        QTest::newRow("licence-hidden-copy-and-raw-style-text")
            << QStringLiteral("<style>/* <span style='display:none'> */</style><b>Known creator</b>")
            << QStringLiteral("<span>CC BY-SA 4.0</span><span style='display:none'>machine copy</span>")
            << QStringLiteral("Known creator / CC BY-SA 4.0");
    }

    void metadataCreditsIgnoreHiddenSubtreesAndPreserveCache() {
        QFETCH(QString, artist);
        QFETCH(QString, licence);
        QFETCH(QString, expected);
        Network network;
        network.responses = {{metadata(QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg"), artist, licence)}, {picture()}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(entry()); panel.show();
        QCOMPARE(network.urls.size(), 0);
        enableImages(panel);
        QCOMPARE(network.urls.size(), 0);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        const auto creditVisible = [&] {
            for (auto *label : panel.findChildren<QLabel *>())
                if (label->text() == expected && label->textFormat() == Qt::PlainText && label->isVisible()) return true;
            return false;
        };
        QVERIFY(creditVisible());
        QCOMPARE(network.urls.size(), 2);
        const auto files = QDir(cacheRoot()).entryList({QStringLiteral("*.json")}, QDir::Files);
        QCOMPARE(files.size(), 1);
        QFile file(QDir(cacheRoot()).filePath(files.front()));
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QByteArray cacheBytes = file.readAll();
        const auto cached = QJsonDocument::fromJson(cacheBytes).object();
        QCOMPARE(cached.value(QStringLiteral("credit")).toString(), expected);
        QCOMPARE(cached.value(QStringLiteral("source")).toString(), QStringLiteral("https://commons.wikimedia.org/wiki/File:Cat.jpg"));
        QCOMPARE(cached.value(QStringLiteral("url")).toString(), QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg"));
        file.close();
        bool sourceEnabled = false;
        for (auto *button : panel.findChildren<QPushButton *>())
            sourceEnabled |= button->text() == QStringLiteral("Source and licence") && button->isEnabled();
        QVERIFY(sourceEnabled);
        panel.setEntry(entry());
        QCOMPARE(network.urls.size(), 2);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(status(panel)->text(), QStringLiteral("Loaded from this device."));
        // addWidget queues the replacement card's show event; cached loading is synchronous.
        QTRY_VERIFY(creditVisible());
        QCOMPARE(network.urls.size(), 2);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), cacheBytes);
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

    void svgUsesCommonsRasterThumbnailAndReusesCache() {
        // Actual Commons imageinfo response (iiurlwidth=960), 2026-10-07.
        const QString thumbnail = QStringLiteral("https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c4/Human_head_and_brain_diagram.svg/960px-Human_head_and_brain_diagram.svg.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail");
        Network network;
        network.responses = {{metadata(QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/c4/Human_head_and_brain_diagram.svg"),
            QStringLiteral("Diagram artist"), QStringLiteral("CC BY-SA 4.0"), thumbnail)}, {picture()}};
        QJsonObject word = entry(QStringLiteral("oog"));
        word[QStringLiteral("media")] = QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
            {QStringLiteral("file"), QStringLiteral("Human head and brain diagram.svg")},
            {QStringLiteral("caption"), QStringLiteral("Human head and brain diagram")}}};
        MediaPanel panel(nullptr, &network);
        panel.setEntry(word, QStringLiteral("af.wiktionary.org")); panel.show();
        enableImages(panel); QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(status(panel)->text(), QStringLiteral("Ready."));
        QCOMPARE(network.urls.size(), 2);
        QCOMPARE(network.urls[1], QUrl(thumbnail));
        for (const auto &request : network.requests) {
            QCOMPARE(request.attribute(QNetworkRequest::RedirectPolicyAttribute).toInt(), int(QNetworkRequest::SameOriginRedirectPolicy));
            QCOMPARE(request.maximumRedirectsAllowed(), 5);
            QCOMPARE(request.transferTimeout(), 30000);
        }
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 2);
        panel.setEntry(word, QStringLiteral("af.wiktionary.org"));
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QCOMPARE(status(panel)->text(), QStringLiteral("Loaded from this device."));
        QCOMPARE(network.urls.size(), 2);
    }

    void rejectsUnsafeThumbnailAddress_data() {
        QTest::addColumn<QString>("thumbnail");
        QTest::newRow("http") << QStringLiteral("http://thumb.wikimedia.org/wikipedia/commons/thumb/image.png");
        QTest::newRow("credentials") << QStringLiteral("https://user@thumb.wikimedia.org/wikipedia/commons/thumb/image.png");
        QTest::newRow("port") << QStringLiteral("https://thumb.wikimedia.org:8443/wikipedia/commons/thumb/image.png");
        QTest::newRow("host-suffix") << QStringLiteral("https://thumb.wikimedia.org.example.invalid/image.png");
        QTest::newRow("subdomain") << QStringLiteral("https://other.thumb.wikimedia.org/image.png");
        QTest::newRow("unrelated-wikimedia-host") << QStringLiteral("https://commons.wikimedia.org/image.png");
    }

    void rejectsUnsafeThumbnailAddress() {
        QFETCH(QString, thumbnail);
        Network network;
        network.responses = {{metadata(QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/cat.jpg"),
            QStringLiteral("Artist"), QStringLiteral("CC BY-SA 4.0"), thumbnail)}};
        MediaPanel panel(nullptr, &network); panel.setEntry(entry()); panel.show();
        enableImages(panel); QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_VERIFY(status(panel)->text().contains(QStringLiteral("unsupported address")));
        QCOMPARE(network.urls.size(), 1);
        QCOMPARE(QDir(cacheRoot()).entryList(QDir::Files).size(), 0);
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
        auto *retryAction = QAccessible::queryAccessibleInterface(loadButton(panel));
        QVERIFY(retryAction);
        QCOMPARE(retryAction->text(QAccessible::Name), QStringLiteral("Retry: A cat"));
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

    void pronunciationControlsTraverseOrderedAndLegacyTableContent() {
        Network network;
        MediaPanel panel(nullptr, &network);
        const auto pronunciation = [](const QString &text) {
            return QJsonObject{{QStringLiteral("role"), QStringLiteral("pronunciation")},
                {QStringLiteral("text"), text}};
        };
        const auto paragraph = [&](const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{pronunciation(text)}}};
        };
        const auto table = [](const QJsonArray &cells) {
            return QJsonObject{{QStringLiteral("rows"), QJsonArray{
                QJsonObject{{QStringLiteral("cells"), cells}}}}};
        };
        const QString top = QStringLiteral("/k\u00e6t/");
        const QJsonObject legacyChild = table(QJsonArray{QJsonObject{{QStringLiteral("spans"),
            QJsonArray{pronunciation(QStringLiteral("/mi/")), pronunciation(top)}}}});
        const QJsonObject orderedChild = table(QJsonArray{QJsonObject{{QStringLiteral("blocks"),
            QJsonArray{paragraph(QStringLiteral("/si/"))}}}});
        QJsonObject heading = paragraph(QStringLiteral("/fi/"));
        heading.insert(QStringLiteral("kind"), QStringLiteral("heading"));
        heading.insert(QStringLiteral("level"), 3);
        const QJsonObject ordered{{QStringLiteral("blocks"), QJsonArray{paragraph(QStringLiteral("/ni/")),
            heading, QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
                {QStringLiteral("table"), orderedChild}}}}};
        const QJsonObject emptyOrdered{{QStringLiteral("blocks"), QJsonArray{}},
            {QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("nested_table"), QJsonValue::Null}};
        const QJsonObject contradictorySpans{{QStringLiteral("blocks"), QJsonArray{}},
            {QStringLiteral("spans"), QJsonArray{pronunciation(QStringLiteral("/vi/"))}}};
        const QJsonObject contradictoryNested{{QStringLiteral("blocks"), QJsonArray{}},
            {QStringLiteral("spans"), QJsonArray{}},
            {QStringLiteral("nested_table"), table(QJsonArray{QJsonObject{{QStringLiteral("spans"),
                QJsonArray{pronunciation(QStringLiteral("/wi/"))}}}})}};
        QJsonObject outer = table(QJsonArray{
            QJsonObject{{QStringLiteral("spans"), QJsonArray{pronunciation(QStringLiteral("/ti/"))}}},
            QJsonObject{{QStringLiteral("nested_table"), legacyChild}}, ordered, emptyOrdered});
        outer.insert(QStringLiteral("caption"), QJsonArray{pronunciation(QStringLiteral("/pi/"))});
        QJsonObject ipaEntry = entry();
        ipaEntry.insert(QStringLiteral("media"), QJsonArray{});
        ipaEntry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("blocks"),
            QJsonArray{paragraph(top), QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
                {QStringLiteral("table"), outer}}}}}});
        panel.setEntry(ipaEntry);
        QStringList names;
        for (QPushButton *button : panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation"))) {
            QCOMPARE(button->text(), QStringLiteral("Listen"));
            auto *accessible = QAccessible::queryAccessibleInterface(button);
            QVERIFY(accessible);
            names.append(accessible->text(QAccessible::Name));
        }
        QStringList expected;
        for (const QString &ipa : {top, QStringLiteral("/pi/"), QStringLiteral("/ti/"), QStringLiteral("/mi/"),
                QStringLiteral("/ni/"), QStringLiteral("/fi/"), QStringLiteral("/si/")})
            expected.append(QStringLiteral("Listen to the transcription %1 offline").arg(ipa));
        QCOMPARE(names, expected);
        QVERIFY(network.urls.isEmpty());
        QCOMPARE(panel.findChild<QPushButton *>(QStringLiteral("mediaListen"))->text(), QStringLiteral("Listen offline"));

        QJsonObject deep = table(QJsonArray{QJsonObject{{QStringLiteral("spans"),
            QJsonArray{pronunciation(QStringLiteral("/zi/"))}}}});
        for (int depth = 1; depth < 16; ++depth)
            deep = table(QJsonArray{QJsonObject{{QStringLiteral("nested_table"), deep}}});
        const auto setTable = [&](const QJsonObject &value) {
            ipaEntry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("blocks"),
                QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
                    {QStringLiteral("table"), value}}}}}});
            panel.setEntry(ipaEntry);
        };
        // Present-empty blocks is a real empty cell, not permission to
        // discard contradictory legacy payloads from malformed compiled data.
        for (const QJsonObject &invalid : {contradictorySpans, contradictoryNested}) {
            setTable(table(QJsonArray{invalid}));
            QVERIFY(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).isEmpty());
            QVERIFY(network.urls.isEmpty());
        }
        setTable(deep);
        QCOMPARE(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).size(), 1);
        setTable(table(QJsonArray{QJsonObject{{QStringLiteral("nested_table"), deep}}}));
        QVERIFY(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).isEmpty());
        ipaEntry.insert(QStringLiteral("language_code"), QStringLiteral("fr"));
        setTable(outer);
        QVERIFY(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).isEmpty());
        QVERIFY(network.urls.isEmpty());
    }

    void installedVoiceUsesMatchingLanguageAndLiteralText() {
        QTemporaryDir directory(QStringLiteral(".tmp/media-voice-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString executable = QFileInfo(directory.path()).absoluteFilePath() + QStringLiteral("/espeak-ng");
        QVERIFY(QFile::link(QString::fromUtf8(DICT_FAKE_VOICE_PATH), executable));
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
        // Keep voice discovery/playback independent of Qt and multimedia loader startup.
        panel.sayWord(QStringLiteral("-v de <literal>"), QStringLiteral("en"));
        QTRY_COMPARE_WITH_TIMEOUT(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text(), QStringLiteral("Finished."), 15000);
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
        auto *pronunciationAction = QAccessible::queryAccessibleInterface(phonemes.first());
        QVERIFY(pronunciationAction);
        const QString initialName = QStringLiteral("Listen to the transcription /k\u00e6t/ offline");
        QCOMPARE(pronunciationAction->text(QAccessible::Name), initialName);
        QTest::mouseClick(phonemes.first(), Qt::LeftButton);
        // The real voice-query QProcess is active synchronously; the button now cancels it.
        QCOMPARE(phonemes.first()->text(), QStringLiteral("Stop"));
        QCOMPARE(pronunciationAction->text(QAccessible::Name), QStringLiteral("Stop reading the transcription /k\u00e6t/ offline"));
        QTest::mouseClick(phonemes.first(), Qt::LeftButton);
        QCOMPARE(phonemes.first()->text(), QStringLiteral("Listen"));
        QCOMPARE(pronunciationAction->text(QAccessible::Name), initialName);
        QTest::mouseClick(phonemes.first(), Qt::LeftButton);
        QTRY_COMPARE_WITH_TIMEOUT(panel.findChild<QLabel *>(QStringLiteral("mediaSpeechStatus"))->text(), QStringLiteral("Finished."), 15000);
        QCOMPARE(pronunciationAction->text(QAccessible::Name), initialName);
        QVERIFY(result.open(QIODevice::ReadOnly));
        QCOMPARE(result.readAll(), QByteArrayLiteral("en-gb\n<speak><phoneme alphabet=\"espeak\" ph=\"kat\"/></speak>\n"));
        result.close();
        QVERIFY(result.remove());
        ipaEntry[QStringLiteral("language_code")] = QStringLiteral("fr");
        panel.setEntry(ipaEntry);
        QVERIFY(panel.findChildren<QPushButton *>(QStringLiteral("mediaPronunciation")).isEmpty());
        panel.sayWord(QStringLiteral("hold"), QStringLiteral("en"));
        QTRY_VERIFY_WITH_TIMEOUT(result.exists(), 15000);
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

    void privateNullOutputDecodesAndUpdatesPlaybackAccessibleNames() {
        if (qEnvironmentVariable("WIKIDICT_PRIVATE_MEDIA_BACKEND") != QStringLiteral("1"))
            QSKIP("Opt-in private null-output backend check; never use a user's audio session.");
        QCOMPARE(qApp->arguments().value(1), QStringLiteral("privateNullOutputDecodesAndUpdatesPlaybackAccessibleNames"));
        const QString ownedTmp = qEnvironmentVariable("WIKIDICT_OWNED_MEDIA_TMP");
        QVERIFY(!ownedTmp.isEmpty());
        QCOMPARE(QDir::cleanPath(QDir::tempPath()), QDir::cleanPath(ownedTmp));
        QVERIFY(QFileInfo(ownedTmp).isDir() && !QFileInfo(ownedTmp).isSymLink());
        QTemporaryDir runtime(ownedTmp + QStringLiteral("/pw-XXXXXX"));
        QVERIFY(runtime.isValid());
        const QString socket = runtime.path() + QStringLiteral("/pulse/native");
        QVERIFY(socket.toUtf8().size() < 104);
        QVERIFY(QDir().mkpath(runtime.path() + QStringLiteral("/pulse")));
        const QString evidence = qEnvironmentVariable("WIKIDICT_MEDIA_EVIDENCE_ROOT");
        QVERIFY(!evidence.isEmpty() && !QFileInfo::exists(evidence));
        QVERIFY(QDir().mkpath(evidence));
        QString configuration = QString::fromUtf8(R"PWCONF(context.properties = { core.daemon = true core.name = wikidict-private-test }
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    audio.adapt = audioconvert/libspa-audioconvert
    support.* = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-access args = { access.force = unrestricted } }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
    { name = libpipewire-module-protocol-pulse }
]
context.objects = [
    { factory = spa-node-factory args = {
        factory.name = support.node.driver node.name = Dummy-Driver
        node.group = pipewire.dummy priority.driver = 20000
    } }
    { factory = adapter args = {
        factory.name = support.null-audio-sink
        node.name = wikidict_null node.description = WikidictPrivateNull
        media.class = Audio/Sink audio.channels = 1 audio.position = [ MONO ]
        adapter.auto-port-config = { mode = dsp monitor = false control = false position = preserve }
    } }
]
pulse.properties = { server.address = [ "unix:/owned/runtime/pulse/native" ] }
pulse.cmd = []
stream.properties = { adapter.auto-port-config = { mode = dsp } }
context.exec = []
)PWCONF");
        configuration.replace(QStringLiteral("/owned/runtime/pulse/native"), socket);
        const QString configName = QStringLiteral("wikidict-private-test.conf");
        QFile config(runtime.path() + QChar('/') + configName);
        QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::NewOnly));
        QCOMPARE(config.write(configuration.toUtf8()), configuration.toUtf8().size()); config.close();
        QFile client(runtime.path() + QStringLiteral("/client.conf"));
        QVERIFY(client.open(QIODevice::WriteOnly | QIODevice::NewOnly));
        const QByteArray clientConfig = "autospawn = no\ndefault-server = unix:" + socket.toUtf8() + '\n';
        QCOMPARE(client.write(clientConfig), clientConfig.size()); client.close();
        const QString clientName = QStringLiteral("wikidict-private-client.conf");
        QFile pipewireClient(runtime.path() + QChar('/') + clientName);
        QVERIFY(pipewireClient.open(QIODevice::WriteOnly | QIODevice::NewOnly));
        const QByteArray pipewireClientConfig = R"PWCLIENT(context.properties = { core.daemon = false }
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.* = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
]
context.objects = []
context.exec = []
stream.properties = { adapter.auto-port-config = { mode = dsp monitor = false control = false position = preserve } }
)PWCLIENT";
        QCOMPARE(pipewireClient.write(pipewireClientConfig), pipewireClientConfig.size()); pipewireClient.close();
        const QMap<QByteArray, QByteArray> privateEnvironment{
            {"PULSE_SERVER", "unix:" + socket.toUtf8()},
            {"PULSE_CLIENTCONFIG", client.fileName().toUtf8()},
            {"PULSE_RUNTIME_PATH", (runtime.path() + QStringLiteral("/pulse")).toUtf8()},
            {"PULSE_SINK", "wikidict_null"},
            {"PIPEWIRE_REMOTE", "wikidict-private-test"},
            {"PIPEWIRE_RUNTIME_DIR", runtime.path().toUtf8()},
            {"PIPEWIRE_CONFIG_DIR", runtime.path().toUtf8()},
            {"PIPEWIRE_CONFIG_PREFIX", ""},
            {"PIPEWIRE_CONFIG_NAME", clientName.toUtf8()},
            {"DBUS_SESSION_BUS_ADDRESS", (QStringLiteral("unix:path=") + runtime.path() + QStringLiteral("/no-dbus")).toUtf8()}
        };
        QMap<QByteArray, QByteArray> previous;
        QSet<QByteArray> absent;
        for (auto i = privateEnvironment.cbegin(); i != privateEnvironment.cend(); ++i) {
            if (qEnvironmentVariableIsSet(i.key().constData())) previous.insert(i.key(), qgetenv(i.key().constData()));
            else absent.insert(i.key());
            qputenv(i.key().constData(), i.value());
        }
        const auto restore = qScopeGuard([&] {
            for (auto i = previous.cbegin(); i != previous.cend(); ++i) qputenv(i.key().constData(), i.value());
            for (const auto &key : absent) qunsetenv(key.constData());
        });
        const QString pipewire = QStandardPaths::findExecutable(QStringLiteral("pipewire"));
        QVERIFY(!pipewire.isEmpty());
        QProcess backend;
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.insert(QStringLiteral("XDG_RUNTIME_DIR"), runtime.path());
        // Only the owned server loads the daemon configuration; Qt uses the private client configuration.
        environment.insert(QStringLiteral("PIPEWIRE_CONFIG_NAME"), configName);
        for (const QString &leaf : {QStringLiteral("config"), QStringLiteral("cache"), QStringLiteral("data"), QStringLiteral("state")}) {
            QVERIFY(QDir().mkpath(runtime.path() + QChar('/') + leaf));
            environment.insert(QStringLiteral("XDG_") + leaf.toUpper() + QStringLiteral("_HOME"), runtime.path() + QChar('/') + leaf);
        }
        environment.remove(QStringLiteral("DISPLAY")); environment.remove(QStringLiteral("WAYLAND_DISPLAY"));
        backend.setProcessEnvironment(environment);
        backend.setStandardOutputFile(evidence + QStringLiteral("/backend.stdout"));
        backend.setStandardErrorFile(evidence + QStringLiteral("/backend.stderr"));
        const auto stopBackend = qScopeGuard([&] {
            if (backend.state() != QProcess::NotRunning) {
                backend.terminate();
                if (!backend.waitForFinished(2000)) { backend.kill(); backend.waitForFinished(2000); }
            }
        });
        backend.start(pipewire, {QStringLiteral("-c"), configName});
        QVERIFY(backend.waitForStarted(3000));
        qInfo() << "Owned private PipeWire PID" << backend.processId() << "socket" << socket;
        QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(socket), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(QMediaDevices::audioOutputs().size(), 1, 5000);
        QCOMPARE(QMediaDevices::defaultAudioOutput().description(), QStringLiteral("WikidictPrivateNull"));
        // Valid three-second PCM silence: decoder/state evidence, never audible hardware evidence.
        QByteArray recording;
        QDataStream wave(&recording, QIODevice::WriteOnly); wave.setByteOrder(QDataStream::LittleEndian);
        wave.writeRawData("RIFF", 4); wave << quint32(36 + 48000); wave.writeRawData("WAVEfmt ", 8);
        wave << quint32(16) << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2) << quint16(16);
        wave.writeRawData("data", 4); wave << quint32(48000); recording.append(QByteArray(48000, '\0'));
        Network network; network.responses = {{metadata(QStringLiteral("https://upload.wikimedia.org/wikipedia/commons/c/owned.wav"))}, {recording}};
        MediaPanel panel(nullptr, &network);
        QJsonObject word = entry();
        word[QStringLiteral("media")] = QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
            {QStringLiteral("file"), QStringLiteral("File:owned.wav")}, {QStringLiteral("caption"), QStringLiteral("Owned recording")}}};
        panel.setEntry(word); panel.show();
        auto *player = panel.findChild<QMediaPlayer *>(); QVERIFY(player);
        auto *action = QAccessible::queryAccessibleInterface(loadButton(panel)); QVERIFY(action);
        QTest::mouseClick(panel.findChild<QCheckBox *>(QStringLiteral("mediaAllowAudio")), Qt::LeftButton);
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        bool graphCaptured = false;
        const auto captureOwnedGraph = [&] {
            if (graphCaptured) return;
            graphCaptured = true;
            qInfo() << "Owned audio final duration" << player->duration() << "position" << player->position()
                    << "playbackState" << player->playbackState() << "mediaStatus" << player->mediaStatus()
                    << "error" << player->error() << "errorString" << player->errorString();
            auto graphEnvironment = environment;
            graphEnvironment.insert(QStringLiteral("PIPEWIRE_CONFIG_NAME"), clientName);
            QProcess graph; graph.setProcessEnvironment(graphEnvironment);
            graph.setStandardOutputFile(evidence + QStringLiteral("/owned-graph.json"));
            graph.setStandardErrorFile(evidence + QStringLiteral("/owned-graph.stderr"));
            const QString dump = QStandardPaths::findExecutable(QStringLiteral("pw-dump"));
            bool started = false, finished = false;
            if (!dump.isEmpty() && backend.state() != QProcess::NotRunning) {
                graph.start(dump, {QStringLiteral("--remote"), QStringLiteral("wikidict-private-test"), QStringLiteral("--no-colors")});
                started = graph.waitForStarted(2000);
                if (started) finished = graph.waitForFinished(3000);
                if (graph.state() != QProcess::NotRunning) { graph.kill(); graph.waitForFinished(2000); }
            }
            QFile result(evidence + QStringLiteral("/owned-graph-result.json"));
            if (result.open(QIODevice::WriteOnly | QIODevice::NewOnly)) {
                const QJsonObject observation{{QStringLiteral("program"), dump}, {QStringLiteral("remote"), QStringLiteral("wikidict-private-test")},
                    {QStringLiteral("runtime"), runtime.path()}, {QStringLiteral("started"), started}, {QStringLiteral("finished"), finished},
                    {QStringLiteral("exitCode"), graph.exitCode()}, {QStringLiteral("reaped"), graph.state() == QProcess::NotRunning}};
                result.write(QJsonDocument(observation).toJson());
            }
        };
        const auto graphBeforeCleanup = qScopeGuard(captureOwnedGraph);
        QTRY_COMPARE_WITH_TIMEOUT(player->playbackState(), QMediaPlayer::PlayingState, 5000);
        // No session policy runs in this fixture: configure mono ports above, then link only our exact graph objects.
        const QString dumpProgram = QStandardPaths::findExecutable(QStringLiteral("pw-dump"));
        const QString linkProgram = QStandardPaths::findExecutable(QStringLiteral("pw-link"));
        QVERIFY(!dumpProgram.isEmpty() && !linkProgram.isEmpty());
        auto routingEnvironment = environment;
        routingEnvironment.insert(QStringLiteral("PIPEWIRE_CONFIG_NAME"), clientName);
        int graphSequence = 0;
        const auto readOwnedGraph = [&]() -> QJsonArray {
            QProcess dump; dump.setProcessEnvironment(routingEnvironment);
            dump.start(dumpProgram, {QStringLiteral("--remote"), QStringLiteral("wikidict-private-test"), QStringLiteral("--no-colors")});
            const bool started = dump.waitForStarted(2000);
            const bool finished = started && dump.waitForFinished(3000);
            if (dump.state() != QProcess::NotRunning) { dump.kill(); dump.waitForFinished(2000); }
            const QByteArray bytes = dump.readAllStandardOutput();
            QFile saved(evidence + QStringLiteral("/route-graph-%1.json").arg(++graphSequence));
            if (saved.open(QIODevice::WriteOnly | QIODevice::NewOnly)) saved.write(bytes);
            if (!finished || dump.exitStatus() != QProcess::NormalExit || dump.exitCode() != 0) return {};
            const QJsonDocument document = QJsonDocument::fromJson(bytes);
            return document.isArray() ? document.array() : QJsonArray{};
        };
        int outputPort = -1, inputPort = -1;
        QJsonArray routeGraph;
        for (int attempt = 0; attempt < 20 && (outputPort < 0 || inputPort < 0); ++attempt) {
            routeGraph = readOwnedGraph();
            QSet<int> ownedClients;
            bool ownedCore = false;
            for (const auto &value : routeGraph) {
                const auto object = value.toObject(); const auto info = object.value(QStringLiteral("info")).toObject();
                const auto props = info.value(QStringLiteral("props")).toObject();
                const auto type = object.value(QStringLiteral("type")).toString();
                if (type == QStringLiteral("PipeWire:Interface:Core"))
                    ownedCore = info.value(QStringLiteral("name")).toString() == QStringLiteral("wikidict-private-test")
                        && props.value(QStringLiteral("application.process.id")).toVariant().toLongLong() == backend.processId();
                if (type == QStringLiteral("PipeWire:Interface:Client")
                    && props.value(QStringLiteral("application.process.id")).toVariant().toLongLong() == QCoreApplication::applicationPid())
                    ownedClients.insert(object.value(QStringLiteral("id")).toInt(-1));
            }
            QVERIFY(ownedCore);
            QList<int> sinks, streams;
            for (const auto &value : routeGraph) {
                const auto object = value.toObject(); if (object.value(QStringLiteral("type")).toString() != QStringLiteral("PipeWire:Interface:Node")) continue;
                const auto props = object.value(QStringLiteral("info")).toObject().value(QStringLiteral("props")).toObject();
                if (props.value(QStringLiteral("node.name")).toString() == QStringLiteral("wikidict_null")
                    && props.value(QStringLiteral("media.class")).toString() == QStringLiteral("Audio/Sink")) sinks.append(object.value(QStringLiteral("id")).toInt());
                if (props.value(QStringLiteral("node.name")).toString() == QStringLiteral("MediaPanel")
                    && props.value(QStringLiteral("media.class")).toString() == QStringLiteral("Stream/Output/Audio")
                    && ownedClients.contains(props.value(QStringLiteral("client.id")).toInt(-1))) streams.append(object.value(QStringLiteral("id")).toInt());
            }
            QCOMPARE(sinks.size(), 1); QVERIFY(streams.size() <= 1);
            if (streams.isEmpty()) { QTest::qWait(50); continue; }
            QList<int> inputs, outputs;
            for (const auto &value : routeGraph) {
                const auto object = value.toObject(); if (object.value(QStringLiteral("type")).toString() != QStringLiteral("PipeWire:Interface:Port")) continue;
                const auto info = object.value(QStringLiteral("info")).toObject(); const auto props = info.value(QStringLiteral("props")).toObject();
                const int node = props.value(QStringLiteral("node.id")).toInt(-1);
                if (node == streams.first() && info.value(QStringLiteral("direction")).toString() == QStringLiteral("output")) outputs.append(object.value(QStringLiteral("id")).toInt());
                if (node == sinks.first() && info.value(QStringLiteral("direction")).toString() == QStringLiteral("input")) inputs.append(object.value(QStringLiteral("id")).toInt());
            }
            QVERIFY(inputs.size() <= 1 && outputs.size() <= 1);
            if (inputs.size() == 1 && outputs.size() == 1) { inputPort = inputs.first(); outputPort = outputs.first(); }
            else QTest::qWait(50);
        }
        QVERIFY(outputPort >= 0 && inputPort >= 0);
        QProcess link; link.setProcessEnvironment(routingEnvironment);
        link.setStandardOutputFile(evidence + QStringLiteral("/owned-link.stdout"));
        link.setStandardErrorFile(evidence + QStringLiteral("/owned-link.stderr"));
        link.start(linkProgram, {QStringLiteral("--remote"), QStringLiteral("wikidict-private-test"), QStringLiteral("--linger"),
            QString::number(outputPort), QString::number(inputPort)});
        const bool linkStarted = link.waitForStarted(2000);
        const bool linkFinished = linkStarted && link.waitForFinished(3000);
        if (link.state() != QProcess::NotRunning) { link.kill(); link.waitForFinished(2000); }
        QVERIFY(linkStarted && linkFinished); QCOMPARE(link.exitStatus(), QProcess::NormalExit); QCOMPARE(link.exitCode(), 0);
        bool exactLink = false;
        for (const auto &value : readOwnedGraph()) {
            const auto object = value.toObject(); if (object.value(QStringLiteral("type")).toString() != QStringLiteral("PipeWire:Interface:Link")) continue;
            const auto info = object.value(QStringLiteral("info")).toObject();
            if (info.value(QStringLiteral("output-port-id")).toInt(-1) == outputPort && info.value(QStringLiteral("input-port-id")).toInt(-1) == inputPort) exactLink = true;
        }
        QVERIFY(exactLink);
        qInfo() << "Owned explicit mono link" << outputPort << inputPort;
        QTRY_VERIFY_WITH_TIMEOUT(player->duration() > 0 && player->position() > 0, 5000);
        QCOMPARE(player->error(), QMediaPlayer::NoError);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Pause: Owned recording"));
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(player->playbackState(), QMediaPlayer::PausedState);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Play: Owned recording"));
        QTest::mouseClick(loadButton(panel), Qt::LeftButton);
        QTRY_COMPARE(player->playbackState(), QMediaPlayer::PlayingState);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Pause: Owned recording"));
        QTRY_COMPARE_WITH_TIMEOUT(player->mediaStatus(), QMediaPlayer::EndOfMedia, 5000);
        QCOMPARE(player->error(), QMediaPlayer::NoError);
        QCOMPARE(action->text(QAccessible::Name), QStringLiteral("Play: Owned recording"));
        QCOMPARE(network.urls.size(), 2);
        panel.stopPlayback();
        captureOwnedGraph();
        backend.terminate(); QVERIFY(backend.waitForFinished(2000));
        QCOMPARE(backend.state(), QProcess::NotRunning);
        qInfo() << "Owned private PipeWire reaped; decoder/Play-Pause names passed, audible hardware/TTS untested";
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
