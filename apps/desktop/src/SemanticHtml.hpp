#pragma once

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QHash>
#include <QFontMetricsF>
#include <QAbstractTextDocumentLayout>
#include <QTextBlock>
#include <QTextLayout>
#include <QTextBrowser>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextFragment>
#include <QVector>
#include <cmath>
#include <stdexcept>

// Renderer-owned HTML metadata is transient. Original semantic text and links
// never change, and original tooltips are restored before returning to the UI.
namespace SemanticHtml {
inline const QString markerOpen = QStringLiteral("<span data-wikidict-font-scale=\"");
inline const QString scalePrefix = QStringLiteral("wikidict-font-scale:scaled:");
inline const QString escapedPrefix = QStringLiteral("wikidict-font-scale:escaped:");
inline const QString reservedPrefix = QStringLiteral("wikidict-font-scale:");

enum class Basis { Context, NormalBody };
inline const QString zeroFontFamilyName = QStringLiteral("Wikidict Zero Probe");

inline qreal maximumFontPoints(const QTextDocument *document = nullptr) {
    const QPaintDevice *device = document ? document->documentLayout()->paintDevice() : nullptr;
    const qreal dpi = QFontMetricsF(document ? document->defaultFont() : QFont(), device).fontDpi();
    if (!std::isfinite(dpi) || dpi <= 0) throw std::runtime_error("invalid font device DPI");
    return 10000.0 * 72.0 / dpi;
}

inline qreal boundedFontPoints(qreal base, double scale, qreal maximum, qreal ratio = 1) {
    if (!std::isfinite(base) || base <= 0 || !std::isfinite(scale) || scale <= 0
        || !std::isfinite(ratio) || ratio <= 0 || !std::isfinite(maximum) || maximum <= 0)
        throw std::runtime_error("invalid presentation font size");
    // Division first: a finite semantic scale must never overflow a Qt size.
    if (scale >= maximum / base / ratio) return maximum;
    return (base * ratio) * scale;
}

inline QString scaledText(const QString &html, double scale, const QString &tooltip,
                          Basis basis = Basis::Context, qreal normalBodyPoints = 0,
                          bool small = false, bool superscript = false, bool subscript = false, qreal contextPoints = 0) {
    QJsonObject metadata{{"scale", scale}, {"tooltip", tooltip}};
    if (basis == Basis::NormalBody) {
        metadata.insert(QStringLiteral("basis"), QStringLiteral("normal_body"));
        metadata.insert(QStringLiteral("body_points"), normalBodyPoints);
        metadata.insert(QStringLiteral("legacy_flags"), (small ? 1 : 0) | (superscript ? 2 : 0) | (subscript ? 4 : 0));
    }
    if (basis == Basis::Context && scale > 0 && contextPoints != 0) {
        if (!std::isfinite(contextPoints) || contextPoints <= 0)
            throw std::runtime_error("invalid context font base");
        metadata.insert(QStringLiteral("context_points"), contextPoints);
    }
    const QByteArray payload = QJsonDocument(metadata)
        .toJson(QJsonDocument::Compact).toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    return markerOpen + QString::fromLatin1(payload) + QStringLiteral("\">") + html + QStringLiteral("</span>");
}

struct ScaleInfo {
    double scale;
    QString tooltip;
    Basis basis = Basis::Context;
    qreal normalBodyPoints = 0;
    qreal contextPoints = 0;
    int legacyFlags = 0;
};

inline QString prepare(const QString &html, QHash<QString, ScaleInfo> &markers) {
    QString escaped = html;
    // Escape authored reserved-prefix tooltips BEFORE introducing our markers.
    // Authored text/attributes are HTML-escaped by the emitter and cannot inject
    // the exact renderer-owned data tag. Even a literal marker-like tooltip is
    // restored verbatim, rather than being interpreted as scale provenance.
    escaped.replace(QStringLiteral("title=\"") + reservedPrefix,
        QStringLiteral("title=\"") + escapedPrefix + reservedPrefix);
    QString out;
    qsizetype cursor = 0, at = 0;
    while ((at = escaped.indexOf(markerOpen, cursor)) >= 0) {
        const qsizetype begin = at + markerOpen.size();
        const qsizetype end = escaped.indexOf(QStringLiteral("\">"), begin);
        if (end < 0) throw std::runtime_error("invalid renderer font-scale marker");
        const QByteArray encoded = escaped.mid(begin, end - begin).toLatin1();
        const QByteArray decoded = QByteArray::fromBase64(encoded,
            QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
        if (decoded.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) != encoded)
            throw std::runtime_error("invalid renderer font-scale marker encoding");
        QJsonParseError error;
        const QJsonDocument payload = QJsonDocument::fromJson(decoded, &error);
        const QJsonObject value = payload.object();
        const double scale = value.value(QStringLiteral("scale")).toDouble(-1);
        const QJsonValue basisValue = value.value(QStringLiteral("basis"));
        const bool normalBody = basisValue.isString() && basisValue.toString() == QStringLiteral("normal_body");
        if (error.error != QJsonParseError::NoError || !payload.isObject()
            || !value.value(QStringLiteral("scale")).isDouble() || !std::isfinite(scale)
            || scale < 0 || (!normalBody && scale == 1) || !value.value(QStringLiteral("tooltip")).isString()
            || (!basisValue.isUndefined() && (!basisValue.isString()
                || (basisValue.toString() != QStringLiteral("context") && !normalBody))))
            throw std::runtime_error("invalid renderer font-scale metadata");
        ScaleInfo info{scale, value.value(QStringLiteral("tooltip")).toString()};
        if (normalBody) {
            const QJsonValue body = value.value(QStringLiteral("body_points"));
            const QJsonValue flags = value.value(QStringLiteral("legacy_flags"));
            const double n = flags.toDouble(-1);
            if (!body.isDouble() || !std::isfinite(body.toDouble()) || body.toDouble() <= 0
                || !flags.isDouble() || n < 0 || n > 7 || std::floor(n) != n)
                throw std::runtime_error("invalid normal-body font-scale metadata");
            info.basis = Basis::NormalBody;
            info.normalBodyPoints = body.toDouble();
            info.legacyFlags = int(n);
        }
        if (!normalBody && scale > 0) {
            const QJsonValue context = value.value(QStringLiteral("context_points"));
            if (!context.isUndefined()) {
                if (!context.isDouble() || !std::isfinite(context.toDouble()) || context.toDouble() <= 0)
                    throw std::runtime_error("invalid context font-scale metadata");
                info.contextPoints = context.toDouble();
            }
        }
        const QString token = scalePrefix + QString::fromLatin1(encoded);
        markers.insert(token, info);
        out += escaped.mid(cursor, at - cursor);
        out += QStringLiteral("<span title=\"") + token + QStringLiteral("\">");
        cursor = end + 2;
    }
    out += escaped.mid(cursor);
    return out;
}

inline void normalize(QTextDocument *document, const QHash<QString, ScaleInfo> &markers) {
    struct Edit { int start; int length; QTextCharFormat format; };
    QVector<Edit> edits;
    struct ZeroBlock {
        QTextBlock block;
        QTextCharFormat parent;
        QTextOption option;
        bool leading;
        int characters = 0;
    };
    QHash<int, ZeroBlock> zeroBlocks;
    // This cache belongs to one actual document/font context only. A later
    // reading-size or title resize starts a new setter call and a fresh cache.
    QHash<QString, qreal> remainingLegacyRatios;
    for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (!fragment.isValid()) continue;
            QTextCharFormat format = fragment.charFormat();
            const QString tooltip = format.toolTip();
            const auto marker = markers.constFind(tooltip);
            if (marker != markers.cend()) {
                const bool adjusted = format.hasProperty(QTextFormat::FontSizeAdjustment);
                if (marker->scale == 0) {
                    // Stylesheet rules on outer code/pre can override the HTML family.
                    format.setFontFamilies(QStringList{zeroFontFamilyName});
                    format.clearProperty(QTextFormat::BackgroundBrush);
                    format.setFontWeight(QFont::Normal);
                    format.setFontStyleStrategy(QFont::StyleStrategy(int(format.font().styleStrategy()) | int(QFont::NoFontMerging)));
                    auto zero = zeroBlocks.find(block.position());
                    if (zero == zeroBlocks.end()) {
                        // Hidden browsers can have no laid-out lines yet. Match
                        // QTextDocumentLayout6.12's paragraph policy independently:
                        // default option plus block direction/tabs/alignment and
                        // leading included, without querying a current line.
                        QTextOption option = document->defaultTextOption();
                        const QTextBlockFormat blockFormat = block.blockFormat();
                        if (blockFormat.hasProperty(QTextFormat::LayoutDirection))
                            option.setTextDirection(blockFormat.layoutDirection());
                        option.setTabs(blockFormat.tabPositions());
                        if (blockFormat.hasProperty(QTextFormat::BlockAlignment))
                            option.setAlignment(blockFormat.alignment());
                        zero = zeroBlocks.insert(block.position(), {block, block.charFormat(), option, true, 0});
                    }
                    zero->characters += fragment.length();
                } else {
                    qreal points;
                    if (marker->basis == Basis::NormalBody) {
                        qreal ratio = 1;
                        if (marker->legacyFlags & 1) {
                            QFont bodyFont = document->defaultFont();
                            bodyFont.setPointSizeF(marker->normalBodyPoints);
                            const QString key = bodyFont.toString() + QLatin1Char(':') + QString::number(marker->legacyFlags);
                            const auto cached = remainingLegacyRatios.constFind(key);
                            if (cached != remainingLegacyRatios.cend()) ratio = cached.value();
                            else {
                                // Measure only the finite legacy flag/font combinations
                                // in the NORMAL body context. Heading CSS may replace
                                // <small>'s adjustment in the imported source fragment.
                                QTextDocument bodyControl;
                                bodyControl.setDefaultFont(bodyFont);
                                bodyControl.setDefaultTextOption(document->defaultTextOption());
                                bodyControl.documentLayout()->setPaintDevice(document->documentLayout()->paintDevice());
                                QString legacy = QStringLiteral("X");
                                if (marker->legacyFlags & 1) legacy = QStringLiteral("<small>%1</small>").arg(legacy);
                                if (marker->legacyFlags & 2) legacy = QStringLiteral("<sup>%1</sup>").arg(legacy);
                                if (marker->legacyFlags & 4) legacy = QStringLiteral("<sub>%1</sub>").arg(legacy);
                                bodyControl.setHtml(legacy);
                                const QTextCursor control = bodyControl.find(QStringLiteral("X"));
                                const qreal observed = control.charFormat().font().pointSizeF();
                                if (control.isNull() || !std::isfinite(observed) || observed <= 0)
                                    throw std::runtime_error("unresolved legacy body font-size ratio");
                                ratio = observed / marker->normalBodyPoints;
                                if (!std::isfinite(ratio) || ratio <= 0)
                                    throw std::runtime_error("invalid legacy body font-size ratio");
                                remainingLegacyRatios.insert(key, ratio);
                            }
                        }
                        points = boundedFontPoints(marker->normalBodyPoints, marker->scale, maximumFontPoints(document), ratio);
                    } else {
                        // Qt overrides raw points in adjusted context fragments;
                        // the observed effective font is the unscaled control.
                        points = boundedFontPoints(adjusted || marker->contextPoints == 0 ? format.font().pointSizeF() : marker->contextPoints,
                            marker->scale, maximumFontPoints(document));
                    }
                    if (!std::isfinite(points) || points <= 0)
                        throw std::runtime_error("invalid resolved presentation font size");
                    format.clearProperty(QTextFormat::FontSizeAdjustment);
                    format.clearProperty(QTextFormat::FontPixelSize);
                    format.setFontPointSize(points);
                }
                if (marker->tooltip.isEmpty()) format.clearProperty(QTextFormat::TextToolTip);
                else format.setToolTip(marker->tooltip);
            } else if (tooltip.startsWith(escapedPrefix)) {
                format.setToolTip(tooltip.mid(escapedPrefix.size()));
            } else continue;
            edits.append({fragment.position(), fragment.length(), format});
        }
    }
    QTextCursor cursor(document);
    cursor.beginEditBlock();
    for (const Edit &edit : edits) {
        cursor.setPosition(edit.start);
        cursor.setPosition(edit.start + edit.length, QTextCursor::KeepAnchor);
        cursor.setCharFormat(edit.format);
    }
    struct ParentStrut { QFont font; bool leading; bool designMetrics; qreal height; };
    QVector<ParentStrut> parentStruts;
    for (const ZeroBlock &zero : zeroBlocks) {
        if (zero.characters != zero.block.length() - 1 || zero.characters == 0) continue;
        QTextBlockFormat blockFormat = zero.block.blockFormat();
        // An explicit line-height policy remains authoritative. The normal
        // single-line/minimum cases otherwise lose their only parent-font strut.
        if (blockFormat.lineHeightType() != QTextBlockFormat::SingleHeight
            && blockFormat.lineHeightType() != QTextBlockFormat::MinimumHeight) continue;
        QFont parent = zero.parent.font();
        // The collection has already resolved inherited heading adjustments.
        // Resolving that font again can discard its computed point size mask.
        if (parent.pointSizeF() <= 0 && parent.pixelSize() <= 0)
            parent = parent.resolve(document->defaultFont());
        qreal height = -1;
        for (const ParentStrut &cached : parentStruts)
            if (cached.font == parent && cached.leading == zero.leading && cached.designMetrics == zero.option.useDesignMetrics()) {
                height = cached.height; break;
            }
        if (height < 0) {
            // The character exists only in this measurement layout, never in the
            // product document, copy text or accessibility text. Qt measures its
            // actual parent-font line box; no guessed metric or rounding factor.
            // MinimumHeight is subsequently scaled by the document's device
            // DPI. Measure in Qt's default-layout storage units, not already
            // device-scaled pixels, to avoid applying that scale twice.
            QTextLayout strut(QString(QChar(0x200b)), parent);
            strut.setTextOption(zero.option);
            strut.beginLayout();
            QTextLine line = strut.createLine();
            if (!line.isValid()) throw std::runtime_error("unresolved parent zero-font strut");
            line.setLeadingIncluded(zero.leading);
            line.setLineWidth(1);
            strut.endLayout();
            height = line.height();
            if (!std::isfinite(height) || height <= 0) throw std::runtime_error("invalid parent zero-font strut");
            parentStruts.append({parent, zero.leading, zero.option.useDesignMetrics(), height});
        }
        if (blockFormat.lineHeightType() == QTextBlockFormat::MinimumHeight)
            height = qMax(height, blockFormat.lineHeight());
        blockFormat.setLineHeight(height, QTextBlockFormat::MinimumHeight);
        QTextCursor blockCursor(zero.block);
        blockCursor.setBlockFormat(blockFormat);
    }
    cursor.endEditBlock();
}

inline void setHtml(QTextDocument *document, const QString &html) {
    if (!html.contains(markerOpen)) { document->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    const QString prepared = prepare(html, markers);
    document->setHtml(prepared);
    normalize(document, markers);
}

inline void setHtml(QTextBrowser *browser, const QString &html) {
    if (!html.contains(markerOpen)) { browser->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    const QString prepared = prepare(html, markers);
    browser->setHtml(prepared);
    normalize(browser->document(), markers);
}
} // namespace SemanticHtml
