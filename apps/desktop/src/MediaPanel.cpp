#include "MediaPanel.hpp"

#include <QAudioOutput>
#include <QAudioDevice>
#include <QBuffer>
#include <QCheckBox>
#include <QComboBox>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGroupBox>
#include <QHash>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QLocale>
#include <QMediaPlayer>
#include <QMediaDevices>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QPainter>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QRegularExpression>
#include <QSaveFile>
#include <QScrollArea>
#include <QSettings>
#include <QSet>
#include <QSignalBlocker>
#include <QSlider>
#include <QStandardPaths>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextFragment>
#include <QTimer>
#include <QUrlQuery>
#include <QVBoxLayout>
#include <algorithm>
#include <functional>

namespace {
constexpr qint64 MaxMediaBytes = 50 * 1024 * 1024;
constexpr qint64 MaxMetadataBytes = 2 * 1024 * 1024;

bool allowedUrl(const QUrl &url, bool download, const QString &sourceHost = {}) {
    if (!url.isValid() || url.scheme() != QStringLiteral("https") || !url.userInfo().isEmpty() ||
        (url.port() != -1 && url.port() != 443)) return false;
    const QString host = url.host().toLower();
    return download ? (host == QStringLiteral("upload.wikimedia.org") || host == QStringLiteral("thumb.wikimedia.org"))
                    : host == QStringLiteral("commons.wikimedia.org") || (!sourceHost.isEmpty() && host == sourceHost);
}

QString plainMetadata(const QJsonObject &metadata, const QString &key) {
    QTextDocument document;
    document.setHtml(metadata.value(key).toObject().value(QStringLiteral("value")).toString());
    QString text;
    for (auto block = document.begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid()) continue;
            const auto format = fragment.charFormat();
            if (format.isImageFormat()) {
                // Qt retains HTML entities in image alt attributes. Decode
                // them once while keeping literal angle brackets as text.
                QString alt = format.stringProperty(QTextFormat::ImageAltText);
                alt.replace(QChar('<'), QStringLiteral("&lt;")).replace(QChar('>'), QStringLiteral("&gt;"));
                text += QTextDocumentFragment::fromHtml(alt).toPlainText();
            } else text += fragment.text();
        }
        text += QChar(' ');
    }
    return text.remove(QChar::ObjectReplacementCharacter).simplified().left(240);
}

QString voiceLanguage(QString code) {
    code = code.trimmed().replace(QChar('_'), QChar('-'));
    const auto language = QLocale::codeToLanguage(code.section(QChar('-'), 0, 0));
    if (language != QLocale::AnyLanguage && language != QLocale::C) return code.toLower();
    for (const QLocale &locale : QLocale::matchingLocales(QLocale::AnyLanguage, QLocale::AnyScript, QLocale::AnyTerritory)) {
        if (QLocale::languageToString(locale.language()).compare(code, Qt::CaseInsensitive) == 0)
            return QLocale::languageToCode(locale.language()).toLower();
    }
    return {};
}

QString pronunciationSsml(QString ipa, const QString &language) {
    if (voiceLanguage(language).section(QChar('-'), 0, 0) != QStringLiteral("en")) return {};
    ipa = ipa.trimmed();
    if (ipa.size() < 3 || !((ipa.startsWith(QChar('/')) && ipa.endsWith(QChar('/'))) ||
                            (ipa.startsWith(QChar('[')) && ipa.endsWith(QChar(']'))))) return {};
    ipa = ipa.mid(1, ipa.size() - 2);
    if (ipa.trimmed().isEmpty() || ipa.size() > 256) return {};
    // Keep the explicit English subset shared with Android; unknown phones are never guessed.
    static const QList<QPair<QString, QString>> phones{
        {QStringLiteral("t\u0361\u0283"), QStringLiteral("tS")}, {QStringLiteral("d\u0361\u0292"), QStringLiteral("dZ")},
        {QStringLiteral("t\u0283"), QStringLiteral("tS")}, {QStringLiteral("d\u0292"), QStringLiteral("dZ")},
        {QStringLiteral("a\u026a"), QStringLiteral("aI")}, {QStringLiteral("a\u028a"), QStringLiteral("aU")},
        {QStringLiteral("e\u026a"), QStringLiteral("eI")}, {QStringLiteral("\u0254\u026a"), QStringLiteral("OI")},
        {QStringLiteral("\u0259\u028a"), QStringLiteral("oU")}, {QStringLiteral("o\u028a"), QStringLiteral("oU")},
        {QStringLiteral("\u026a\u0259"), QStringLiteral("i@")}, {QStringLiteral("\u025b\u0259"), QStringLiteral("e@")},
        {QStringLiteral("\u028a\u0259"), QStringLiteral("U@")}, {QStringLiteral("i\u02d0"), QStringLiteral("i:")},
        {QStringLiteral("u\u02d0"), QStringLiteral("u:")}, {QStringLiteral("\u0251\u02d0"), QStringLiteral("A:")},
        {QStringLiteral("\u0254\u02d0"), QStringLiteral("O:")}, {QStringLiteral("\u025c\u02d0"), QStringLiteral("3:")},
        {QStringLiteral("p"), QStringLiteral("p")}, {QStringLiteral("b"), QStringLiteral("b")},
        {QStringLiteral("t"), QStringLiteral("t")}, {QStringLiteral("d"), QStringLiteral("d")},
        {QStringLiteral("k"), QStringLiteral("k")}, {QStringLiteral("\u0261"), QStringLiteral("g")},
        {QStringLiteral("g"), QStringLiteral("g")}, {QStringLiteral("f"), QStringLiteral("f")},
        {QStringLiteral("v"), QStringLiteral("v")}, {QStringLiteral("\u03b8"), QStringLiteral("T")},
        {QStringLiteral("\u00f0"), QStringLiteral("D")}, {QStringLiteral("s"), QStringLiteral("s")},
        {QStringLiteral("z"), QStringLiteral("z")}, {QStringLiteral("\u0283"), QStringLiteral("S")},
        {QStringLiteral("\u0292"), QStringLiteral("Z")}, {QStringLiteral("h"), QStringLiteral("h")},
        {QStringLiteral("m"), QStringLiteral("m")}, {QStringLiteral("n"), QStringLiteral("n")},
        {QStringLiteral("\u014b"), QStringLiteral("N")}, {QStringLiteral("l"), QStringLiteral("l")},
        {QStringLiteral("\u0279"), QStringLiteral("r")}, {QStringLiteral("r"), QStringLiteral("r")},
        {QStringLiteral("j"), QStringLiteral("j")}, {QStringLiteral("w"), QStringLiteral("w")},
        {QStringLiteral("\u00e6"), QStringLiteral("a")}, {QStringLiteral("\u025b"), QStringLiteral("E")},
        {QStringLiteral("\u026a"), QStringLiteral("I")}, {QStringLiteral("\u0252"), QStringLiteral("0")},
        {QStringLiteral("\u028c"), QStringLiteral("V")}, {QStringLiteral("\u028a"), QStringLiteral("U")},
        {QStringLiteral("\u0259"), QStringLiteral("@")}, {QStringLiteral("i"), QStringLiteral("i")},
        {QStringLiteral("u"), QStringLiteral("u:")}, {QStringLiteral("\u02c8"), QStringLiteral("'")},
        {QStringLiteral("\u02cc"), QStringLiteral(",")}, {QStringLiteral("."), QString()},
        {QStringLiteral(" "), QStringLiteral(" ")}
    };
    QString result;
    for (qsizetype at = 0; at < ipa.size();) {
        const auto found = std::find_if(phones.begin(), phones.end(), [&](const auto &phone) { return ipa.mid(at, phone.first.size()) == phone.first; });
        if (found == phones.end()) return {};
        result += found->second;
        at += found->first.size();
    }
    if (!result.contains(QRegularExpression(QStringLiteral("[A-Za-z0-9@]")))) return {};
    return QStringLiteral("<speak><phoneme alphabet=\"espeak\" ph=\"%1\"/></speak>").arg(result);
}

