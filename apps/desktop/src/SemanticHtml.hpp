#pragma once

#include "CompiledImageMap.hpp"
#include "CompiledContent.hpp"
#include "MissingFigurePaint.hpp"
#include "LogicalFlow.hpp"
#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QHash>
#include <QMap>
#include <QSet>
#include <QScopeGuard>
#include <QPointer>
#include <QFontMetricsF>
#include <QJsonArray>
#include <QTextTable>
#include <QTextList>
#include <QTextImageFormat>
#include <QUrl>
#include <QImage>
#include <QDateTime>
#include <algorithm>
#include <limits>
#include <QAbstractTextDocumentLayout>
#include <QTextBlock>
#include <QTextLayout>
#include <QTextBrowser>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextFragment>
#include <QVariant>
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
inline constexpr int sourceRunProperty = QTextFormat::UserProperty + 0x57c0;
inline constexpr int sourceBoundaryProperty = QTextFormat::UserProperty + 0x57c2;
inline const QString paragraphRunOpen = QStringLiteral("<p data-wikidict-source-run=\"");
inline constexpr int spanAdvisoryProperty = QTextFormat::UserProperty + 0x5748;
inline constexpr int spanExpansionProperty = QTextFormat::UserProperty + 0x5749;

inline QString spanExplanation(const QTextCharFormat &format) {
    return format.hasProperty(spanAdvisoryProperty)
        ? format.stringProperty(spanExpansionProperty) : format.toolTip();
}

enum class Basis { Context, NormalBody, CssPx };
enum class FontFeaturePolicy { Legacy, Normal, SevenOn };
inline FontFeaturePolicy fontFeaturePolicy(const QJsonValue &value) {
    if (value.isUndefined() || value.isNull()) return FontFeaturePolicy::Legacy;
    if (value.isString() && value.toString() == QStringLiteral("normal")) return FontFeaturePolicy::Normal;
    if (value.isString() && value.toString() == QStringLiteral("seven_on")) return FontFeaturePolicy::SevenOn;
    throw std::runtime_error("invalid typed font feature policy");
}
inline QMap<QFont::Tag, quint32> fontFeatureMap(FontFeaturePolicy policy) {
    QMap<QFont::Tag, quint32> features;
    if (policy == FontFeaturePolicy::SevenOn)
        for (const auto tag : {QFont::Tag("liga"), QFont::Tag("clig"), QFont::Tag("kern"), QFont::Tag("ccmp"),
                               QFont::Tag("dist"), QFont::Tag("mark"), QFont::Tag("mkmk")}) features.insert(tag, 1);
    return features;
}
inline void applyFontFeatures(QFont &font, FontFeaturePolicy policy) {
    if (policy == FontFeaturePolicy::Legacy) return;
    font.clearFeatures();
    font.setResolveMask(font.resolveMask() | QFont::FeaturesResolved);
    const auto features = fontFeatureMap(policy);
    for (auto it = features.cbegin(); it != features.cend(); ++it) font.setFeature(it.key(), it.value());
    font.setStyleStrategy(QFont::StyleStrategy(int(font.styleStrategy()) & ~int(QFont::PreferNoShaping)));
}
inline void applyFontFeatures(QTextCharFormat &format, FontFeaturePolicy policy, const QFont &ownerFont) {
    if (policy == FontFeaturePolicy::Legacy) return;
    // Earlier size edits may have invalidated the document-resolved font cache.
    const auto strategy = format.font().resolve(ownerFont).styleStrategy();
    format.setFontFeatures(fontFeatureMap(policy));
    format.setFontStyleStrategy(QFont::StyleStrategy(int(strategy) & ~int(QFont::PreferNoShaping)));
}
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

inline qreal cssPixelFontBase(qreal readingPoints) {
    const qreal dpi = QFontMetricsF(QFont()).fontDpi();
    if (!std::isfinite(readingPoints) || readingPoints <= 0 || !std::isfinite(dpi) || dpi <= 0)
        throw std::runtime_error("invalid CSS pixel font origin");
    return (readingPoints / 12.0) * 72.0 / dpi;
}

