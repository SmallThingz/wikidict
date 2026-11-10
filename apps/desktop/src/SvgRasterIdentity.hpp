#pragma once

#include "FigureSizing.hpp"
#include <QCryptographicHash>
#include <QDateTime>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUrl>

// Pure validation used by the existing MediaPanel resolver and its cache.
// These values bind one API metadata/texture transaction, not a historical blob revision.
namespace SvgRasterIdentity {
inline bool language(const QString &value) {
    if (value.isEmpty() || value.toUtf8().size() > 32 * 1024 * 1024) return false;
    bool segment = false;
    for (const auto ch : value) {
        if (ch == QChar('-')) { if (!segment) return false; segment = false; }
        else if (ch >= QChar('a') && ch <= QChar('z')) segment = true;
        else return false;
    }
    return segment;
}
inline bool axis(const QJsonValue &value) {
    const double number = value.toDouble(-1);
    return value.isDouble() && std::isfinite(number) && number > 0 && number <= 4294967295.0 && std::floor(number) == number;
}
inline bool allowed(const QUrl &url) {
    return url.isValid() && url.scheme() == QStringLiteral("https") && url.userInfo().isEmpty()
        && (url.port() == -1 || url.port() == 443) && !url.hasFragment()
        && (url.host() == QStringLiteral("upload.wikimedia.org") || url.host() == QStringLiteral("thumb.wikimedia.org"));
}
inline QString component(const QUrl &url, int index) {
    return QUrl::fromPercentEncoding(url.path(QUrl::FullyEncoded).section(QChar('/'), index, index).toLatin1());
}
inline bool original(const QJsonObject &page, const QString &file, const QJsonObject &info) {
    const QString pageTitle = page.value(QStringLiteral("title")).toString();
    const int separator = pageTitle.indexOf(QChar(':'));
    const QString mime = info.value(QStringLiteral("mime")).toString().toLower();
    const QString sha = info.value(QStringLiteral("sha1")).toString(), time = info.value(QStringLiteral("timestamp")).toString();
    const QUrl url(info.value(QStringLiteral("url")).toString());
    return page.value(QStringLiteral("ns")).isDouble() && page.value(QStringLiteral("ns")).toDouble() == 6
        && separator > 0 && pageTitle.mid(separator + 1).replace(QChar('_'), QChar(' ')) == file
        // A missing local description page can still have positive shared-file
        // imageinfo (the actual RU Logo_NIKE response has missing=true/known=true).
        && !page.contains(QStringLiteral("invalid"))
        && (mime == QStringLiteral("image/svg+xml") || mime == QStringLiteral("image/svg"))
        && info.value(QStringLiteral("mediatype")) == QStringLiteral("DRAWING")
        && axis(info.value(QStringLiteral("width"))) && axis(info.value(QStringLiteral("height")))
        && QRegularExpression(QRegularExpression::anchoredPattern(QStringLiteral("[0-9a-f]{40}"))).match(sha).hasMatch()
        && time.endsWith(QChar('Z')) && QDateTime::fromString(time, Qt::ISODate).isValid()
        && allowed(url) && component(url, -1) == QString(file).replace(QChar(' '), QChar('_'))
        && !info.contains(QStringLiteral("filehidden")) && !info.contains(QStringLiteral("filemissing"))
        && !info.contains(QStringLiteral("suppressed")) && !info.contains(QStringLiteral("thumberror"));
}
inline bool sameOriginal(const QJsonObject &left, const QJsonObject &right) {
    for (const auto &name : {QStringLiteral("sha1"), QStringLiteral("timestamp"), QStringLiteral("width"), QStringLiteral("height"), QStringLiteral("mime"), QStringLiteral("url"), QStringLiteral("mediatype")})
        if (left.value(name) != right.value(name)) return false;
    return true;
}
inline std::optional<quint32> demand(const QJsonObject &image, const QString &sizing, qreal dpr, const QSizeF &originalSize) {
    if (!std::isfinite(dpr) || dpr <= 0) return std::nullopt;
    const auto width = FigureSizing::axis(image.value(QStringLiteral("width_px")));
    const auto height = FigureSizing::axis(image.value(QStringLiteral("height_px")));
    FigureSizing::Policy policy = FigureSizing::Policy::Intrinsic;
    if (sizing == QStringLiteral("requested_fit")) policy = FigureSizing::Policy::RequestedFit;
    else if (sizing == QStringLiteral("requested_fit_cap_original_width")) policy = FigureSizing::Policy::RequestedFitCapOriginalWidth;
    else if (sizing == QStringLiteral("original_width_with_height_bound")) policy = FigureSizing::Policy::OriginalWidthWithHeightBound;
    else if (!sizing.isEmpty() && sizing != QStringLiteral("intrinsic")) return std::nullopt;
    else if (sizing.isEmpty() && width) policy = FigureSizing::Policy::RequestedFit;
    else if (sizing.isEmpty() && height) return std::nullopt; // Existing unproved inline SVG height-only context.
    const auto fit = FigureSizing::resolveOriginal({policy, width, height}, originalSize);
    if (!fit) return std::nullopt;
    const qreal pixels = std::ceil(fit->width() * dpr);
    if (!std::isfinite(pixels) || pixels <= 0 || pixels > 4294967295.0) return std::nullopt;
    return quint32(pixels);
}
inline std::optional<quint32> rasterWidth(const QJsonObject &page, const QString &file, const QJsonObject &info,
                                         const QString &lang, quint32 requested) {
    if (!language(lang) || !requested || !original(page, file, info) ||
        !axis(info.value(QStringLiteral("thumbwidth"))) || info.value(QStringLiteral("thumbwidth")).toDouble() != requested ||
        !axis(info.value(QStringLiteral("thumbheight"))) || info.value(QStringLiteral("thumbmime")) != QStringLiteral("image/png")) return std::nullopt;
    const auto ow = quint64(info.value(QStringLiteral("width")).toDouble()), oh = quint64(info.value(QStringLiteral("height")).toDouble());
    const auto height = FigureSizing::positiveRound(oh * requested, ow);
    if (!height || std::max<quint64>(1, *height) != quint64(info.value(QStringLiteral("thumbheight")).toDouble())) return std::nullopt;
    const auto attributes = info.value(QStringLiteral("thumbattribs")).toObject();
    if (attributes.value(QStringLiteral("width")) != info.value(QStringLiteral("thumbwidth")) ||
        attributes.value(QStringLiteral("height")) != info.value(QStringLiteral("thumbheight"))) return std::nullopt;
    const QUrl source(info.value(QStringLiteral("url")).toString()), thumbnail(info.value(QStringLiteral("thumburl")).toString());
    if (!allowed(thumbnail) || thumbnail.adjusted(QUrl::RemoveQuery) == source.adjusted(QUrl::RemoveQuery)
        || component(thumbnail, -2) != component(source, -1)) return std::nullopt;
    const auto match = QRegularExpression(QRegularExpression::anchoredPattern(QStringLiteral("lang%1-([1-9][0-9]{0,9})px-(.+)\\.png")
        .arg(QRegularExpression::escape(lang)))).match(component(thumbnail, -1));
    if (!match.hasMatch()) return std::nullopt;
    bool ok = false; const auto bucket = match.captured(1).toULongLong(&ok);
    if (!ok || bucket < requested || bucket > 4294967295ULL) return std::nullopt;
    return quint32(bucket);
}
inline QString cacheIdentity(const QString &file, const QString &lang, const QJsonObject &info, quint32 bucket) {
    const QJsonObject identity{{"file", file}, {"svg_language", lang}, {"raster_width", double(bucket)},
        {"url", info.value(QStringLiteral("thumburl"))}, {"sha1", info.value(QStringLiteral("sha1"))},
        {"timestamp", info.value(QStringLiteral("timestamp"))}};
    return QString::fromLatin1(QCryptographicHash::hash(QJsonDocument(identity).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256).toHex());
}
}