QString durationText(qint64 milliseconds) {
    const qint64 seconds = milliseconds / 1000;
    return QStringLiteral("%1:%2").arg(seconds / 60).arg(seconds % 60, 2, 10, QChar('0'));
}

class ImagePreview final : public QWidget {
public:
    explicit ImagePreview(QWidget *parent) : QWidget(parent) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        setMinimumSize(1, 120);
        setMaximumHeight(280);
    }
    void setImage(const QImage &image) { pixmap_ = QPixmap::fromImage(image); update(); }
    QSize sizeHint() const override { return QSize(240, 240); }
    QSize minimumSizeHint() const override { return QSize(1, 120); }
protected:
    void paintEvent(QPaintEvent *) override {
        if (pixmap_.isNull()) return;
        const QSize fit = pixmap_.size().scaled(size(), Qt::KeepAspectRatio);
        const QRect target(QPoint((width() - fit.width()) / 2, (height() - fit.height()) / 2), fit);
        QPainter painter(this);
        painter.setRenderHint(QPainter::SmoothPixmapTransform);
        painter.drawPixmap(target, pixmap_);
    }
private:
    QPixmap pixmap_;
};

class MediaCard final : public QGroupBox {
public:
    MediaCard(const QJsonObject &media, QWidget *parent) : QGroupBox(parent) {
        kind = media.value(QStringLiteral("kind")).toString();
        file = media.value(QStringLiteral("file")).toString();
        file.remove(QRegularExpression(QStringLiteral("^(File|Image):"), QRegularExpression::CaseInsensitiveOption));
        const QString caption = media.value(QStringLiteral("caption")).toString();
        display = caption.isEmpty() ? file : caption;
        auto *layout = new QVBoxLayout(this);
        auto *name = new QLabel(display, this);
        name->setTextFormat(Qt::PlainText);
        name->setWordWrap(true);
        name->setTextInteractionFlags(Qt::TextSelectableByMouse);
        layout->addWidget(name);
        image = new ImagePreview(this);
        image->setAccessibleName(display);
        image->hide();
        layout->addWidget(image);
        auto *row = new QHBoxLayout;
        button = new QPushButton(this);
        button->setObjectName(QStringLiteral("mediaLoad"));
        button->setAccessibleName((kind == QStringLiteral("image") ? QStringLiteral("Load image: ") : QStringLiteral("Play recording: ")) + display);
        row->addWidget(button);
        position = new QSlider(Qt::Horizontal, this);
        position->setRange(0, 0);
        position->setAccessibleName(QStringLiteral("Recording position: ") + display);
        position->setVisible(kind == QStringLiteral("audio"));
        position->setEnabled(false);
        row->addWidget(position, 1);
        time = new QLabel(this);
        time->setVisible(kind == QStringLiteral("audio"));
        row->addWidget(time);
        layout->addLayout(row);
        progress = new QProgressBar(this);
        progress->setRange(0, 0);
        progress->setAccessibleName(QStringLiteral("Media download progress"));
        progress->hide();
        layout->addWidget(progress);
        status = new QLabel(this);
        status->setObjectName(QStringLiteral("mediaStatus"));
        status->setTextFormat(Qt::PlainText);
        status->setWordWrap(true);
        layout->addWidget(status);
        credit = new QLabel(this);
        credit->setTextFormat(Qt::PlainText);
        credit->setWordWrap(true);
        credit->hide();
        layout->addWidget(credit);
        source = new QPushButton(QStringLiteral("Source and licence"), this);
        source->setFlat(true);
        source->setVisible(false);
        source->setAccessibleName(QStringLiteral("Open media source and licence in browser"));
        layout->addWidget(source, 0, Qt::AlignLeft);
    }
    void setAction(const QString &action) {
        button->setText(action);
        button->setAccessibleName(action + QStringLiteral(": ") + display);
    }
    QString kind, file, key, sourceHost, display;
    QByteArray data;
    QJsonObject metadata;
    ImagePreview *image;
    QLabel *status, *credit, *time;
    QPushButton *button, *source;
    QSlider *position;
    QProgressBar *progress;
    bool busy = false;
};
}