// Table metadata belongs only to generated semantic HTML, never authored text.
inline const QString tableMarkerOpen = QStringLiteral("<!--wikidict-table-style:");
inline constexpr int tableListOwnerProperty = QTextFormat::UserProperty + 0x5750;
struct TableInfo { int ordinal; QJsonObject value; int empty = -1; };
inline bool present(const QJsonValue &value) { return !value.isUndefined() && !value.isNull(); }
inline QString textAlignment(const QJsonValue &value) {
    if (!present(value)) return {};
    const QString alignment = value.toString();
    if (!value.isString() || (alignment != QStringLiteral("left") && alignment != QStringLiteral("center") && alignment != QStringLiteral("right")))
        throw std::runtime_error("invalid typed text alignment");
    return alignment;
}
inline int cellVerticalAlignment(const QJsonValue &value) {
    if (!present(value)) return -1;
    if (value.isString() && value.toString() == QStringLiteral("top")) return QTextCharFormat::AlignTop;
    if (value.isString() && value.toString() == QStringLiteral("middle")) return QTextCharFormat::AlignMiddle;
    throw std::runtime_error("invalid typed cell vertical alignment");
}
inline QJsonObject typedStyle(const QJsonValue &value, const QStringList &keys) {
    if (!present(value)) return {};
    if (!value.isObject() || value.toObject().isEmpty()) throw std::runtime_error("invalid table style");
    const QJsonObject object = value.toObject();
    bool nonempty = false;
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (!keys.contains(it.key())) throw std::runtime_error("unknown table style field");
        nonempty = nonempty || present(it.value());
    }
    if (!nonempty) throw std::runtime_error("empty table style");
    return object;
}
inline QColor styleColor(const QJsonValue &value) {
    const QString text = value.toString();
    bool valid = value.isString() && text.size() == 7 && text[0] == QChar('#');
    for (const QChar digit : text.mid(1)) valid = valid && ((digit >= QChar('0') && digit <= QChar('9')) || (digit >= QChar('a') && digit <= QChar('f')));
    if (!valid) throw std::runtime_error("invalid style color");
    return QColor(text);
}
inline qreal styleLengthUnits(const QJsonValue &value, const QTextDocument *document, qreal containerPoints) {
    const QJsonObject length = value.toObject();
    const QString unit = length.value(QStringLiteral("unit")).toString();
    const QJsonValue number = length.value(QStringLiteral("value"));
    const double n = number.toDouble(-1);
    if (!value.isObject() || length.size() != 2 || !number.isDouble() || !std::isfinite(n) || n < 0 || n > std::numeric_limits<float>::max()
        || (unit != QStringLiteral("px") && unit != QStringLiteral("em"))
        || !std::isfinite(containerPoints) || containerPoints <= 0) throw std::runtime_error("invalid style length");
    if (n == 0) return 0;
    // A fresh public QFont starts with Qt's environment-selected default DPI.
    const qreal defaultDpi = QFontMetricsF(QFont()).fontDpi();
    if (!std::isfinite(defaultDpi) || defaultDpi <= 0) throw std::runtime_error("invalid default font DPI");
    // QTextDocumentLayout scales stored qreal table metrics by deviceDpi/defaultDpi.
    const qreal maximum = maximumFontPoints(document) * defaultDpi / 72;
    const qreal base = unit == QStringLiteral("em") ? containerPoints * defaultDpi / 72 : 1;
    return boundedFontPoints(base, n, maximum);
}
inline constexpr int tableBoxOwnerProperty = QTextFormat::UserProperty + 0x57d0;
inline constexpr int tableBoxPaddingProperty = QTextFormat::UserProperty + 0x57d1;
inline constexpr int tableBoxClearProperty = QTextFormat::UserProperty + 0x57d2;
inline constexpr int tableBoxWidthProperty = QTextFormat::UserProperty + 0x57d3;
inline constexpr int tableAutoMarginsProperty = QTextFormat::UserProperty + 0x57f1;
inline constexpr int tableCaptionBlockProperty = QTextFormat::UserProperty + 0x57f3;
inline constexpr int emptyTableRoleProperty = QTextFormat::UserProperty + 0x57d4;
inline constexpr int emptyTableBoundaryProperty = QTextFormat::UserProperty + 0x57d5;
inline constexpr int tableDisplayProperty = QTextFormat::UserProperty + 0x57d6;
inline constexpr int tableVerticalAlignProperty = QTextFormat::UserProperty + 0x57d7;
inline constexpr int tableLineHeightProperty = QTextFormat::UserProperty + 0x57d8;
inline constexpr int generatedParentStrutProperty = QTextFormat::UserProperty + 0x57d9;
inline constexpr int cellStylePolicyProperty = QTextFormat::UserProperty + 0x57da;
inline constexpr int cellWidthProperty = QTextFormat::UserProperty + 0x57db;
inline constexpr int cellMinimumWidthProperty = QTextFormat::UserProperty + 0x57dc;
inline constexpr int cellLineHeightProperty = QTextFormat::UserProperty + 0x57dd;
inline constexpr int cellOwnerFontProperty = QTextFormat::UserProperty + 0x57f0;
inline constexpr int tablePhysicalEdgesProperty = QTextFormat::UserProperty + 0x57de;
inline constexpr int cellHiddenEdgesProperty = QTextFormat::UserProperty + 0x57df;
inline const QString cellStyleCapability = QStringLiteral("wikidict.cell-style/1");
struct CellLineInput {
    bool present = false;
    bool strut = false;
    qreal strutPoints = 0;
    QString kind;
    qreal value = 0; // A fixed text length is in the native default-DPI coordinate.
};
inline CellLineInput cellLineHeight(const QJsonValue &value, qreal bodyPoints,
                                    const QTextDocument *document = nullptr) {
    CellLineInput result;
    if (!present(value)) return result;
    const auto object = value.toObject();
    if (!value.isObject() || object.size() != 2 || !object.contains(QStringLiteral("strut"))
        || !object.contains(QStringLiteral("height"))) throw std::runtime_error("invalid cell line-height owner");
    const auto metric = [&](const QJsonValue &input, const QString &number, bool font) {
        const auto spec = input.toObject();
        const auto amount = spec.value(number);
        const auto basis = spec.value(QStringLiteral("font_scale_basis"));
        if (!input.isObject() || spec.size() != 2 || !amount.isDouble()
            || !std::isfinite(amount.toDouble()) || amount.toDouble() < 0
            || amount.toDouble() > std::numeric_limits<float>::max() || !basis.isString()
            || (basis.toString() != QStringLiteral("normal_body") && basis.toString() != QStringLiteral("css_px")))
            throw std::runtime_error("invalid cell text metric");
        const qreal base = basis.toString() == QStringLiteral("css_px") ? cssPixelFontBase(bodyPoints) : bodyPoints;
        if (!std::isfinite(base) || base <= 0) throw std::runtime_error("invalid cell body metric");
        if (amount.toDouble() == 0) return qreal(0);
        if (font) return boundedFontPoints(base, amount.toDouble(), maximumFontPoints(document));
        const qreal resolved = base * amount.toDouble() * QFontMetricsF(QFont()).fontDpi() / 72;
        if (!std::isfinite(resolved)) throw std::runtime_error("unrepresentable cell line height");
        return resolved;
    };
    result.present = true;
    if (present(object.value(QStringLiteral("strut")))) {
        result.strut = true;
        result.strutPoints = metric(object.value(QStringLiteral("strut")), QStringLiteral("font_scale"), true);
    }
    const auto height = object.value(QStringLiteral("height"));
    const auto spec = height.toObject();
    if (!height.isObject() || spec.size() != 1) throw std::runtime_error("invalid cell line-height kind");
    result.kind = spec.keys().first();
    const auto amount = spec.value(result.kind);
    if (result.kind == QStringLiteral("normal")) {
        if (!amount.isObject() || !amount.toObject().isEmpty()) throw std::runtime_error("invalid normal cell height");
    } else if (result.kind == QStringLiteral("multiplier")) {
        if (!amount.isDouble() || !std::isfinite(amount.toDouble()) || amount.toDouble() < 0
            || amount.toDouble() > std::numeric_limits<float>::max()) throw std::runtime_error("invalid cell multiplier");
        result.value = amount.toDouble();
    } else if (result.kind == QStringLiteral("length")) result.value = metric(amount, QStringLiteral("value"), false);
    else throw std::runtime_error("unknown cell line-height kind");
    return result;
}
inline bool cellLineHeightOwner(const QTextBlock &block) {
    for (auto *frame = block.document()->frameAt(block.position()); frame; frame = frame->parentFrame())
        if (auto *table = qobject_cast<QTextTable *>(frame)) {
            const auto cell = table->cellAt(block.position());
            if (cell.isValid() && cell.format().hasProperty(cellLineHeightProperty)) return true;
        }
    return false;
}
inline bool emptyCompiledCell(const QJsonObject &cell) {
    if (present(cell.value(QStringLiteral("nested_table")))) return false;
    if (present(cell.value(QStringLiteral("blocks")))) return cell.value(QStringLiteral("blocks")).isArray()
        && cell.value(QStringLiteral("blocks")).toArray().isEmpty();
    return cell.value(QStringLiteral("spans")).isArray() && cell.value(QStringLiteral("spans")).toArray().isEmpty();
}
inline bool hasExtendedCellStyle(const QJsonObject &style) {
    return style.value(QStringLiteral("border")).toObject().contains(QStringLiteral("edges"))
         || present(style.value(QStringLiteral("border_edges")))
        || present(style.value(QStringLiteral("letter_spacing")))
        || present(style.value(QStringLiteral("width")))
        || present(style.value(QStringLiteral("min_width")))
        || present(style.value(QStringLiteral("line_height")));
}
inline bool hasTableFlowStyle(const QJsonObject &style) {
    return present(style.value(QStringLiteral("display"))) || present(style.value(QStringLiteral("vertical_align")))
        || present(style.value(QStringLiteral("line_height")));
}
inline int tableDisplay(const QJsonObject &style) {
    const auto value = style.value(QStringLiteral("display"));
    if (!present(value)) return 0;
    const int display = QStringList{"table", "inline_block", "inline_table"}.indexOf(value.toString());
    if (!value.isString() || display < 0 || (display && present(style.value(QStringLiteral("float_side")))))
        throw std::runtime_error("invalid inline table display");
    return display;
}
inline QStringList inlineTableClasses(QString value) {
    for (const QChar space : {QChar('\t'), QChar('\r'), QChar('\n'), QChar('\v'), QChar('\f')}) value.replace(space, QChar(' '));
    return value.split(QChar(' '), Qt::SkipEmptyParts);
}
inline QHash<QString, bool> inlineTableMediaOwners(const QJsonArray &media, const QString &kind) {
    QHash<QString, bool> owners;
    for (const auto &value : media) {
        if (!value.isObject()) throw std::runtime_error("invalid inline table media catalog");
        const auto item = value.toObject();
        const QString key = QStringLiteral("wikidict-media-file-") + QString::fromLatin1(item.value(QStringLiteral("file")).toString().toUtf8().toHex());
        const bool valid = !item.value(QStringLiteral("file")).toString().isEmpty() && !owners.contains(key)
            && item.value(QStringLiteral("kind")).toString() == kind;
        owners.insert(key, valid);
    }
    return owners;
}
inline QHash<QString, bool> inlineTableAudioOwners(const QJsonArray &media) {
    return inlineTableMediaOwners(media, QStringLiteral("audio"));
}
inline QHash<QString, bool> inlineTableImageOwners(const QJsonArray &media) {
    return inlineTableMediaOwners(media, QStringLiteral("image"));
}
inline QJsonObject checkedImage(const QJsonValue &value);
inline void validateInlineTableDomain(const QJsonObject &table, int tableDepth, int contentDepth,
                                     bool inReference, const QHash<QString, bool> &audioOwners,
                                     const QHash<QString, bool> &imageOwners = {}) {
    const auto style = table.value(QStringLiteral("style")).toObject();
    const auto alignment = style.value(QStringLiteral("vertical_align"));
    if (present(alignment) && (!alignment.isString()
        || !QStringList{"baseline", "middle", "top"}.contains(alignment.toString())))
        throw std::runtime_error("invalid inline table alignment");
    if (!tableDisplay(style)) {
        if (style.value(QStringLiteral("vertical_align")) == QStringLiteral("top"))
            throw std::runtime_error("top alignment requires an inline table");
        return;
    }
    const auto array = [](const QJsonValue &value) {
        if (present(value) && !value.isArray()) throw std::runtime_error("invalid inline table array");
        return value.toArray();
    };
    if (tableDepth != 1 || contentDepth != 0 || inReference
        || !array(table.value(QStringLiteral("caption"))).isEmpty() || present(table.value(QStringLiteral("caption_blocks"))))
        throw std::runtime_error("unsupported inline table context");
    bool hasCells = false;
    for (const auto &rowValue : array(table.value(QStringLiteral("rows")))) {
        if (!rowValue.isObject()) throw std::runtime_error("invalid inline table row");
        for (const auto &cellValue : array(rowValue.toObject().value(QStringLiteral("cells")))) {
            if (!cellValue.isObject()) throw std::runtime_error("invalid inline table cell");
            hasCells = true; const auto cell = cellValue.toObject();
            if (present(cell.value(QStringLiteral("nested_table"))) || present(cell.value(QStringLiteral("blocks"))))
                throw std::runtime_error("unsupported inline table cell content");
            for (const auto &spanValue : array(cell.value(QStringLiteral("spans")))) {
                if (!spanValue.isObject()) throw std::runtime_error("invalid inline table span");
                const auto span = spanValue.toObject(); const auto classes = inlineTableClasses(span.value(QStringLiteral("classes")).toString());
                QString imageOwner;
                if (present(span.value(QStringLiteral("image")))) {
                    const auto kind = span.value(QStringLiteral("kind"));
                    const auto target = span.value(QStringLiteral("target"));
                    const auto emptyText = [&](const char *key) {
                        const auto value = span.value(QLatin1StringView(key));
                        return !present(value) || (value.isString() && value.toString().isEmpty());
                    };
                    if (!kind.isString() || !emptyText("text") || !emptyText("trail")
                        || (kind == QStringLiteral("text") ? !emptyText("target")
                            : (kind != QStringLiteral("link") && kind != QStringLiteral("external_link"))
                                || !target.isString() || target.toString().isEmpty()))
                        throw std::runtime_error("invalid inline table image action");
                    const auto image = checkedImage(span.value(QStringLiteral("image")));
                    if (present(image.value(QStringLiteral("map"))) || present(image.value(QStringLiteral("static_poster")))
                        || present(image.value(QStringLiteral("dark_mode_filter"))))
                        throw std::runtime_error("unsupported inline table image policy");
                    imageOwner = QStringLiteral("wikidict-media-file-")
                        + QString::fromLatin1(image.value(QStringLiteral("file")).toString().toUtf8().toHex());
                    if (!imageOwners.value(imageOwner, false))
                        throw std::runtime_error("unresolved inline table image owner");
                }
                if (!span.value(QStringLiteral("code")).toBool() && span.value(QStringLiteral("font_scale")).toDouble(1) != 0
                    && classes.contains(QStringLiteral("Egyp"))) {
                    const QString text = span.value(QStringLiteral("kind")).toString() == QStringLiteral("line_break") ? QStringLiteral("\n") : span.value(QStringLiteral("text")).toString();
                    for (const auto scalar : text.toUcs4()) if (scalar >= 0x13000 && scalar <= 0x13455)
                        throw std::runtime_error("unsupported inline table glyph layout");
                }
                if (classes.contains(QStringLiteral("wikidict-media"))) {
                    QStringList owners;
                    for (const auto &token : classes) if (token.startsWith(QStringLiteral("wikidict-media-file-"))) owners.append(token);
                    QString owner;
                    if (owners.size() == 1) owner = owners.first();
                    else if (owners.isEmpty()) {
                        const QString target = span.value(QStringLiteral("target")).toString();
                        if (target.startsWith(QStringLiteral("File:"))) owner = QStringLiteral("wikidict-media-file-")
                            + QString::fromLatin1(QString(target.mid(5)).replace(QChar('_'), QChar(' ')).toUtf8().toHex());
                    }
                    if (!imageOwner.isEmpty()) {
                        if (owner != imageOwner || !imageOwners.value(owner, false))
                            throw std::runtime_error("mismatched inline table image owner");
                    } else if (!audioOwners.value(owner, false)) throw std::runtime_error("unresolved inline table audio owner");
                }
            }
        }
    }
    if (!hasCells) throw std::runtime_error("unsupported empty inline table");
}
inline qreal tableComputedLineHeight(const QJsonValue &value, qreal normalPoints, qreal originPoints) {
    if (!value.isObject()) throw std::runtime_error("invalid computed table line height");
    const auto object = value.toObject();
    for (auto it = object.begin(); it != object.end(); ++it)
        if (it.key() != QStringLiteral("value") && it.key() != QStringLiteral("font_scale_basis"))
            throw std::runtime_error("invalid computed table line height field");
    const auto amount = object.value(QStringLiteral("value"));
    const auto basis = object.value(QStringLiteral("font_scale_basis"));
    if (!amount.isDouble() || !std::isfinite(amount.toDouble()) || amount.toDouble() <= 0
        || amount.toDouble() > std::numeric_limits<float>::max()
        || (!basis.isUndefined() && (!basis.isString() || (basis.toString() != QStringLiteral("context") && basis.toString() != QStringLiteral("normal_body")))))
        throw std::runtime_error("invalid computed table line height");
    const qreal points = basis.toString() == QStringLiteral("normal_body") ? normalPoints : originPoints;
    const qreal height = amount.toDouble() * points * QFontMetricsF(QFont()).fontDpi() / 72;
    if (!std::isfinite(points) || points <= 0 || !std::isfinite(height) || height <= 0 || height >= 1e6)
        throw std::runtime_error("unrepresentable computed table line height");
    return height;
}
inline const QString tableBoxCapability = QStringLiteral("wikidict.table-box/1");
inline const QString emptyTableCapability = QStringLiteral("wikidict.empty-table/1");
inline const QString emptyTableScheme = QStringLiteral("wikidict-empty-table");
inline bool hasTableBoxStyle(const QJsonObject &style) {
    return present(style.value(QStringLiteral("width"))) || present(style.value(QStringLiteral("padding")))
        || present(style.value(QStringLiteral("clear"))) || present(style.value(QStringLiteral("margin_values")))
        || hasTableFlowStyle(style);
}
inline QVariantMap tableBoxLength(const QJsonValue &value, qreal normalBodyPoints, bool allowPercent) {
    const QJsonObject length = value.toObject();
    const QString unit = length.value(QStringLiteral("unit")).toString();
    const QJsonValue number = length.value(QStringLiteral("value"));
    const double amount = number.toDouble(-1);
    if (!value.isObject() || length.size() != 2 || !number.isDouble() || !std::isfinite(amount)
        || amount < 0 || amount > std::numeric_limits<float>::max()
        || (unit != QStringLiteral("px") && unit != QStringLiteral("em")
            && !(allowPercent && unit == QStringLiteral("percent"))))
        throw std::runtime_error("invalid table box length");
    double resolved = amount;
    if (unit == QStringLiteral("em")) {
        const qreal dpi = QFontMetricsF(QFont()).fontDpi();
        if (!std::isfinite(normalBodyPoints) || normalBodyPoints <= 0 || !std::isfinite(dpi) || dpi <= 0)
            throw std::runtime_error("invalid table box typography");
        // The producer already normalized the table's font ratio to body em.
        // Native table layout applies its device scale to these units once.
        resolved = amount * (normalBodyPoints * dpi / 72.0);
    }
    if (!std::isfinite(resolved) || resolved < 0)
        throw std::runtime_error("unrepresentable table box length");
    return {{QStringLiteral("unit"), unit == QStringLiteral("percent") ? QStringLiteral("percent") : QStringLiteral("fixed")},
        {QStringLiteral("value"), resolved}};
}
inline void requireTableBoxLayout(QTextDocument *document, bool empty = false) {
    QPointer<QTextDocument> live(document);
    if (!live) throw std::runtime_error("missing table box document");
    const int revision = live->revision(), count = live->characterCount();
    const QString source = live->toRawText();
    QPointer<QAbstractTextDocumentLayout> layout(live->documentLayout());
    const auto current = [&] {
        if (!live || !layout) return false;
        const auto *active = live->documentLayout();
        return live && layout && active == layout && live->revision() == revision
            && live->characterCount() == count && live->toRawText() == source;
    };
    if (!current()) throw std::runtime_error("replaced table box document");
    const QVariant capability = layout->property(empty ? "_wikidictEmptyTableLayoutCapability" : "_wikidictTableBoxLayoutCapability");
    if (!current() || capability.metaType().id() != QMetaType::QString
        || capability.toString() != (empty ? emptyTableCapability : tableBoxCapability))
        throw std::runtime_error("missing paired table box layout");
}
inline void applyTableAutoMargins(QTextTableFormat &format, const QJsonObject &style, qreal normalBodyPoints, qreal indent) {
    const bool hasMargins = present(style.value(QStringLiteral("margin_values")));
    const auto sourceDirection = style.value(QStringLiteral("containing_direction"));
    if (hasMargins != present(sourceDirection))
        throw std::runtime_error("unpaired table margins and containing direction");
    if (!hasMargins) return;
    if (!sourceDirection.isString() || (sourceDirection != QStringLiteral("ltr") && sourceDirection != QStringLiteral("rtl")))
        throw std::runtime_error("invalid source table containing direction");
    const int containing = sourceDirection == QStringLiteral("rtl") ? int(Qt::RightToLeft) : int(Qt::LeftToRight);
    if (present(style.value(QStringLiteral("margins"))))
        throw std::runtime_error("conflicting table margin representations");
    const auto value = style.value(QStringLiteral("margin_values"));
    if (!value.isObject() || value.toObject().size() != 4)
        throw std::runtime_error("invalid typed table margins");
    QVariantList autos; qreal lengths[4] = {};
    const QString names[] = {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
    for (int i = 0; i < 4; ++i) {
        const auto edge = value.toObject().value(names[i]);
        if (!edge.isObject() || edge.toObject().size() != 1)
            throw std::runtime_error("invalid typed table margin edge");
        const auto tagged = edge.toObject();
        const bool automatic = tagged.contains(QStringLiteral("auto"));
        if (automatic) {
            if ((i != 1 && i != 3) || !tagged.value(QStringLiteral("auto")).isObject()
                || !tagged.value(QStringLiteral("auto")).toObject().isEmpty())
                throw std::runtime_error("invalid automatic table margin");
        } else {
            if (!tagged.contains(QStringLiteral("length"))) throw std::runtime_error("invalid table margin tag");
            lengths[i] = tableBoxLength(tagged.value(QStringLiteral("length")), normalBodyPoints, false)
                .value(QStringLiteral("value")).toDouble();
        }
        autos.append(automatic);
    }
    if (!autos[1].toBool() && !autos[3].toBool()) throw std::runtime_error("table margin values require horizontal auto");
    format.setTopMargin(lengths[0]); format.setRightMargin(lengths[1]);
    format.setBottomMargin(lengths[2]); format.setLeftMargin(lengths[3] + indent);
    format.setProperty(tableAutoMarginsProperty, QVariantMap{
        {QStringLiteral("capability"), QStringLiteral("wikidict.table-auto-margins/1")},
        {QStringLiteral("autos"), autos}, {QStringLiteral("direction"), containing}});
}
inline void applyTableBoxStyle(QTextTableFormat &format, const QJsonObject &style, qreal normalBodyPoints) {
    if (!hasTableBoxStyle(style)) return;
    format.setProperty(tableBoxOwnerProperty, tableBoxCapability);
    if (present(style.value(QStringLiteral("width"))))
        format.setProperty(tableBoxWidthProperty, tableBoxLength(style.value(QStringLiteral("width")), normalBodyPoints, true));
    if (present(style.value(QStringLiteral("padding")))) {
        const QJsonValue value = style.value(QStringLiteral("padding"));
        if (!value.isObject() || value.toObject().size() != 4) throw std::runtime_error("invalid table box padding");
        QVariantList padding;
        for (const auto &edge : {"top", "right", "bottom", "left"})
            padding.append(tableBoxLength(value.toObject().value(QString::fromLatin1(edge)), normalBodyPoints, false).value(QStringLiteral("value")));
        format.setProperty(tableBoxPaddingProperty, padding);
    }
    if (present(style.value(QStringLiteral("clear")))) {
        const QJsonValue value = style.value(QStringLiteral("clear"));
        const int clear = QStringList{"none", "left", "right", "both"}.indexOf(value.toString());
        if (!value.isString() || clear < 0) throw std::runtime_error("invalid table box clear");
        format.setProperty(tableBoxClearProperty, clear);
    }
}
inline bool hasTableBoxes(const QTextDocument *document) {
    const auto visit = [&](auto &&self, const QTextFrame *frame) -> bool {
        if ((qobject_cast<const QTextTable *>(frame) && frame->frameFormat().hasProperty(tableBoxOwnerProperty))
            || frame->frameFormat().stringProperty(tableBoxOwnerProperty) == emptyTableCapability) return true;
        for (const QTextFrame *child : frame->childFrames()) if (self(self, child)) return true;
        return false;
    };
    return document && visit(visit, document->rootFrame());
}
inline constexpr int tableViewportProperty = QTextFormat::UserProperty + 0x57f5;
inline constexpr int tableViewportGridProperty = QTextFormat::UserProperty + 0x57f6;
inline constexpr int tableViewportFormatsProperty = QTextFormat::UserProperty + 0x57f7;
inline constexpr int tableViewportInheritedLineProperty = QTextFormat::UserProperty + 0x57f9;
inline constexpr int tableSourceLanguageProperty = QTextFormat::UserProperty + 0x57fa;
inline const QString tableViewportCapability = QStringLiteral("wikidict.table-block-viewport/1");

inline bool sourceLanguageTag(const QString &tag) {
    const auto parts = tag.split(QChar('-'));
    if (tag.isEmpty() || tag.toUtf8().size() > 32 * 1024 * 1024 || parts.first().size() > 8) return false;
    const auto letter = [](QChar c) { return (c >= QChar('a') && c <= QChar('z')) || (c >= QChar('A') && c <= QChar('Z')); };
    for (const auto c : parts.first()) if (!letter(c)) return false;
    if (parts.first().size() == 1 && (parts.size() < 2 || (parts.first().toLower() != "x" && parts.first().toLower() != "i"))) return false;
    for (const auto &part : parts) {
        if (part.isEmpty() || part.size() > 8) return false;
        for (const auto c : part) if (!letter(c) && !(c >= QChar('0') && c <= QChar('9'))) return false;
    }
    return true;
}

inline QJsonObject flowPlaceholderMetadata(const QString &name) {
    const QUrl url(name);
    CompiledContent::require(url.scheme() == QStringLiteral("wikidict-flow"));
    const auto encoded = url.path().toLatin1();
    const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    CompiledContent::require(error.error == QJsonParseError::NoError && document.isObject()
        && bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded);
    const auto metadata = document.object();
    CompiledContent::require(metadata.value(QStringLiteral("block")).isObject()
        && metadata.value(QStringLiteral("html")).isString() && metadata.value(QStringLiteral("parts")).isArray()
        && metadata.value(QStringLiteral("language")).isString() && metadata.value(QStringLiteral("alignment")).isString());
    return metadata;
}

// Inline image frames have firstPosition == lastPosition + 1. Only the exact
// generated Flow object in an actual caption block may accompany the grid
// during construction; expansion must remove it before final native layout.
inline void validateStagedTableCaption(QTextFrame *frame, QTextFrame *parent, QTextFrame *grid) {
    if (!frame || !parent || !grid || frame == grid || frame->parentFrame() != parent
        || frame->document() != parent->document() || grid->document() != parent->document()
        || qobject_cast<QTextTable *>(frame) || !frame->childFrames().isEmpty()
        || frame->firstPosition() != frame->lastPosition() + 1
        || frame->lastPosition() >= grid->firstPosition())
        throw std::runtime_error("invalid staged table caption frame");
    auto *document = parent->document();
    const int position = frame->lastPosition();
    const auto block = document->findBlock(position);
    if (!block.isValid() || document->frameAt(position) != parent
        || block.blockFormat().stringProperty(tableCaptionBlockProperty) != QStringLiteral("wikidict.table-caption/1")
        || document->characterAt(position) != QChar::ObjectReplacementCharacter)
        throw std::runtime_error("invalid staged table caption position");
    int matches = 0;
    for (auto it = block.begin(); !it.atEnd(); ++it) {
        const auto fragment = it.fragment();
        if (!fragment.isValid() || fragment.position() != position) continue;
        const auto format = fragment.charFormat();
        if (fragment.length() != 1 || !format.isImageFormat() || format.objectIndex() != frame->objectIndex())
            throw std::runtime_error("invalid staged table caption object");
        const auto metadata = flowPlaceholderMetadata(format.toImageFormat().name());
        if (!CompiledContent::contentRole(metadata.value(QStringLiteral("block")).toObject()))
            throw std::runtime_error("invalid staged table caption role");
        ++matches;
    }
    if (matches != 1) throw std::runtime_error("missing staged table caption object");
}

inline QTextFrame *tableViewportConstructionGrid(QTextFrame *owner) {
    if (!owner) throw std::runtime_error("missing table viewport construction owner");
    const auto policy = owner->frameFormat().property(tableViewportProperty).toMap();
    if (policy.value(QStringLiteral("capability")).toString() != tableViewportCapability)
        throw std::runtime_error("invalid table viewport construction capability");
    QTextFrame *grid = nullptr;
    for (auto *child : owner->childFrames()) {
        if (child->frameFormat().property(tableViewportGridProperty) != policy.value(QStringLiteral("source"))) continue;
        if (grid || (!qobject_cast<QTextTable *>(child)
            && child->frameFormat().stringProperty(emptyTableRoleProperty) != QStringLiteral("wrapper")))
            throw std::runtime_error("invalid table viewport construction grid");
        grid = child;
    }
    if (!grid) throw std::runtime_error("missing table viewport construction grid");
    for (auto *child : owner->childFrames()) if (child != grid) validateStagedTableCaption(child, owner, grid);
    return grid;
}

inline QByteArray tableViewportSource(const QJsonObject &metadata) {
    return QJsonDocument(QJsonObject{{QStringLiteral("style"), metadata.value(QStringLiteral("style")).isUndefined()
            ? QJsonValue(QJsonValue::Null) : metadata.value(QStringLiteral("style"))},
        {QStringLiteral("block_viewport"), metadata.value(QStringLiteral("block_viewport"))}}).toJson(QJsonDocument::Compact);
}

inline QJsonObject tableBlockViewport(const QJsonObject &table) {
    const auto value = table.value(QStringLiteral("block_viewport"));
    if (!present(value)) return {};
    const auto policy = value.toObject();
    const QStringList fields{"max_viewport_width_px", "box_style", "box_sizing", "max_width", "grid_style", "grid_direction", "language"};
    if (!value.isObject() || policy.size() != fields.size())
        throw std::runtime_error("invalid table block viewport");
    for (const auto &field : fields) if (!policy.contains(field))
        throw std::runtime_error("incomplete table block viewport");
    const auto language = policy.value(QStringLiteral("language"));
    if (!language.isString() || !sourceLanguageTag(language.toString()))
        throw std::runtime_error("invalid table source language");
    const auto threshold = policy.value(QStringLiteral("max_viewport_width_px"));
    if (!threshold.isDouble() || !std::isfinite(threshold.toDouble()) || threshold.toDouble() < 0
        || threshold.toDouble() > 4294967295.0 || std::floor(threshold.toDouble()) != threshold.toDouble())
        throw std::runtime_error("invalid table viewport threshold");
    const auto sizing = policy.value(QStringLiteral("box_sizing"));
    const auto direction = policy.value(QStringLiteral("grid_direction"));
    if (!sizing.isString() || (sizing != QStringLiteral("content_box") && sizing != QStringLiteral("border_box"))
        || !direction.isString() || (direction != QStringLiteral("ltr") && direction != QStringLiteral("rtl")))
        throw std::runtime_error("invalid table viewport box or grid direction");
    const QStringList styleFields{"background", "border", "collapse", "margins", "margin_values", "containing_direction",
        "float_side", "width", "padding", "clear", "display", "vertical_align", "line_height"};
    const auto wide = typedStyle(table.value(QStringLiteral("style")), styleFields);
    const auto box = typedStyle(policy.value(QStringLiteral("box_style")), styleFields);
    const auto grid = typedStyle(policy.value(QStringLiteral("grid_style")), styleFields);
    if (present(table.value(QStringLiteral("geometry"))) || present(wide.value(QStringLiteral("float_side")))
        || tableDisplay(wide) != 0 || !policy.value(QStringLiteral("box_style")).isObject()
        || !policy.value(QStringLiteral("grid_style")).isObject())
        throw std::runtime_error("unsupported table viewport header");
    for (const auto &key : {"margins", "float_side", "display", "vertical_align", "collapse", "line_height"})
        if (present(box.value(QLatin1StringView(key)))) throw std::runtime_error("invalid table viewport box field");
    for (const auto &key : {"background", "border", "padding", "width", "margins", "margin_values", "containing_direction",
                            "float_side", "clear", "display", "vertical_align"})
        if (present(grid.value(QLatin1StringView(key)))) throw std::runtime_error("invalid anonymous table grid field");
    if (grid.value(QStringLiteral("collapse")) != QStringLiteral("collapse"))
        throw std::runtime_error("anonymous table grid requires proved collapse");
    // These calls validate the typed lengths without using a reader/font guess.
    // Em resolution is performed later with the same authenticated owner points.
    const auto width = tableBoxLength(box.value(QStringLiteral("width")), 12, true);
    tableBoxLength(policy.value(QStringLiteral("max_width")), 12, true);
    if (width.value(QStringLiteral("value")).toDouble() <= 0)
        throw std::runtime_error("table viewport width must be positive");
    QTextTableFormat margins;
    applyTableAutoMargins(margins, box, 12, 0);
    if (!margins.hasProperty(tableAutoMarginsProperty))
        throw std::runtime_error("table viewport requires source automatic margins");
    return policy;
}

inline bool hasTableBlockViewports(const QTextDocument *document) {
    if (!document) return false;
    QVector<QTextFrame *> pending{document->rootFrame()};
    while (!pending.isEmpty()) {
        const auto *frame = pending.takeLast();
        if (frame->frameFormat().hasProperty(tableViewportProperty)) return true;
        for (auto *child : frame->childFrames()) pending.append(child);
    }
    return false;
}

inline void reflowTableBlockViewports(QTextDocument *document, qreal viewportCssWidth) {
    if (!document || !std::isfinite(viewportCssWidth) || viewportCssWidth < 0)
        throw std::runtime_error("invalid table CSS viewport");
    QPointer<QTextDocument> live(document);
    QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
    const auto capability = native ? native->property("_wikidictTableBlockViewportCapability") : QVariant();
    if (!live || !native || live->documentLayout() != native || capability.metaType().id() != QMetaType::QString
        || capability.toString() != tableViewportCapability)
        throw std::runtime_error("missing paired table viewport layout");
    QVector<QPointer<QTextFrame>> owners;
    const auto collect = [&](auto &&self, QTextFrame *frame) -> void {
        if (frame->frameFormat().hasProperty(tableViewportProperty)) owners.append(frame);
        for (auto *child : frame->childFrames()) self(self, child);
    };
    collect(collect, document->rootFrame());
    for (const auto &owner : owners) {
        if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native)
            throw std::runtime_error("replaced table viewport owner");
        const auto state = owner->frameFormat().property(tableViewportFormatsProperty).toMap();
        auto policy = owner->frameFormat().property(tableViewportProperty).toMap();
        const bool active = viewportCssWidth <= policy.value(QStringLiteral("threshold")).toDouble();
        if (policy.value(QStringLiteral("active")).metaType().id() != QMetaType::Bool)
            throw std::runtime_error("invalid table viewport state");
        const auto children = owner->childFrames();
        if (children.size() != 1)
            throw std::runtime_error("invalid table viewport grid identity");
        const QPointer<QTextFrame> grid(children.first());
        const auto current = [&] {
            return live && native && owner && grid && live->documentLayout() == native
                && grid->document() == live && grid->parentFrame() == owner;
        };
        if (grid->frameFormat().property(tableViewportGridProperty) != policy.value(QStringLiteral("source")))
            throw std::runtime_error("foreign table viewport grid");
        if (active == policy.value(QStringLiteral("active")).toBool()) continue;
        const QString ownerKey = active ? QStringLiteral("box") : QStringLiteral("wide_owner");
        const QString gridKey = active ? QStringLiteral("grid") : QStringLiteral("wide_grid");
        if (state.value(ownerKey).metaType().id() != QMetaType::QTextFormat
            || state.value(gridKey).metaType().id() != QMetaType::QTextFormat)
            throw std::runtime_error("invalid table viewport format state");
        auto format = state.value(ownerKey).value<QTextFormat>().toFrameFormat();
        policy.insert(QStringLiteral("active"), active);
        format.setProperty(tableViewportProperty, policy);
        format.setProperty(tableViewportFormatsProperty, state);
        owner->setFrameFormat(format);
        if (!current()) throw std::runtime_error("replaced table viewport during reflow");
        const auto gridFormat = state.value(gridKey).value<QTextFormat>();
        if (auto *real = qobject_cast<QTextTable *>(grid.data())) real->setFormat(gridFormat.toTableFormat());
        else {
            if (grid->frameFormat().stringProperty(emptyTableRoleProperty) != QStringLiteral("wrapper")
                || grid->childFrames().size() != 1
                || grid->childFrames().first()->frameFormat().stringProperty(emptyTableRoleProperty) != QStringLiteral("grid"))
                throw std::runtime_error("invalid empty viewport grid during reflow");
            grid->setFrameFormat(gridFormat.toFrameFormat());
            if (!current()) throw std::runtime_error("replaced empty table viewport during reflow");
            const auto emptyFormat = state.value(active ? QStringLiteral("empty_grid") : QStringLiteral("empty_wide"));
            if (emptyFormat.metaType().id() != QMetaType::QTextFormat)
                throw std::runtime_error("invalid empty viewport grid state");
            grid->childFrames().first()->setFrameFormat(emptyFormat.value<QTextFormat>().toFrameFormat());
        }
        if (!current()) throw std::runtime_error("replaced table viewport grid during reflow");
        if (auto *real = qobject_cast<QTextTable *>(grid.data())) {
            const auto backgrounds = state.value(QStringLiteral("cell_backgrounds")).toList();
            for (const auto &item : backgrounds) {
                const auto saved = item.toMap();
                auto cell = real->cellAt(saved.value(QStringLiteral("row")).toInt(), saved.value(QStringLiteral("column")).toInt());
                if (!cell.isValid() || cell.row() != saved.value(QStringLiteral("row")).toInt()
                    || cell.column() != saved.value(QStringLiteral("column")).toInt()
                    || saved.value(QStringLiteral("brush")).metaType().id() != QMetaType::QBrush)
                    throw std::runtime_error("changed table viewport cell owner");
                auto cellFormat = cell.format().toTableCellFormat();
                cellFormat.setBackground(active && !saved.value(QStringLiteral("authored")).toBool()
                    ? QBrush(Qt::NoBrush) : saved.value(QStringLiteral("brush")).value<QBrush>());
                cell.setFormat(cellFormat);
                if (!current()) throw std::runtime_error("replaced table viewport cell during reflow");
            }
        }
        for (auto block = document->findBlock(grid->firstPosition()); block.isValid() && block.position() < grid->lastPosition(); block = block.next()) {
            auto blockFormat = block.blockFormat();
            if (blockFormat.property(tableViewportInheritedLineProperty) != policy.value(QStringLiteral("source"))) continue;
            if (gridFormat.hasProperty(tableLineHeightProperty))
                blockFormat.setProperty(tableLineHeightProperty, gridFormat.property(tableLineHeightProperty));
            else blockFormat.clearProperty(tableLineHeightProperty);
            QTextCursor cursor(block); cursor.setBlockFormat(blockFormat);
            if (!current()) throw std::runtime_error("replaced table viewport text during reflow");
        }
    }
}

