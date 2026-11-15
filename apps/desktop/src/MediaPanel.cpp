#include "MediaPanel.hpp"
#include "CompiledContent.hpp"
#include "SvgRasterIdentity.hpp"
#include "SemanticHtml.hpp"
#include <QResizeEvent>

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
#include <QSvgRenderer>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextFragment>
#include <QTimer>
#include <QUrlQuery>
#include <QVBoxLayout>
#include <algorithm>
#include <functional>
#include <cmath>

namespace {
constexpr qint64 MaxMediaBytes = 50 * 1024 * 1024;
constexpr qint64 MaxMetadataBytes = 2 * 1024 * 1024;

bool svgMime(const QString &mime) {
    return mime.trimmed().compare(QStringLiteral("image/svg+xml"), Qt::CaseInsensitive) == 0;
}

bool allowedUrl(const QUrl &url, bool download, const QString &sourceHost = {}) {
    if (!url.isValid() || url.scheme() != QStringLiteral("https") || !url.userInfo().isEmpty() ||
        (url.port() != -1 && url.port() != 443)) return false;
    const QString host = url.host().toLower();
    return download ? (host == QStringLiteral("upload.wikimedia.org") || host == QStringLiteral("thumb.wikimedia.org"))
                    : host == QStringLiteral("commons.wikimedia.org") || (!sourceHost.isEmpty() && host == sourceHost);
}

// QTextDocument imports rich text, but ignores inline CSS display:none. Commons
// uses that markup for machine-readable duplicates. Remove only balanced hidden
// subtrees here; leave all remaining HTML and entity/alt decoding to Qt.
bool metadataSpace(QChar ch) {
    return ch == QChar(' ') || ch == QChar('\t') || ch == QChar('\n') || ch == QChar('\r') || ch == QChar('\f');
}

QString metadataTrim(const QString &value) {
    qsizetype first = 0, last = value.size();
    while (first < last && metadataSpace(value[first])) ++first;
    while (last > first && metadataSpace(value[last - 1])) --last;
    return value.mid(first, last - first);
}

bool metadataDisplayNone(QString style) {
    QString declarations;
    QChar quote;
    for (qsizetype i = 0; i < style.size(); ++i) {
        const QChar ch = style[i];
        if (!quote.isNull()) {
            declarations += ch;
            if (ch == QChar('\\') && i + 1 < style.size()) declarations += style[++i];
            else if (ch == quote) quote = QChar();
        } else if (ch == QChar('\'') || ch == QChar('"')) {
            quote = ch;
            declarations += ch;
        } else if (ch == QChar('/') && i + 1 < style.size() && style[i + 1] == QChar('*')) {
            const qsizetype end = style.indexOf(QStringLiteral("*/"), i + 2);
            if (end < 0) break;
            declarations += QChar(' ');
            i = end + 1;
        } else declarations += ch;
    }
    bool hidden = false, important = false;
    qsizetype start = 0;
    int parentheses = 0;
    quote = QChar();
    for (qsizetype i = 0; i <= declarations.size(); ++i) {
        const QChar ch = i == declarations.size() ? QChar(';') : declarations[i];
        if (!quote.isNull()) {
            if (ch == QChar('\\')) ++i;
            else if (ch == quote) quote = QChar();
            continue;
        }
        if (ch == QChar('\'') || ch == QChar('"')) { quote = ch; continue; }
        if (ch == QChar('(')) ++parentheses;
        if (ch == QChar(')') && parentheses > 0) --parentheses;
        if (ch != QChar(';') || parentheses != 0) continue;
        const QString declaration = metadataTrim(declarations.mid(start, i - start));
        start = i + 1;
        const qsizetype colon = declaration.indexOf(QChar(':'));
        if (colon < 0 || metadataTrim(declaration.left(colon)).compare(QStringLiteral("display"), Qt::CaseInsensitive) != 0) continue;
        QString value = metadataTrim(declaration.mid(colon + 1)).toLower();
        static const QRegularExpression priority(QStringLiteral("[ \\t\\n\\r\\f]*![ \\t\\n\\r\\f]*important[ \\t\\n\\r\\f]*$"));
        const auto match = priority.match(value);
        const bool nextImportant = match.hasMatch();
        if (nextImportant) value.truncate(match.capturedStart());
        value = metadataTrim(value);
        static const QRegularExpression spaces(QStringLiteral("[ \\t\\n\\r\\f]+"));
        value.replace(spaces, QStringLiteral(" "));
        // Unknown declarations cannot override an earlier valid display value.
        static const QSet<QString> displays{
            QStringLiteral("none"), QStringLiteral("contents"), QStringLiteral("block"),
            QStringLiteral("inline"), QStringLiteral("inline-block"), QStringLiteral("flow-root"),
            QStringLiteral("list-item"), QStringLiteral("flex"), QStringLiteral("inline-flex"),
            QStringLiteral("grid"), QStringLiteral("inline-grid"), QStringLiteral("table"),
            QStringLiteral("inline-table"), QStringLiteral("table-row"), QStringLiteral("table-cell"),
            QStringLiteral("table-row-group"), QStringLiteral("table-header-group"),
            QStringLiteral("table-footer-group"), QStringLiteral("table-column"),
            QStringLiteral("table-column-group"), QStringLiteral("table-caption"),
            QStringLiteral("ruby"), QStringLiteral("ruby-base"), QStringLiteral("ruby-text"),
            QStringLiteral("ruby-base-container"), QStringLiteral("ruby-text-container"), QStringLiteral("run-in"),
            QStringLiteral("initial"), QStringLiteral("inherit"), QStringLiteral("unset"),
            QStringLiteral("revert"), QStringLiteral("revert-layer")};
        auto keywords = value.split(QChar(' '));
        const bool listItem = keywords.removeOne(QStringLiteral("list-item"));
        int outer = 0, inner = 0;
        for (const QString &keyword : keywords) {
            if (keyword == QStringLiteral("inline") || keyword == QStringLiteral("block") || keyword == QStringLiteral("run-in")) ++outer;
            else if (keyword == QStringLiteral("flow") || keyword == QStringLiteral("flow-root") ||
                     (!listItem && (keyword == QStringLiteral("table") || keyword == QStringLiteral("flex") ||
                                    keyword == QStringLiteral("grid") || keyword == QStringLiteral("ruby")))) ++inner;
        }
        const bool combination = outer <= 1 && inner <= 1 && outer + inner == keywords.size() &&
                                 (listItem || !keywords.isEmpty());
        // Functions and CSS escapes need interpretation beyond this bounded
        // literal-keyword check. If such a declaration wins, preserve text;
        // it cannot prove display:none. Quoted text is not a function token.
        bool unresolved = false;
        QChar valueQuote;
        for (qsizetype j = 0; j < value.size(); ++j) {
            const QChar ch = value[j];
            if (!valueQuote.isNull()) {
                if (ch == QChar('\\')) ++j;
                else if (ch == valueQuote) valueQuote = QChar();
                continue;
            }
            if (ch == QChar('\'') || ch == QChar('"')) { valueQuote = ch; continue; }
            if (ch == QChar('(') || ch == QChar('\\')) unresolved = true;
        }
        if ((displays.contains(value) || combination || unresolved) && (!important || nextImportant)) {
            hidden = value == QStringLiteral("none");
            important = nextImportant;
        }
    }
    return hidden;
}

QString visibleMetadataHtml(const QString &html) {
    QString visible;
    QStringList hiddenTags;
    qsizetype hiddenStart = -1;
    const auto nameCharacter = [](QChar ch) {
        return (ch >= QChar('a') && ch <= QChar('z')) || (ch >= QChar('A') && ch <= QChar('Z')) ||
               (ch >= QChar('0') && ch <= QChar('9')) || ch == QChar('-') || ch == QChar(':');
    };
    static const QSet<QString> voidTags{
        QStringLiteral("area"), QStringLiteral("base"), QStringLiteral("br"), QStringLiteral("col"),
        QStringLiteral("embed"), QStringLiteral("hr"), QStringLiteral("img"), QStringLiteral("input"),
        QStringLiteral("link"), QStringLiteral("meta"), QStringLiteral("param"), QStringLiteral("source"),
        QStringLiteral("track"), QStringLiteral("wbr")};
    for (qsizetype i = 0; i < html.size();) {
        if (html[i] != QChar('<')) {
            if (hiddenTags.isEmpty()) visible += html[i];
            ++i;
            continue;
        }
        if (html.mid(i, 4) == QStringLiteral("<!--")) {
            const qsizetype end = html.indexOf(QStringLiteral("-->"), i + 4);
            const qsizetype next = end < 0 ? html.size() : end + 3;
            if (hiddenTags.isEmpty()) visible += html.mid(i, next - i);
            i = next;
            continue;
        }
        qsizetype cursor = i + 1;
        const bool closing = cursor < html.size() && html[cursor] == QChar('/');
        if (closing) ++cursor;
        const qsizetype nameStart = cursor;
        while (cursor < html.size() && nameCharacter(html[cursor])) ++cursor;
        if (cursor == nameStart) {
            if (hiddenTags.isEmpty()) visible += html[i];
            ++i;
            continue;
        }
        const QString tag = html.mid(nameStart, cursor - nameStart).toLower();
        QChar quote;
        qsizetype end = cursor;
        for (; end < html.size(); ++end) {
            const QChar ch = html[end];
            if (!quote.isNull()) { if (ch == quote) quote = QChar(); }
            else if (ch == QChar('\'') || ch == QChar('"')) quote = ch;
            else if (ch == QChar('>')) break;
        }
        if (end == html.size()) {
            if (hiddenTags.isEmpty()) visible += html.mid(i);
            break;
        }
        bool hidden = false, styleSeen = false;
        while (!closing && cursor < end) {
            while (cursor < end && (metadataSpace(html[cursor]) || html[cursor] == QChar('/'))) ++cursor;
            const qsizetype attributeStart = cursor;
            while (cursor < end && !metadataSpace(html[cursor]) && html[cursor] != QChar('=') && html[cursor] != QChar('/')) ++cursor;
            const QString attribute = html.mid(attributeStart, cursor - attributeStart).toLower();
            while (cursor < end && metadataSpace(html[cursor])) ++cursor;
            QString value;
            if (cursor < end && html[cursor] == QChar('=')) {
                ++cursor;
                while (cursor < end && metadataSpace(html[cursor])) ++cursor;
                const QChar delimiter = cursor < end ? html[cursor] : QChar();
                const bool quoted = delimiter == QChar('\'') || delimiter == QChar('"');
                if (quoted) ++cursor;
                const qsizetype valueStart = cursor;
                while (cursor < end && (quoted ? html[cursor] != delimiter : !metadataSpace(html[cursor]))) ++cursor;
                value = html.mid(valueStart, cursor - valueStart);
                if (quoted && cursor < end) ++cursor;
            }
            if (attribute == QStringLiteral("style") && !styleSeen) {
                styleSeen = true;
                value.replace(QChar('<'), QStringLiteral("&lt;")).replace(QChar('>'), QStringLiteral("&gt;"));
                hidden = metadataDisplayNone(QTextDocumentFragment::fromHtml(value).toRawText());
            }
            if (cursor == attributeStart) ++cursor;
        }
        const bool wasHidden = !hiddenTags.isEmpty();
        if (closing) {
            const qsizetype index = hiddenTags.lastIndexOf(tag);
            if (index >= 0) hiddenTags.erase(hiddenTags.begin() + index, hiddenTags.end());
        } else if ((wasHidden || hidden) && !voidTags.contains(tag)) {
            if (!wasHidden) hiddenStart = i;
            hiddenTags.append(tag);
        }
        if (!wasHidden && !hidden) visible += html.mid(i, end + 1 - i);
        i = end + 1;
        // Script/style text is not markup. Preserve its original Qt handling,
        // and do not let strings inside it alter the surrounding element stack.
        if (!closing && (tag == QStringLiteral("script") || tag == QStringLiteral("style"))) {
            const qsizetype rawEnd = html.indexOf(QStringLiteral("</") + tag, i, Qt::CaseInsensitive);
            const qsizetype next = rawEnd < 0 ? html.size() : rawEnd;
            if (hiddenTags.isEmpty()) visible += html.mid(i, next - i);
            i = next;
        }
    }
    // Incomplete markup cannot establish a balanced hidden subtree. Preserve it
    // instead of dropping unrelated visible attribution after a missing close.
    if (!hiddenTags.isEmpty()) visible += html.mid(hiddenStart);
    return visible;
}

QString plainMetadata(const QJsonObject &metadata, const QString &key) {
    QTextDocument document;
    document.setHtml(visibleMetadataHtml(metadata.value(key).toObject().value(QStringLiteral("value")).toString()));
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
    std::function<void()> resized;
    void setImage(const QImage &image) { pixmap_ = QPixmap::fromImage(image); update(); }
    QSize sizeHint() const override { return QSize(240, 240); }
    QSize minimumSizeHint() const override { return QSize(1, 120); }
protected:
    void resizeEvent(QResizeEvent *event) override { QWidget::resizeEvent(event); if (resized) resized(); }
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
    MediaCard(const QJsonObject &media, QWidget *parent, bool canonicalIdentity) : QGroupBox(parent) {
        kind = media.value(QStringLiteral("kind")).toString();
        file = media.value(QStringLiteral("file")).toString();
        if (!canonicalIdentity) file.remove(QRegularExpression(QStringLiteral("^(File|Image):"), QRegularExpression::CaseInsensitiveOption));
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
    std::optional<QString> svgLanguage;
    QJsonObject staticPoster, pinnedRendition;
    QList<QJsonObject> blockFigures;
    QList<QPair<QJsonObject, QString>> occurrences;
    qreal requestedDpr = 1;
    quint32 requestedPixels = 0, rasterPixels = 0;
    bool catalogRequested = false;
    QJsonObject verifiedOriginal, verifiedPage;
    QByteArray data;
    QImage decodedImage;
    std::shared_ptr<QSvgRenderer> vectorImage;
    QSizeF intrinsicImage;
    bool inlineRequested = false;
    QString inlineFailure;
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
    QString currentSourceHost;
    struct InlineSubscriber { QPointer<QObject> owner; QString key; std::function<void(const MediaPanel::InlineImageAsset &)> changed; };
    QHash<QString, QVector<InlineSubscriber>> inlineSubscribers;
    QList<QPointer<MediaCard>> inlineQueue;
    bool pumpingInline = false;
    static QSizeF originalImageSize(const QJsonObject &metadata, const QString &widthKey, const QString &heightKey) {
        const double width = metadata.value(widthKey).toDouble(-1), height = metadata.value(heightKey).toDouble(-1);
        if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 || width > 4294967295.0 || height > 4294967295.0
            || std::floor(width) != width || std::floor(height) != height) return {};
        return QSizeF(width, height);
    }
    static QString resourceKey(const QString &file, const std::optional<QString> &language, const QJsonObject &poster = {}, const QJsonObject &pinned = {}) {
        if (!pinned.isEmpty()) return QString::fromUtf8(QJsonDocument(QJsonArray{file, QStringLiteral("block-media"), pinned}).toJson(QJsonDocument::Compact));
        if (!poster.isEmpty()) return QString::fromUtf8(QJsonDocument(QJsonArray{file, QJsonValue::Null, poster}).toJson(QJsonDocument::Compact));
        return language ? QString::fromUtf8(QJsonDocument(QJsonArray{file, *language}).toJson(QJsonDocument::Compact)) : file;
    }
    std::optional<quint32> rasterDemand(const MediaCard *card, const QJsonObject &original) const {
        const QSizeF axes = originalImageSize(original, QStringLiteral("width"), QStringLiteral("height"));
        if (!axes.isValid()) return std::nullopt;
        quint32 result = 1;
        try {
            for (const auto &occurrence : card->occurrences) {
                const auto demand = SvgRasterIdentity::demand(occurrence.first, occurrence.second, card->requestedDpr, axes);
                if (!demand) return std::nullopt;
                result = std::max(result, *demand);
            }
        } catch (const std::exception &) { return std::nullopt; }
        if (card->catalogRequested) {
            const QSizeF viewport = card->image->size();
            const QSizeF fitted = axes.scaled(viewport, Qt::KeepAspectRatio);
            const qreal value = std::ceil(fitted.width() * card->image->devicePixelRatioF());
            if (!std::isfinite(value) || value <= 0 || value > 4294967295.0) return std::nullopt;
            result = std::max(result, quint32(value));
        }
        return result;
    }
    std::optional<quint32> posterDemand(const MediaCard *card) const {
        double required = 1;
        for (const auto &occurrence : card->occurrences) {
            try { if (SemanticHtml::checkedStaticPoster(occurrence.first) != card->staticPoster) return std::nullopt; }
            catch (const std::exception &) { return std::nullopt; }
            required = std::max(required, std::ceil(occurrence.first.value("width_px").toDouble() * card->requestedDpr));
        }
        if (card->catalogRequested)
            required = std::max(required, std::ceil(card->image->width() * card->image->devicePixelRatioF()));
        if (!std::isfinite(required) || required <= 0 || required > 4294967295.0) return std::nullopt;
        return quint32(required);
    }
    bool posterIdentity(MediaCard *card, const QJsonObject &page, const QJsonObject &info, quint32 requested) const {
        if (card->staticPoster.isEmpty() || requested == 0 || card->occurrences.isEmpty()) return false;
        try { if (SemanticHtml::checkedStaticPoster(card->occurrences.first().first) != card->staticPoster) return false; }
        catch (const std::exception &) { return false; }
        QString title = page.value("title").toString(); title.replace(QChar('_'), QChar(' '));
        if (page.value("ns").toInt(-1) != 6 || title != QStringLiteral("File:") + card->file) return false;
        for (const QString &key : {QStringLiteral("invalid"), QStringLiteral("filemissing"), QStringLiteral("filehidden"), QStringLiteral("suppressed")})
            if (page.contains(key) && page.value(key) != false) return false;
        if (info.contains("thumberror") || info.value("mime") != QStringLiteral("application/sla")
            || info.value("mediatype") != QStringLiteral("3D")
            || info.value("sha1") != card->staticPoster.value("file_sha1")
            || info.value("timestamp") != card->staticPoster.value("file_timestamp")
            || info.value("thumbmime") != QStringLiteral("image/png")) return false;
        const QUrl original(info.value("url").toString()), raster(info.value("thumburl").toString());
        if (!allowedUrl(original, true) || !allowedUrl(raster, true) || raster == original
            || !raster.path().endsWith(QStringLiteral(".png"), Qt::CaseInsensitive)) return false;
        const auto originalAxes = originalImageSize(info, "width", "height");
        const auto axes = originalImageSize(info, "thumbwidth", "thumbheight");
        if (!originalAxes.isValid() || !axes.isValid() || axes.width() < requested
            || quint64(axes.height()) != (quint64(axes.width()) * 3 + 2) / 4) return false;
        return true;
    }
    bool validatePosterMetadata(MediaCard *card, const QJsonObject &metadata) {
        const auto page = metadata.value("poster_page").toObject();
        const auto info = metadata.value("poster_info").toObject();
        const auto requested = metadata.value("poster_requested");
        const auto required = posterDemand(card);
        if (!SvgRasterIdentity::axis(requested) || !required
            || metadata.value("static_poster") != card->staticPoster
            || !posterIdentity(card, page, info, quint32(requested.toDouble()))
            || info.value("thumbwidth").toDouble() < *required
            || metadata.value("url") != info.value("thumburl")
            || metadata.value("original_mime") != info.value("mime")
            || originalImageSize(metadata, "intrinsic_width", "intrinsic_height") != QSizeF(4, 3)) return false;
        card->verifiedOriginal = info; card->verifiedPage = page;
        card->rasterPixels = quint32(info.value("thumbwidth").toDouble());
        return true;
    }
    bool adequate(const MediaCard *card) const {
        if (card->decodedImage.isNull() || !card->intrinsicImage.isValid()) return false;
        if (!card->pinnedRendition.isEmpty()) return card->metadata == pinnedMetadata(card)
            && card->decodedImage.width() == card->pinnedRendition.value("width").toDouble()
            && card->decodedImage.height() == card->pinnedRendition.value("height").toDouble();
        if (!card->staticPoster.isEmpty()) { const auto required = posterDemand(card); return required && card->rasterPixels >= *required && card->decodedImage.width() >= *required; }
        if (!card->svgLanguage) return true;
        const auto required = rasterDemand(card, card->verifiedOriginal);
        return required && card->rasterPixels >= *required && card->decodedImage.width() >= *required;
    }
    void pumpInline() {
        if (pumpingInline) return;
        pumpingInline = true;
        const QPointer<MediaPanel> panel(q);
        while (!inlineQueue.isEmpty()) {
            const int active = int(std::count_if(cards.begin(), cards.end(), [](const MediaCard *card) { return card->kind == QStringLiteral("image") && card->busy; }));
            if (active >= 4) break;
            QPointer<MediaCard> card = inlineQueue.takeFirst();
            if (!card || !allowed(card) || card->busy || adequate(card)) continue;
            load(card);
            if (!panel) return;
        }
        pumpingInline = false;
    }
    void enqueueInline(MediaCard *card) {
        if (card->busy || !allowed(card) || !card->inlineFailure.isEmpty() || adequate(card)) return;
        if (!inlineQueue.contains(card)) inlineQueue.append(card);
        pumpInline();
    }


    MediaPanel::InlineImageAsset inlineAsset(const MediaCard *card) const {
        using State = MediaPanel::InlineImageState;
        const bool verified = card->svgLanguage && !card->verifiedOriginal.isEmpty();
        // Geometry learned for this card survives pixel availability changes.
        // setEntry creates new cards when the source asset identity changes.
        const QSizeF axes = verified ? originalImageSize(card->verifiedOriginal, QStringLiteral("width"), QStringLiteral("height")) : card->intrinsicImage;
        const QString mime = verified ? QStringLiteral("image/svg+xml")
            : card->metadata.value(QStringLiteral("original_mime")).toString().trimmed().toLower();
        if (!allowed(card)) return {State::Disabled, {}, QStringLiteral("Online images are disabled."), axes, mime, {}, verified};
        if (card->busy) return {State::Loading, {}, card->status->text(), axes, mime, {}, verified};
        if (!card->inlineFailure.isEmpty()) return {State::Error, {}, card->inlineFailure, axes, mime, {}, verified};
        if (adequate(card)) return {State::Ready, card->decodedImage, QString(), card->intrinsicImage, card->metadata.value(QStringLiteral("original_mime")).toString().trimmed().toLower(), card->vectorImage, verified, card->pinnedRendition};
        return {State::Loading, {}, QStringLiteral("Loading image."), axes, mime, {}, verified};
    }
    void notifyInline(MediaCard *card) {
        if (card->kind != QStringLiteral("image")) return;
        auto &subscribers = inlineSubscribers[resourceKey(card->file, card->svgLanguage, card->staticPoster, card->pinnedRendition)];
        subscribers.removeIf([](const InlineSubscriber &item) { return item.owner.isNull(); });
        const auto copy = subscribers;
        const auto asset = inlineAsset(card);
        const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
        for (const auto &item : copy) if (item.owner) {
            item.changed(asset);
            if (!panel || !current) return;
        }
    }
    MediaPanel::InlineImageAsset inlineImage(const QJsonObject &image, const QString &sizing, qreal dpr,
            QObject *owner, const QString &key, std::function<void(const MediaPanel::InlineImageAsset &)> changed,
            const QJsonObject &figure = {}) {
        using State = MediaPanel::InlineImageState;
        QJsonObject poster, pinned;
        try {
            SemanticHtml::checkedImage(image); poster = SemanticHtml::checkedStaticPoster(image);
            if (!figure.isEmpty()) {
                if (figure.value("image_span").toObject().value("image") != image || !poster.isEmpty())
                    throw std::runtime_error("invalid compiled block image");
                pinned = SemanticHtml::blockMediaRendition(SemanticHtml::blockMediaResource(figure), dpr);
            }
        }
        catch (const std::exception &) { return {State::Error, {}, QStringLiteral("Invalid compiled image request.")}; }
        const QString file = image.value(QStringLiteral("file")).toString();
        const auto value = image.value(QStringLiteral("svg_language"));
        const std::optional<QString> lang = value.isUndefined() || value.isNull() ? std::nullopt : std::optional<QString>(value.toString());
        if ((lang && (!value.isString() || !SvgRasterIdentity::language(*lang))) || !std::isfinite(dpr) || dpr <= 0)
            return {State::Error, {}, QStringLiteral("Invalid compiled image request.")};
        for (auto it = inlineSubscribers.begin(); it != inlineSubscribers.end(); ++it)
            it.value().removeIf([&](const InlineSubscriber &item) { return item.owner.isNull() || (item.owner == owner && item.key == key); });
        for (MediaCard *card : cards) {
            if (card->kind != QStringLiteral("image") || card->file != file || card->svgLanguage != lang || card->staticPoster != poster
                || card->pinnedRendition != pinned || (!pinned.isEmpty() && !card->blockFigures.contains(figure))) continue;
            card->inlineRequested = true;
            card->requestedDpr = std::max(card->requestedDpr, dpr);
            const QPair<QJsonObject, QString> occurrence{image, sizing};
            if ((lang || !poster.isEmpty()) && !card->occurrences.contains(occurrence)) card->occurrences.append(occurrence);
            auto &subscribers = inlineSubscribers[resourceKey(file, lang, poster, pinned)];
            subscribers.append({owner, key, std::move(changed)});
            const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
            enqueueInline(card);
            if (!panel || !current) return {State::Error, {}, QStringLiteral("The image request is no longer current.")};
            return inlineAsset(card);
        }
        return {State::Error, {}, QStringLiteral("This image occurrence is not in the dictionary's media catalogue.")};
    }
    QUrl inlineSourceUrl(const QString &target, const std::optional<QString> &fragment = std::nullopt) const {
        if (currentSourceHost.isEmpty() || !target.startsWith(QStringLiteral("File:")) || target.size() <= 5) return {};
        const QString page = fragment ? target : target.section(QChar('#'), 0, 0);
        QUrl source(QStringLiteral("https://") + currentSourceHost + QStringLiteral("/wiki/") + QString::fromLatin1(QUrl::toPercentEncoding(page)));
        if (fragment) {
            if (!fragment->isEmpty()) source.setFragment(*fragment, QUrl::DecodedMode);
        } else if (target.contains(QChar('#'))) source.setFragment(target.section(QChar('#'), 1));
        return allowedUrl(source, false, currentSourceHost) ? source : QUrl();
    }
    bool openInlineSource(const QString &target, const std::optional<QString> &fragment) {
        const QUrl source = inlineSourceUrl(target, fragment);
        return !source.isEmpty() && QDesktopServices::openUrl(source);
    }

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
        else if (!card->data.isEmpty() || (card->kind == QStringLiteral("image") && !card->decodedImage.isNull())) {
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
            card->image->setVisible(enabled && !card->decodedImage.isNull() && kind == QStringLiteral("image"));
            card->status->setText(enabled ? QStringLiteral("Ready when you are.")
                : QStringLiteral("Enable online %1 above to load this media.").arg(kind == QStringLiteral("image") ? QStringLiteral("images") : QStringLiteral("audio")));
            updateButton(card);
            if (kind == QStringLiteral("image")) {
                const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
                notifyInline(card);
                if (!panel || !current) return;
                if (enabled && !inlineSubscribers.value(resourceKey(card->file, card->svgLanguage, card->staticPoster, card->pinnedRendition)).isEmpty()) { card->inlineFailure.clear(); enqueueInline(card); }
                if (!panel || !current) return;
            }
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
        inlineSubscribers.clear(); inlineQueue.clear();
        currentSourceHost = QRegularExpression(QStringLiteral("^[a-z0-9-]+\\.wiktionary\\.org$")).match(sourceHost).hasMatch() ? sourceHost : QString();
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
        QSet<QString> inlineFiles;
        QHash<QString, QList<QPair<QJsonObject, QString>>> occurrenceImages;
        QHash<QString, QList<QJsonObject>> blockFigures;
        const auto imageFiles = [&](auto &&visit, const QJsonValue &value) -> void {
            if (value.isObject()) {
                const QJsonObject object = value.toObject();
                if (object.value(QStringLiteral("image")).isObject()) {
                    const auto image = object.value(QStringLiteral("image")).toObject();
                    const QString file = image.value(QStringLiteral("file")).toString();
                    inlineFiles.insert(file);
                    auto &items = occurrenceImages[file];
                    const QPair<QJsonObject, QString> item{image, QString()};
                    if (!items.contains(item)) items.append(item);
                }
                // The stored image span is a semantic branch, not a second inline occurrence.
                if (object.value(QStringLiteral("image_span")).isObject()) {
                    const auto span = object.value(QStringLiteral("image_span")).toObject();
                    const auto image = span.value(QStringLiteral("image")).toObject();
                    const QString file = image.value(QStringLiteral("file")).toString();
                    inlineFiles.insert(file);
                    if (CompiledContent::present(object.value(QStringLiteral("block_media_layout")))) {
                        // The Figure branch has its own source-pinned resources;
                        // never enqueue its original SVG as an inline fallback.
                        try {
                            SemanticHtml::blockMediaResource(object);
                            if (!blockFigures[file].contains(object)) blockFigures[file].append(object);
                        } catch (const std::exception &) { /* The caller receives a visible request refusal. */ }
                    } else {
                        const QPair<QJsonObject, QString> item{image, object.value(QStringLiteral("sizing")).toString()};
                        auto &items = occurrenceImages[file];
                        if (!items.contains(item)) items.append(item);
                    }
                }
                for (auto it = object.begin(); it != object.end(); ++it)
                    if (it.key() != QStringLiteral("image_span") && (it.value().isArray() || it.value().isObject())) visit(visit, it.value());
            } else if (value.isArray()) for (const auto &child : value.toArray()) visit(visit, child);
        };
        imageFiles(imageFiles, entry);
        for (const QJsonValue &value : entry.value(QStringLiteral("media")).toArray()) {
            const QJsonObject media = value.toObject();
            const QString kind = media.value(QStringLiteral("kind")).toString();
            if ((kind != QStringLiteral("image") && kind != QStringLiteral("audio")) ||
                media.value(QStringLiteral("file")).toString().trimmed().isEmpty()) continue;
            const QString canonicalFile = media.value(QStringLiteral("file")).toString();
            struct Variant {
                std::optional<QString> language; QJsonObject poster, pinned;
                bool operator==(const Variant &other) const { return language == other.language && poster == other.poster && pinned == other.pinned; }
            };
            QList<Variant> variants;
            if (kind == QStringLiteral("image")) for (const auto &item : occurrenceImages.value(canonicalFile)) {
                const auto value = item.first.value(QStringLiteral("svg_language"));
                const std::optional<QString> lang = value.isUndefined() || value.isNull() ? std::nullopt : std::optional<QString>(value.toString());
                const Variant variant{lang, item.first.value("static_poster").toObject(), {}};
                if (!variants.contains(variant)) variants.append(variant);
            }
            if (variants.isEmpty()) variants.append(Variant{std::nullopt, {}, {}});
            for (const auto &figure : blockFigures.value(canonicalFile)) {
                const auto image = figure.value("image_span").toObject().value("image").toObject();
                const auto language = image.value("svg_language");
                const std::optional<QString> lang = language.isUndefined() || language.isNull() ? std::nullopt : std::optional<QString>(language.toString());
                for (qreal density : {1.0, 2.0}) {
                    const Variant variant{lang, {}, SemanticHtml::blockMediaRendition(SemanticHtml::blockMediaResource(figure), density)};
                    if (!variants.contains(variant)) variants.append(variant);
                }
            }
            for (const auto &variant : variants) {
            auto *card = new MediaCard(media, cardsBody, inlineFiles.contains(canonicalFile));
            card->svgLanguage = variant.language; card->staticPoster = variant.poster; card->pinnedRendition = variant.pinned;
            for (const auto &figure : blockFigures.value(canonicalFile)) {
                const auto resource = SemanticHtml::blockMediaResource(figure);
                if (variant.pinned == SemanticHtml::blockMediaRendition(resource, 1)
                    || variant.pinned == SemanticHtml::blockMediaRendition(resource, 2)) card->blockFigures.append(figure);
            }
            for (const auto &item : occurrenceImages.value(canonicalFile)) {
                const auto value = item.first.value(QStringLiteral("svg_language"));
                const std::optional<QString> lang = value.isUndefined() || value.isNull() ? std::nullopt : std::optional<QString>(value.toString());
                if (lang == variant.language && item.first.value("static_poster").toObject() == variant.poster) card->occurrences.append(item);
            }
            if (variant.language) {
                card->setTitle(QStringLiteral("SVG language: %1").arg(*variant.language));
                card->display += QStringLiteral(" [SVG %1]").arg(*variant.language);
            }
            if (QRegularExpression(QStringLiteral("^[a-z0-9-]+\\.wiktionary\\.org$")).match(sourceHost).hasMatch()) card->sourceHost = sourceHost;
            card->key = QString::fromLatin1(QCryptographicHash::hash((card->sourceHost + QChar(':') + kind + QChar(':') + card->file).toUtf8(), QCryptographicHash::Sha256).toHex());
            if (variant.language) card->key = QString::fromLatin1(QCryptographicHash::hash((card->key + QChar(':') + *variant.language).toUtf8(), QCryptographicHash::Sha256).toHex());
            else if (!variant.poster.isEmpty()) card->key = QString::fromLatin1(QCryptographicHash::hash((card->key + QChar(':') + resourceKey(card->file, variant.language, variant.poster)).toUtf8(), QCryptographicHash::Sha256).toHex());
            if (!variant.pinned.isEmpty()) card->key = QString::fromLatin1(QCryptographicHash::hash(
                QJsonDocument(QJsonArray{variant.pinned.value("url"), variant.pinned.value("sha256")}).toJson(QJsonDocument::Compact),
                QCryptographicHash::Sha256).toHex());
            card->image->resized = [this, guard = QPointer<MediaCard>(card)] {
                QTimer::singleShot(0, q, [this, guard] {
                    if (guard && (guard->svgLanguage || !guard->staticPoster.isEmpty()) && guard->catalogRequested && !guard->busy) enqueueInline(guard);
                });
            };
            cards.append(card);
            cardsLayout->addWidget(card);
            // Density resources share the existing owned request/cache lifecycle.
            // The catalogue retains its one ordinary card; no density UI is added.
            if (!variant.pinned.isEmpty()) card->hide();
            card->status->setText(allowed(card) ? QStringLiteral("Ready when you are.")
                : QStringLiteral("Enable online %1 above to load this media.").arg(kind == QStringLiteral("image") ? QStringLiteral("images") : QStringLiteral("audio")));
            updateButton(card);
            QObject::connect(card->button, &QPushButton::clicked, q, [this, card] {
                if (!allowed(card) || card->busy) return;
                if (card->svgLanguage || !card->staticPoster.isEmpty()) { card->catalogRequested = true; card->image->show(); }
                if (card->kind == QStringLiteral("audio") && !card->data.isEmpty()) play(card);
                else {
                    if (!card->data.isEmpty() || !card->decodedImage.isNull()) { removeCached(card); card->data.clear(); card->decodedImage = {}; card->vectorImage.reset(); }
                    if (card->kind == QStringLiteral("image") && card->inlineRequested) { card->inlineFailure.clear(); enqueueInline(card); }
                    else load(card);
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
        } // Exact language variants share the existing catalogue and resolver.
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
        const auto collectSpans = [&](const QJsonArray &values, const CompiledContent::Context &context) {
            for (const QJsonValue &value : values) {
                const QJsonObject span = value.toObject();
                const QString ipa = span.value(QStringLiteral("text")).toString();
                if (span.value(QStringLiteral("role")).toString() != QStringLiteral("pronunciation") || seen.contains(ipa)) continue;
                const QString effectiveLanguage = CompiledContent::languageForSpan(span, context);
                const QString ssml = pronunciationSsml(ipa, effectiveLanguage);
                if (ssml.isEmpty()) continue;
                seen.insert(ipa);
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
                QObject::connect(button, &QPushButton::clicked, q, [this, ipa, ssml, effectiveLanguage] {
                    if (speech && activeSpeechKey == ipa) stopSpeech();
                    else say(title, effectiveLanguage, ssml, ipa);
                });
            }
        };
        QList<QPair<QJsonArray, CompiledContent::Context>> pending;
        const auto retainSpans = [&](const QJsonArray &spans, const CompiledContent::Context &context) {
            pending.append({spans, context});
        };
        try {
            CompiledContent::Walker walker(retainSpans, CompiledContent::TableSpans::VisibleBody);
            for (const QJsonValue &section : entry.value(QStringLiteral("sections")).toArray())
                walker.blocks(section.toObject().value(QStringLiteral("blocks")).toArray(), {}, {language});
        } catch (const std::runtime_error &) {
            // Malformed direct caller data must not create partial speech actions.
            return;
        }
        for (const auto &part : pending) collectSpans(part.first, part.second);
    }

    void fail(MediaCard *card, const QString &message) {
        card->busy = false;
        card->progress->hide();
        card->status->setText(message + QStringLiteral(" Try again."));
        updateButton(card);
        card->setAction(QStringLiteral("Retry"));
        card->inlineFailure = message;
        const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
        notifyInline(card);
        if (panel && current) pumpInline();
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
        if (card->inlineRequested && !originalImageSize(info, QStringLiteral("intrinsic_width"), QStringLiteral("intrinsic_height")).isValid()) {
            removeCached(card); return false; // Refresh old manual-cache metadata through the same resolver.
        }
        if (!card->pinnedRendition.isEmpty() && info != pinnedMetadata(card)) { removeCached(card); return false; }
        if (card->pinnedRendition.isEmpty() && card->svgLanguage && !validateRasterMetadata(card, info)) { removeCached(card); return false; }
        if (!card->staticPoster.isEmpty() && !validatePosterMetadata(card, info)) { removeCached(card); return false; }
        const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
        if (!present(card, payload.readAll(), info)) {
            if (!panel || !current) return false;
            removeCached(card);
            return false;
        }
        payload.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
        metadata.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
        card->status->setText(QStringLiteral("Loaded from this device."));
        if (card->inlineRequested) card->data.clear();
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

    bool validateRasterMetadata(MediaCard *card, const QJsonObject &metadata) {
        const auto page = metadata.value(QStringLiteral("svg_page")).toObject();
        const auto info = metadata.value(QStringLiteral("svg_info")).toObject();
        const auto requested = metadata.value(QStringLiteral("svg_requested"));
        if (!card->svgLanguage || !SvgRasterIdentity::axis(requested)) return false;
        const auto bucket = SvgRasterIdentity::rasterWidth(page, card->file, info, *card->svgLanguage, quint32(requested.toDouble()));
        const auto required = rasterDemand(card, info);
        if (!bucket || !required || *bucket < *required || metadata.value(QStringLiteral("url")) != info.value(QStringLiteral("thumburl"))
            || metadata.value(QStringLiteral("svg_language")) != *card->svgLanguage
            || metadata.value(QStringLiteral("original_mime")) != info.value(QStringLiteral("mime"))
            || metadata.value(QStringLiteral("svg_identity")) != SvgRasterIdentity::cacheIdentity(card->file, *card->svgLanguage, info, *bucket)
            || originalImageSize(metadata, QStringLiteral("intrinsic_width"), QStringLiteral("intrinsic_height"))
                != originalImageSize(info, QStringLiteral("width"), QStringLiteral("height"))) return false;
        card->verifiedOriginal = info; card->verifiedPage = page; card->rasterPixels = *bucket;
        return true;
    }
    QJsonObject pinnedMetadata(const MediaCard *card) const {
        const auto &source = card->pinnedRendition;
        return {{QStringLiteral("url"), source.value("url")}, {QStringLiteral("source"), source.value("url")},
            {QStringLiteral("original_mime"), QStringLiteral("image/png")},
            {QStringLiteral("intrinsic_width"), source.value("width")}, {QStringLiteral("intrinsic_height"), source.value("height")},
            {QStringLiteral("pinned_rendition"), source}};
    }
    bool pinnedPixels(MediaCard *card, const QByteArray &bytes, const QJsonObject &metadata, QImage *pixels) const {
        if (card->pinnedRendition.isEmpty() || metadata != pinnedMetadata(card)
            || bytes.isEmpty() || bytes.size() > MaxMediaBytes
            || QString::fromLatin1(QCryptographicHash::hash(bytes, QCryptographicHash::Sha256).toHex()) != card->pinnedRendition.value("sha256").toString()) return false;
        QBuffer buffer; buffer.setData(bytes); if (!buffer.open(QIODevice::ReadOnly)) return false;
        QImageReader reader(&buffer, QByteArrayLiteral("png")); reader.setAutoDetectImageFormat(false); reader.setAutoTransform(false);
        const QSize dimensions = reader.size();
        if (reader.format().toLower() != QByteArrayLiteral("png") || !dimensions.isValid()
            || dimensions.width() != card->pinnedRendition.value("width").toDouble()
            || dimensions.height() != card->pinnedRendition.value("height").toDouble()
            || quint64(dimensions.width()) * quint64(dimensions.height()) > 64 * 1024 * 1024) return false;
        const QImage decoded = reader.read();
        if (decoded.isNull() || decoded.size() != dimensions) return false;
        *pixels = decoded;
        return true;
    }
    void loadPinned(MediaCard *card) {
        const QUrl url(card->pinnedRendition.value("url").toString());
        if (!allowedUrl(url, true)) { fail(card, QStringLiteral("The compiled image address is unsupported.")); return; }
        const auto metadata = pinnedMetadata(card);
        card->status->setText(QStringLiteral("Downloading image..."));
        request(card, url, MaxMediaBytes, [this, card, metadata](const QByteArray &bytes) {
            const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
            if (!present(card, bytes, metadata) || !panel || !current) return;
            writeCached(card);
            if (card->inlineRequested) card->data.clear();
        });
    }

    bool present(MediaCard *card, const QByteArray &bytes, const QJsonObject &metadata) {
        if (card->kind == QStringLiteral("image")) {
            QImage image;
            std::shared_ptr<QSvgRenderer> vector;
            if (!card->pinnedRendition.isEmpty()) {
                if (!pinnedPixels(card, bytes, metadata, &image)) {
                    fail(card, QStringLiteral("The image did not match its compiled rendition.")); return false;
                }
            } else if (!card->svgLanguage && svgMime(metadata.value(QStringLiteral("original_mime")).toString())) {
                // Metadata can describe an SVG whose old cached payload is PNG.
                // Only a successful native SVG parse grants the vector path.
                auto candidate = std::make_shared<QSvgRenderer>();
                candidate->setFramesPerSecond(0); // Before load: no animation timer.
                if (candidate->load(bytes) && candidate->defaultSize().isValid()) {
                    const QSize preview = candidate->defaultSize().scaled(QSize(1280, 800), Qt::KeepAspectRatio);
                    image = QImage(preview, QImage::Format_ARGB32_Premultiplied);
                    if (!image.isNull()) {
                        image.fill(Qt::transparent);
                        QPainter painter(&image);
                        painter.setRenderHint(QPainter::Antialiasing);
                        if (candidate->animated()) candidate->setCurrentFrame(0);
                        candidate->render(&painter, QRectF(QPointF(), preview));
                        vector = std::move(candidate);
                    }
                }
            }
            if (image.isNull()) {
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
                if (!card->staticPoster.isEmpty()) {
                    const auto required = posterDemand(card);
                    const auto expectedHeight = (quint64(card->rasterPixels) * 3 + 2) / 4;
                    if (reader.format().toLower() != QByteArrayLiteral("png") || !required
                        || dimensions.width() != qint64(card->rasterPixels) || dimensions.height() != qint64(expectedHeight)
                        || dimensions.width() < *required || quint64(dimensions.width()) * quint64(dimensions.height()) > 64 * 1024 * 1024) {
                        fail(card, QStringLiteral("The static PNG poster is invalid or undersized.")); return false;
                    }
                } else if (card->svgLanguage) {
                    const auto required = rasterDemand(card, card->verifiedOriginal);
                    const auto expectedHeight = FigureSizing::positiveRound(
                        quint64(card->verifiedOriginal.value(QStringLiteral("height")).toDouble()) * card->rasterPixels,
                        quint64(card->verifiedOriginal.value(QStringLiteral("width")).toDouble()));
                    if (reader.format().toLower() != QByteArrayLiteral("png") || !required || !expectedHeight
                        || dimensions.width() != qint64(card->rasterPixels) || dimensions.height() != qint64(std::max<quint64>(1, *expectedHeight))
                        || dimensions.width() < *required || quint64(dimensions.width()) * quint64(dimensions.height()) > 64 * 1024 * 1024) {
                        fail(card, QStringLiteral("The language-specific SVG raster is invalid or undersized.")); return false;
                    }
                } else reader.setScaledSize(dimensions.scaled(QSize(1280, 800), Qt::KeepAspectRatio));
                image = reader.read();
            }
            if (image.isNull()) {
                fail(card, QStringLiteral("This image could not be opened."));
                return false;
            }
            card->decodedImage = image;
            card->vectorImage = std::move(vector);
            card->intrinsicImage = originalImageSize(metadata, QStringLiteral("intrinsic_width"), QStringLiteral("intrinsic_height"));
            card->image->setImage(image);
            card->image->show();
        }
        card->inlineFailure.clear();
        card->data = bytes;
        card->metadata = metadata;
        card->busy = false;
        card->progress->hide();
        card->status->setText(QStringLiteral("Ready."));
        card->credit->setText(metadata.value(QStringLiteral("credit")).toString());
        card->credit->setVisible(!card->credit->text().isEmpty());
        card->source->show();
        updateButton(card);
        const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
        notifyInline(card);
        if (!panel || !current) return false;
        pumpInline();
        return panel && current;
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
        const QPointer<MediaPanel> panel(q); const QPointer<MediaCard> current(card);
        if (!allowed(card)) return;
        card->inlineFailure.clear();
        if (readCached(card)) {
            if (!panel || !current) return;
            if (card->kind == QStringLiteral("audio")) play(card);
            return;
        }
        if (!panel || !current) return;
        if (card->inlineRequested) { card->data.clear(); card->decodedImage = {}; card->vectorImage.reset(); }
        card->busy = true;
        card->status->setText(QStringLiteral("Finding media..."));
        card->progress->setRange(0, 0);
        card->progress->show();
        updateButton(card);
        notifyInline(card);
        if (!panel || !current) return;
        if (!card->pinnedRendition.isEmpty()) { loadPinned(card); return; }
        resolve(card, 0);
    }

    void resolve(MediaCard *card, int hostIndex, bool rendition = false) {
        const QString host = hostIndex == 0 ? QStringLiteral("commons.wikimedia.org") : card->sourceHost;
        QUrl url(QStringLiteral("https://") + host + QStringLiteral("/w/api.php"));
        QUrlQuery query;
        query.addQueryItem(QStringLiteral("action"), QStringLiteral("query"));
        query.addQueryItem(QStringLiteral("format"), QStringLiteral("json"));
        query.addQueryItem(QStringLiteral("formatversion"), QStringLiteral("2"));
        query.addQueryItem(QStringLiteral("prop"), QStringLiteral("imageinfo"));
        query.addQueryItem(QStringLiteral("iiprop"), (card->svgLanguage || !card->staticPoster.isEmpty()) ? QStringLiteral("url|size|mime|mediatype|sha1|timestamp|thumbmime|extmetadata") : QStringLiteral("url|size|mime|extmetadata"));
        if (!card->staticPoster.isEmpty()) {
            const auto required = posterDemand(card);
            if (!required) { fail(card, QStringLiteral("Invalid static poster request.")); return; }
            card->requestedPixels = *required;
            query.addQueryItem(QStringLiteral("iiurlwidth"), QString::number(*required));
        } else if (!card->svgLanguage) query.addQueryItem(QStringLiteral("iiurlwidth"), QStringLiteral("960"));
        else if (rendition) {
            const auto required = rasterDemand(card, card->verifiedOriginal);
            if (!required) { fail(card, QStringLiteral("The compiled SVG sizing request is unsupported.")); return; }
            card->requestedPixels = *required;
            query.addQueryItem(QStringLiteral("iiurlwidth"), QString::number(*required));
            query.addQueryItem(QStringLiteral("iiurlparam"), QStringLiteral("lang%1-%2px").arg(*card->svgLanguage).arg(*required));
        }
        query.addQueryItem(QStringLiteral("titles"), QStringLiteral("File:") + card->file);
        url.setQuery(query);
        request(card, url, MaxMetadataBytes, [this, card, hostIndex, rendition, requested = card->requestedPixels](const QByteArray &bytes) {
            QJsonParseError error;
            const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
            if (error.error != QJsonParseError::NoError) { fail(card, QStringLiteral("The media server sent an unreadable response.")); return; }
            if ((card->svgLanguage || !card->staticPoster.isEmpty()) && (document.object().contains(QStringLiteral("error")) || document.object().contains(QStringLiteral("warnings")))) {
                fail(card, QStringLiteral("The SVG handler did not accept this rendition request without warnings.")); return;
            }
            const QJsonArray pages = document.object().value(QStringLiteral("query")).toObject().value(QStringLiteral("pages")).toArray();
            QJsonObject info, selectedPage;
            for (const QJsonValue &page : pages) {
                const QJsonArray media = page.toObject().value(QStringLiteral("imageinfo")).toArray();
                if (!media.isEmpty()) { if ((card->svgLanguage || !card->staticPoster.isEmpty()) && (pages.size() != 1 || media.size() != 1)) { fail(card, QStringLiteral("Ambiguous SVG metadata.")); return; } info = media.first().toObject(); selectedPage = page.toObject(); break; }
            }
            if (info.isEmpty()) {
                if (hostIndex == 0 && !card->sourceHost.isEmpty()) resolve(card, 1);
                else fail(card, QStringLiteral("This media is no longer available from Wikimedia."));
                return;
            }
            if (card->svgLanguage) {
                if (!SvgRasterIdentity::original(selectedPage, card->file, info)
                    || (rendition && !SvgRasterIdentity::sameOriginal(card->verifiedOriginal, info))) {
                    fail(card, QStringLiteral("The SVG source identity could not be verified.")); return;
                }
                card->verifiedOriginal = info; card->verifiedPage = selectedPage;
                if (!rendition) { notifyInline(card); resolve(card, hostIndex, true); return; }
                const auto required = rasterDemand(card, info);
                const auto bucket = SvgRasterIdentity::rasterWidth(selectedPage, card->file, info, *card->svgLanguage, requested);
                if (!required || !bucket) { fail(card, QStringLiteral("The server did not return the requested SVG language and resolution.")); return; }
                if (*bucket < *required) { resolve(card, hostIndex, true); return; }
                card->rasterPixels = *bucket;
            }
            if (!card->staticPoster.isEmpty()) {
                if (!posterIdentity(card, selectedPage, info, requested)) { fail(card, QStringLiteral("The static PNG poster identity could not be verified.")); return; }
                card->verifiedOriginal = info; card->verifiedPage = selectedPage;
                card->rasterPixels = quint32(info.value("thumbwidth").toDouble());
            }
            const QUrl mediaUrl((card->svgLanguage || !card->staticPoster.isEmpty()) ? info.value(QStringLiteral("thumburl")).toString() : card->kind == QStringLiteral("image") && !svgMime(info.value(QStringLiteral("mime")).toString())
                && !info.value(QStringLiteral("thumburl")).toString().isEmpty()
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
            if (card->svgLanguage) {
                metadata.insert(QStringLiteral("svg_page"), selectedPage);
                metadata.insert(QStringLiteral("svg_info"), info);
                metadata.insert(QStringLiteral("svg_requested"), double(requested));
                metadata.insert(QStringLiteral("svg_language"), *card->svgLanguage);
                metadata.insert(QStringLiteral("svg_identity"), SvgRasterIdentity::cacheIdentity(card->file, *card->svgLanguage, info, card->rasterPixels));
            }
            if (info.value(QStringLiteral("mime")).isString()) metadata.insert(QStringLiteral("original_mime"), info.value(QStringLiteral("mime")));
            if (!card->staticPoster.isEmpty()) {
                metadata.insert("poster_page", selectedPage); metadata.insert("poster_info", info);
                metadata.insert("poster_requested", double(requested)); metadata.insert("static_poster", card->staticPoster);
            }
            // Source API metadata axes are identity evidence, not STL layout.
            const QSizeF original = !card->staticPoster.isEmpty() ? QSizeF(4, 3)
                : originalImageSize(info, QStringLiteral("width"), QStringLiteral("height"));
            if (original.isValid()) { metadata.insert(QStringLiteral("intrinsic_width"), original.width()); metadata.insert(QStringLiteral("intrinsic_height"), original.height()); }
            else if (card->inlineRequested) { fail(card, QStringLiteral("Original image dimensions are unavailable.")); return; }
            card->status->setText(QStringLiteral("Downloading media..."));
            card->progress->setRange(0, 0);
            request(card, mediaUrl, MaxMediaBytes, [this, card, metadata](const QByteArray &payload) {
                if (payload.isEmpty()) { fail(card, QStringLiteral("The media file was empty.")); return; }
                if (card->svgLanguage) {
                    const auto required = rasterDemand(card, card->verifiedOriginal);
                    if (required && card->rasterPixels < *required) { resolve(card, 0); return; }
                    if (!validateRasterMetadata(card, metadata)) { fail(card, QStringLiteral("The SVG raster transaction did not match its request.")); return; }
                }
                if (!card->staticPoster.isEmpty()) {
                    const auto required = posterDemand(card);
                    if (required && card->rasterPixels < *required) { resolve(card, 0); return; }
                    if (!validatePosterMetadata(card, metadata)) { fail(card, QStringLiteral("The static poster transaction did not match its request.")); return; }
                }
                if (!present(card, payload, metadata)) return;
                writeCached(card);
                // Inline rendering retains shared bounded pixels/parsed vectors and attribution,
                // never up to50MiB of source bytes per visible occurrence. A
                // disabled/failed disk cache does not invalidate decoded pixels.
                if (card->inlineRequested) card->data.clear();
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
MediaPanel::InlineImageAsset MediaPanel::requestInlineImage(const QString &file, QObject *owner, const QString &key,
        std::function<void(const InlineImageAsset &)> changed) { return impl_->inlineImage(QJsonObject{{QStringLiteral("file"), file}}, {}, 1, owner, key, std::move(changed)); }
MediaPanel::InlineImageAsset MediaPanel::requestInlineImage(const QJsonObject &image, const QString &sizing,
        qreal dpr, QObject *owner, const QString &key, std::function<void(const InlineImageAsset &)> changed) {
    return impl_->inlineImage(image, sizing, dpr, owner, key, std::move(changed));
}

MediaPanel::InlineImageAsset MediaPanel::requestBlockImage(const QJsonObject &figure, qreal dpr,
        QObject *owner, const QString &key, std::function<void(const InlineImageAsset &)> changed) {
    return impl_->inlineImage(figure.value("image_span").toObject().value("image").toObject(),
        figure.value("sizing").toString(), dpr, owner, key, std::move(changed), figure);
}

QUrl MediaPanel::inlineImageSource(const QString &compiledTarget, const std::optional<QString> &fragment) const { return impl_->inlineSourceUrl(compiledTarget, fragment); }
bool MediaPanel::openInlineImageSource(const QString &compiledTarget, const std::optional<QString> &fragment) { return impl_->openInlineSource(compiledTarget, fragment); }
void MediaPanel::setEntry(const QJsonObject &entry, const QString &sourceHost) { impl_->setEntry(entry, sourceHost); }
void MediaPanel::sayWord(const QString &title, const QString &languageCode) { impl_->say(title, languageCode); }
void MediaPanel::stopPlayback() { impl_->stopSpeech(); impl_->stopAudio(); }