struct MediaPanel::Impl {
    MediaPanel *q;
    QNetworkAccessManager *network;
    QCheckBox *images, *audio;
    QComboBox *limit;
    QLabel *cacheStatus, *speechStatus;
    QPushButton *listen;
    QVBoxLayout *cardsLayout;
    QWidget *cardsBody;
    QList<MediaCard *> cards;
    QList<QPair<QString, QPushButton *>> pronunciations;
    QHash<QNetworkReply *, QPointer<MediaCard>> requests;
    QMediaPlayer *player;
    QAudioOutput *output;
    std::unique_ptr<QBuffer> audioBuffer;
    QPointer<MediaCard> playing;
    QPointer<QProcess> speech;
    QString title, language, cacheRoot, activeSpeechKey;

    explicit Impl(MediaPanel *parent, QNetworkAccessManager *manager) : q(parent) {
        network = manager ? manager : new QNetworkAccessManager(q);
        cacheRoot = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/media-v1");
        QDir().mkpath(cacheRoot);
        auto *outer = new QVBoxLayout(q);
        outer->setContentsMargins(0, 0, 0, 0);
        auto *scroll = new QScrollArea(q);
        scroll->setObjectName(QStringLiteral("mediaContentScroll"));
        scroll->setWidgetResizable(true);
        scroll->setFrameShape(QFrame::NoFrame);
        auto *body = new QWidget(scroll);
        auto *layout = new QVBoxLayout(body);
        layout->setContentsMargins(14, 14, 14, 14);
        layout->setSizeConstraint(QLayout::SetMinimumSize);
        scroll->setWidget(body);
        outer->addWidget(scroll);
        auto *speechRow = new QHBoxLayout;
        listen = new QPushButton(QStringLiteral("Listen offline"), body);
        listen->setObjectName(QStringLiteral("mediaListen"));
        listen->setEnabled(false);
        speechRow->addWidget(listen);
        speechStatus = new QLabel(QStringLiteral("Open a word to hear its pronunciation."), body);
        speechStatus->setObjectName(QStringLiteral("mediaSpeechStatus"));
        speechStatus->setTextFormat(Qt::PlainText);
        speechStatus->setWordWrap(true);
        speechRow->addWidget(speechStatus, 1);
        layout->addLayout(speechRow);

        auto *preferences = new QGroupBox(QStringLiteral("Online media"), body);
        auto *preferencesLayout = new QVBoxLayout(preferences);
        auto *permissions = new QHBoxLayout;
        images = new QCheckBox(QStringLiteral("Allow images"), preferences);
        images->setObjectName(QStringLiteral("mediaAllowImages"));
        audio = new QCheckBox(QStringLiteral("Allow audio"), preferences);
        audio->setObjectName(QStringLiteral("mediaAllowAudio"));
        images->setChecked(QSettings().value(QStringLiteral("media/allowImages"), false).toBool());
        audio->setChecked(QSettings().value(QStringLiteral("media/allowAudio"), false).toBool());
        permissions->addWidget(images);
        permissions->addWidget(audio);
        permissions->addStretch();
        preferencesLayout->addLayout(permissions);
        auto *note = new QLabel(QStringLiteral("Only requested media is downloaded from Wikimedia. Word listening stays offline."), preferences);
        note->setWordWrap(true);
        preferencesLayout->addWidget(note);
        auto *cacheRow = new QHBoxLayout;
        auto *cacheLabel = new QLabel(QStringLiteral("Media cache"), preferences);
        limit = new QComboBox(preferences);
        limit->setObjectName(QStringLiteral("mediaCacheLimit"));
        limit->setAccessibleName(QStringLiteral("Maximum media cache size"));
        for (int mb : {0, 25, 100, 500})
            limit->addItem(mb == 0 ? QStringLiteral("Off") : QStringLiteral("%1 MB").arg(mb), mb);
        const int saved = QSettings().value(QStringLiteral("media/cacheMb"), 100).toInt();
        const int index = limit->findData(saved);
        limit->setCurrentIndex(index < 0 ? 2 : index);
        cacheLabel->setBuddy(limit);
        cacheRow->addWidget(cacheLabel);
        cacheRow->addWidget(limit);
        auto *clear = new QPushButton(QStringLiteral("Clear cache"), preferences);
        clear->setObjectName(QStringLiteral("mediaClearCache"));
        cacheRow->addStretch();
        preferencesLayout->addLayout(cacheRow);
        preferencesLayout->addWidget(clear, 0, Qt::AlignLeft);
        cacheStatus = new QLabel(preferences);
        cacheStatus->setObjectName(QStringLiteral("mediaCacheStatus"));
        preferencesLayout->addWidget(cacheStatus);
        layout->addWidget(preferences);

        cardsBody = new QWidget(body);
        cardsLayout = new QVBoxLayout(cardsBody);
        cardsLayout->setContentsMargins(0, 0, 0, 0);
        cardsLayout->setAlignment(Qt::AlignTop);
        layout->addWidget(cardsBody, 1);

        player = new QMediaPlayer(q);
        output = new QAudioOutput(q);
        player->setAudioOutput(output);
        QObject::connect(player, &QMediaPlayer::playbackStateChanged, q, [this] {
            for (auto *card : cards) updateButton(card);
        });
        QObject::connect(player, &QMediaPlayer::positionChanged, q, [this](qint64 position) {
            if (!playing) return;
            if (!playing->position->isSliderDown()) {
                const QSignalBlocker blocker(playing->position);
                playing->position->setValue(int(position));
            }
            playing->time->setText(durationText(position) + QStringLiteral(" / ") + durationText(player->duration()));
        });
        QObject::connect(player, &QMediaPlayer::durationChanged, q, [this](qint64 duration) {
            if (!playing) return;
            const QSignalBlocker blocker(playing->position);
            playing->position->setRange(0, int(std::min<qint64>(duration, 2147483647)));
            playing->position->setEnabled(duration > 0 && player->isSeekable());
        });
        QObject::connect(player, &QMediaPlayer::seekableChanged, q, [this](bool seekable) {
            if (playing) playing->position->setEnabled(seekable && player->duration() > 0);
        });
        QObject::connect(player, &QMediaPlayer::errorOccurred, q, [this](QMediaPlayer::Error, const QString &message) {
            if (!playing) return;
            auto *card = playing.data();
            stopAudio();
            card->data.clear();
            removeCached(card);
            fail(card, QStringLiteral("Could not play this recording. %1").arg(message));
        });
        QObject::connect(listen, &QPushButton::clicked, q, [this] {
            if (speech) stopSpeech(); else say(title, language);
        });
        QObject::connect(images, &QCheckBox::toggled, q, [this](bool enabled) {
            permissionChanged(QStringLiteral("image"), enabled);
        });
        QObject::connect(audio, &QCheckBox::toggled, q, [this](bool enabled) {
            permissionChanged(QStringLiteral("audio"), enabled);
        });
        QObject::connect(limit, &QComboBox::currentIndexChanged, q, [this] {
            QSettings().setValue(QStringLiteral("media/cacheMb"), limit->currentData().toInt());
            trimCache(cacheLimit());
        });
        QObject::connect(clear, &QPushButton::clicked, q, [this] {
            trimCache(0);
        });
        trimCache(cacheLimit());
        setEntry(QJsonObject{}, QString{});
    }