inline constexpr int tableFloatViewportProperty = QTextFormat::UserProperty + 0x57fb;
inline constexpr int tableFloatViewportFillerProperty = QTextFormat::UserProperty + 0x57fc;
inline const QString tableFloatViewportCapability = QStringLiteral("wikidict.table-float-viewport/1");

inline QJsonObject tableFloatViewport(const QJsonObject &table) {
    const auto value = table.value(QStringLiteral("float_viewport"));
    if (!present(value)) return {};
    const auto policy = value.toObject();
    const QStringList fields{"max_viewport_width_px", "containing_direction", "grid_direction", "language"};
    if (!value.isObject() || policy.size() != fields.size())
        throw std::runtime_error("invalid table float viewport");
    for (const auto &field : fields) if (!policy.contains(field))
        throw std::runtime_error("incomplete table float viewport");
    const auto threshold = policy.value(QStringLiteral("max_viewport_width_px"));
    if (!threshold.isDouble() || !std::isfinite(threshold.toDouble()) || threshold.toDouble() <= 0
        || threshold.toDouble() > 4294967295.0 || std::floor(threshold.toDouble()) != threshold.toDouble())
        throw std::runtime_error("invalid table float viewport threshold");
    for (const auto &key : {"containing_direction", "grid_direction"}) {
        const auto direction = policy.value(QLatin1StringView(key));
        if (!direction.isString() || (direction != QStringLiteral("ltr") && direction != QStringLiteral("rtl")))
            throw std::runtime_error("invalid table float viewport direction");
    }
    const auto language = policy.value(QStringLiteral("language"));
    if (!language.isString() || !sourceLanguageTag(language.toString()))
        throw std::runtime_error("unsupported table float viewport source language");
    const auto style = typedStyle(table.value(QStringLiteral("style")), {"background", "border", "collapse", "margins",
        "margin_values", "containing_direction", "float_side", "width", "padding", "clear", "display", "vertical_align", "line_height"});
    if (present(table.value(QStringLiteral("geometry"))) || present(table.value(QStringLiteral("block_viewport")))
        || !table.value(QStringLiteral("caption")).toArray().isEmpty() || present(table.value(QStringLiteral("caption_blocks")))
        || style.value(QStringLiteral("float_side")) != QStringLiteral("right"))
        throw std::runtime_error("unsupported table float viewport owner");
    for (const auto &key : {"width", "padding", "margin_values", "containing_direction", "display", "vertical_align", "line_height"})
        if (present(style.value(QLatin1StringView(key)))) throw std::runtime_error("unsupported table float viewport style");
    const auto margins = style.value(QStringLiteral("margins"));
    if (!margins.isObject() || margins.toObject().size() != 4)
        throw std::runtime_error("missing fixed table float viewport margins");
    for (const auto &side : {"top", "right", "bottom", "left"})
        tableBoxLength(margins.toObject().value(QLatin1StringView(side)), 12, false);
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    if (!hasCell) throw std::runtime_error("unsupported empty table float viewport");
    return policy;
}

inline void materializeTableFloatViewport(QTextDocument *document, QTextTable *table,
                                         const QJsonObject &metadata, qreal points) {
    QPointer<QTextDocument> live(document);
    QPointer<QAbstractTextDocumentLayout> native(document ? document->documentLayout() : nullptr);
    QPointer<QTextTable> owner(table);
    const auto capability = native ? native->property("_wikidictTableFloatViewportCapability") : QVariant();
    if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native
        || capability.metaType().id() != QMetaType::QString || capability.toString() != tableFloatViewportCapability)
        throw std::runtime_error("missing paired table float viewport layout");
    const auto policy = metadata.value(QStringLiteral("float_viewport")).toObject();
    const auto language = policy.value(QStringLiteral("language")).toString();
    const auto style = metadata.value(QStringLiteral("style")).toObject();
    const auto source = QJsonDocument(QJsonObject{{QStringLiteral("style"), style},
        {QStringLiteral("float_viewport"), policy},
        {QStringLiteral("rows"), metadata.value(QStringLiteral("rows"))}}).toJson(QJsonDocument::Compact);
    auto format = owner->format();
    if (format.hasProperty(tableAutoMarginsProperty) || format.hasProperty(tableViewportProperty)
        || format.hasProperty(tableViewportGridProperty) || format.hasProperty(QTextFormat::UserProperty + 0x57f4)
        || format.intProperty(tableDisplayProperty) != 0 || format.position() != QTextFrameFormat::FloatRight)
        throw std::runtime_error("foreign table float viewport format");
    QVariantList margins;
    for (const auto &side : {"top", "right", "bottom", "left"})
        margins.append(tableBoxLength(style.value(QStringLiteral("margins")).toObject().value(QLatin1StringView(side)),
                                     points, false).value(QStringLiteral("value")));
    format.setTopMargin(margins[0].toDouble()); format.setRightMargin(margins[1].toDouble());
    format.setBottomMargin(margins[2].toDouble()); format.setLeftMargin(margins[3].toDouble());
    format.clearProperty(QTextFormat::BlockAlignment);
    format.setLayoutDirection(policy.value(QStringLiteral("grid_direction")) == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight);
    format.setProperty(tableSourceLanguageProperty, language);
    auto base = format; base.clearProperty(QTextFormat::ObjectIndex);
    const qreal bodyPixels = points * QFontMetricsF(QFont()).fontDpi() / 72.0;
    if (!std::isfinite(bodyPixels) || bodyPixels <= 0)
        throw std::runtime_error("invalid table float viewport body metric");
    format.setProperty(tableFloatViewportProperty, QVariantMap{
        {QStringLiteral("capability"), tableFloatViewportCapability}, {QStringLiteral("source"), source},
        {QStringLiteral("threshold"), policy.value(QStringLiteral("max_viewport_width_px")).toDouble()},
        {QStringLiteral("viewport"), policy.value(QStringLiteral("max_viewport_width_px")).toDouble() + 1.0},
        {QStringLiteral("active"), false}, {QStringLiteral("body_pixels"), bodyPixels},
        {QStringLiteral("direction"), int(policy.value(QStringLiteral("containing_direction")) == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)},
        {QStringLiteral("grid_direction"), int(format.layoutDirection())}, {QStringLiteral("language"), language},
        {QStringLiteral("margins"), margins}, {QStringLiteral("base_format"), QVariant::fromValue(QTextFormat(base))}});
    owner->setFormat(format);
    if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native)
        throw std::runtime_error("replaced table float viewport during construction");
}

inline bool hasTableFloatViewports(const QTextDocument *document) {
    if (!document) return false;
    const auto visit = [&](auto &&self, const QTextFrame *frame) -> bool {
        if (frame->frameFormat().hasProperty(tableFloatViewportProperty)) return true;
        for (auto *child : frame->childFrames()) if (self(self, child)) return true;
        return false;
    };
    return visit(visit, document->rootFrame());
}

inline void reflowTableFloatViewports(QTextDocument *document, qreal viewportCssWidth) {
    if (!document || !std::isfinite(viewportCssWidth) || viewportCssWidth < 0)
        throw std::runtime_error("invalid table float CSS viewport");
    QPointer<QTextDocument> live(document);
    QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
    const auto capability = native ? native->property("_wikidictTableFloatViewportCapability") : QVariant();
    if (!live || !native || live->documentLayout() != native || capability.metaType().id() != QMetaType::QString
        || capability.toString() != tableFloatViewportCapability)
        throw std::runtime_error("missing paired table float viewport layout");
    QVector<QPointer<QTextTable>> owners;
    const auto collect = [&](auto &&self, QTextFrame *frame) -> void {
        if (frame->frameFormat().hasProperty(tableFloatViewportProperty)) {
            auto *table = qobject_cast<QTextTable *>(frame);
            if (!table) throw std::runtime_error("foreign table float viewport owner");
            owners.append(table);
        }
        for (auto *child : frame->childFrames()) self(self, child);
    };
    collect(collect, document->rootFrame());
    for (const auto &owner : owners) {
        if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native)
            throw std::runtime_error("replaced table float viewport");
        auto format = owner->format();
        const auto raw = format.property(tableFloatViewportProperty);
        auto policy = raw.toMap();
        if (raw.metaType().id() != QMetaType::QVariantMap || policy.size() != 11
            || policy.value(QStringLiteral("capability")).metaType().id() != QMetaType::QString
            || policy.value(QStringLiteral("capability")).toString() != tableFloatViewportCapability
            || policy.value(QStringLiteral("threshold")).metaType().id() != QMetaType::Double
            || policy.value(QStringLiteral("viewport")).metaType().id() != QMetaType::Double
            || policy.value(QStringLiteral("active")).metaType().id() != QMetaType::Bool
            || policy.value(QStringLiteral("base_format")).metaType().id() != QMetaType::QTextFormat)
            throw std::runtime_error("invalid table float viewport state");
        const bool active = viewportCssWidth <= policy.value(QStringLiteral("threshold")).toDouble();
        auto expected = policy.value(QStringLiteral("base_format")).value<QTextFormat>().toTableFormat();
        expected.setPosition(policy.value(QStringLiteral("active")).toBool() ? QTextFrameFormat::InFlow : QTextFrameFormat::FloatRight);
        auto current = format; current.clearProperty(QTextFormat::ObjectIndex); current.clearProperty(tableFloatViewportProperty);
        if (QTextFormat(current) != QTextFormat(expected)) throw std::runtime_error("changed table float viewport format");
        if (policy.value(QStringLiteral("viewport")).toDouble() == viewportCssWidth) continue;
        policy.insert(QStringLiteral("viewport"), viewportCssWidth); policy.insert(QStringLiteral("active"), active);
        format.setPosition(active ? QTextFrameFormat::InFlow : QTextFrameFormat::FloatRight);
        format.setProperty(tableFloatViewportProperty, policy);
        owner->setFormat(format);
        if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native)
            throw std::runtime_error("replaced table float viewport during reflow");
    }
}

