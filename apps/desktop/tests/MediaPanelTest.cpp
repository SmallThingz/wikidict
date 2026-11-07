#include "MediaPanel.hpp"

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
            {QStringLiteral("spans"), QJsonArray{pronunciation(QStringLiteral("/vi/"))}},
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