    ~Impl() {
        cancelRequests();
        stopSpeech();
        for (auto *process : q->findChildren<QProcess *>(QString(), Qt::FindDirectChildrenOnly))
            if (process->state() != QProcess::NotRunning) process->waitForFinished(1000);
        stopAudio();
    }

    qint64 cacheLimit() const { return limit->currentData().toLongLong() * 1024 * 1024; }
    bool allowed(const MediaCard *card) const { return card->kind == QStringLiteral("image") ? images->isChecked() : audio->isChecked(); }

    void updateButton(MediaCard *card) {
        card->button->setEnabled(!card->busy && allowed(card));
        if (card->busy) card->setAction(QStringLiteral("Loading..."));
        else if (!card->data.isEmpty()) {
            if (card->kind == QStringLiteral("image")) card->setAction(QStringLiteral("Reload image"));
            else card->setAction(playing == card && player->playbackState() == QMediaPlayer::PlayingState
                ? QStringLiteral("Pause") : QStringLiteral("Play"));
        } else card->setAction(card->kind == QStringLiteral("image") ? QStringLiteral("Load image") : QStringLiteral("Play recording"));
    }

    void permissionChanged(const QString &kind, bool enabled) {
        QSettings().setValue(kind == QStringLiteral("image") ? QStringLiteral("media/allowImages") : QStringLiteral("media/allowAudio"), enabled);
        if (!enabled) {
            cancelRequests(kind);
            if (kind == QStringLiteral("audio")) stopAudio();
        }
        for (auto *card : cards) {
            if (card->kind != kind) continue;
            card->image->setVisible(enabled && !card->data.isEmpty() && kind == QStringLiteral("image"));
            card->status->setText(enabled ? QStringLiteral("Ready when you are.")
                : QStringLiteral("Enable online %1 above to load this media.").arg(kind == QStringLiteral("image") ? QStringLiteral("images") : QStringLiteral("audio")));
            updateButton(card);
        }
    }

    void cancelRequests(const QString &kind = {}) {
        const auto pending = requests;
        for (auto it = pending.begin(); it != pending.end(); ++it) {
            if (!kind.isEmpty() && it.value() && it.value()->kind != kind) continue;
            requests.remove(it.key());
            QObject::disconnect(it.key(), nullptr, nullptr, nullptr);
            it.key()->abort();
            it.key()->deleteLater();
            if (it.value()) {
                it.value()->busy = false;
                it.value()->progress->hide();
                updateButton(it.value());
            }
        }
    }

    void stopSpeech() {
        if (speech) {
            auto *old = speech.data();
            speech = nullptr;
            QObject::disconnect(old, nullptr, q, nullptr);
            QObject::connect(old, &QProcess::finished, old, &QObject::deleteLater);
            if (old->state() == QProcess::NotRunning) old->deleteLater();
            else old->kill();
        }
        updateSpeechButtons();
        speechStatus->setText(title.isEmpty() ? QStringLiteral("Open a word to hear its pronunciation.")
                                              : QStringLiteral("Uses an installed offline voice for this word's language."));
    }

    void stopAudio() {
        playing = nullptr;
        player->stop();
        player->setSource({});
        audioBuffer.reset();
        for (auto *card : cards) {
            card->position->setEnabled(false);
            updateButton(card);
        }
    }