inline QString tableStyleMarker(const QJsonObject &table, qreal containerPoints, int indent, bool resetTextAlignment = false,
                                const QString &listMarker = {}, int tableDepth = 1, qreal tableOriginPoints = -1) {
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    const auto viewport = tableBlockViewport(table);
    const auto floatViewport = tableFloatViewport(table);
    if (!floatViewport.isEmpty() && (indent != 0 || !listMarker.isEmpty() || tableDepth != 1))
        throw std::runtime_error("unsupported table float viewport containing context");
    bool styled = !viewport.isEmpty() || !listMarker.isEmpty() || resetTextAlignment || present(table.value(QStringLiteral("style")))
        || (!hasCell && present(table.value(QStringLiteral("geometry"))));
    if (!styled) {
        for (const QJsonValue &row : table.value(QStringLiteral("rows")).toArray())
            for (const QJsonValue &cell : row.toObject().value(QStringLiteral("cells")).toArray())
                styled = styled || present(cell.toObject().value(QStringLiteral("style")));
    }
    if (!styled && !hasCell) return {};
    QJsonArray rows;
    for (const QJsonValue &rowValue : table.value(QStringLiteral("rows")).toArray()) {
        QJsonArray cells;
        for (const QJsonValue &cellValue : rowValue.toObject().value(QStringLiteral("cells")).toArray()) {
            const QJsonObject cell = cellValue.toObject();
            QJsonObject shape{{"rowspan", qMax(1, cell.value(QStringLiteral("rowspan")).toInt(1))},
                {"colspan", qMax(1, cell.value(QStringLiteral("colspan")).toInt(1))}};
            if (present(cell.value(QStringLiteral("style")))) { shape.insert(QStringLiteral("style"), cell.value(QStringLiteral("style"))); styled = true; }
            if (!viewport.isEmpty()) shape.insert(QStringLiteral("background"), cell.value(QStringLiteral("background")).isUndefined()
                ? QJsonValue(QJsonValue::Null) : cell.value(QStringLiteral("background")));
            if (present(cell.value(QStringLiteral("style")).toObject().value(QStringLiteral("line_height")))) {
                shape.insert(QStringLiteral("header"), cell.value(QStringLiteral("header")).toBool());
                shape.insert(QStringLiteral("empty_content"), emptyCompiledCell(cell));
            }
            cells.append(shape);
        }
        rows.append(cells);
    }
    if (!styled && !hasCell) return {};
    QJsonObject metadata{{"container_points", containerPoints}, {"indent", indent}, {"rows", rows}};
    metadata.insert(QStringLiteral("empty_nested"), tableDepth > 1);
    if (!viewport.isEmpty()) metadata.insert(QStringLiteral("block_viewport"), viewport);
    if (!floatViewport.isEmpty()) metadata.insert(QStringLiteral("float_viewport"), floatViewport);
    if (hasTableFlowStyle(table.value(QStringLiteral("style")).toObject())) {
        metadata.insert(QStringLiteral("table_origin_points"), tableOriginPoints > 0 ? tableOriginPoints : containerPoints);
        const int display = tableDisplay(table.value(QStringLiteral("style")).toObject());
        if (display && (!hasCell || !table.value(QStringLiteral("caption")).toArray().isEmpty()
            || present(table.value(QStringLiteral("caption_blocks")))))
            throw std::runtime_error("unsupported inline table caption or empty grid");
    }
    if (present(table.value(QStringLiteral("geometry")))) metadata.insert(QStringLiteral("empty_geometry"), table.value(QStringLiteral("geometry")));
    if (!listMarker.isEmpty()) metadata.insert(QStringLiteral("list_marker"), listMarker);
    if (resetTextAlignment) metadata.insert(QStringLiteral("reset_text_alignment"), true);
    if (present(table.value(QStringLiteral("style")))) metadata.insert(QStringLiteral("style"), table.value(QStringLiteral("style")));
    return tableMarkerOpen + QString::fromLatin1(QJsonDocument(metadata).toJson(QJsonDocument::Compact).toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)) + QStringLiteral("-->");
}
inline QString prepareTables(const QString &html, QVector<TableInfo> &tables, int &tableCount) {
    QString out; out.reserve(html.size()); tableCount = 0;
    QVector<bool> materialized; QVector<int> stack;
    QVector<QPair<qsizetype, qsizetype>> bounds;
    const auto tag = [&](qsizetype at, const QString &name) {
        return html.mid(at, name.size()) == name && at + name.size() < html.size()
            && (html[at + name.size()].isSpace() || html[at + name.size()] == QChar('>'));
    };
    for (qsizetype i = 0; i < html.size();) {
        if (html.mid(i, tableMarkerOpen.size()) == tableMarkerOpen) {
            const qsizetype begin = i + tableMarkerOpen.size(), end = html.indexOf(QStringLiteral("-->"), begin);
            if (end < 0 || !tag(end + 3, QStringLiteral("<table"))) throw std::runtime_error("invalid table style placement");
            const QByteArray encoded = html.mid(begin, end - begin).toLatin1();
            const QByteArray bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
            QJsonParseError error; const QJsonDocument value = QJsonDocument::fromJson(bytes, &error);
            if (bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) != encoded || error.error != QJsonParseError::NoError || !value.isObject())
                throw std::runtime_error("invalid table style metadata");
            tables.append({int(materialized.size()), value.object()}); i = end + 3; continue;
        }
        if (tag(i, QStringLiteral("<table"))) {
            stack.append(int(materialized.size())); materialized.append(false); bounds.append({out.size(), -1});
        }
        else if (tag(i, QStringLiteral("<td")) || tag(i, QStringLiteral("<th"))) {
            if (stack.isEmpty()) throw std::runtime_error("table style cell outside table");
            materialized[stack.last()] = true;
        } else if (tag(i, QStringLiteral("</table"))) {
            if (stack.isEmpty()) throw std::runtime_error("unbalanced table style HTML");
            const qsizetype close = html.indexOf(QChar('>'), i);
            if (close < 0) throw std::runtime_error("unterminated table style HTML");
            bounds[stack.last()].second = out.size() + close - i + 1;
            stack.removeLast();
        }
        out += html[i++];
    }
    if (!stack.isEmpty()) throw std::runtime_error("unbalanced table style HTML");
    QVector<int> ordinals;
    QVector<QPair<qsizetype, QString>> insertions;
    for (const bool exists : materialized) ordinals.append(exists ? tableCount++ : -1);
    for (TableInfo &table : tables) {
        if (table.ordinal >= ordinals.size()) throw std::runtime_error("unmatched table style metadata");
        if (!materialized[table.ordinal] && (present(table.value.value(QStringLiteral("style")))
                || present(table.value.value(QStringLiteral("empty_geometry")))
                || present(table.value.value(QStringLiteral("block_viewport"))))) {
            table.empty = table.ordinal;
            const auto marker = [&](const QString &edge) {
                return QStringLiteral("<p style='margin:0'><img src='%1:%2:%3'></p>")
                    .arg(emptyTableScheme).arg(table.empty).arg(edge);
            };
            if (bounds[table.ordinal].second < 0) throw std::runtime_error("unclosed empty table");
            insertions.append({bounds[table.ordinal].first, marker(QStringLiteral("begin"))});
            insertions.append({bounds[table.ordinal].second, marker(QStringLiteral("end"))});
        }
        table.ordinal = ordinals[table.ordinal];
    }
    std::sort(insertions.begin(), insertions.end(), [](const auto &a, const auto &b) {
        if (a.first != b.first) return a.first > b.first;
        return a.second.contains(QStringLiteral(":begin")) && !b.second.contains(QStringLiteral(":begin"));
    });
    for (const auto &insertion : insertions) out.insert(insertion.first, insertion.second);
    return out;
}
inline QTextTableFormat emptyTableDefaults(const TableInfo &record, int indent) {
    const auto value = record.value.value(QStringLiteral("empty_geometry"));
    if (present(value) && !value.isObject()) throw std::runtime_error("invalid empty table geometry");
    const auto geometry = value.toObject();
    const bool nested = record.value.value(QStringLiteral("empty_nested")).toBool();
    const auto dimension = [&](const QString &key, int fallback) {
        const auto v = geometry.value(key);
        if (!present(v)) return fallback;
        const double n = v.toDouble(-1);
        if (!v.isDouble() || !std::isfinite(n) || n < 0 || n > 65535 || std::floor(n) != n)
            throw std::runtime_error("invalid empty table dimension");
        return int(n);
    };
    QTextTableFormat format;
    format.setTopMargin(nested ? 0 : 8); format.setBottomMargin(nested ? 0 : 8);
    format.setLeftMargin(indent); format.setRightMargin(0);
    format.setBorderStyle(QTextFrameFormat::BorderStyle_Outset); format.setBorderBrush(Qt::darkGray);
    format.setBorder(!geometry.isEmpty() || nested ? dimension(QStringLiteral("border"), 1) : 0);
    format.setCellPadding(dimension(QStringLiteral("cell_padding"), 5));
    format.setCellSpacing(dimension(QStringLiteral("cell_spacing"), 0));
    format.setBorderCollapse(!present(geometry.value(QStringLiteral("cell_spacing"))));
    const auto width = geometry.value(QStringLiteral("width"));
    if (present(width)) {
        const auto spec = width.toObject();
        const auto unit = spec.value(QStringLiteral("unit")).toString();
        const auto value = spec.value(QStringLiteral("value"));
        const double amount = value.toDouble(-1);
        if (!width.isObject() || spec.size() != 2 || !value.isDouble() || !std::isfinite(amount)
            || amount < 0 || amount > 4294967295.0 || std::floor(amount) != amount
            || (unit != QStringLiteral("px") && unit != QStringLiteral("percent"))
            || (unit == QStringLiteral("percent") && amount > 100))
            throw std::runtime_error("invalid empty table width");
        format.setWidth(QTextLength(unit == QStringLiteral("px") ? QTextLength::FixedLength : QTextLength::PercentageLength, amount));
    }
    return format;
}

inline QTextFrame *materializeEmptyTable(QTextDocument *document, const TableInfo &record, const QTextTableFormat &format) {
    QPointer<QTextDocument> live(document);
    QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    const auto current = [&] { return live && layout && live->documentLayout() == layout; };
    const auto require = [&](bool accepted) { if (!accepted || !current()) throw std::runtime_error("invalid empty table ownership"); };
    require(current() && record.empty >= 0);
    QTextCursor begin(document), end(document);
    int begins = 0, ends = 0;
    const QString prefix = emptyTableScheme + QChar(':') + QString::number(record.empty) + QChar(':');
    for (auto block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            const auto name = fragment.charFormat().toImageFormat().name();
            const bool first = name == prefix + QStringLiteral("begin"), last = name == prefix + QStringLiteral("end");
            if (!first && !last) continue;
            require(fragment.length() == 1 && block.length() == 2 && block.position() == fragment.position());
            QTextCursor &cursor = first ? begin : end;
            cursor.setPosition(fragment.position()); cursor.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor);
            if (first) ++begins; else ++ends;
        }
    require(begins == 1 && ends == 1 && begin.selectionStart() < end.selectionStart());
    QPointer<QTextFrame> parent(document->frameAt(begin.selectionStart()));
    require(parent && parent == document->frameAt(end.selectionEnd()));
    const int revision = document->revision(), count = document->characterCount();
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    require(current());
    require(document->revision() == revision && document->characterCount() == count);
    bool restored = false, finished = false;
    const auto restore = qScopeGuard([&] { if (!restored && live) live->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (!finished && live) transaction.endEditBlock(); });
    QTextFrameFormat wrapper;
    wrapper.setProperty(tableBoxOwnerProperty, emptyTableCapability);
    wrapper.setProperty(emptyTableRoleProperty, QStringLiteral("wrapper"));
    wrapper.setProperty(tableBoxClearProperty, format.hasProperty(tableBoxClearProperty) ? format.intProperty(tableBoxClearProperty) : 0);
    if (format.hasProperty(tableBoxWidthProperty)) wrapper.setProperty(tableBoxWidthProperty, format.property(tableBoxWidthProperty));
    if (format.hasProperty(tableAutoMarginsProperty))
        wrapper.setProperty(tableAutoMarginsProperty, format.property(tableAutoMarginsProperty));
    wrapper.setWidth(format.width()); wrapper.setPosition(format.position());
    wrapper.setTopMargin(format.topMargin()); wrapper.setRightMargin(format.rightMargin());
    wrapper.setBottomMargin(format.bottomMargin()); wrapper.setLeftMargin(format.leftMargin());
    wrapper.setBorder(0); wrapper.setPadding(0);
    QTextCursor selection(begin); selection.setPosition(end.selectionEnd(), QTextCursor::KeepAnchor);
    const QPointer<QTextFrame> frame(selection.insertFrame(wrapper));
    require(frame && parent && frame->parentFrame() == parent);
    const auto markBoundary = [&](QTextBlock block) {
        require(block.isValid() && block.length() == 1);
        QTextCursor cursor(block); QTextBlockFormat boundary;
        boundary.setProperty(emptyTableBoundaryProperty, true);
        cursor.setBlockFormat(boundary);
        require(current());
        block.setVisible(false); block.setLineCount(0);
    };
    // The selected endpoint uses KeepCursor on insertFrame: recover the two
    // actual marker units inside the new frame rather than guessing offsets.
    QTextCursor first = frame->firstCursorPosition();
    require(document->characterAt(first.position()) == QChar::ObjectReplacementCharacter);
    first.deleteChar(); require(frame && current());
    markBoundary(first.block());
    // Recover the source fragment while layout is disabled. Grapheme navigation
    // and the cursor's adjacent format do not identify a selected marker unit.
    QTextCursor last(document);
    int endMarkers = 0;
    for (auto block = document->findBlock(frame->firstPosition());
         block.isValid() && block.position() <= frame->lastPosition(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()
                || fragment.charFormat().toImageFormat().name() != prefix + QStringLiteral("end")) continue;
            require(fragment.length() == 1 && block.length() == 2 && block.position() == fragment.position());
            require(fragment.position() >= frame->firstPosition()
                && fragment.position() + 1 <= frame->lastPosition()
                && document->frameAt(fragment.position()) == frame);
            last.setPosition(fragment.position());
            last.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor);
            ++endMarkers;
        }
    require(endMarkers == 1 && last.selectionEnd() - last.selectionStart() == 1
        && last.selectedText() == QString(QChar::ObjectReplacementCharacter));
    QTextFrameFormat grid;
    grid.setProperty(tableBoxOwnerProperty, emptyTableCapability);
    grid.setProperty(emptyTableRoleProperty, QStringLiteral("grid"));
    if (format.hasProperty(tableBoxPaddingProperty)) grid.setProperty(tableBoxPaddingProperty, format.property(tableBoxPaddingProperty));
    grid.setProperty(QTextFormat::TableBorderCollapse, format.borderCollapse());
    grid.setProperty(QTextFormat::TableCellPadding, format.cellPadding());
    grid.setProperty(QTextFormat::TableCellSpacing, format.cellSpacing());
    grid.setBorder(format.border()); grid.setBorderStyle(format.borderStyle()); grid.setBorderBrush(format.borderBrush());
    grid.setBackground(format.background()); grid.setPadding(0); grid.setMargin(0);
    grid.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    const QPointer<QTextFrame> empty(last.insertFrame(grid));
    require(empty && frame && empty->parentFrame() == frame);
    QTextCursor content = empty->firstCursorPosition();
    require(document->characterAt(content.position()) == QChar::ObjectReplacementCharacter);
    content.deleteChar(); require(empty && frame && current());
    markBoundary(content.block()); markBoundary(document->findBlock(empty->firstPosition() - 1));
    markBoundary(frame->lastCursorPosition().block());
    // Public insertFrame necessarily splits the generated marker paragraphs.
    // Mark only their new empty outer storage blocks, never caption paragraphs.
    markBoundary(document->findBlock(frame->firstPosition() - 1));
    markBoundary(document->findBlock(frame->lastPosition() + 1));
    const QString source = document->toRawText();
    const int finalRevision = document->revision(), finalCount = document->characterCount();
    transaction.endEditBlock(); finished = true;
    require(current());
    require(document->revision() == finalRevision && document->characterCount() == finalCount && document->toRawText() == source);
    document->setLayoutEnabled(enabled); restored = true;
    require(current());
    require(document->revision() == finalRevision && document->characterCount() == finalCount && document->toRawText() == source);
    return frame;
}