    void setEntry(const QJsonObject &entry, const QString &sourceHost) {
        cancelRequests();
        stopSpeech();
        stopAudio();
        cards.clear();
        pronunciations.clear();
        while (auto *item = cardsLayout->takeAt(0)) {
            delete item->widget();
            delete item;
        }
        title = entry.value(QStringLiteral("title")).toString();
        language = entry.value(QStringLiteral("language_code")).toString();
        if (language.isEmpty()) language = entry.value(QStringLiteral("language")).toString();
        listen->setEnabled(!title.isEmpty());
        speechStatus->setText(title.isEmpty() ? QStringLiteral("Open a word to hear its pronunciation.")
                                              : QStringLiteral("Uses an installed offline voice for this word's language."));
        addPronunciations(entry);
        for (const QJsonValue &value : entry.value(QStringLiteral("media")).toArray()) {
            const QJsonObject media = value.toObject();
            const QString kind = media.value(QStringLiteral("kind")).toString();
            if ((kind != QStringLiteral("image") && kind != QStringLiteral("audio")) ||
                media.value(QStringLiteral("file")).toString().trimmed().isEmpty()) continue;
            auto *card = new MediaCard(media, cardsBody);
            if (QRegularExpression(QStringLiteral("^[a-z0-9-]+\\.wiktionary\\.org$")).match(sourceHost).hasMatch()) card->sourceHost = sourceHost;
            card->key = QString::fromLatin1(QCryptographicHash::hash((card->sourceHost + QChar(':') + kind + QChar(':') + card->file).toUtf8(), QCryptographicHash::Sha256).toHex());
            cards.append(card);
            cardsLayout->addWidget(card);
            card->status->setText(allowed(card) ? QStringLiteral("Ready when you are.")
                : QStringLiteral("Enable online %1 above to load this media.").arg(kind == QStringLiteral("image") ? QStringLiteral("images") : QStringLiteral("audio")));
            updateButton(card);
            QObject::connect(card->button, &QPushButton::clicked, q, [this, card] {
                if (!allowed(card) || card->busy) return;
                if (card->kind == QStringLiteral("audio") && !card->data.isEmpty()) play(card);
                else {
                    if (!card->data.isEmpty()) { removeCached(card); card->data.clear(); }
                    load(card);
                }
            });
            QObject::connect(card->position, &QSlider::valueChanged, q, [this, card](int position) {
                if (playing == card) player->setPosition(position);
            });
            QObject::connect(card->source, &QPushButton::clicked, q, [card] {
                const QUrl url(card->metadata.value(QStringLiteral("source")).toString());
                if (allowedUrl(url, false, card->sourceHost) || allowedUrl(url, true)) {
                    if (!QDesktopServices::openUrl(url)) card->status->setText(QStringLiteral("Could not open your browser."));
                }
            });
        }
        if (cards.isEmpty()) {
            auto *empty = new QLabel(title.isEmpty() ? QStringLiteral("Media will appear here when you open a word.")
                                                    : QStringLiteral("This entry has no images or recorded pronunciations."), cardsBody);
            empty->setWordWrap(true);
            cardsLayout->addWidget(empty);
        }
    }

    void updateSpeechButtons() {
        listen->setText(speech ? QStringLiteral("Stop") : QStringLiteral("Listen offline"));
        for (const auto &pronunciation : pronunciations) {
            const bool active = speech && activeSpeechKey == pronunciation.first;
            pronunciation.second->setText(active ? QStringLiteral("Stop") : QStringLiteral("Listen"));
            pronunciation.second->setAccessibleName((active
                ? QStringLiteral("Stop reading the transcription %1 offline")
                : QStringLiteral("Listen to the transcription %1 offline")).arg(pronunciation.first));
        }
    }

    void addPronunciations(const QJsonObject &entry) {
        QSet<QString> seen;
        QGroupBox *group = nullptr;
        QVBoxLayout *layout = nullptr;
        const auto collectSpans = [&](const QJsonArray &values) {
            for (const QJsonValue &value : values) {
                const QJsonObject span = value.toObject();
                const QString ipa = span.value(QStringLiteral("text")).toString();
                if (span.value(QStringLiteral("role")).toString() != QStringLiteral("pronunciation") || seen.contains(ipa)) continue;
                seen.insert(ipa);
                const QString ssml = pronunciationSsml(ipa, language);
                if (ssml.isEmpty()) continue;
                if (!group) {
                    group = new QGroupBox(QStringLiteral("English transcriptions"), cardsBody);
                    layout = new QVBoxLayout(group);
                    cardsLayout->addWidget(group);
                }
                auto *row = new QHBoxLayout;
                auto *label = new QLabel(ipa, group);
                label->setTextFormat(Qt::PlainText);
                label->setWordWrap(true);
                label->setTextInteractionFlags(Qt::TextSelectableByMouse);
                auto *button = new QPushButton(QStringLiteral("Listen"), group);
                button->setObjectName(QStringLiteral("mediaPronunciation"));
                button->setAccessibleName(QStringLiteral("Listen to the transcription %1 offline").arg(ipa));
                row->addWidget(label, 1);
                row->addWidget(button);
                layout->addLayout(row);
                pronunciations.append({ipa, button});
                QObject::connect(button, &QPushButton::clicked, q, [this, ipa, ssml] {
                    if (speech && activeSpeechKey == ipa) stopSpeech();
                    else say(title, language, ssml, ipa);
                });
            }
        };
        std::function<void(const QJsonArray &, int)> collectBlocks;
        const auto collectTable = [&](auto &&visit, const QJsonObject &table, int depth) -> void {
            if (depth > 16) return;
            collectSpans(table.value(QStringLiteral("caption")).toArray());
            for (const QJsonValue &row : table.value(QStringLiteral("rows")).toArray()) {
                for (const QJsonValue &value : row.toObject().value(QStringLiteral("cells")).toArray()) {
                    const QJsonObject cell = value.toObject();
                    const QJsonValue blocks = cell.value(QStringLiteral("blocks"));
                    if (!blocks.isUndefined() && !blocks.isNull()) {
                        collectBlocks(blocks.toArray(), depth);
                    } else if (cell.value(QStringLiteral("nested_table")).isObject()) {
                        visit(visit, cell.value(QStringLiteral("nested_table")).toObject(), depth + 1);
                    } else {
                        collectSpans(cell.value(QStringLiteral("spans")).toArray());
                    }
                }
            }
        };
        collectBlocks = [&](const QJsonArray &blocks, int depth) {
            for (const QJsonValue &value : blocks) {
                const QJsonObject block = value.toObject();
                if (block.value(QStringLiteral("table")).isObject())
                    collectTable(collectTable, block.value(QStringLiteral("table")).toObject(), depth + 1);
                else
                    collectSpans(block.value(QStringLiteral("spans")).toArray());
            }
        };
        for (const QJsonValue &section : entry.value(QStringLiteral("sections")).toArray())
            collectBlocks(section.toObject().value(QStringLiteral("blocks")).toArray(), 0);
    }

    void fail(MediaCard *card, const QString &message) {
        card->busy = false;
        card->progress->hide();
        card->status->setText(message + QStringLiteral(" Try again."));
        updateButton(card);
        card->setAction(QStringLiteral("Retry"));
    }

    QString cachedPath(const MediaCard *card, const QString &extension) const {
        return cacheRoot + QChar('/') + card->key + extension;
    }

    void removeCached(const MediaCard *card) {
        QFile::remove(cachedPath(card, QStringLiteral(".bin")));
        QFile::remove(cachedPath(card, QStringLiteral(".json")));
    }

    void trimCache(qint64 budget) {
        QDir directory(cacheRoot);
        const auto files = directory.entryInfoList({QStringLiteral("*.bin"), QStringLiteral("*.json")}, QDir::Files, QDir::Time | QDir::Reversed);
        qint64 total = 0;
        for (const QFileInfo &file : files) total += file.size();
        for (const QFileInfo &file : files) {
            if (total <= budget) break;
            const QString stem = file.completeBaseName();
            for (const QString &extension : {QStringLiteral(".bin"), QStringLiteral(".json")}) {
                QFileInfo candidate(directory.filePath(stem + extension));
                const qint64 size = candidate.size();
                if (candidate.exists() && QFile::remove(candidate.filePath())) total -= size;
            }
        }
        cacheStatus->setText(QStringLiteral("%1 MB stored on this device.").arg(double(std::max<qint64>(0, total)) / (1024 * 1024), 0, 'f', 1));
    }

    bool readCached(MediaCard *card) {
        if (cacheLimit() <= 0) return false;
        QFile payload(cachedPath(card, QStringLiteral(".bin")));
        QFile metadata(cachedPath(card, QStringLiteral(".json")));
        if (!payload.exists() || !metadata.exists()) return false;
        if (payload.size() > MaxMediaBytes || metadata.size() > MaxMetadataBytes ||
            !payload.open(QIODevice::ReadOnly) || !metadata.open(QIODevice::ReadOnly)) {
            removeCached(card);
            return false;
        }
        const auto info = QJsonDocument::fromJson(metadata.readAll()).object();
        const QUrl source(info.value(QStringLiteral("source")).toString());
        if ((!allowedUrl(source, false, card->sourceHost) && !allowedUrl(source, true)) ||
            !allowedUrl(QUrl(info.value(QStringLiteral("url")).toString()), true)) {
            removeCached(card);
            return false;
        }
        if (!present(card, payload.readAll(), info)) {
            removeCached(card);
            return false;
        }
        payload.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
        metadata.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
        card->status->setText(QStringLiteral("Loaded from this device."));
        return true;
    }

    void writeCached(MediaCard *card) {
        const QByteArray metadata = QJsonDocument(card->metadata).toJson(QJsonDocument::Compact);
        const qint64 size = card->data.size() + metadata.size();
        if (size > cacheLimit() || cacheLimit() <= 0) return;
        removeCached(card);
        trimCache(cacheLimit() - size);
        QSaveFile payload(cachedPath(card, QStringLiteral(".bin")));
        QSaveFile meta(cachedPath(card, QStringLiteral(".json")));
        if (!payload.open(QIODevice::WriteOnly) || !meta.open(QIODevice::WriteOnly) ||
            payload.write(card->data) != card->data.size() || meta.write(metadata) != metadata.size() ||
            !payload.commit() || !meta.commit()) {
            removeCached(card);
            card->status->setText(QStringLiteral("Loaded. Could not save this media for later."));
        }
        trimCache(cacheLimit());
    }

    bool present(MediaCard *card, const QByteArray &bytes, const QJsonObject &metadata) {
        if (card->kind == QStringLiteral("image")) {
            QBuffer buffer;
            buffer.setData(bytes);
            buffer.open(QIODevice::ReadOnly);
            QImageReader reader(&buffer);
            reader.setAutoTransform(true);
            const QSize dimensions = reader.size();
            if (!dimensions.isValid()) {
                fail(card, QStringLiteral("This image format could not be opened."));
                return false;
            }
            reader.setScaledSize(dimensions.scaled(QSize(1280, 800), Qt::KeepAspectRatio));
            const QImage image = reader.read();
            if (image.isNull()) {
                fail(card, QStringLiteral("This image could not be opened."));
                return false;
            }
            card->image->setImage(image);
            card->image->show();
        }
        card->data = bytes;
        card->metadata = metadata;
        card->busy = false;
        card->progress->hide();
        card->status->setText(QStringLiteral("Ready."));
        card->credit->setText(metadata.value(QStringLiteral("credit")).toString());
        card->credit->setVisible(!card->credit->text().isEmpty());
        card->source->show();
        updateButton(card);
        return true;
    }