inline void materializeTableBlockViewport(QTextDocument *document, QTextFrame *table,
                                          const QJsonObject &metadata, qreal points) {
    const auto policyValue = metadata.value(QStringLiteral("block_viewport"));
    if (!present(policyValue)) return;
    if (!table) throw std::runtime_error("unmapped table viewport grid");
    QPointer<QTextDocument> live(document);
    QPointer<QTextFrame> grid(table);
    QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
    const auto capability = native ? native->property("_wikidictTableBlockViewportCapability") : QVariant();
    if (!live || !grid || !native || capability.metaType().id() != QMetaType::QString
        || capability.toString() != tableViewportCapability)
        throw std::runtime_error("missing paired table viewport materializer");
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    if (!live || !grid || !native || live->documentLayout() != native)
        throw std::runtime_error("replaced table viewport document");
    const auto restoreLayout = qScopeGuard([&] { if (live) live->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (live) transaction.endEditBlock(); });
    const auto source = tableViewportSource(metadata);
    const auto policy = tableBlockViewport(QJsonDocument::fromJson(source).object());
    const auto boxStyle = policy.value(QStringLiteral("box_style")).toObject();
    const auto gridStyle = policy.value(QStringLiteral("grid_style")).toObject();
    const auto language = policy.value(QStringLiteral("language")).toString();
    if (native->property("_wikidictSourceTextLanguageCapability").toString() != QStringLiteral("wikidict.source-text-language/1"))
        throw std::runtime_error("missing paired source-language shaping");
    QTextTableFormat boxMargins;
    applyTableAutoMargins(boxMargins, boxStyle, points, 0);
    const auto autoMargins = boxMargins.property(tableAutoMarginsProperty).toMap();
    QVariantList margins{boxMargins.topMargin(), boxMargins.rightMargin(), boxMargins.bottomMargin(), boxMargins.leftMargin()};
    QVariantMap allocation{{QStringLiteral("capability"), tableViewportCapability}, {QStringLiteral("source"), source},
        {QStringLiteral("language"), language},
        {QStringLiteral("em"), points * QFontMetricsF(QFont()).fontDpi() / 72.0},
        {QStringLiteral("threshold"), policy.value(QStringLiteral("max_viewport_width_px")).toDouble()},
        {QStringLiteral("active"), false}, {QStringLiteral("width"), tableBoxLength(boxStyle.value(QStringLiteral("width")), points, true)},
        {QStringLiteral("max_width"), tableBoxLength(policy.value(QStringLiteral("max_width")), points, true)},
        {QStringLiteral("border_box"), policy.value(QStringLiteral("box_sizing")) == QStringLiteral("border_box")},
        {QStringLiteral("autos"), autoMargins.value(QStringLiteral("autos"))}, {QStringLiteral("margins"), margins},
        {QStringLiteral("direction"), autoMargins.value(QStringLiteral("direction"))},
        {QStringLiteral("grid_direction"), int(policy.value(QStringLiteral("grid_direction")) == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)}};
    QTextFrameFormat box;
    box.setMargin(0); box.setBorder(0); box.setPadding(0);
    box.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    box.setLayoutDirection(Qt::LayoutDirection(allocation.value(QStringLiteral("direction")).toInt()));
    box.setProperty(tableBoxClearProperty, 0);
    if (present(boxStyle.value(QStringLiteral("clear")))) {
        const int clear = QStringList{"none", "left", "right", "both"}.indexOf(boxStyle.value(QStringLiteral("clear")).toString());
        if (clear < 0) throw std::runtime_error("invalid viewport clear");
        box.setProperty(tableBoxClearProperty, clear);
    }
    if (present(boxStyle.value(QStringLiteral("background")))) box.setBackground(styleColor(boxStyle.value(QStringLiteral("background"))));
    QVariantList physicalPadding{0.0, 0.0, 0.0, 0.0};
    if (present(boxStyle.value(QStringLiteral("padding")))) {
        const auto edges = boxStyle.value(QStringLiteral("padding")).toObject();
        if (edges.size() != 4) throw std::runtime_error("invalid viewport padding");
        int side = 0;
        for (const auto &name : {"top", "right", "bottom", "left"})
            physicalPadding[side++] = tableBoxLength(edges.value(QLatin1StringView(name)), points, false).value(QStringLiteral("value"));
    }
    const auto border = boxStyle.value(QStringLiteral("border"));
    QVariantList physicalBorders;
    const auto edge = [&](const QJsonValue &value) {
        if (!present(value)) return QVariantMap{{"style", 0}, {"width", 0.0}, {"color", QColor(Qt::transparent)}};
        const auto spec = value.toObject();
        if (!value.isObject() || spec.size() != 1) throw std::runtime_error("invalid viewport border");
        const QString kind = spec.keys().first();
        const int style = QStringList{"none", "hidden", "solid", "dotted"}.indexOf(kind);
        const auto payload = spec.value(kind);
        if (style < 0 || !payload.isObject() || payload.toObject().size() != (style < 2 ? 0 : 2))
            throw std::runtime_error("invalid viewport border style");
        return QVariantMap{{"style", style}, {"width", style < 2 ? 0.0
            : tableBoxLength(payload.toObject().value(QStringLiteral("width")), points, false).value(QStringLiteral("value")).toDouble()},
            {"color", style < 2 ? QColor(Qt::transparent) : styleColor(payload.toObject().value(QStringLiteral("color")))}};
    };
    if (border.toObject().contains(QStringLiteral("edges"))) {
        const auto edges = border.toObject().value(QStringLiteral("edges")).toObject();
        if (border.toObject().size() != 1 || edges.size() != 4) throw std::runtime_error("invalid viewport physical border");
        for (const auto &name : {"top", "right", "bottom", "left"}) physicalBorders.append(edge(edges.value(QLatin1StringView(name))));
    } else for (int side = 0; side < 4; ++side) physicalBorders.append(edge(border));
    box.setProperty(QTextFormat::UserProperty + 0x57e8,
        QVariantMap{{QStringLiteral("padding"), physicalPadding}, {QStringLiteral("borders"), physicalBorders}});
    QTextFrameFormat narrow = table->frameFormat();
    for (int property : {int(QTextFormat::BackgroundBrush), int(QTextFormat::BlockAlignment), tableAutoMarginsProperty,
                         tablePhysicalEdgesProperty, tableBoxWidthProperty, tableBoxPaddingProperty,
                         tableDisplayProperty, tableVerticalAlignProperty, tableLineHeightProperty}) narrow.clearProperty(property);
    narrow.setMargin(0); narrow.setPadding(0); narrow.setBorder(0); narrow.setBorderStyle(QTextFrameFormat::BorderStyle_None);
    narrow.setProperty(QTextFormat::TableCellPadding, 0.0); narrow.setProperty(QTextFormat::TableCellSpacing, 0.0);
    narrow.setProperty(QTextFormat::TableBorderCollapse, true);
    narrow.setWidth(QTextLength()); narrow.setLayoutDirection(Qt::LayoutDirection(allocation.value(QStringLiteral("grid_direction")).toInt()));
    narrow.setProperty(tableBoxClearProperty, 0);
    narrow.setProperty(tableViewportGridProperty, source);
    narrow.setProperty(tableSourceLanguageProperty, language);
    if (present(gridStyle.value(QStringLiteral("line_height"))))
        narrow.setProperty(tableLineHeightProperty, tableComputedLineHeight(gridStyle.value(QStringLiteral("line_height")), points, points));
    QTextFrameFormat wide = table->frameFormat(); wide.setProperty(tableViewportGridProperty, source);
    wide.setProperty(tableSourceLanguageProperty, language);
    wide.clearProperty(QTextFormat::ObjectIndex); narrow.clearProperty(QTextFormat::ObjectIndex);
    QTextFrameFormat wideOwner;
    wideOwner.setMargin(0); wideOwner.setBorder(0); wideOwner.setPadding(0);
    wideOwner.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    wideOwner.setProperty(tableBoxClearProperty, wide.intProperty(tableBoxClearProperty));
    // The transparent wide owner carries the source table's external vertical
    // margins; the same real grid keeps its horizontal allocation and direction.
    wideOwner.setTopMargin(wide.topMargin()); wideOwner.setBottomMargin(wide.bottomMargin());
    wide.setTopMargin(0); wide.setBottomMargin(0);
    QVariantMap formats{{QStringLiteral("box"), QVariant::fromValue(QTextFormat(box))},
        {QStringLiteral("wide_owner"), QVariant::fromValue(QTextFormat(wideOwner))},
        {QStringLiteral("grid"), QVariant::fromValue(QTextFormat(narrow))},
        {QStringLiteral("wide_grid"), QVariant::fromValue(QTextFormat(wide))}};
    if (auto *real = qobject_cast<QTextTable *>(table)) {
        QVariantList backgrounds;
        const auto sourceRows = metadata.value(QStringLiteral("rows")).toArray();
        for (int row = 0; row < real->rows(); ++row) {
            const auto sourceCells = sourceRows.at(row).toArray(); int index = 0;
            for (int column = 0; column < real->columns(); ++column) {
                auto cell = real->cellAt(row, column);
                if (cell.row() != row || cell.column() != column) continue;
                const bool sourceCell = index < sourceCells.size();
                if (sourceCell) {
                    if (cell.format().property(tableSourceLanguageProperty).metaType().id() != QMetaType::QString
                        || cell.format().stringProperty(tableSourceLanguageProperty) != language)
                        throw std::runtime_error("unmatched imported table source language");
                } else {
                    if (cell.firstCursorPosition().position() != cell.lastCursorPosition().position())
                        throw std::runtime_error("nonempty unowned table filler");
                    auto filler = cell.format(); filler.setProperty(tableSourceLanguageProperty, language); cell.setFormat(filler);
                    if (!live || !native || !grid || live->documentLayout() != native)
                        throw std::runtime_error("replaced table source language owner");
                }
                const auto authored = sourceCell
                    ? sourceCells.at(index++).toObject().value(QStringLiteral("background")) : QJsonValue();
                if (present(authored)) styleColor(authored);
                backgrounds.append(QVariantMap{{QStringLiteral("row"), row}, {QStringLiteral("column"), column},
                    {QStringLiteral("authored"), present(authored)}, {QStringLiteral("brush"), cell.format().background()}});
            }
        }
        formats.insert(QStringLiteral("cell_backgrounds"), backgrounds);
    }
    if (!qobject_cast<QTextTable *>(table)) {
        if (table->frameFormat().stringProperty(emptyTableRoleProperty) != QStringLiteral("wrapper")
            || table->childFrames().size() != 1
            || table->childFrames().first()->frameFormat().stringProperty(emptyTableRoleProperty) != QStringLiteral("grid"))
            throw std::runtime_error("invalid empty viewport grid");
        auto *empty = table->childFrames().first();
        const auto emptyWide = empty->frameFormat(); auto emptyNarrow = emptyWide;
        emptyNarrow.setBackground(Qt::NoBrush); emptyNarrow.setBorder(0);
        emptyNarrow.setBorderStyle(QTextFrameFormat::BorderStyle_None);
        emptyNarrow.clearProperty(tableBoxPaddingProperty);
        emptyNarrow.setProperty(QTextFormat::TableBorderCollapse, true);
        emptyNarrow.setProperty(QTextFormat::TableCellPadding, 0.0);
        emptyNarrow.setProperty(QTextFormat::TableCellSpacing, 0.0);
        formats.insert(QStringLiteral("empty_wide"), QVariant::fromValue(QTextFormat(emptyWide)));
        formats.insert(QStringLiteral("empty_grid"), QVariant::fromValue(QTextFormat(emptyNarrow)));
    }
    wideOwner.setProperty(tableViewportProperty, allocation);
    wideOwner.setProperty(tableViewportFormatsProperty, formats);
    QPointer<QTextFrame> parent(table->parentFrame());
    int start = table->firstPosition() - 1;
    QList<QTextBlock> captions;
    for (auto it = parent->begin(); !it.atEnd(); ++it) {
        if (it.currentFrame() == table) break;
        if (it.currentFrame()) { captions.clear(); continue; }
        const auto block = it.currentBlock();
        if (block.blockFormat().stringProperty(tableCaptionBlockProperty) == QStringLiteral("wikidict.table-caption/1")) captions.append(block);
        else if (block.length() != 1) captions.clear();
    }
    QTextCursor captionStart(document);
    QTextBlockFormat captionBlockFormat;
    QTextCharFormat captionCharacterFormat;
    QString captionText;
    const bool wrapsCaption = qobject_cast<QTextTable *>(table) && !captions.isEmpty();
    if (wrapsCaption) {
        const auto first = captions.first();
        start = first.position();
        captionStart.setPosition(start);
        captionStart.setKeepPositionOnInsert(false);
        captionBlockFormat = first.blockFormat();
        captionCharacterFormat = first.charFormat();
        captionText = first.text();
    }
    QVector<QPointer<QTextFrame>> stagedCaptions;
    for (auto *child : parent->childFrames()) {
        if (child == grid || child->lastPosition() < start || child->firstPosition() > table->lastPosition() + 1) continue;
        validateStagedTableCaption(child, parent, grid);
        stagedCaptions.append(child);
    }
    QTextCursor selection(document); selection.setPosition(start);
    selection.setPosition(table->lastPosition() + 1, QTextCursor::KeepAnchor);
    const QPointer<QTextFrame> owner(selection.insertFrame(wideOwner));
    if (!live || !native || !grid || !owner || !parent || live->documentLayout() != native
        || owner->parentFrame() != parent || grid->parentFrame() != owner
        || owner->childFrames().size() != stagedCaptions.size() + 1)
        throw std::runtime_error("invalid native table viewport association");
    if (wrapsCaption) {
        // insertFrame gives the new interior block a default format and leaves
        // the original format on its empty exterior prefix. Move that exact
        // authenticated caption format with its source payload, not its prefix.
        const auto current = [&] {
            return live && native && grid && owner && parent && live->documentLayout() == native
                && owner->parentFrame() == parent && grid->parentFrame() == owner;
        };
        const auto interior = captionStart.block();
        const auto exterior = document->findBlock(owner->firstPosition() - 1);
        if (!interior.isValid() || captionStart.position() != owner->firstPosition()
            || interior.position() != captionStart.position() || captionStart.currentFrame() != owner
            || interior.text() != captionText || !exterior.isValid()
            || exterior.position() != owner->firstPosition() - 1 || exterior.length() != 1
            || document->characterAt(exterior.position()) != QChar(0xfdd0)
            || document->frameAt(exterior.position()) != parent || exterior.blockFormat() != captionBlockFormat)
            throw std::runtime_error("changed caption during viewport wrapping");
        captionStart.setBlockFormat(captionBlockFormat);
        if (!current()) throw std::runtime_error("replaced caption block during viewport wrapping");
        // This public setter preserves the new frame separator's ObjectIndex.
        captionStart.setBlockCharFormat(captionCharacterFormat);
        if (!current()) throw std::runtime_error("replaced caption strut during viewport wrapping");
        QTextCursor boundary(exterior); boundary.setBlockFormat(QTextBlockFormat());
        if (!current()) throw std::runtime_error("replaced exterior caption storage");
        auto storage = boundary.block(); storage.setVisible(false); storage.setLineCount(0);
    }
    for (const auto &caption : stagedCaptions) validateStagedTableCaption(caption, owner, grid);
    if (auto *real = qobject_cast<QTextTable *>(grid.data())) real->setFormat(wide.toTableFormat());
    else grid->setFrameFormat(wide);
    if (tableViewportConstructionGrid(owner) != grid)
        throw std::runtime_error("changed table viewport construction grid");
    // The old empty-table exterior storage becomes exterior viewport storage.
    // Its empty-table-only marker no longer describes its immediate owner.
    // Clear only the exact generated one-property boundary at the new edges;
    // all inner empty wrapper/grid boundaries retain their existing identity.
    if (grid->frameFormat().stringProperty(emptyTableRoleProperty) == QStringLiteral("wrapper")) {
        for (int position : {owner->firstPosition() - 1, owner->lastPosition() + 1}) {
            const auto block = document->findBlock(position);
            auto format = block.blockFormat();
            if (!format.hasProperty(emptyTableBoundaryProperty)) continue;
            const auto marker = format.property(emptyTableBoundaryProperty);
            const bool before = position == owner->firstPosition() - 1;
            if (!block.isValid() || block.position() != position || block.length() != 1
                || document->frameAt(position) != parent || marker.metaType().id() != QMetaType::Bool || !marker.toBool()
                || format.properties().size() != 1 || block.isVisible()
                || (before ? document->characterAt(position) != QChar(0xfdd0)
                           : document->characterAt(position - 1) != QChar(0xfdd1)))
                throw std::runtime_error("invalid exterior empty viewport storage");
            format.clearProperty(emptyTableBoundaryProperty);
            QTextCursor boundary(block); boundary.setBlockFormat(format);
            if (!live || !native || !grid || !owner || !parent || live->documentLayout() != native
                || owner->parentFrame() != parent || grid->parentFrame() != owner)
                throw std::runtime_error("replaced exterior empty viewport storage");
        }
    }
    if (!live || !native || !grid || !owner || live->documentLayout() != native || grid->parentFrame() != owner)
        throw std::runtime_error("replaced materialized table viewport");
    // Public frame insertion creates only storage boundary blocks. Do not hide
    // authored caption paragraphs or any existing source paragraph outside it.
    for (auto it = owner->begin(); !it.atEnd(); ++it) {
        auto block = it.currentBlock();
        if (block.isValid() && block.length() == 1
            && !block.blockFormat().hasProperty(tableCaptionBlockProperty)) {
            block.setVisible(false); block.setLineCount(0);
        }
    }
}

inline void normalizeTables(QTextDocument *document, const QVector<TableInfo> &records, int expectedTables) {
    if (records.isEmpty()) return;
    bool needsTableBoxLayout = false;
    bool needsCellStyleLayout = false;
    bool needsCellMinimum = false;
    bool needsCellPreferredWidth = false;
    for (const TableInfo &record : records)
        for (const QJsonValue &row : record.value.value(QStringLiteral("rows")).toArray())
            for (const QJsonValue &cell : row.toArray())
            {
                const auto style = cell.toObject().value(QStringLiteral("style")).toObject();
                needsCellStyleLayout |= hasExtendedCellStyle(style);
                needsCellMinimum |= present(style.value(QStringLiteral("min_width")));
                needsCellPreferredWidth |= present(style.value(QStringLiteral("width")));
            }
    if (needsCellPreferredWidth) {
        const auto capability = document->documentLayout()->property("_wikidictCellPreferredWidthCapability");
        if (capability.metaType().id() != QMetaType::QString
            || capability.toString() != QStringLiteral("wikidict.cell-preferred-width/1"))
            throw std::runtime_error("missing paired cell preferred width layout");
    }
    if (needsCellMinimum) {
        const auto capability = document->documentLayout()->property("_wikidictCellMinimumWidthCapability");
        if (capability.metaType().id() != QMetaType::QString
            || capability.toString() != QStringLiteral("wikidict.cell-minimum-width/1"))
            throw std::runtime_error("missing paired cell minimum width layout");
    }
    if (needsCellStyleLayout) {
        requireTableBoxLayout(document);
        const auto capability = document->documentLayout()->property("_wikidictCellStyleLayoutCapability");
        if (capability.metaType().id() != QMetaType::QString || capability.toString() != cellStyleCapability)
            throw std::runtime_error("missing paired cell style layout");
    }
    for (const TableInfo &record : records)
        needsTableBoxLayout |= record.ordinal >= 0;
    if (needsTableBoxLayout) requireTableBoxLayout(document);
    for (const TableInfo &record : records) if (record.empty >= 0) { requireTableBoxLayout(document, true); break; }
    QHash<int, QPointer<QTextFrame>> emptyTables;
    QVector<QTextTable *> tables;
    const auto collect = [&](auto &&visit, QTextFrame *frame) -> void {
        for (QTextFrame *child : frame->childFrames()) {
            if (auto *table = qobject_cast<QTextTable *>(child)) tables.append(table);
            visit(visit, child);
        }
    };
    collect(collect, document->rootFrame());
    if (tables.size() != expectedTables) throw std::runtime_error("table style structural count mismatch");
    for (const TableInfo &record : records) {
        if (record.ordinal < -1 || record.ordinal >= tables.size()) throw std::runtime_error("table style ordinal mismatch");
        QTextTable *table = record.ordinal < 0 ? nullptr : tables[record.ordinal];
        const QJsonValue markerValue = record.value.value(QStringLiteral("list_marker"));
        if (!markerValue.isUndefined() && (!markerValue.isString() || markerValue.toString().isEmpty()))
            throw std::runtime_error("invalid table list marker");
        const qreal points = record.value.value(QStringLiteral("container_points")).toDouble(-1);
        const int indent = record.value.value(QStringLiteral("indent")).toInt(-1);
        if (!std::isfinite(points) || points <= 0 || indent < 0 || !record.value.value(QStringLiteral("rows")).isArray()) throw std::runtime_error("invalid table style context");
        const QJsonArray rows = record.value.value(QStringLiteral("rows")).toArray();
        if (table && rows.size() != table->rows()) throw std::runtime_error("table style row count mismatch");
        const bool floatViewport = present(record.value.value(QStringLiteral("float_viewport")));
        const auto length = [&](const QJsonValue &value) {
            return floatViewport ? tableBoxLength(value, points, false).value(QStringLiteral("value")).toDouble()
                : styleLengthUnits(value, document, points);
        };
        const auto edges = [&](const QJsonValue &value) {
            if (!value.isObject() || value.toObject().size() != 4) throw std::runtime_error("invalid style edges");
            const QJsonObject object = value.toObject();
            return QVector<qreal>{length(object.value(QStringLiteral("top"))), length(object.value(QStringLiteral("right"))), length(object.value(QStringLiteral("bottom"))), length(object.value(QStringLiteral("left")))};
        };
        struct Border { qreal width; QTextFrameFormat::BorderStyle style; QColor color; };
        const auto border = [&](const QJsonValue &value) {
            const QJsonObject object = value.toObject();
            if (!value.isObject() || object.size() != 1) throw std::runtime_error("invalid style border");
            if (object.contains(QStringLiteral("none")) && object.value(QStringLiteral("none")).isObject() && object.value(QStringLiteral("none")).toObject().isEmpty())
                return Border{0, QTextFrameFormat::BorderStyle_None, QColor(Qt::transparent)};
            const QJsonValue solidValue = object.value(QStringLiteral("solid")); const QJsonObject solid = solidValue.toObject();
            if (!solidValue.isObject() || solid.size() != 2) throw std::runtime_error("invalid solid border");
            return Border{length(solid.value(QStringLiteral("width"))), QTextFrameFormat::BorderStyle_Solid, styleColor(solid.value(QStringLiteral("color")))};
        };
        const auto cellBorder = [&](const QJsonValue &value) {
            if (!value.isObject() || !value.toObject().contains(QStringLiteral("double"))) return border(value);
            const auto object = value.toObject();
            const auto payload = object.value(QStringLiteral("double"));
            if (object.size() != 1 || !payload.isObject() || payload.toObject().size() != 2)
                throw std::runtime_error("invalid double cell border");
            return Border{length(payload.toObject().value(QStringLiteral("width"))),
                QTextFrameFormat::BorderStyle_Double, styleColor(payload.toObject().value(QStringLiteral("color")))};
        };
        const auto physicalBorder = [&](const QJsonValue &value) {
            const auto physical = typedStyle(value, {"top", "right", "bottom", "left"});
            if (physical.size() != 4) throw std::runtime_error("incomplete physical border");
            QVariantList result;
            for (const QString &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")}) {
                const auto edge = physical.value(side).toObject();
                if (!physical.value(side).isObject() || edge.size() != 1) throw std::runtime_error("invalid physical border edge");
                const QString kind = edge.keys().first(); const auto payload = edge.value(kind);
                const int mode = QStringList{"none", "hidden", "solid", "dotted"}.indexOf(kind);
                if (mode < 0 || !payload.isObject() || payload.toObject().size() != (mode < 2 ? 0 : 2))
                    throw std::runtime_error("invalid physical border style");
                const qreal width = mode < 2 ? 0 : tableBoxLength(payload.toObject().value(QStringLiteral("width")), points, false).value(QStringLiteral("value")).toDouble();
                const QColor color = mode < 2 ? QColor(Qt::transparent) : styleColor(payload.toObject().value(QStringLiteral("color")));
                result.append(QVariantMap{{QStringLiteral("style"), mode}, {QStringLiteral("width"), width}, {QStringLiteral("color"), color}});
            }
            QPointer<QTextDocument> live(document);
            QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
            const int revision = document->revision(), count = document->characterCount();
            const auto capability = native ? native->property("_wikidictPhysicalBorderCapability") : QVariant();
            if (!live || !native || live->documentLayout() != native || live->revision() != revision
                || live->characterCount() != count || capability.metaType().id() != QMetaType::QString
                || capability.toString() != QStringLiteral("wikidict.physical-border/1"))
                throw std::runtime_error("missing paired physical border layout");
            return result;
        };
        QTextTableFormat format = table ? table->format() : record.empty >= 0 ? emptyTableDefaults(record, indent) : QTextTableFormat();
        if (present(record.value.value(QStringLiteral("block_viewport")))) {
            format.setCellPadding(0); format.setCellSpacing(0);
            if (!table) { format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None); }
        }
        if (table) {
            // Ownership follows the decoded table association, even when its
            // style uses only ordinary Qt fields. Keep legacy width/padding.
            format.setProperty(tableBoxOwnerProperty, tableBoxCapability);
            format.setProperty(tableBoxClearProperty, 0); // Default clear:none.
        }
        for (const QJsonValue &row : rows) for (const QJsonValue &cell : row.toArray()) {
            if (hasExtendedCellStyle(cell.toObject().value(QStringLiteral("style")).toObject())) {
                format.setProperty(tableBoxOwnerProperty, tableBoxCapability);
                format.setProperty(cellStylePolicyProperty, cellStyleCapability);
            }
        }
        const QJsonValue resetAlignment = record.value.value(QStringLiteral("reset_text_alignment"));
        if (!resetAlignment.isUndefined() && !resetAlignment.isBool()) throw std::runtime_error("invalid table text-alignment scope");
        // A surrounding aligned td otherwise moves a nested table as well as
        // its text. Cell align attributes carry the intended text inheritance;
        // restore the frame's default alignment independently of float position.
        if (resetAlignment.toBool()) format.clearProperty(QTextFormat::BlockAlignment);
        const QJsonObject style = typedStyle(record.value.value(QStringLiteral("style")), {"background", "border", "collapse", "margins", "margin_values", "containing_direction", "float_side", "width", "padding", "clear", "display", "vertical_align", "line_height"});
        if (present(style.value(QStringLiteral("float_side")))) {
            const QJsonValue side = style.value(QStringLiteral("float_side"));
            if (!side.isString() || (side.toString() != QStringLiteral("left") && side.toString() != QStringLiteral("right")))
                throw std::runtime_error("invalid table float side");
            // Public frame positioning participates in normal text flow and
            // preserves the original QTextTable cells, offsets and selection.
            format.setPosition(side.toString() == QStringLiteral("left") ? QTextFrameFormat::FloatLeft : QTextFrameFormat::FloatRight);
        }
        if (present(style.value(QStringLiteral("background")))) format.setBackground(styleColor(style.value(QStringLiteral("background"))));
        if (present(style.value(QStringLiteral("border")))) {
            const auto spec = style.value(QStringLiteral("border")).toObject();
            if (spec.contains(QStringLiteral("edges"))) {
                if (spec.size() != 1 || !table) throw std::runtime_error("physical table border requires a real table owner");
                format.setProperty(tablePhysicalEdgesProperty, QVariantMap{
                    {QStringLiteral("padding"), QVariantList{0.0, 0.0, 0.0, 0.0}},
                    {QStringLiteral("borders"), physicalBorder(spec.value(QStringLiteral("edges")))}});
                format.setProperty(cellStylePolicyProperty, cellStyleCapability);
                format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
            } else {
                const Border b = border(style.value(QStringLiteral("border")));
                format.setBorder(b.width); format.setBorderStyle(b.style); format.setBorderBrush(b.color);
            }
        }
        if (present(style.value(QStringLiteral("collapse")))) {
            const QString collapse = style.value(QStringLiteral("collapse")).toString();
            if (collapse != QStringLiteral("separate") && collapse != QStringLiteral("collapse")) throw std::runtime_error("invalid border collapse");
            format.setBorderCollapse(collapse == QStringLiteral("collapse"));
        }
        if (present(style.value(QStringLiteral("margins")))) {
            const auto e = edges(style.value(QStringLiteral("margins")));
            const qreal maximum = maximumFontPoints(document) * QFontMetricsF(QFont()).fontDpi() / 72;
            format.setTopMargin(e[0]); format.setRightMargin(e[1]); format.setBottomMargin(e[2]); format.setLeftMargin(floatViewport ? e[3] : qMin(maximum, e[3] + indent));
        }
        if (present(style.value(QStringLiteral("margin_values")))) {
            const auto capability = document->documentLayout()->property("_wikidictTableAutoMarginsCapability");
            if (capability.metaType().id() != QMetaType::QString
                || capability.toString() != QStringLiteral("wikidict.table-auto-margins/1"))
                throw std::runtime_error("missing paired table automatic margin layout");
        }
        applyTableAutoMargins(format, style, points, indent);
        applyTableBoxStyle(format, style, points);
        if (hasTableFlowStyle(style)) {
            QPointer<QTextDocument> live(document);
            QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
            const int revision = document->revision(), count = document->characterCount();
            const auto capability = native ? native->property("_wikidictInlineTableLayoutCapability") : QVariant();
            if (!live || !native || live->documentLayout() != native || live->revision() != revision
                || live->characterCount() != count || capability.metaType().id() != QMetaType::QString
                || capability.toString() != QStringLiteral("wikidict.inline-table/1"))
                throw std::runtime_error("missing paired inline table layout");
            format.setProperty(tableDisplayProperty, tableDisplay(style));
            if (present(style.value(QStringLiteral("vertical_align")))) {
                const auto value = style.value(QStringLiteral("vertical_align"));
                const int alignment = QStringList{"baseline", "middle", "top"}.indexOf(value.toString());
                if (!value.isString() || alignment < 0) throw std::runtime_error("invalid inline table alignment");
                if (alignment == 2 && format.intProperty(tableDisplayProperty) == 0)
                    throw std::runtime_error("top alignment requires an inline table");
                format.setProperty(tableVerticalAlignProperty, alignment);
            }
            if (present(style.value(QStringLiteral("line_height"))))
                format.setProperty(tableLineHeightProperty, tableComputedLineHeight(style.value(QStringLiteral("line_height")),
                    points, record.value.value(QStringLiteral("table_origin_points")).toDouble(-1)));
        }
        if (table && format.intProperty(tableDisplayProperty) > 0) {
            bool image = false;
            for (QTextBlock block = document->findBlock(table->firstPosition()); block.isValid() && block.position() < table->lastPosition(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    image |= it.fragment().isValid() && it.fragment().charFormat().isImageFormat();
            if (image || format.intProperty(tableVerticalAlignProperty) == 2) {
                const auto capability = document->documentLayout()->property("_wikidictInlineTableImageTopCapability");
                if (capability.metaType().id() != QMetaType::QString
                    || capability.toString() != QStringLiteral("wikidict.inline-table-image-top/1"))
                    throw std::runtime_error("missing paired inline table image/top layout");
            }
        }
        if (!table) {
            for (const QJsonValue &row : rows)
                if (!row.isArray() || !row.toArray().isEmpty()) throw std::runtime_error("unexpected nonempty elided table");
            if (record.empty >= 0) emptyTables.insert(record.empty, materializeEmptyTable(document, record, format));
            else if (hasTableBoxStyle(style)) throw std::runtime_error("unmapped empty table box");
            continue;
        }
        if (format.intProperty(tableDisplayProperty) > 0) {
            format.setLeftMargin(format.leftMargin() - indent);
            if (!present(style.value(QStringLiteral("margins"))) && !present(style.value(QStringLiteral("margin_values")))) {
                format.setTopMargin(0); format.setBottomMargin(0);
            }
        }
        table->setFormat(format);
        if (format.hasProperty(tableLineHeightProperty) || present(record.value.value(QStringLiteral("block_viewport")))) {
            for (QTextBlock block = document->findBlock(table->firstPosition()); block.isValid() && block.position() < table->lastPosition(); block = block.next()) {
                auto inherited = block.blockFormat();
                // Existing explicit paragraph policies override inherited table line height.
                if (inherited.lineHeightType() != QTextBlockFormat::SingleHeight
                    && !inherited.boolProperty(generatedParentStrutProperty) && !inherited.hasProperty(tableLineHeightProperty)) continue;
                if (format.hasProperty(tableLineHeightProperty))
                    inherited.setProperty(tableLineHeightProperty, format.property(tableLineHeightProperty));
                if (present(record.value.value(QStringLiteral("block_viewport"))))
                    inherited.setProperty(tableViewportInheritedLineProperty, tableViewportSource(record.value));
                else inherited.clearProperty(tableViewportInheritedLineProperty);
                QTextCursor cursor(block); cursor.setBlockFormat(inherited);
            }
        }
        if (format.intProperty(tableDisplayProperty) > 0) {
            // The producer admits one complete isolated table line. Keep real
            // table cells and create only the native storage boundary blocks.
            QTextCursor before(document); before.setPosition(table->firstPosition() - 1);
            if (!before.atBlockEnd() || before.currentFrame() != table->parentFrame())
                throw std::runtime_error("invalid inline table boundary");
            if (before.block().length() != 1) before.insertBlock(QTextBlockFormat(), QTextCharFormat());
            QTextCursor after(document); after.setPosition(table->lastPosition() + 1);
            if (!after.atBlockStart() || after.currentFrame() != table->parentFrame())
                throw std::runtime_error("invalid inline table end boundary");
            if (after.block().length() != 1) after.insertBlock(QTextBlockFormat(), QTextCharFormat());
            before.setPosition(table->firstPosition() - 1);
            auto ownerFormat = before.blockFormat(); ownerFormat.setTopMargin(0); ownerFormat.setBottomMargin(0);
            ownerFormat.setLeftMargin(indent);
            before.setBlockFormat(ownerFormat);
            QTextCharFormat font = before.blockCharFormat();
            font.setFontPointSize(record.value.value(QStringLiteral("table_origin_points")).toDouble(points));
            before.setBlockCharFormat(font);
        }
        bool cellFormatsChanged = false;
        for (int row = 0; row < table->rows(); ++row) {
            if (!rows[row].isArray()) throw std::runtime_error("invalid table style row metadata");
            const QJsonArray cells = rows[row].toArray(); int index = 0;
            for (int column = 0; column < table->columns(); ++column) {
                QTextTableCell cell = table->cellAt(row, column);
                if (cell.row() != row || cell.column() != column) continue;
                if (index >= cells.size()) {
                    // QTextTable rectangularizes a ragged source row. Only its
                    // empty, unit-span trailing filler cells have no author entry.
                    if (cell.rowSpan() != 1 || cell.columnSpan() != 1 ||
                        cell.firstCursorPosition().position() != cell.lastCursorPosition().position() ||
                        !cell.firstCursorPosition().charFormat().anchorNames().isEmpty())
                        throw std::runtime_error("table style unexpected cell");
                    if (floatViewport) {
                        auto filler = cell.format().toTableCellFormat();
                        filler.setPadding(0); filler.setBorder(0);
                        filler.setBorderStyle(QTextFrameFormat::BorderStyle_None);
                        filler.setBorderBrush(QColor(Qt::transparent));
                        for (const int property : {cellWidthProperty, cellMinimumWidthProperty,
                                cellLineHeightProperty, cellOwnerFontProperty, cellHiddenEdgesProperty})
                            filler.clearProperty(property);
                        filler.setProperty(tableFloatViewportFillerProperty, true);
                        filler.setProperty(tableSourceLanguageProperty,
                            record.value.value(QStringLiteral("float_viewport")).toObject().value(QStringLiteral("language")).toString());
                        cell.setFormat(filler);
                    }
                    // Collapsed Qt tables paint cell backgrounds, not the frame
                    // background. The missing source slot still exposes that
                    // table color; preserve every other filler format property.
                    if (format.background().style() != Qt::NoBrush) {
                        QTextTableCellFormat fillerFormat = cell.format().toTableCellFormat();
                        fillerFormat.setBackground(format.background());
                        cell.setFormat(fillerFormat);
                    }
                    continue;
                }
                const QJsonObject expected = cells[index++].toObject();
                if (expected.value(QStringLiteral("rowspan")).toInt() != cell.rowSpan() || expected.value(QStringLiteral("colspan")).toInt() != cell.columnSpan()) throw std::runtime_error("table style span mismatch");
                const QJsonObject cellStyle = typedStyle(expected.value(QStringLiteral("style")), {"border", "padding", "text_align", "border_edges", "letter_spacing", "width", "min_width", "vertical_align", "line_height"});
                if (cellStyle.isEmpty()) continue;
                QTextTableCellFormat cellFormat = cell.format().toTableCellFormat();
                const auto line = cellLineHeight(cellStyle.value(QStringLiteral("line_height")), points, document);
                if (line.present) {
                    const auto capability = document->documentLayout()->property("_wikidictCellLineHeightCapability");
                    const auto captured = cellFormat.property(cellOwnerFontProperty);
                    const auto imported = captured.toMap();
                    if (capability.metaType().id() != QMetaType::QString
                        || capability.toString() != QStringLiteral("wikidict.cell-line-height/1")
                        || captured.metaType().id() != QMetaType::QVariantMap || imported.size() != 2
                        || imported.value(QStringLiteral("capability")).toString() != capability.toString()
                        || imported.value(QStringLiteral("font")).metaType().id() != QMetaType::QFont
                        || !expected.value(QStringLiteral("header")).isBool()
                        || !expected.value(QStringLiteral("empty_content")).isBool())
                        throw std::runtime_error("missing native cell owner metrics");
                    QFont font = imported.value(QStringLiteral("font")).value<QFont>();
                    if (expected.value(QStringLiteral("header")).toBool() && font.weight() != QFont::Bold)
                        throw std::runtime_error("inconsistent typed header cell font");
                    if (line.strut) {
                        if (line.strutPoints > 0) font.setPointSizeF(line.strutPoints);
                        else { font.setFamilies(QStringList{zeroFontFamilyName}); font.setStyleStrategy(QFont::NoFontMerging); }
                    }
                    const QFontMetricsF metrics(font);
                    const qreal pixels = metrics.ascent() == 0 && metrics.descent() == 0 ? 0
                        : font.pixelSize() > 0 ? qreal(font.pixelSize()) : font.pointSizeF() * metrics.fontDpi() / 72;
                    if (!std::isfinite(pixels) || pixels < 0) throw std::runtime_error("invalid native cell font");
                    cellFormat.clearProperty(cellOwnerFontProperty);
                    cellFormat.setProperty(cellLineHeightProperty, QVariantMap{
                        {QStringLiteral("capability"), capability.toString()}, {QStringLiteral("font"), font},
                        {QStringLiteral("owner_px"), pixels}, {QStringLiteral("kind"), line.kind},
                        {QStringLiteral("value"), line.value},
                        {QStringLiteral("empty"), expected.value(QStringLiteral("empty_content")).toBool()}});
                }
                const int vertical = cellVerticalAlignment(cellStyle.value(QStringLiteral("vertical_align")));
                if (vertical >= 0) cellFormat.setVerticalAlignment(QTextCharFormat::VerticalAlignment(vertical));
                if (present(cellStyle.value(QStringLiteral("border")))) {
                    const auto spec = cellStyle.value(QStringLiteral("border")).toObject();
                    if (spec.contains(QStringLiteral("edges"))) {
                        if (spec.size() != 1) throw std::runtime_error("invalid cell border union");
                        const auto physical = physicalBorder(spec.value(QStringLiteral("edges")));
                        int hidden = 0;
                        for (int i = 0; i < 4; ++i) {
                            const auto edge = physical[i].toMap();
                            const int mode = edge.value(QStringLiteral("style")).toInt();
                            const qreal width = edge.value(QStringLiteral("width")).toDouble();
                            const auto style = mode == 2 ? QTextFrameFormat::BorderStyle_Solid : mode == 3
                                ? QTextFrameFormat::BorderStyle_Dotted : QTextFrameFormat::BorderStyle_None;
                            const QColor color = edge.value(QStringLiteral("color")).value<QColor>();
                            if (mode == 1) hidden |= 1 << i;
                            if (i == 0) { cellFormat.setTopBorder(width); cellFormat.setTopBorderStyle(style); cellFormat.setTopBorderBrush(color); }
                            else if (i == 1) { cellFormat.setRightBorder(width); cellFormat.setRightBorderStyle(style); cellFormat.setRightBorderBrush(color); }
                            else if (i == 2) { cellFormat.setBottomBorder(width); cellFormat.setBottomBorderStyle(style); cellFormat.setBottomBorderBrush(color); }
                            else { cellFormat.setLeftBorder(width); cellFormat.setLeftBorderStyle(style); cellFormat.setLeftBorderBrush(color); }
                        }
                        cellFormat.setProperty(cellHiddenEdgesProperty, hidden);
                    } else {
                        const Border b = border(cellStyle.value(QStringLiteral("border")));
                        cellFormat.setBorder(b.width); cellFormat.setBorderStyle(b.style); cellFormat.setBorderBrush(b.color);
                    }
                }
                if (present(cellStyle.value(QStringLiteral("padding")))) { const auto e = edges(cellStyle.value(QStringLiteral("padding"))); cellFormat.setTopPadding(e[0]); cellFormat.setRightPadding(e[1]); cellFormat.setBottomPadding(e[2]); cellFormat.setLeftPadding(e[3]); }
                if (present(cellStyle.value(QStringLiteral("border_edges")))) {
                    const auto physical = typedStyle(cellStyle.value(QStringLiteral("border_edges")), {"top", "right", "bottom", "left"});
                    for (const QString &edge : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")}) {
                        if (!present(physical.value(edge))) continue;
                        const Border b = cellBorder(physical.value(edge));
                        if (cellFormat.hasProperty(cellHiddenEdgesProperty)) {
                            const int side = QStringList{"top", "right", "bottom", "left"}.indexOf(edge);
                            cellFormat.setProperty(cellHiddenEdgesProperty, cellFormat.intProperty(cellHiddenEdgesProperty) & ~(1 << side));
                        }
                        if (edge == QStringLiteral("top")) { cellFormat.setTopBorder(b.width); cellFormat.setTopBorderStyle(b.style); cellFormat.setTopBorderBrush(b.color); }
                        else if (edge == QStringLiteral("right")) { cellFormat.setRightBorder(b.width); cellFormat.setRightBorderStyle(b.style); cellFormat.setRightBorderBrush(b.color); }
                        else if (edge == QStringLiteral("bottom")) { cellFormat.setBottomBorder(b.width); cellFormat.setBottomBorderStyle(b.style); cellFormat.setBottomBorderBrush(b.color); }
                        else { cellFormat.setLeftBorder(b.width); cellFormat.setLeftBorderStyle(b.style); cellFormat.setLeftBorderBrush(b.color); }
                    }
                }
                if (present(cellStyle.value(QStringLiteral("width"))))
                    cellFormat.setProperty(cellWidthProperty, tableBoxLength(cellStyle.value(QStringLiteral("width")), points, true));
                if (present(cellStyle.value(QStringLiteral("min_width"))))
                    cellFormat.setProperty(cellMinimumWidthProperty,
                        tableBoxLength(cellStyle.value(QStringLiteral("min_width")), points, false));
                cell.setFormat(cellFormat);
                cellFormatsChanged = true;
                if (present(cellStyle.value(QStringLiteral("letter_spacing")))) {
                    const double spacing = tableBoxLength(cellStyle.value(QStringLiteral("letter_spacing")), points, false)
                        .value(QStringLiteral("value")).toDouble();
                    if (!std::isfinite(spacing) || spacing < 0 || spacing >= double(std::numeric_limits<int>::max()) / 256)
                        throw std::runtime_error("unrepresentable cell letter spacing");
                    QTextCharFormat tracking;
                    tracking.setFontLetterSpacingType(QFont::AbsoluteSpacing);
                    tracking.setFontLetterSpacing(spacing);
                    // Outer cells are normalized before nested tables. A child's
                    // explicit tracking (including zero) then overrides this inherited length.
                    QTextCursor content = cell.firstCursorPosition();
                    content.setPosition(cell.lastCursorPosition().position(), QTextCursor::KeepAnchor);
                    content.mergeCharFormat(tracking);
                }
                // Generated align attributes already resolve inheritance and
                // explicit block overrides. Rewriting every block here erased
                // e.g. the centered middle number of a right-aligned cell.
                textAlignment(cellStyle.value(QStringLiteral("text_align")));
            }
            if (index != cells.size()) throw std::runtime_error("table style cell count mismatch");
        }
        if (markerValue.isString()) {
            // The imported frame can directly follow authored heading/prose.
            // Give the marker its own empty native block in that case; Qt
            // collapses this block against the table without wrapping its frame.
            QTextCursor cursor(document);
            cursor.setPosition(table->firstPosition() - 1);
            if (cursor.currentFrame() != table->parentFrame() || !cursor.atBlockEnd())
                throw std::runtime_error("invalid table list boundary");
            if (!cursor.block().text().isEmpty() || cursor.block().textList()
                || cursor.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)
                || cursor.blockFormat().hasProperty(QTextFormat::BackgroundBrush)) {
                // A direct child table did not consume this block margin. Qt's
                // empty-before-table collapse would newly activate it; keep the
                // same rendered boundary without changing any table margin.
                if (cursor.blockFormat().bottomMargin() > 0) {
                    QTextBlockFormat preceding = cursor.blockFormat();
                    preceding.setBottomMargin(0);
                    cursor.setBlockFormat(preceding);
                }
                QTextBlockFormat empty;
                empty.setTopMargin(0);
                empty.setBottomMargin(0);
                cursor.insertBlock(empty, QTextCharFormat());
            }
            cursor.setPosition(table->firstPosition() - 1);
            if (cursor.currentFrame() != table->parentFrame() || cursor.block().length() != 1
                || table->firstPosition() != cursor.block().position() + 1)
                throw std::runtime_error("invalid native table list block");
            const QString marker = markerValue.toString();
            QTextListFormat list;
            const int level = qMax(1, (indent - 30) / 16 + 1);
            list.setIndent(level);
            if (marker == QStringLiteral("•")) {
                list.setStyle(QTextListFormat::ListDisc);
            } else {
                // The compiler emits decimal, alphabetic, Roman and dotted
                // labels. Preserve the complete label via Qt's prefix/suffix;
                // use one ASCII counter character, avoiding integer overflow.
                int digit = marker.size() - 1;
                while (digit >= 0 && !((marker[digit] >= QChar('0') && marker[digit] <= QChar('9'))
                    || (marker[digit] >= QChar('a') && marker[digit] <= QChar('z'))
                    || (marker[digit] >= QChar('A') && marker[digit] <= QChar('Z')))) --digit;
                if (digit < 0) throw std::runtime_error("unrepresentable compiled table list label");
                const QChar counter = marker[digit];
                const bool decimal = counter >= QChar('0') && counter <= QChar('9');
                const bool upper = counter >= QChar('A') && counter <= QChar('Z');
                list.setStyle(decimal ? QTextListFormat::ListDecimal
                    : upper ? QTextListFormat::ListUpperAlpha : QTextListFormat::ListLowerAlpha);
                list.setStart(counter.unicode() - (decimal ? '0' : upper ? 'A' : 'a') + (decimal ? 0 : 1));
                list.setNumberPrefix(marker.left(digit));
                list.setNumberSuffix(marker.mid(digit + 1));
            }
            QTextBlockFormat block = cursor.blockFormat();
            block.setProperty(tableListOwnerProperty, table->objectIndex());
            block.setIndent(0);
            block.setLeftMargin(indent - level * document->indentWidth());
            block.setAlignment(Qt::AlignLeft);
            block.setLayoutDirection(Qt::LeftToRight);
            // A float does not advance the surrounding text flow. Retain the
            // native list item's ordinary line so its label cannot collide with
            // following prose. Qt preserves a block with an explicit background
            // instead of collapsing it into the table; this brush paints nothing.
            if (format.position() != QTextFrameFormat::InFlow)
                block.setBackground(QColor(Qt::transparent));
            cursor.setBlockFormat(block);
            QTextCharFormat character = cursor.blockCharFormat();
            character.setFontPointSize(points);
            cursor.setBlockCharFormat(character);
            cursor.createList(list);
        }
        if (cellFormatsChanged) {
            // The first cell's delimiter precedes the Table's content range.
            // Its format edit alone cannot invalidate the cached Table size.
            document->markContentsDirty(table->firstPosition(),
                table->lastPosition() - table->firstPosition() + 1);
        }
    }
    for (const auto &record : records) if (present(record.value.value(QStringLiteral("float_viewport")))) {
        QTextTable *table = record.ordinal >= 0 ? tables[record.ordinal] : nullptr;
        if (!table || table->parentFrame() != document->rootFrame())
            throw std::runtime_error("unmapped table float viewport");
        materializeTableFloatViewport(document, table, record.value,
            record.value.value(QStringLiteral("container_points")).toDouble());
    }
    // Complete all existing cell/table normalization before wrapping; public
    // frame insertion retains table objects but changes their positions.
    for (const auto &record : records) if (present(record.value.value(QStringLiteral("block_viewport")))) {
        QTextFrame *grid = record.ordinal >= 0 ? tables[record.ordinal] : emptyTables.value(record.empty).data();
        if (!grid) throw std::runtime_error("unmapped table viewport");
        materializeTableBlockViewport(document, grid, record.value,
            record.value.value(QStringLiteral("container_points")).toDouble());
    }
}