    void request(MediaCard *card, const QUrl &url, qint64 maximum, std::function<void(QByteArray)> done) {
        QNetworkRequest request(url);
        request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("WikidictDesktop/0.3 (native offline dictionary)"));
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::SameOriginRedirectPolicy);
        request.setMaximumRedirectsAllowed(5);
        request.setTransferTimeout(30000);
        auto *reply = network->get(request);
        requests.insert(reply, card);
        struct Download { QByteArray bytes; QString error; };
        auto state = std::make_shared<Download>();
        QObject::connect(reply, &QNetworkReply::readyRead, card, [reply, state, maximum] {
            const qint64 available = reply->bytesAvailable();
            if (available > maximum - state->bytes.size()) {
                state->error = QStringLiteral("This media file is too large.");
                reply->abort();
                return;
            }
            state->bytes += reply->readAll();
        });
        QObject::connect(reply, &QNetworkReply::metaDataChanged, card, [reply, state, maximum] {
            if (reply->header(QNetworkRequest::ContentLengthHeader).toLongLong() > maximum) {
                state->error = QStringLiteral("This media file is too large.");
                reply->abort();
            }
        });
        QObject::connect(reply, &QNetworkReply::downloadProgress, card, [card](qint64 received, qint64 total) {
            card->progress->setRange(0, total > 0 ? 100 : 0);
            if (total > 0) card->progress->setValue(int(100.0 * double(received) / double(total)));
        });
        QObject::connect(reply, &QNetworkReply::finished, card, [this, card, reply, state, maximum, done = std::move(done)] {
            requests.remove(reply);
            reply->deleteLater();
            if (reply->bytesAvailable() > maximum - state->bytes.size()) state->error = QStringLiteral("This media file is too large.");
            if (!state->error.isEmpty()) { fail(card, state->error); return; }
            state->bytes += reply->readAll();
            if (reply->error() != QNetworkReply::NoError) {
                fail(card, QStringLiteral("Download failed. Check your connection. %1").arg(reply->errorString()));
                return;
            }
            done(state->bytes);
        });
    }

    void load(MediaCard *card) {
        if (!allowed(card)) return;
        if (readCached(card)) {
            if (card->kind == QStringLiteral("audio")) play(card);
            return;
        }
        card->busy = true;
        card->status->setText(QStringLiteral("Finding media..."));
        card->progress->setRange(0, 0);
        card->progress->show();
        updateButton(card);
        resolve(card, 0);
    }

    void resolve(MediaCard *card, int hostIndex) {
        const QString host = hostIndex == 0 ? QStringLiteral("commons.wikimedia.org") : card->sourceHost;
        QUrl url(QStringLiteral("https://") + host + QStringLiteral("/w/api.php"));
        QUrlQuery query;
        query.addQueryItem(QStringLiteral("action"), QStringLiteral("query"));
        query.addQueryItem(QStringLiteral("format"), QStringLiteral("json"));
        query.addQueryItem(QStringLiteral("formatversion"), QStringLiteral("2"));
        query.addQueryItem(QStringLiteral("prop"), QStringLiteral("imageinfo"));
        query.addQueryItem(QStringLiteral("iiprop"), QStringLiteral("url|extmetadata"));
        query.addQueryItem(QStringLiteral("iiurlwidth"), QStringLiteral("960"));
        query.addQueryItem(QStringLiteral("titles"), QStringLiteral("File:") + card->file);
        url.setQuery(query);
        request(card, url, MaxMetadataBytes, [this, card, hostIndex](const QByteArray &bytes) {
            QJsonParseError error;
            const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
            if (error.error != QJsonParseError::NoError) { fail(card, QStringLiteral("The media server sent an unreadable response.")); return; }
            const QJsonArray pages = document.object().value(QStringLiteral("query")).toObject().value(QStringLiteral("pages")).toArray();
            QJsonObject info;
            for (const QJsonValue &page : pages) {
                const QJsonArray media = page.toObject().value(QStringLiteral("imageinfo")).toArray();
                if (!media.isEmpty()) { info = media.first().toObject(); break; }
            }
            if (info.isEmpty()) {
                if (hostIndex == 0 && !card->sourceHost.isEmpty()) resolve(card, 1);
                else fail(card, QStringLiteral("This media is no longer available from Wikimedia."));
                return;
            }
            const QUrl mediaUrl(card->kind == QStringLiteral("image") && !info.value(QStringLiteral("thumburl")).toString().isEmpty()
                ? info.value(QStringLiteral("thumburl")).toString() : info.value(QStringLiteral("url")).toString());
            if (!allowedUrl(mediaUrl, true)) { fail(card, QStringLiteral("The media server returned an unsupported address.")); return; }
            QUrl source(info.value(QStringLiteral("descriptionurl")).toString());
            if (!allowedUrl(source, false, card->sourceHost) && !allowedUrl(source, true)) source = mediaUrl;
            const QJsonObject ext = info.value(QStringLiteral("extmetadata")).toObject();
            QStringList credit;
            for (const QString &key : {QStringLiteral("Artist"), QStringLiteral("LicenseShortName")}) {
                const QString value = plainMetadata(ext, key);
                if (!value.isEmpty()) credit.append(value);
            }
            QJsonObject metadata{{QStringLiteral("url"), mediaUrl.toString()}, {QStringLiteral("source"), source.toString()},
                                 {QStringLiteral("credit"), credit.join(QStringLiteral(" / "))}};
            card->status->setText(QStringLiteral("Downloading media..."));
            request(card, mediaUrl, MaxMediaBytes, [this, card, metadata](const QByteArray &payload) {
                if (payload.isEmpty()) { fail(card, QStringLiteral("The media file was empty.")); return; }
                if (!present(card, payload, metadata)) return;
                writeCached(card);
                if (card->kind == QStringLiteral("audio")) play(card);
            });
        });
    }

    void play(MediaCard *card) {
        stopSpeech();
        if (QMediaDevices::audioOutputs().isEmpty()) {
            fail(card, QStringLiteral("No sound output is available. Connect or enable a speaker in system settings."));
            return;
        }
        if (playing == card) {
            if (player->playbackState() == QMediaPlayer::PlayingState) player->pause();
            else {
                if (player->mediaStatus() == QMediaPlayer::EndOfMedia) player->setPosition(0);
                player->play();
            }
            return;
        }
        stopAudio();
        playing = card;
        audioBuffer = std::make_unique<QBuffer>();
        audioBuffer->setData(card->data);
        audioBuffer->open(QIODevice::ReadOnly);
        player->setSourceDevice(audioBuffer.get(), QUrl(card->metadata.value(QStringLiteral("url")).toString()));
        player->play();
    }

    void say(const QString &word, const QString &code, const QString &ssml = {}, const QString &speechKey = {}) {
        stopSpeech();
        stopAudio();
        if (word.trimmed().isEmpty()) return;
        const QString languageCode = voiceLanguage(code);
        if (languageCode.isEmpty()) {
            speechStatus->setText(QStringLiteral("This entry does not identify a language supported by offline speech."));
            return;
        }
        QString executable = QStandardPaths::findExecutable(QStringLiteral("espeak-ng"));
        if (executable.isEmpty()) executable = QStandardPaths::findExecutable(QStringLiteral("espeak"));
        if (executable.isEmpty()) {
            speechStatus->setText(QStringLiteral("Install eSpeak NG with your system's software manager, then choose Listen offline again."));
            return;
        }
        speechStatus->setText(QStringLiteral("Finding an offline voice..."));
        auto *query = new QProcess(q);
        speech = query;
        activeSpeechKey = speechKey.isEmpty() ? word : speechKey;
        updateSpeechButtons();
        QObject::connect(query, &QProcess::errorOccurred, q, [this, query](QProcess::ProcessError) {
            if (speech != query) return;
            const QString error = query->errorString();
            stopSpeech();
            speechStatus->setText(QStringLiteral("The offline voice could not start. %1").arg(error));
        });
        QObject::connect(query, &QProcess::finished, q, [this, query, word, languageCode, executable, ssml](int exitCode, QProcess::ExitStatus status) {
            if (speech != query) return;
            const QString response = QString::fromUtf8(query->readAllStandardOutput());
            speech = nullptr;
            query->deleteLater();
            QString chosen;
            const QString base = languageCode.section(QChar('-'), 0, 0);
            for (const QString &line : response.split(QChar('\n'))) {
                const QStringList parts = line.simplified().split(QChar(' '));
                if (parts.size() < 5 || !QRegularExpression(QStringLiteral("^[0-9]+$")).match(parts[0]).hasMatch()) continue;
                const QString candidate = parts[1].toLower();
                if (!QRegularExpression(QStringLiteral("^[a-z0-9_-]+$")).match(candidate).hasMatch()) continue;
                if (candidate == languageCode) { chosen = candidate; break; }
                if (chosen.isEmpty() && candidate.section(QChar('-'), 0, 0) == base) chosen = candidate;
            }
            if (exitCode != 0 || status != QProcess::NormalExit || chosen.isEmpty()) {
                updateSpeechButtons();
                speechStatus->setText(QStringLiteral("No installed offline voice supports %1. Install its eSpeak NG voice data and try again.").arg(codeForDisplay(languageCode)));
                return;
            }
            auto *voice = new QProcess(q);
            speech = voice;
            QObject::connect(voice, &QProcess::started, q, [voice, word, ssml] {
                voice->write((ssml.isEmpty() ? word : ssml).toUtf8() + '\n');
                voice->closeWriteChannel();
            });
            QObject::connect(voice, &QProcess::errorOccurred, q, [this, voice](QProcess::ProcessError) {
                if (speech != voice) return;
                const QString error = voice->errorString();
                stopSpeech();
                speechStatus->setText(QStringLiteral("The offline voice could not play. %1").arg(error));
            });
            QObject::connect(voice, &QProcess::finished, q, [this, voice](int exitCode, QProcess::ExitStatus status) {
                if (speech != voice) return;
                const QString error = QString::fromUtf8(voice->readAllStandardError()).simplified().left(200);
                speech = nullptr;
                voice->deleteLater();
                updateSpeechButtons();
                speechStatus->setText(exitCode == 0 && status == QProcess::NormalExit ? QStringLiteral("Finished.")
                    : QStringLiteral("The offline voice could not play. Check your sound output. %1").arg(error));
            });
            speechStatus->setText(QStringLiteral("Speaking with the %1 offline voice.").arg(codeForDisplay(chosen)));
            QStringList arguments{QStringLiteral("-v"), chosen, QStringLiteral("--stdin")};
            if (!ssml.isEmpty()) arguments.append(QStringLiteral("-m"));
            voice->start(executable, arguments);
        });
        QTimer::singleShot(5000, query, [this, query] {
            if (speech != query) return;
            stopSpeech();
            speechStatus->setText(QStringLiteral("The offline voice took too long to respond. Try again."));
        });
        query->start(executable, {QStringLiteral("--voices")});
    }

    QString codeForDisplay(const QString &code) const {
        const auto language = QLocale::codeToLanguage(code.section(QChar('-'), 0, 0));
        return language == QLocale::AnyLanguage || language == QLocale::C ? code : QLocale::languageToString(language);
    }
};

MediaPanel::MediaPanel(QWidget *parent, QNetworkAccessManager *network) : QWidget(parent), impl_(std::make_unique<Impl>(this, network)) {}
MediaPanel::~MediaPanel() = default;
void MediaPanel::setEntry(const QJsonObject &entry, const QString &sourceHost) { impl_->setEntry(entry, sourceHost); }
void MediaPanel::sayWord(const QString &title, const QString &languageCode) { impl_->say(title, languageCode); }
void MediaPanel::stopPlayback() { impl_->stopSpeech(); impl_->stopAudio(); }