inline QVariantList inlineTableOwners(QTextDocument *document) {
    QVariantList result;
    const auto visit = [&](auto &&self, QTextFrame *frame) -> void {
        if (auto *table = qobject_cast<QTextTable *>(frame); table && table->format().intProperty(tableDisplayProperty) > 0) {
            const int first = table->firstPosition() - 1, last = table->lastPosition() + 1;
            const auto begin = document->findBlock(first), end = document->findBlock(last);
            if (begin.position() != first || begin.length() != 1 || end.position() != last || end.length() != 1)
                throw std::runtime_error("inline table must own an isolated line");
            result.append(QVariantMap{{QStringLiteral("first"), first}, {QStringLiteral("last"), last},
                {QStringLiteral("direction"), int(Qt::LayoutDirectionAuto)}, {QStringLiteral("joins"), QVariantList{}},
                {QStringLiteral("parts"), QVariantList{QVariantMap{{QStringLiteral("kind"), QStringLiteral("frame")},
                    {QStringLiteral("object"), table->objectIndex()}}}}});
        }
        for (auto *child : frame->childFrames()) self(self, child);
    };
    visit(visit, document->rootFrame());
    return result;
}
inline void registerInlineTableOwners(QTextDocument *document) {
    const auto owners = inlineTableOwners(document);
    if (!owners.isEmpty() && !LogicalFlow::registerOwners(document, owners))
        throw std::runtime_error("refused inline table owner");
}

inline const QString inlineImageScheme = QStringLiteral("wikidict-inline-image");
inline constexpr char imageDarkThemeProperty[] = "wikidict.image.effectiveDarkTheme";
inline constexpr int inlineImageStateProperty = QTextFormat::UserProperty + 0x5744;
inline constexpr int inlineImageStatusProperty = inlineImageStateProperty + 1;
inline constexpr int inlineImageExplanationProperty = inlineImageStateProperty + 2;
inline constexpr int inlineImageBorderProperty = inlineImageStateProperty + 3;
inline constexpr int figureImageProperty = QTextFormat::UserProperty + 0x57b0;
inline constexpr int imageOriginalSizeProperty = figureImageProperty + 1;
inline constexpr int imageLayoutSizeProperty = figureImageProperty + 2;
inline constexpr int imageCompiledDataProperty = figureImageProperty + 3;
inline QJsonObject checkedStaticPoster(const QJsonObject &image) {
    const auto value = image.value(QStringLiteral("static_poster"));
    if (!present(value)) return {};
    if (!value.isObject()) throw std::runtime_error("invalid static poster");
    const auto poster = value.toObject();
    if (poster.size() != 4 || poster.value("policy") != QStringLiteral("three_d_stl_v1")
        || !poster.value("label").isString() || poster.value("label").toString().toUtf8().size() > 32 * 1024 * 1024
        || !poster.value("file_sha1").isString() || !poster.value("file_timestamp").isString()
        || !image.value("file").toString().endsWith(QStringLiteral(".stl"), Qt::CaseInsensitive))
        throw std::runtime_error("invalid static poster policy");
    const QString hash = poster.value("file_sha1").toString();
    if (hash.size() != 40) throw std::runtime_error("invalid static poster identity");
    for (QChar ch : hash)
        if (!(ch >= QChar('0') && ch <= QChar('9')) && !(ch >= QChar('a') && ch <= QChar('f')))
            throw std::runtime_error("invalid static poster identity");
    const QString stamp = poster.value("file_timestamp").toString();
    const auto parsed = QDateTime::fromString(stamp, Qt::ISODate);
    if (stamp.size() != 20 || !parsed.isValid()
        || parsed.toUTC().toString(QStringLiteral("yyyy-MM-dd'T'HH:mm:ss'Z'")) != stamp)
        throw std::runtime_error("invalid static poster timestamp");
    const auto axis = [](const QJsonValue &v) {
        const double n = v.toDouble(-1);
        return v.isDouble() && std::isfinite(n) && n > 0 && n <= 4294967295.0 && std::floor(n) == n;
    };
    if (!axis(image.value("width_px")) || !axis(image.value("height_px"))
        || quint64(image.value("height_px").toDouble()) != (quint64(image.value("width_px").toDouble()) * 3 + 2) / 4
        || present(image.value("map")) || present(image.value("svg_language")) || present(image.value("dark_mode_filter")))
        throw std::runtime_error("unsupported static poster geometry or combination");
    return poster;
}
inline QJsonObject checkedImage(const QJsonValue &value) {
    if (!value.isObject()) throw std::runtime_error("invalid inline image");
    const QJsonObject image = value.toObject();
    if (!image.value(QStringLiteral("file")).isString() || image.value(QStringLiteral("file")).toString().isEmpty())
        throw std::runtime_error("invalid inline image file");
    const QString file = image.value(QStringLiteral("file")).toString();
    if (file.toUtf8().size() > 32 * 1024 * 1024 || file.startsWith(QChar(' ')) || file.endsWith(QChar(' ')))
        throw std::runtime_error("invalid canonical inline image file");
    for (const QChar character : file)
        if (character.unicode() < 0x20 || (character.unicode() >= 0x7f && character.unicode() <= 0x9f)
            || QStringLiteral("_[]{}<>|#").contains(character)) throw std::runtime_error("invalid canonical inline image file");
    for (auto it = image.begin(); it != image.end(); ++it)
        if (it.key() != QStringLiteral("file") && it.key() != QStringLiteral("width_px") && it.key() != QStringLiteral("height_px")
            && it.key() != QStringLiteral("alt") && it.key() != QStringLiteral("tooltip")
            && it.key() != QStringLiteral("border") && it.key() != QStringLiteral("map")
            && it.key() != QStringLiteral("dark_mode_filter") && it.key() != QStringLiteral("svg_language")
            && it.key() != QStringLiteral("static_poster")) throw std::runtime_error("unknown inline image field");
    for (const QString &key : {QStringLiteral("width_px"), QStringLiteral("height_px")}) {
        const QJsonValue axis = image.value(key); if (!present(axis)) continue;
        const double n = axis.toDouble(-1);
        if (!axis.isDouble() || !std::isfinite(n) || n <= 0 || n > 4294967295.0 || std::floor(n) != n)
            throw std::runtime_error("invalid inline image dimension");
    }
    for (const QString &key : {QStringLiteral("alt"), QStringLiteral("tooltip")})
        if (present(image.value(key)) && !image.value(key).isString()) throw std::runtime_error("invalid inline image text");
    if (image.contains(QStringLiteral("border")) && !image.value(QStringLiteral("border")).isBool())
        throw std::runtime_error("invalid inline image border");
    if (present(image.value(QStringLiteral("map")))) CompiledImageMap::validate(image.value(QStringLiteral("map")));
    const QJsonValue filter = image.value(QStringLiteral("dark_mode_filter"));
    if (present(filter) && (!filter.isString() || filter.toString() != QStringLiteral("invert_hue_rotate_180")))
        throw std::runtime_error("invalid inline image dark mode filter");
    const auto svgLanguage = image.value(QStringLiteral("svg_language"));
    if (present(svgLanguage)) {
        if (!svgLanguage.isString() || svgLanguage.toString().isEmpty()) throw std::runtime_error("invalid SVG language");
        bool segment = false;
        for (const QChar ch : svgLanguage.toString()) {
            if (ch == QChar('-')) { if (!segment) throw std::runtime_error("invalid SVG language"); segment = false; }
            else if (ch >= QChar('a') && ch <= QChar('z')) segment = true;
            else throw std::runtime_error("invalid SVG language");
        }
        if (!segment || svgLanguage.toString().toUtf8().size() > 32 * 1024 * 1024) throw std::runtime_error("invalid SVG language");
    }
    checkedStaticPoster(image);
    return image;
}
inline QUrl inlineImageUrl(const QJsonObject &image) {
    return QUrl(inlineImageScheme + QChar(':') + QString::fromLatin1(QJsonDocument(image).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
}
inline QJsonObject inlineImageData(const QUrl &url) {
    if (url.scheme() != inlineImageScheme || url.hasQuery() || url.hasFragment() || !url.host().isEmpty())
        throw std::runtime_error("invalid inline image resource");
    const QByteArray encoded = url.path().toLatin1();
    const QByteArray bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error; const QJsonDocument value = QJsonDocument::fromJson(bytes, &error);
    if (bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) != encoded || error.error != QJsonParseError::NoError || !value.isObject())
        throw std::runtime_error("invalid inline image metadata");
    return checkedImage(value.object());
}
inline QString inlineImageHtml(const QJsonValue &value) {
    const QJsonObject image = checkedImage(value);
    QString html = QStringLiteral("<img src=\"%1\"").arg(inlineImageUrl(image).toString(QUrl::FullyEncoded).toHtmlEscaped());
    for (const auto &axis : {qMakePair(QStringLiteral("width_px"), QStringLiteral("width")), qMakePair(QStringLiteral("height_px"), QStringLiteral("height"))})
        if (present(image.value(axis.first))) html += QStringLiteral(" %1=\"%2\"").arg(axis.second).arg(qMin(10000.0, image.value(axis.first).toDouble()), 0, 'g', 17);
    if (present(image.value(QStringLiteral("alt")))) html += QStringLiteral(" alt=\"%1\"").arg(image.value(QStringLiteral("alt")).toString().toHtmlEscaped());
    return html + QStringLiteral(">");
}
inline void imageDimensions(QTextImageFormat &format, const QJsonObject &image, const QTextDocument *document, const QSizeF &intrinsic = {}, bool vectorImage = false) {
    const qreal maximum = maximumFontPoints(document) * QFontMetricsF(QFont()).fontDpi() / 72;
    const QJsonObject figure = QJsonDocument::fromJson(format.property(figureImageProperty).toByteArray()).object();
    const bool framed = figure.value(QStringLiteral("format")).toString() == QStringLiteral("framed")
        && !present(image.value("static_poster"));
    const bool hasWidth = !framed && present(image.value(QStringLiteral("width_px")));
    const bool hasHeight = !framed && present(image.value(QStringLiteral("height_px")));
    const qreal width = hasWidth ? image.value(QStringLiteral("width_px")).toDouble() : (intrinsic.isValid() ? intrinsic.width() : 1);
    const qreal height = hasHeight ? image.value(QStringLiteral("height_px")).toDouble() : (intrinsic.isValid() ? intrinsic.height() : 1);
    qreal w = qMin(maximum, width), h = qMin(maximum, height);
    qreal layoutWidth = w, layoutHeight = h;
    if (intrinsic.isValid() && !present(image.value("static_poster"))) {
        const auto fitBoxWidth = [&](qreal boundHeight) {
            const qreal ideal = intrinsic.width() * boundHeight / intrinsic.height();
            const qreal up = std::ceil(ideal);
            return qMax(1.0, std::round(up * intrinsic.height() / intrinsic.width()) > boundHeight ? std::floor(ideal) : up);
        };
        qreal displayWidth = width, displayHeight = height;
        // Height-only vector images are not limited by their natural width.
        if (!hasWidth && hasHeight && vectorImage) displayWidth = fitBoxWidth(height);
        else if (!hasHeight || width * intrinsic.height() <= height * intrinsic.width())
            displayHeight = qMax(1.0, std::round(intrinsic.height() * width / intrinsic.width()));
        else if (hasHeight) displayWidth = fitBoxWidth(height);
        if (!figure.isEmpty() && !framed && !vectorImage && displayWidth > intrinsic.width()) {
            displayWidth = intrinsic.width(); displayHeight = intrinsic.height();
        }
        layoutWidth = displayWidth; layoutHeight = displayHeight;
        // Bound both authored axes before display, retaining MediaWiki's integer
        // client sizing rather than imposing a fractional generic contain-fit.
        const qreal factor = qMin(1.0, qMin(maximum / displayWidth, maximum / displayHeight));
        w = displayWidth * factor; h = displayHeight * factor;
    } else if (hasWidth && !hasHeight) h = w;
    else if (hasHeight && !hasWidth) w = h;
    if (!intrinsic.isValid()) { layoutWidth = w; layoutHeight = h; }
    // Authored dimensions describe content; the image handler adds the outside border.
    format.setWidth(w); format.setHeight(h);
    if (!figure.isEmpty() || present(image.value(QStringLiteral("map")))) {
        format.setProperty(imageOriginalSizeProperty, intrinsic);
        format.setProperty(imageLayoutSizeProperty, QSizeF(layoutWidth, layoutHeight));
        if (present(image.value(QStringLiteral("map")))) format.setProperty(imageCompiledDataProperty, image);
    }
    if (!format.hasProperty(figureImageProperty) && image.value(QStringLiteral("border")).toBool()) format.setProperty(inlineImageBorderProperty, true);
    else format.clearProperty(inlineImageBorderProperty);
}
inline void normalizeImages(QTextDocument *document) {
    struct ImageEdit { int position; QTextImageFormat format; };
    QVector<ImageEdit> edits;
    for (QTextBlock block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment(); if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            QTextImageFormat format = fragment.charFormat().toImageFormat();
            const QUrl url(format.name()); if (url.scheme() != inlineImageScheme) continue;
            const QJsonObject image = inlineImageData(url);
            format.setProperty(inlineImageExplanationProperty, spanExplanation(format));
            if (present(image.value("static_poster"))) format.setVerticalAlignment(QTextCharFormat::AlignTop);
            if (present(image.value(QStringLiteral("alt")))) format.setProperty(QTextFormat::ImageAltText, image.value(QStringLiteral("alt")).toString());
            else format.clearProperty(QTextFormat::ImageAltText);
            if (present(image.value(QStringLiteral("tooltip")))) {
                format.setProperty(QTextFormat::ImageTitle, image.value(QStringLiteral("tooltip")).toString());
                format.setToolTip(image.value(QStringLiteral("tooltip")).toString());
            } else format.clearProperty(QTextFormat::ImageTitle);
            format.setProperty(inlineImageStateProperty, 1);
            format.setProperty(inlineImageStatusProperty, QStringLiteral("Loading image."));
            imageDimensions(format, image, document);
            edits.append({fragment.position(), format});
        }
    if (!edits.isEmpty()) {
        const bool layoutEnabled = document->isLayoutEnabled();
        document->setLayoutEnabled(false);
        const auto restoreLayout = qScopeGuard([document, layoutEnabled] {
            document->setLayoutEnabled(layoutEnabled);
        });
        QTextCursor cursor(document);
        cursor.beginEditBlock();
        const auto finishEdit = qScopeGuard([&cursor] { cursor.endEditBlock(); });
        for (const ImageEdit &edit : edits) {
            cursor.setPosition(edit.position);
            cursor.setPosition(edit.position + 1, QTextCursor::KeepAnchor);
            cursor.setCharFormat(edit.format);
        }
    }
    // A cached QTextDocument image can bypass the provider after setHtml,
    // but the new occurrence formats still need current state and geometry.
    // Reuse the installed provider's guarded request/apply path once per URL.
    const auto provider = document->resourceProvider();
    if (provider) {
        QSet<QUrl> requested;
        for (const ImageEdit &edit : edits) {
            const QUrl url(edit.format.name());
            if (!requested.contains(url)) { requested.insert(url); provider(url); }
        }
    }
}

inline QString scaledText(const QString &html, double scale, const QString &tooltip,
                          Basis basis = Basis::Context, qreal normalBodyPoints = 0,
                          bool small = false, bool superscript = false, bool subscript = false, qreal contextPoints = 0,
                          const QJsonValue &advisory = QJsonValue(), bool metadataOnly = false, int sourceRun = -1, const QJsonObject &linkPaint = {}, qint64 linkOwner = -1, qreal linkEm = 0, bool linkUnderline = false, const QJsonValue &fontFeatures = {}) {
    QJsonObject metadata{{"scale", scale}, {"tooltip", tooltip}};
    if (fontFeaturePolicy(fontFeatures) != FontFeaturePolicy::Legacy) metadata.insert("font_features", fontFeatures);
    if (!linkPaint.isEmpty()) {
        MissingFigurePaint::validate(linkPaint, linkEm);
        if (linkOwner < (qint64(1) << 32) || linkOwner >= (qint64(1) << 33))
            throw std::runtime_error("invalid compiled link span owner");
        metadata.insert("link_paint", linkPaint); metadata.insert("link_owner", double(linkOwner)); metadata.insert("link_em", linkEm); metadata.insert("link_underline", linkUnderline);
    }
    if (present(advisory)) {
        if (!advisory.isString()) throw std::runtime_error("invalid span advisory");
        metadata.insert(QStringLiteral("advisory"), advisory);
    }
    if (sourceRun < -1) throw std::runtime_error("invalid renderer source run");
    if (sourceRun >= 0) metadata.insert(QStringLiteral("source_run"), sourceRun);
    if (metadataOnly) metadata.insert(QStringLiteral("metadata_only"), true);
    if (basis == Basis::NormalBody || basis == Basis::CssPx) {
        metadata.insert(QStringLiteral("basis"), basis == Basis::CssPx ? QStringLiteral("css_px") : QStringLiteral("normal_body"));
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
    QJsonValue advisory;
    bool metadataOnly = false;
    int sourceRun = -1;
    QJsonObject linkPaint;
    qint64 linkOwner = -1;
    qreal linkEm = 0;
    bool linkUnderline = false;
    FontFeaturePolicy fontFeatures = FontFeaturePolicy::Legacy;
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
        const bool cssPx = basisValue.isString() && basisValue.toString() == QStringLiteral("css_px");
        const bool absolute = normalBody || cssPx;
        const QJsonValue metadataValue = value.value(QStringLiteral("metadata_only"));
        const bool metadataOnly = metadataValue.toBool();
        const QJsonValue advisory = value.value(QStringLiteral("advisory"));
        const QJsonValue sourceRun = value.value(QStringLiteral("source_run"));
        const bool hasSourceRun = !sourceRun.isUndefined();
        const bool hasLinkPaint = present(value.value("link_paint"));
        const auto fontFeatures = fontFeaturePolicy(value.value("font_features"));
        const double run = sourceRun.toDouble(-1);
        if (error.error != QJsonParseError::NoError || !payload.isObject()
            || !value.value(QStringLiteral("scale")).isDouble() || !std::isfinite(scale)
            || scale < 0 || (!absolute && scale == 1 && !metadataOnly) || !value.value(QStringLiteral("tooltip")).isString()
            || (!metadataValue.isUndefined() && !metadataValue.isBool())
            || (present(advisory) && !advisory.isString())
            || (hasSourceRun && (!sourceRun.isDouble() || !std::isfinite(run)
                || run < 0 || run > std::numeric_limits<int>::max() || std::floor(run) != run))
            || (metadataOnly && (scale != 1 || absolute || (!present(advisory) && !hasSourceRun && !hasLinkPaint && fontFeatures == FontFeaturePolicy::Legacy)
                || value.contains(QStringLiteral("context_points")) || value.contains(QStringLiteral("legacy_flags"))))
            || (!basisValue.isUndefined() && (!basisValue.isString()
                || (basisValue.toString() != QStringLiteral("context") && !absolute))))
            throw std::runtime_error("invalid renderer font-scale metadata");
        ScaleInfo info{scale, value.value(QStringLiteral("tooltip")).toString()};
        if (hasLinkPaint) {
            const auto owner = value.value("link_owner"); const auto em = value.value("link_em");
            const double id = owner.toDouble(-1);
            if (!owner.isDouble() || !std::isfinite(id) || std::floor(id) != id
                || id < double(qint64(1) << 32) || id >= double(qint64(1) << 33) || !em.isDouble())
                throw std::runtime_error("invalid compiled link span identity");
            info.linkPaint = MissingFigurePaint::validate(value.value("link_paint"), em.toDouble());
            info.linkOwner = qint64(id); info.linkEm = em.toDouble();
            if (!value.value("link_underline").isBool()) throw std::runtime_error("invalid compiled link decoration");
            info.linkUnderline = value.value("link_underline").toBool();
        } else if (value.contains("link_owner") || value.contains("link_em") || value.contains("link_underline"))
            throw std::runtime_error("unowned compiled link span metadata");
        info.fontFeatures = fontFeatures;
        info.advisory = advisory;
        info.metadataOnly = metadataOnly;
        if (hasSourceRun) info.sourceRun = int(run);
        if (absolute) {
            const QJsonValue body = value.value(QStringLiteral("body_points"));
            const QJsonValue flags = value.value(QStringLiteral("legacy_flags"));
            const double n = flags.toDouble(-1);
            if (!body.isDouble() || !std::isfinite(body.toDouble()) || body.toDouble() <= 0
                || !flags.isDouble() || n < 0 || n > 7 || std::floor(n) != n)
                throw std::runtime_error("invalid normal-body font-scale metadata");
            info.basis = cssPx ? Basis::CssPx : Basis::NormalBody;
            info.normalBodyPoints = body.toDouble();
            info.legacyFlags = int(n);
        }
        if (!absolute && scale > 0) {
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
        out += QStringLiteral("<span title=\"") + token + QChar('"');
        if (info.sourceRun >= 0)
            out += QStringLiteral(" data-wikidict-source-run=\"%1\"").arg(info.sourceRun);
        out += QChar('>');
        cursor = end + 2;
    }
    out += escaped.mid(cursor);
    return out;
}

// Qt imports -qt-user-state without creating text or changing paragraph layout.
// Only our generated paragraph tag can allocate a temporary state; normalization
// transfers that association to a format property and restores the stock state.
inline QString prepareParagraphRuns(const QString &html, QHash<int, int> &runs) {
    QString out;
    qsizetype cursor = 0, at = 0;
    while ((at = html.indexOf(paragraphRunOpen, cursor)) >= 0) {
        const qsizetype begin = at + paragraphRunOpen.size();
        const qsizetype end = html.indexOf(QStringLiteral("\" "), begin);
        if (end < 0) throw std::runtime_error("invalid source paragraph marker");
        const QString number = html.mid(begin, end - begin);
        bool ok = false;
        const int run = number.toInt(&ok);
        if (!ok || run < 0 || number != QString::number(run)
            || runs.size() >= std::numeric_limits<int>::max() - 1)
            throw std::runtime_error("invalid source paragraph run");
        const qsizetype tagEnd = html.indexOf(QChar('>'), end + 2);
        if (tagEnd < 0) throw std::runtime_error("unterminated source paragraph");
        QString attributes = html.mid(end + 2, tagEnd - end - 2);
        const QString style = QStringLiteral("style='");
        const qsizetype styleAt = attributes.indexOf(style);
        if (styleAt < 0 || attributes.indexOf(style, styleAt + style.size()) >= 0
            || attributes.contains(QStringLiteral("-qt-user-state")))
            throw std::runtime_error("invalid generated source paragraph style");
        const int state = std::numeric_limits<int>::min() + int(runs.size());
        runs.insert(state, run);
        attributes.insert(styleAt + style.size(), QStringLiteral("-qt-user-state:%1;").arg(state));
        out += html.mid(cursor, at - cursor) + QStringLiteral("<p ") + attributes + QChar('>');
        cursor = tagEnd + 1;
    }
    out += html.mid(cursor);
    return out;
}

inline bool normalizeParagraphRuns(QTextDocument *document, const QHash<int, int> &runs) {
    const QPointer<QTextDocument> guard(document);
    if (!guard) return false;
    if (runs.isEmpty()) return true;
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    if (!guard || !layout || document->documentLayout() != layout) return false;
    struct Edit { QTextBlock block; int run; };
    QVector<Edit> edits;
    QSet<int> found;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        const auto item = runs.constFind(block.userState());
        if (item == runs.cend()) continue;
        if (found.contains(item.key())) throw std::runtime_error("duplicate source paragraph state");
        found.insert(item.key());
        edits.append({block, item.value()});
    }
    if (found.size() != runs.size()) throw std::runtime_error("source paragraph lost during import");
    QTextCursor transaction(document);
    transaction.beginEditBlock();
    for (auto &edit : edits) {
        auto format = edit.block.blockFormat();
        format.setProperty(sourceRunProperty, edit.run);
        QTextCursor cursor(edit.block);
        cursor.setBlockFormat(format);
        edit.block.setUserState(-1);
    }
    const int revision = document->revision();
    const int count = document->characterCount();
    transaction.endEditBlock();
    // Edit completion can synchronously recompose the document or replace its
    // layout. Never apply the remaining old HTML metadata to that replacement.
    return guard && layout && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count;
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
                // Scale-free metadata leaves size and other inherited font traits intact.
                if (!marker->metadataOnly) {
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
                        if (marker->basis == Basis::NormalBody || marker->basis == Basis::CssPx) {
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
                            points = boundedFontPoints(marker->basis == Basis::CssPx ? cssPixelFontBase(marker->normalBodyPoints)
                                : marker->normalBodyPoints, marker->scale, maximumFontPoints(document), ratio);
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
                        if (marker->basis == Basis::CssPx
                            && format.fontFamilies().toStringList().contains(zeroFontFamilyName))
                            format.setFontFamilies(document->defaultFont().families());
                    }
                }
                applyFontFeatures(format, marker->fontFeatures, document->defaultFont());
                if (!marker->linkPaint.isEmpty()) {
                    if (!format.isAnchor() || format.anchorHref().isEmpty() || format.isImageFormat())
                        throw std::runtime_error("compiled link span lost its action");
                    format.setProperty(MissingFigurePaint::policyProperty, MissingFigurePaint::fixedPolicy);
                    format.setProperty(MissingFigurePaint::ownerProperty, marker->linkOwner);
                    format.setProperty(MissingFigurePaint::fixedPolicyProperty, marker->linkPaint.toVariantMap());
                    format.setProperty(MissingFigurePaint::outlineProperty, MissingFigurePaint::outline(marker->linkPaint, marker->linkEm));
                    format.setProperty(MissingFigurePaint::underlineProperty, marker->linkUnderline);
                    const bool zeroLink = marker->scale == 0 || format.fontFamilies().toStringList().contains(zeroFontFamilyName);
                    format.setProperty(MissingFigurePaint::zeroFontProperty, zeroLink);
                    format.setForeground(zeroLink ? QColor(Qt::transparent)
                        : QColor(marker->linkPaint.value("normal").toObject().value("foreground").toString()));
                    format.setUnderlineStyle(!zeroLink && (marker->linkUnderline || marker->linkPaint.value("normal").toObject().value("underline").toBool())
                        ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
                }
                if (marker->sourceRun >= 0) format.setProperty(sourceRunProperty, marker->sourceRun);
                if (present(marker->advisory)) {
                    format.setProperty(spanAdvisoryProperty, marker->advisory.toString());
                    format.setProperty(spanExpansionProperty, marker->tooltip);
                    format.setToolTip(marker->advisory.toString());
                } else if (marker->tooltip.isEmpty()) format.clearProperty(QTextFormat::TextToolTip);
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
        if (blockFormat.lineHeightType() == QTextBlockFormat::SingleHeight)
            blockFormat.setProperty(generatedParentStrutProperty, true);
        blockFormat.setLineHeight(height, QTextBlockFormat::MinimumHeight);
        QTextCursor blockCursor(zero.block);
        blockCursor.setBlockFormat(blockFormat);
    }
    cursor.endEditBlock();
}

inline void finishFloatingLayout(QTextDocument *document) {
    if (!document || !document->isLayoutEnabled()) return;
    QVector<QTextFrame *> pending{document->rootFrame()};
    while (!pending.isEmpty()) {
        QTextFrame *frame = pending.takeLast();
        if (frame != document->rootFrame() && frame->frameFormat().position() != QTextFrameFormat::InFlow) {
            // Qt's incremental layout can reuse a float-displaced line offset
            // without advancing the following block by that displacement.
            // A whole-range invalidation while enabled lays out the flow
            // together, preserving authored floats, margins and text formats.
            document->markContentsDirty(0, document->characterCount());
            return;
        }
        for (QTextFrame *child : frame->childFrames()) pending.append(child);
    }
}

inline void setHtml(QTextDocument *document, const QString &html) {
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(paragraphRunOpen) && !html.contains(inlineImageScheme + QChar(':'))) { document->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    QHash<int, int> paragraphRuns;
    const QString fontHtml = prepare(prepareParagraphRuns(html, paragraphRuns), markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    document->setHtml(prepared);
    if (!normalizeParagraphRuns(document, paragraphRuns)) return;
    normalize(document, markers);
    normalizeTables(document, tables, tableCount);
    normalizeImages(document);
    registerInlineTableOwners(document);
    finishFloatingLayout(document);
}

template <typename AfterImport>
inline void setHtml(QTextBrowser *browser, const QString &html, AfterImport afterImport) {
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(paragraphRunOpen) && !html.contains(inlineImageScheme + QChar(':'))) {
        browser->setHtml(html); afterImport(); return;
    }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    QHash<int, int> paragraphRuns;
    const QString fontHtml = prepare(prepareParagraphRuns(html, paragraphRuns), markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    const QPointer<QTextBrowser> browserGuard(browser);
    const QPointer<QTextDocument> document(browser->document());
    browser->setHtml(prepared);
    // The owning compositor completes its structural edit before table
    // traversal, then may batch the following format normalization separately.
    afterImport();
    if (!browserGuard || !document || browser->document() != document) return;
    if (!normalizeParagraphRuns(document, paragraphRuns)
        || !browserGuard || !document || browser->document() != document) return;
    normalize(browser->document(), markers);
    normalizeTables(browser->document(), tables, tableCount);
    normalizeImages(browser->document());
    finishFloatingLayout(browser->document());
}
inline void setHtml(QTextBrowser *browser, const QString &html) {
    setHtml(browser, html, [] {});
}
} // namespace SemanticHtml
