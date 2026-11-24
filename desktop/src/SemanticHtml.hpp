#pragma once

#include "CompiledImageMap.hpp"
#include "TableCellLayers.hpp"
#include "CompiledContent.hpp"
#include "ReferencePolicy.hpp"
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
inline void applyFontFamily(QFont &font, const QJsonValue &value) {
    CompiledContent::containerFontFamily(value);
    if (!CompiledContent::present(value)) return;
    QStringList names;
    QString generic = QStringLiteral("sans_serif");
    if (value.isObject()) {
        const auto stack = value.toObject().value(QStringLiteral("stack")).toObject();
        for (const auto &name : stack.value(QStringLiteral("names")).toArray()) names.append(name.toString());
        generic = stack.value(QStringLiteral("fallback")).toString();
    }
    // The request is data, not CSS and not a claim about an installed face.
    // Keep ordinary glyph fallback; the closed generic is a native style hint.
    font.setStyleHint(generic == QStringLiteral("serif") ? QFont::Serif : QFont::SansSerif,
        QFont::StyleStrategy(font.styleStrategy() & ~QFont::NoFontMerging));
    const auto terminal = font.defaultFamily();
    CompiledContent::require(!terminal.isEmpty());
    names.append(terminal);
    font.setFamilies(names);
}
inline const QString markerOpen = QStringLiteral("<span data-wikidict-font-scale=\"");
inline const QString scalePrefix = QStringLiteral("wikidict-font-scale:scaled:");
inline const QString escapedPrefix = QStringLiteral("wikidict-font-scale:escaped:");
inline const QString reservedPrefix = QStringLiteral("wikidict-font-scale:");
// Only the renderer may attach this scalar provenance. Authored identical
// Unicode controls remain ordinary text and must never be filtered by value.
inline constexpr int generatedIsolateProperty = QTextFormat::UserProperty + 0x5860;
inline bool isGeneratedIsolateScalar(int scalar) { return scalar >= 0x2066 && scalar <= 0x2069; }
inline QString generatedIsolateHtml(ushort scalar) {
    if (!isGeneratedIsolateScalar(scalar)) throw std::runtime_error("invalid generated isolate");
    const QJsonObject metadata{{"scale", 1}, {"tooltip", ""}, {"metadata_only", true}, {"generated_isolate", int(scalar)}};
    const auto encoded = QJsonDocument(metadata).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    return markerOpen + QString::fromLatin1(encoded) + QStringLiteral("\">")
        + QChar(scalar) + QStringLiteral("</span>");
}
inline QList<int> generatedIsolatePositions(const QTextDocument *document) {
    QList<int> positions;
    for (auto block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().hasProperty(generatedIsolateProperty)) continue;
            const auto tag = fragment.charFormat().property(generatedIsolateProperty);
            if (tag.metaType().id() != QMetaType::Int || !isGeneratedIsolateScalar(tag.toInt()))
                throw std::runtime_error("invalid generated isolate provenance");
            for (int i = 0; i < fragment.length(); ++i) {
                if (document->characterAt(fragment.position() + i).unicode() != tag.toInt())
                    throw std::runtime_error("generated isolate provenance no longer matches source");
                positions.append(fragment.position() + i);
            }
        }
    return positions;
}
inline constexpr int sourceRunProperty = QTextFormat::UserProperty + 0x57c0;
inline constexpr int sourceBoundaryProperty = QTextFormat::UserProperty + 0x57c2;
inline const QString paragraphRunOpen = QStringLiteral("<p data-wikidict-source-run=\"");
inline constexpr int spanAdvisoryProperty = QTextFormat::UserProperty + 0x5748;
inline constexpr int spanExpansionProperty = QTextFormat::UserProperty + 0x5749;

inline QString spanExplanation(const QTextCharFormat &format) {
    return format.hasProperty(spanAdvisoryProperty)
        ? format.stringProperty(spanExpansionProperty) : format.toolTip();
}

inline constexpr int authoredRuleProperty = QTextFormat::UserProperty + 0x5803;
inline const QString authoredRuleMarkerOpen = QStringLiteral("<hr data-wikidict-authored-rule=\"");
inline QVariantMap authoredRuleMetadata(const QJsonObject &block, qreal normalBodyCssPixels, bool dark) {
    const auto style = CompiledContent::ruleStyle(block);
    CompiledContent::require(!style.isEmpty() && std::isfinite(normalBodyCssPixels) && normalBodyCssPixels > 0);
    const auto length = [&](const QJsonValue &value) {
        const auto spec = value.toObject();
        const qreal result = spec.value(QStringLiteral("value")).toDouble()
            * (spec.value(QStringLiteral("unit")) == QStringLiteral("em") ? normalBodyCssPixels : 1);
        CompiledContent::require(std::isfinite(result) && result >= 0);
        return result;
    };
    const auto color = style.value(QStringLiteral("fill")).toObject();
    QColor fill(Qt::transparent);
    if (color.contains(QStringLiteral("rgb"))) fill = QColor(color.value(QStringLiteral("rgb")).toString());
    else if (color.contains(QStringLiteral("light_dark")))
        fill = QColor(color.value(QStringLiteral("light_dark")).toObject().value(dark ? QStringLiteral("dark") : QStringLiteral("light")).toString());
    QVariantList margins;
    for (const auto &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")})
        margins.append(length(style.value(QStringLiteral("margins")).toObject().value(side)));
    QVariantMap result{{QStringLiteral("capability"), QStringLiteral("wikidict.authored-rule/1")},
        {QStringLiteral("source"), QJsonDocument(block).toJson(QJsonDocument::Compact)},
        {QStringLiteral("em"), normalBodyCssPixels}, {QStringLiteral("dark"), dark},
        {QStringLiteral("height"), length(style.value(QStringLiteral("height")))},
        {QStringLiteral("fill"), fill}, {QStringLiteral("margins"), margins}};
    const auto clear = style.value(QStringLiteral("clear"));
    if (CompiledContent::present(clear)) {
        result.insert(QStringLiteral("clear"), int(QStringList{QStringLiteral("none"), QStringLiteral("left"),
            QStringLiteral("right"), QStringLiteral("both")}.indexOf(clear.toString())));
        result.insert(QStringLiteral("capability"), QStringLiteral("wikidict.authored-rule-clear/1"));
    }
    return result;
}
inline QString authoredRuleHtml(const QJsonObject &block, qreal em, bool dark) {
    authoredRuleMetadata(block, em, dark);
    const QJsonObject payload{{QStringLiteral("block"), block}, {QStringLiteral("em"), em}, {QStringLiteral("dark"), dark}};
    const auto encoded = QJsonDocument(payload).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    return authoredRuleMarkerOpen + QString::fromLatin1(encoded) + QStringLiteral("\">");
}
inline QString prepareAuthoredRules(const QString &html, QHash<int, QVariantMap> &rules) {
    QString out;
    qsizetype cursor = 0, at = 0;
    while ((at = html.indexOf(authoredRuleMarkerOpen, cursor)) >= 0) {
        const qsizetype begin = at + authoredRuleMarkerOpen.size();
        const qsizetype end = html.indexOf(QStringLiteral("\">"), begin);
        CompiledContent::require(end >= 0 && rules.size() < std::numeric_limits<int>::max() / 2);
        const auto encoded = html.mid(begin, end - begin).toLatin1();
        const auto decoded = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
        CompiledContent::require(decoded.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded);
        QJsonParseError error;
        const auto json = QJsonDocument::fromJson(decoded, &error);
        const auto payload = json.object();
        CompiledContent::require(error.error == QJsonParseError::NoError && json.isObject() && payload.size() == 3
            && payload.value(QStringLiteral("block")).isObject() && payload.value(QStringLiteral("em")).isDouble()
            && payload.value(QStringLiteral("dark")).isBool());
        const int state = std::numeric_limits<int>::max() / 2 + int(rules.size());
        rules.insert(state, authoredRuleMetadata(payload.value(QStringLiteral("block")).toObject(),
            payload.value(QStringLiteral("em")).toDouble(), payload.value(QStringLiteral("dark")).toBool()));
        out += html.mid(cursor, at - cursor) + QStringLiteral("<hr style='margin:0px;-qt-user-state:%1;'>").arg(state);
        cursor = end + 2;
    }
    return out + html.mid(cursor);
}
inline bool normalizeAuthoredRules(QTextDocument *document, const QHash<int, QVariantMap> &rules) {
    const QPointer<QTextDocument> guard(document);
    if (!guard) return false;
    if (rules.isEmpty()) return true;
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    const auto source = document->toRawText(); const int count = document->characterCount();
    QHash<int, QTextBlock> blocks;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        if (!rules.contains(block.userState())) continue;
        CompiledContent::require(!blocks.contains(block.userState()) && block.length() == 1 && block.text().isEmpty()
            && !block.textList() && block.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth));
        blocks.insert(block.userState(), block);
    }
    CompiledContent::require(blocks.size() == rules.size());
    QTextCursor edit(document); edit.beginEditBlock();
    auto finish = qScopeGuard([&] { if (guard) edit.endEditBlock(); });
    for (auto it = blocks.cbegin(); it != blocks.cend(); ++it) {
        if (!guard || !layout || document->documentLayout() != layout) return false;
        auto block = it.value(); auto format = block.blockFormat();
        format.clearProperty(QTextFormat::BlockTrailingHorizontalRulerWidth);
        format.clearProperty(QTextFormat::LineHeight); format.clearProperty(QTextFormat::LineHeightType);
        format.setTopMargin(0); format.setRightMargin(0); format.setBottomMargin(0); format.setLeftMargin(0);
        format.clearBackground();
        format.setProperty(authoredRuleProperty, rules.value(it.key()));
        QTextCursor cursor(block); cursor.setBlockFormat(format);
        if (!guard || !layout || document->documentLayout() != layout) return false;
        // Qt can reuse an empty block after a linked table and leave only its
        // anchor flag. The verified Rule has no inline action; retain real
        // destinations and named anchors for their existing owner to handle.
        auto strut = block.charFormat();
        if (strut.isAnchor() && !strut.hasProperty(QTextFormat::AnchorHref) && strut.anchorNames().isEmpty()) {
            strut.clearProperty(QTextFormat::IsAnchor);
            cursor.setBlockCharFormat(strut);
            if (!guard || !layout || document->documentLayout() != layout) return false;
        }
        block.setUserState(-1);
    }
    finish.dismiss(); edit.endEditBlock();
    if (!guard || !layout || document->documentLayout() != layout) return false;
    CompiledContent::require(document->toRawText() == source && document->characterCount() == count);
    return true;
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
inline constexpr int tableMinimumWidthProperty = QTextFormat::UserProperty + 0x5866;
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
inline constexpr int cellOpacityProperty = QTextFormat::UserProperty + 0x58f0;
inline constexpr int cellLineHeightProperty = QTextFormat::UserProperty + 0x57dd;
inline constexpr int cellOwnerFontProperty = QTextFormat::UserProperty + 0x57f0;
inline constexpr int tablePhysicalEdgesProperty = QTextFormat::UserProperty + 0x57de;
inline constexpr int tableCornerRadiiProperty = QTextFormat::UserProperty + 0x5810;
inline constexpr int cellHiddenEdgesProperty = QTextFormat::UserProperty + 0x57df;
inline constexpr int resolvedBorderEdgesProperty = QTextFormat::UserProperty + 0x58b0;
inline constexpr int resolvedBorderOwnerInkProperty = QTextFormat::UserProperty + 0x58b1;
inline constexpr int resolvedTableBordersProperty = QTextFormat::UserProperty + 0x58b2;
inline const QString resolvedTableBordersCapability = QStringLiteral("wikidict.resolved-table-border/1");
inline bool hasResolvedBorder(const QJsonObject &style) {
    return style.value(QStringLiteral("border")).toObject().contains(QStringLiteral("resolved_edges"));
}
inline const QString cellStyleCapability = QStringLiteral("wikidict.cell-style/1");
inline QJsonObject inlineFontSnapshot(const QJsonValue &value);
struct CellLineInput {
    bool present = false;
    bool strut = false;
    qreal strutPoints = 0;
    QJsonObject ownerFont;
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
        const bool hasOwner = font && spec.contains(QStringLiteral("owner_font"));
        if (!input.isObject() || spec.size() != 2 + int(hasOwner) || !amount.isDouble()
            || !std::isfinite(amount.toDouble()) || amount.toDouble() < 0
            || amount.toDouble() > std::numeric_limits<float>::max() || !basis.isString()
            || (basis.toString() != QStringLiteral("normal_body") && basis.toString() != QStringLiteral("css_px")))
            throw std::runtime_error("invalid cell text metric");
        if (hasOwner && present(spec.value(QStringLiteral("owner_font")))) {
            const auto owner = inlineFontSnapshot(spec.value(QStringLiteral("owner_font")));
            // The strut owns the single size; the snapshot supplies its declaring
            // font traits, independently of the cell's painted descendants.
            if (owner.value("font_scale") != amount || owner.value("font_scale_basis") != basis
                || !present(owner.value("font_family")) || !present(owner.value("font_features"))
                || owner.value("language").toString().isEmpty() || owner.value("language").toString().toUtf8().size() > 1024
                || !owner.value("classes").toString().isEmpty() || owner.value("role") != QStringLiteral("normal"))
                throw std::runtime_error("invalid declaring cell font");
            for (const auto &key : {"small", "superscript", "subscript", "font_normalized", "code"})
                if (owner.value(QLatin1StringView(key)).toBool()) throw std::runtime_error("invalid declaring cell font flags");
            result.ownerFont = owner;
        }
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
    return present(style.value(QStringLiteral("opacity")))
        || style.value(QStringLiteral("border")).toObject().contains(QStringLiteral("edges"))
         || hasResolvedBorder(style)
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
        || !QStringList{"baseline", "middle", "top", "bottom"}.contains(alignment.toString())))
        throw std::runtime_error("invalid inline table alignment");
    if (!tableDisplay(style)) {
        if (style.value(QStringLiteral("vertical_align")) == QStringLiteral("top")
            || style.value(QStringLiteral("vertical_align")) == QStringLiteral("bottom"))
            throw std::runtime_error("top/bottom alignment requires an inline table");
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
                        || present(image.value(QStringLiteral("dark_mode_filter"))) || present(image.value(QStringLiteral("vertical_align"))))
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
inline const QString tableMinimumWidthCapability = QStringLiteral("wikidict.table-minimum-width/1");
inline const QString emptyTableCapability = QStringLiteral("wikidict.empty-table/1");
inline const QString emptyTableScheme = QStringLiteral("wikidict-empty-table");
inline bool hasTableBoxStyle(const QJsonObject &style) {
    return present(style.value(QStringLiteral("width"))) || present(style.value(QStringLiteral("min_width")))
        || present(style.value(QStringLiteral("padding")))
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
inline QVariantMap tableMinimumWidthPolicy(const QJsonObject &table, qreal normalBodyPoints) {
    const auto value = table.value(QStringLiteral("style")).toObject().value(QStringLiteral("min_width"));
    if (!present(value)) return {};
    if (present(table.value(QStringLiteral("block_viewport"))) || present(table.value(QStringLiteral("float_viewport"))))
        throw std::runtime_error("unsupported responsive table minimum width");
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    if (!hasCell) throw std::runtime_error("unsupported empty table minimum width");
    tableBoxLength(value, normalBodyPoints, true);
    const double em = normalBodyPoints * QFontMetricsF(QFont()).fontDpi() / 72.0;
    if (!std::isfinite(em) || em <= 0) throw std::runtime_error("invalid table minimum typography");
    const auto width = value.toObject();
    // Preserve the authored minimum independently of the preferred width. The
    // native solver resolves percentages only when its containing width exists.
    return {{QStringLiteral("capability"), tableMinimumWidthCapability},
        {QStringLiteral("source"), QJsonDocument(table).toJson(QJsonDocument::Compact)},
        {QStringLiteral("em"), em}, {QStringLiteral("unit"), width.value(QStringLiteral("unit")).toString()},
        {QStringLiteral("value"), width.value(QStringLiteral("value")).toDouble()}};
}
inline void requireTableMinimumWidthLayout(QTextDocument *document) {
    QPointer<QTextDocument> live(document);
    if (!live) throw std::runtime_error("missing table minimum document");
    const int revision = live->revision(), count = live->characterCount();
    const QString source = live->toRawText();
    QPointer<QAbstractTextDocumentLayout> layout(live->documentLayout());
    const auto current = [&] {
        if (!live || !layout) return false;
        const auto *active = live->documentLayout();
        return live && layout && active == layout && live->revision() == revision
            && live->characterCount() == count && live->toRawText() == source;
    };
    if (!current()) throw std::runtime_error("replaced table minimum document");
    const QVariant capability = layout->property("_wikidictTableMinimumWidthCapability");
    if (!current() || capability.metaType().id() != QMetaType::QString
        || capability.toString() != tableMinimumWidthCapability)
        throw std::runtime_error("missing paired table minimum width layout");
}
inline void applyTableAutoMargins(QTextTableFormat &format, const QJsonObject &style, qreal normalBodyPoints, qreal indent) {
    const bool hasMargins = present(style.value(QStringLiteral("margin_values")));
    const auto sourceDirection = style.value(QStringLiteral("containing_direction"));
    const bool cornerNumeric = !hasMargins && present(sourceDirection)
        && present(style.value(QStringLiteral("corner_radii"))) && present(style.value(QStringLiteral("margins")));
    if (cornerNumeric) {
        if (!sourceDirection.isString() || (sourceDirection != QStringLiteral("ltr") && sourceDirection != QStringLiteral("rtl")))
            throw std::runtime_error("invalid corner table containing direction");
        const auto margins = typedStyle(style.value(QStringLiteral("margins")), {"top", "right", "bottom", "left"});
        if (margins.size() != 4) throw std::runtime_error("incomplete corner table numeric margins");
        qreal lengths[4]; int side = 0;
        for (const auto &name : {"top", "right", "bottom", "left"})
            lengths[side++] = tableBoxLength(margins.value(QLatin1StringView(name)), normalBodyPoints, false).value(QStringLiteral("value")).toDouble();
        format.setTopMargin(lengths[0]); format.setRightMargin(lengths[1]);
        format.setBottomMargin(lengths[2]); format.setLeftMargin(lengths[3] + indent);
        format.setProperty(tableAutoMarginsProperty, QVariantMap{
            {QStringLiteral("capability"), QStringLiteral("wikidict.table-auto-margins/1")},
            {QStringLiteral("autos"), QVariantList{false, false, false, false}},
            {QStringLiteral("direction"), int(sourceDirection == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)}});
        return;
    }
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
inline const QString tablePairedViewportCapability = QStringLiteral("wikidict.table-paired-scroll/1");

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
    QJsonObject source{{QStringLiteral("style"), metadata.value(QStringLiteral("style")).isUndefined()
            ? QJsonValue(QJsonValue::Null) : metadata.value(QStringLiteral("style"))},
        {QStringLiteral("block_viewport"), metadata.value(QStringLiteral("block_viewport"))}};
    if (present(metadata.value(QStringLiteral("empty_geometry"))))
        source.insert(QStringLiteral("geometry"), metadata.value(QStringLiteral("empty_geometry")));
    if (present(metadata.value(QStringLiteral("block_viewport")).toObject().value(QStringLiteral("intrinsic_containing_direction"))))
        source.insert(QStringLiteral("rows"), metadata.value(QStringLiteral("rows")));
    if (present(metadata.value(QStringLiteral("float_viewport")))) {
        source.insert(QStringLiteral("float_viewport"), metadata.value(QStringLiteral("float_viewport")));
        source.insert(QStringLiteral("rows"), metadata.value(QStringLiteral("rows")));
    }
    return QJsonDocument(source).toJson(QJsonDocument::Compact);
}

inline QJsonObject tableScrollFocusPaint(const QJsonValue &value) {
    const auto paint = value.toObject();
    const auto mode = paint.value(QStringLiteral("mode"));
    if (!value.isObject() || paint.size() != 1 + int(paint.contains(QStringLiteral("color")))
        || (mode != QStringLiteral("authored_none") && mode != QStringLiteral("ua_auto")))
        throw std::runtime_error("invalid source table focus policy");
    const auto color = paint.value(QStringLiteral("color"));
    if (present(color)) {
        const auto object = color.toObject(); const auto kind = object.value(QStringLiteral("kind"));
        const auto data = object.value(QStringLiteral("value"));
        if (mode != QStringLiteral("ua_auto") || !color.isObject()
            || object.size() != 1 + int(object.contains(QStringLiteral("value"))))
            throw std::runtime_error("invalid source table focus color");
        if (kind == QStringLiteral("rgb")) styleColor(data);
        else if ((kind != QStringLiteral("native_theme") && kind != QStringLiteral("transparent")) || present(data))
            throw std::runtime_error("invalid source table focus color kind");
    }
    return paint;
}

// The source keeps physical circular CSS-pixel radii. Used-size normalization
// belongs to the native owner, after its actual border rectangle is allocated.
inline QVariantList tableCornerRadii(const QJsonObject &style, bool viewportBox = false) {
    const auto value = style.value(QStringLiteral("corner_radii"));
    if (!present(value)) return {};
    const auto corners = typedStyle(value, {"top_left", "top_right", "bottom_right", "bottom_left"});
    if (corners.size() != 4) throw std::runtime_error("incomplete table corner radii");
    const auto border = style.value(QStringLiteral("border"));
    const auto tagged = border.toObject();
    if (!border.isObject() || tagged.size() != 1
        || (!tagged.contains(QStringLiteral("none")) && !tagged.contains(QStringLiteral("solid"))))
        throw std::runtime_error("table corners require an explicit uniform border");
    if (viewportBox ? present(style.value(QStringLiteral("collapse")))
        : style.value(QStringLiteral("collapse")) != QStringLiteral("separate"))
        throw std::runtime_error("table corners require separate source borders");
    const auto display = style.value(QStringLiteral("display"));
    if (display == QStringLiteral("inline_table") || display == QStringLiteral("inline_block"))
        throw std::runtime_error("inline table corners are unsupported");
    QVariantList result;
    for (const auto &key : {"top_left", "top_right", "bottom_right", "bottom_left"}) {
        const auto length = typedStyle(corners.value(QLatin1StringView(key)), {"unit", "value"});
        const auto number = length.value(QStringLiteral("value"));
        if (length.size() != 2 || length.value(QStringLiteral("unit")) != QStringLiteral("px")
            || !number.isDouble() || !std::isfinite(number.toDouble()) || number.toDouble() < 0
            || number.toDouble() > 16777216)
            throw std::runtime_error("invalid table corner radius");
        result.append(number.toDouble());
    }
    return result;
}
inline void applyTableCorners(QTextFrameFormat &format, const QJsonObject &style,
                              QTextDocument *document, bool viewportBox = false) {
    const auto radii = tableCornerRadii(style, viewportBox);
    if (radii.isEmpty()) return;
    QPointer<QTextDocument> live(document);
    QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
    const int revision = document->revision(), count = document->characterCount();
    const auto capability = native ? native->property("_wikidictTableCornersCapability") : QVariant();
    if (!live || !native || live->documentLayout() != native || live->revision() != revision
        || live->characterCount() != count || capability.metaType().id() != QMetaType::QString
        || capability.toString() != QStringLiteral("wikidict.table-corners/1"))
        throw std::runtime_error("missing paired table corner paint");
    format.setProperty(tableCornerRadiiProperty, radii);
}

inline bool intrinsicTableViewport(const QJsonObject &policy) {
    return present(policy.value(QStringLiteral("intrinsic_containing_direction")));
}
inline QJsonObject intrinsicTableGridGeometry(const QJsonValue &value) {
    const auto geometry = typedStyle(value, {"border", "width", "cell_spacing", "cell_padding"});
    if (!value.isObject() || present(geometry.value(QStringLiteral("width"))))
        throw std::runtime_error("invalid intrinsic table grid geometry");
    for (const auto &key : {"border", "cell_spacing", "cell_padding"}) {
        const auto amount = geometry.value(QLatin1StringView(key));
        if (!amount.isDouble() || !std::isfinite(amount.toDouble()) || amount.toDouble() < 0
            || amount.toDouble() > 65535 || std::floor(amount.toDouble()) != amount.toDouble())
            throw std::runtime_error("missing intrinsic table legacy metric");
    }
    return geometry;
}
inline bool cornerSeparateTableViewport(const QJsonObject &policy) {
    return present(policy.value(QStringLiteral("box_style")).toObject().value(QStringLiteral("corner_radii")))
        && policy.value(QStringLiteral("grid_style")).toObject().value(QStringLiteral("collapse")) == QStringLiteral("separate");
}
inline QJsonObject cornerTableGridGeometry(const QJsonValue &value) {
    const auto geometry = typedStyle(value, {"border", "width", "cell_spacing", "cell_padding"});
    if (!value.isObject() || present(geometry.value(QStringLiteral("border"))) || present(geometry.value(QStringLiteral("width"))))
        throw std::runtime_error("invalid corner table grid geometry");
    for (const auto &key : {"cell_spacing", "cell_padding"}) {
        const auto amount = geometry.value(QLatin1StringView(key));
        if (!amount.isDouble() || !std::isfinite(amount.toDouble()) || amount.toDouble() < 0
            || amount.toDouble() > 65535 || std::floor(amount.toDouble()) != amount.toDouble())
            throw std::runtime_error("missing or invalid corner table grid metric");
    }
    return geometry;
}

inline QJsonObject tableBlockViewport(const QJsonObject &table) {
    const auto value = table.value(QStringLiteral("block_viewport"));
    if (!present(value)) return {};
    auto policy = value.toObject();
    if (policy.value(QStringLiteral("focus_paint")).isNull()) policy.remove(QStringLiteral("focus_paint"));
    const bool paired = present(table.value(QStringLiteral("float_viewport")));
    const bool cornerSeparate = cornerSeparateTableViewport(policy);
    if (policy.value(QStringLiteral("intrinsic_containing_direction")).isNull())
        policy.remove(QStringLiteral("intrinsic_containing_direction"));
    const bool intrinsic = intrinsicTableViewport(policy);
    const bool sourceFocus = paired || cornerSeparate || intrinsic;
    const QStringList fields{"max_viewport_width_px", "box_style", "box_sizing", "max_width", "grid_style", "grid_direction", "language"};
    if (!value.isObject() || policy.size() != fields.size() + int(sourceFocus) + int(intrinsic))
        throw std::runtime_error("invalid table block viewport");
    for (const auto &field : fields) if (!policy.contains(field))
        throw std::runtime_error("incomplete table block viewport");
    if (sourceFocus) tableScrollFocusPaint(policy.value(QStringLiteral("focus_paint")));
    if (paired) {
        const auto floating = table.value(QStringLiteral("float_viewport")).toObject();
        if (!table.value(QStringLiteral("float_viewport")).isObject()
            || floating.value(QStringLiteral("max_viewport_width_px")) != policy.value(QStringLiteral("max_viewport_width_px"))
            || floating.value(QStringLiteral("grid_direction")) != policy.value(QStringLiteral("grid_direction"))
            || floating.value(QStringLiteral("language")) != policy.value(QStringLiteral("language"))
            || present(floating.value(QStringLiteral("narrow_clear"))))
            throw std::runtime_error("unmatched paired table viewport");
    }
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
        "float_side", "width", "min_width", "padding", "clear", "display", "vertical_align", "line_height", "corner_radii"};
    const auto wide = typedStyle(table.value(QStringLiteral("style")), styleFields);
    const auto box = typedStyle(policy.value(QStringLiteral("box_style")), styleFields);
    const auto grid = typedStyle(policy.value(QStringLiteral("grid_style")), styleFields);
    if (present(wide.value(QStringLiteral("min_width"))) || present(box.value(QStringLiteral("min_width")))
        || present(grid.value(QStringLiteral("min_width"))))
        throw std::runtime_error("unsupported responsive table minimum width");
    tableCornerRadii(wide); tableCornerRadii(box, true);
    if (cornerSeparate) {
        if (paired || tableCornerRadii(wide).isEmpty()
            || !wide.value(QStringLiteral("margins")).isObject() || present(wide.value(QStringLiteral("margin_values")))
            || (wide.value(QStringLiteral("containing_direction")) != QStringLiteral("ltr")
                && wide.value(QStringLiteral("containing_direction")) != QStringLiteral("rtl"))
            || !present(box.value(QStringLiteral("margins"))) || present(box.value(QStringLiteral("margin_values")))
            || (box.value(QStringLiteral("containing_direction")) != QStringLiteral("ltr")
                && box.value(QStringLiteral("containing_direction")) != QStringLiteral("rtl"))
            || present(grid.value(QStringLiteral("line_height"))))
            throw std::runtime_error("invalid separate corner viewport ownership");
        cornerTableGridGeometry(table.value(QStringLiteral("geometry")));
        for (const auto &length : {wide.value(QStringLiteral("width")), box.value(QStringLiteral("width")), policy.value(QStringLiteral("max_width"))})
            if (length.toObject() != QJsonObject{{QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100}})
                throw std::runtime_error("corner viewport requires source percent100 width and cap");
    }
    if (intrinsic) {
        const auto direction = policy.value(QStringLiteral("intrinsic_containing_direction"));
        if (paired || cornerSeparate || policy.value(QStringLiteral("max_viewport_width_px")).toDouble() == 0
            || (direction != QStringLiteral("ltr") && direction != QStringLiteral("rtl"))
            || present(wide.value(QStringLiteral("display"))) || present(wide.value(QStringLiteral("vertical_align")))
            || present(wide.value(QStringLiteral("line_height"))) || present(grid.value(QStringLiteral("line_height")))
            || wide.value(QStringLiteral("collapse")) != QStringLiteral("collapse")
            || !wide.value(QStringLiteral("margins")).isObject()
            || present(wide.value(QStringLiteral("width"))) || present(wide.value(QStringLiteral("margin_values")))
            || present(wide.value(QStringLiteral("containing_direction"))) || present(wide.value(QStringLiteral("corner_radii")))
            || present(box.value(QStringLiteral("corner_radii")))
            || policy.value(QStringLiteral("max_width")).toObject() != QJsonObject{{"unit", "percent"}, {"value", 100}})
            throw std::runtime_error("invalid intrinsic source table ownership");
        intrinsicTableGridGeometry(table.value(QStringLiteral("geometry")));
        if (wide.value(QStringLiteral("margins")).toObject().size() != 4)
            throw std::runtime_error("incomplete intrinsic wide margins");
        for (const auto &side : {"top", "right", "bottom", "left"})
            tableBoxLength(wide.value(QStringLiteral("margins")).toObject().value(QLatin1StringView(side)), 12, false);
    }
    if (present(grid.value(QStringLiteral("corner_radii"))))
        throw std::runtime_error("anonymous grid cannot own table corners");
    if ((!cornerSeparate && !intrinsic && present(table.value(QStringLiteral("geometry"))))
        || (paired ? wide.value(QStringLiteral("float_side")) != QStringLiteral("right") : present(wide.value(QStringLiteral("float_side"))))
        || tableDisplay(wide) != 0 || !policy.value(QStringLiteral("box_style")).isObject()
        || !policy.value(QStringLiteral("grid_style")).isObject())
        throw std::runtime_error("unsupported table viewport header");
    for (const auto &key : {"float_side", "display", "vertical_align", "collapse", "line_height"})
        if (present(box.value(QLatin1StringView(key)))) throw std::runtime_error("invalid table viewport box field");
    if (paired || intrinsic) {
        if (present(box.value(QStringLiteral("width"))) || present(box.value(QStringLiteral("margin_values")))
            || present(box.value(QStringLiteral("containing_direction")))
            || !box.value(QStringLiteral("margins")).isObject() || box.value(QStringLiteral("margins")).toObject().size() != 4)
            throw std::runtime_error("invalid paired table fixed margins or fit width");
        for (const auto &side : {"top", "right", "bottom", "left"})
            tableBoxLength(box.value(QStringLiteral("margins")).toObject().value(QLatin1StringView(side)), 12, false);
    } else if (!cornerSeparate && present(box.value(QStringLiteral("margins"))))
        throw std::runtime_error("invalid table viewport box margins");
    for (const auto &key : {"background", "border", "padding", "width", "margins", "margin_values", "containing_direction",
                            "float_side", "clear", "display", "vertical_align"})
        if (present(grid.value(QLatin1StringView(key)))) throw std::runtime_error("invalid anonymous table grid field");
    if (grid.value(QStringLiteral("collapse")) != (cornerSeparate ? QStringLiteral("separate") : QStringLiteral("collapse")))
        throw std::runtime_error("anonymous table grid requires proved collapse");
    // These calls validate the typed lengths without using a reader/font guess.
    // Em resolution is performed later with the same authenticated owner points.
    const auto width = paired || intrinsic ? QVariantMap() : tableBoxLength(box.value(QStringLiteral("width")), 12, true);
    tableBoxLength(policy.value(QStringLiteral("max_width")), 12, true);
    if (!paired && !intrinsic) {
        if (width.value(QStringLiteral("value")).toDouble() <= 0)
            throw std::runtime_error("table viewport width must be positive");
        QTextTableFormat margins;
        applyTableAutoMargins(margins, box, 12, 0);
        if (!margins.hasProperty(tableAutoMarginsProperty))
            throw std::runtime_error("table viewport requires source automatic margins");
    }
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
        if (policy.contains(QStringLiteral("paired"))
            && native->property("_wikidictTablePairedScrollCapability").toString() != tablePairedViewportCapability)
            throw std::runtime_error("missing paired source table scroll owner during reflow");
        if (policy.contains(QStringLiteral("intrinsic"))
            && native->property("_wikidictTableIntrinsicScrollCapability").toString() != QStringLiteral("wikidict.table-intrinsic-scroll/1"))
            throw std::runtime_error("missing intrinsic source table scroll owner during reflow");
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
                    || saved.value(QStringLiteral("brush")).metaType().id() != QMetaType::QBrush
                    || saved.value(QStringLiteral("present")).metaType().id() != QMetaType::Bool
                    || (!saved.value(QStringLiteral("present")).toBool()
                        && saved.value(QStringLiteral("brush")).value<QBrush>().style() != Qt::NoBrush))
                    throw std::runtime_error("changed table viewport cell owner");
                auto cellFormat = cell.format().toTableCellFormat();
                const bool suppress = active && !saved.value(QStringLiteral("authored")).toBool();
                const auto brush = saved.value(QStringLiteral("brush")).value<QBrush>();
                if (!saved.value(QStringLiteral("present")).toBool())
                    cellFormat.clearProperty(QTextFormat::BackgroundBrush);
                else cellFormat.setBackground(suppress ? QBrush(Qt::NoBrush) : brush);
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
inline constexpr int pairedTableEmptyCellProperty = QTextFormat::UserProperty + 0x5808;
inline const QString tableFloatViewportCapability = QStringLiteral("wikidict.table-float-viewport/1");

inline int tableFloatViewportNarrowClear(const QJsonObject &policy) {
    const auto value = policy.value(QStringLiteral("narrow_clear"));
    if (!present(value)) return -1;
    const int clear = QStringList{"none", "left", "right", "both"}.indexOf(value.toString());
    if (!value.isString() || clear < 0) throw std::runtime_error("invalid table float viewport narrow clear");
    return clear;
}

inline QJsonObject tableFloatViewport(const QJsonObject &table) {
    const auto value = table.value(QStringLiteral("float_viewport"));
    if (!present(value)) return {};
    const auto policy = value.toObject();
    const QStringList fields{"max_viewport_width_px", "containing_direction", "grid_direction", "language"};
    if (!value.isObject() || policy.size() != fields.size() + int(policy.contains(QStringLiteral("narrow_clear"))))
        throw std::runtime_error("invalid table float viewport");
    for (const auto &field : fields) if (!policy.contains(field))
        throw std::runtime_error("incomplete table float viewport");
    tableFloatViewportNarrowClear(policy);
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
        "margin_values", "containing_direction", "float_side", "width", "min_width", "padding", "clear", "display", "vertical_align", "line_height", "corner_radii"});
    if (present(table.value(QStringLiteral("geometry")))
        || !table.value(QStringLiteral("caption")).toArray().isEmpty() || present(table.value(QStringLiteral("caption_blocks")))
        || style.value(QStringLiteral("float_side")) != QStringLiteral("right"))
        throw std::runtime_error("unsupported table float viewport owner");
    for (const auto &key : {"padding", "margin_values", "containing_direction", "display", "vertical_align", "line_height", "min_width"})
        if (present(style.value(QLatin1StringView(key)))) throw std::runtime_error("unsupported table float viewport style");
    if (present(style.value(QStringLiteral("width")))) tableBoxLength(style.value(QStringLiteral("width")), 12, false);
    const auto margins = style.value(QStringLiteral("margins"));
    if (!margins.isObject() || margins.toObject().size() != 4)
        throw std::runtime_error("missing fixed table float viewport margins");
    for (const auto &side : {"top", "right", "bottom", "left"})
        tableBoxLength(margins.toObject().value(QLatin1StringView(side)), 12, false);
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    if (!hasCell) throw std::runtime_error("unsupported empty table float viewport");
    if (present(table.value(QStringLiteral("block_viewport")))) tableBlockViewport(table);
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
            || policy.value(QStringLiteral("base_format")).metaType().id() != QMetaType::QTextFormat
            || policy.value(QStringLiteral("source")).metaType().id() != QMetaType::QByteArray)
            throw std::runtime_error("invalid table float viewport state");
        const bool active = viewportCssWidth <= policy.value(QStringLiteral("threshold")).toDouble();
        const auto source = QJsonDocument::fromJson(policy.value(QStringLiteral("source")).toByteArray());
        if (!source.isObject() || !source.object().value(QStringLiteral("float_viewport")).isObject())
            throw std::runtime_error("invalid table float viewport source");
        const int narrowClear = tableFloatViewportNarrowClear(source.object().value(QStringLiteral("float_viewport")).toObject());
        const auto base = policy.value(QStringLiteral("base_format")).value<QTextFormat>().toTableFormat();
        auto expected = base;
        expected.setPosition(policy.value(QStringLiteral("active")).toBool() ? QTextFrameFormat::InFlow : QTextFrameFormat::FloatRight);
        if (policy.value(QStringLiteral("active")).toBool() && narrowClear >= 0)
            expected.setProperty(tableBoxClearProperty, narrowClear);
        auto current = format; current.clearProperty(QTextFormat::ObjectIndex); current.clearProperty(tableFloatViewportProperty);
        if (QTextFormat(current) != QTextFormat(expected)) throw std::runtime_error("changed table float viewport format");
        if (policy.value(QStringLiteral("viewport")).toDouble() == viewportCssWidth) continue;
        policy.insert(QStringLiteral("viewport"), viewportCssWidth); policy.insert(QStringLiteral("active"), active);
        format.setPosition(active ? QTextFrameFormat::InFlow : QTextFrameFormat::FloatRight);
        if (active && narrowClear >= 0) format.setProperty(tableBoxClearProperty, narrowClear);
        else if (base.hasProperty(tableBoxClearProperty)) format.setProperty(tableBoxClearProperty, base.property(tableBoxClearProperty));
        else format.clearProperty(tableBoxClearProperty);
        format.setProperty(tableFloatViewportProperty, policy);
        owner->setFormat(format);
        if (!live || !native || !owner || owner->document() != live || live->documentLayout() != native)
            throw std::runtime_error("replaced table float viewport during reflow");
    }
}

// Stored spans stay declared values. Qt's used row span is checked separately
// against the authenticated source row count, never inferred from its result.
inline int compiledTableSpan(const QJsonValue &value, bool allowAbsent = true) {
    if (value.isUndefined() && allowAbsent) return 1;
    const double number = value.toDouble(-1);
    if (!value.isDouble() || !std::isfinite(number) || number < 1 || number > 100 || std::floor(number) != number)
        throw std::runtime_error("invalid compiled table span");
    return int(number);
}

inline QString tableStyleMarker(const QJsonObject &table, qreal containerPoints, int indent, bool resetTextAlignment = false,
                                const QString &listMarker = {}, int tableDepth = 1, qreal tableOriginPoints = -1,
                                const QColor &ownerInk = {}, const QJsonArray &cellOwnerInks = {},
                                const std::optional<TableCellLayers::FooterOverlap> &cover = {}) {
    const auto minimum = tableMinimumWidthPolicy(table, containerPoints);
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    const auto viewport = tableBlockViewport(table);
    const auto floatViewport = tableFloatViewport(table);
    const auto sourceStyle = table.value(QStringLiteral("style")).toObject();
    bool resolvedBorders = hasResolvedBorder(sourceStyle);
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        for (const auto &cell : row.toObject().value(QStringLiteral("cells")).toArray())
            resolvedBorders |= hasResolvedBorder(cell.toObject().value(QStringLiteral("style")).toObject());
    if (resolvedBorders && (!hasCell || !viewport.isEmpty() || !floatViewport.isEmpty()
        || tableDisplay(sourceStyle) != 0 || present(sourceStyle.value(QStringLiteral("float_side")))
        || present(sourceStyle.value(QStringLiteral("corner_radii")))
        || !ownerInk.isValid() || ownerInk.alpha() != 255
        || cellOwnerInks.size() != table.value(QStringLiteral("rows")).toArray().size()))
        throw std::runtime_error("unsupported resolved table border owner");
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
    qsizetype ownerRow = 0;
    for (const QJsonValue &rowValue : table.value(QStringLiteral("rows")).toArray()) {
        QJsonArray cells;
        const auto inks = ownerRow < cellOwnerInks.size() ? cellOwnerInks.at(ownerRow).toArray() : QJsonArray();
        ++ownerRow;
        if (resolvedBorders && inks.size() != rowValue.toObject().value(QStringLiteral("cells")).toArray().size())
            throw std::runtime_error("missing resolved cell owner ink");
        for (const QJsonValue &cellValue : rowValue.toObject().value(QStringLiteral("cells")).toArray()) {
            const QJsonObject cell = cellValue.toObject();
            QJsonObject shape{{"rowspan", compiledTableSpan(cell.value(QStringLiteral("rowspan")))},
                {"colspan", compiledTableSpan(cell.value(QStringLiteral("colspan")))}};
            if (resolvedBorders) {
                if (shape.value(QStringLiteral("rowspan")).toInt() != 1 || shape.value(QStringLiteral("colspan")).toInt() != 1
                    || (hasResolvedBorder(cell.value(QStringLiteral("style")).toObject())
                        && present(cell.value(QStringLiteral("style")).toObject().value(QStringLiteral("border_edges")))))
                    throw std::runtime_error("unsupported resolved cell border domain");
                styleColor(inks.at(cells.size()));
                shape.insert(QStringLiteral("resolved_owner_ink"), inks.at(cells.size()));
            }
            if (present(cell.value(QStringLiteral("style")))) { shape.insert(QStringLiteral("style"), cell.value(QStringLiteral("style"))); styled = true; }
            if (!viewport.isEmpty() || present(table.value(QStringLiteral("style")).toObject().value(QStringLiteral("corner_radii")))
                || present(cell.value(QStringLiteral("style")).toObject().value(QStringLiteral("opacity"))))
                shape.insert(QStringLiteral("background"), cell.value(QStringLiteral("background")).isUndefined()
                ? QJsonValue(QJsonValue::Null) : cell.value(QStringLiteral("background")));
            if (present(cell.value(QStringLiteral("style")).toObject().value(QStringLiteral("line_height")))) {
                shape.insert(QStringLiteral("header"), cell.value(QStringLiteral("header")).toBool());
                shape.insert(QStringLiteral("empty_content"), emptyCompiledCell(cell));
            }
            if (!viewport.isEmpty() && (!floatViewport.isEmpty() || intrinsicTableViewport(viewport)))
                shape.insert(QStringLiteral("empty_content"), emptyCompiledCell(cell));
            cells.append(shape);
        }
        rows.append(cells);
    }
    if (!styled && !hasCell) return {};
    QJsonObject metadata{{"container_points", containerPoints}, {"indent", indent}, {"rows", rows}};
    if (cover) {
        if (resolvedBorders || !viewport.isEmpty() || !floatViewport.isEmpty() || present(sourceStyle.value("border_edges")))
            throw std::runtime_error("unsupported styled covering cell");
        metadata.insert("covered_cell", QJsonObject{{"row",cover->lowerRow},{"cell",cover->lowerCell},
            {"column",cover->lowerColumn},{"declared_rows",cover->lowerDeclaredRows},
            {"front_row",cover->upperRow},{"front_columns",cover->upperColumns}});
    }
    if (resolvedBorders) metadata.insert(QStringLiteral("resolved_owner_ink"), ownerInk.name());
    if (!minimum.isEmpty()) metadata.insert(QStringLiteral("minimum_source"), table);
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
    if (format.hasProperty(tableCornerRadiiProperty))
        grid.setProperty(tableCornerRadiiProperty, format.property(tableCornerRadiiProperty));
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
    const bool cornerSeparate = cornerSeparateTableViewport(policy);
    const bool intrinsic = intrinsicTableViewport(policy);
    const auto gridGeometry = intrinsic ? intrinsicTableGridGeometry(metadata.value(QStringLiteral("empty_geometry")))
        : cornerSeparate ? cornerTableGridGeometry(metadata.value(QStringLiteral("empty_geometry"))) : QJsonObject();
    const double gridSpacing = cornerSeparate || intrinsic ? gridGeometry.value(QStringLiteral("cell_spacing")).toDouble() : 0;
    const double gridPadding = cornerSeparate || intrinsic ? gridGeometry.value(QStringLiteral("cell_padding")).toDouble() : 0;
    const auto language = policy.value(QStringLiteral("language")).toString();
    const bool paired = present(metadata.value(QStringLiteral("float_viewport")));
    if ((paired || cornerSeparate) && native->property("_wikidictTablePairedScrollCapability").toString() != tablePairedViewportCapability)
        throw std::runtime_error("missing paired source table scroll owner");
    if (intrinsic && native->property("_wikidictTableIntrinsicScrollCapability").toString() != QStringLiteral("wikidict.table-intrinsic-scroll/1"))
        throw std::runtime_error("missing intrinsic source table scroll owner");
    if (native->property("_wikidictSourceTextLanguageCapability").toString() != QStringLiteral("wikidict.source-text-language/1"))
        throw std::runtime_error("missing paired source-language shaping");
    QTextTableFormat boxMargins;
    applyTableAutoMargins(boxMargins, boxStyle, points, 0);
    auto autoMargins = boxMargins.property(tableAutoMarginsProperty).toMap();
    QVariantList margins{boxMargins.topMargin(), boxMargins.rightMargin(), boxMargins.bottomMargin(), boxMargins.leftMargin()};
    if (paired || intrinsic) {
        margins.clear();
        for (const auto &side : {"top", "right", "bottom", "left"})
            margins.append(tableBoxLength(boxStyle.value(QStringLiteral("margins")).toObject().value(QLatin1StringView(side)), points, false).value(QStringLiteral("value")));
        autoMargins = {{QStringLiteral("autos"), QVariantList{false, false, false, false}},
            {QStringLiteral("direction"), int((intrinsic ? policy.value(QStringLiteral("intrinsic_containing_direction")) : metadata.value(QStringLiteral("float_viewport")).toObject().value(QStringLiteral("containing_direction"))) == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)}};
    }
    QVariantMap allocation{{QStringLiteral("capability"), tableViewportCapability}, {QStringLiteral("source"), source},
        {QStringLiteral("language"), language},
        {QStringLiteral("em"), points * QFontMetricsF(QFont()).fontDpi() / 72.0},
        {QStringLiteral("threshold"), policy.value(QStringLiteral("max_viewport_width_px")).toDouble()},
        {QStringLiteral("active"), false}, {QStringLiteral("width"), paired || intrinsic ? QVariantMap() : tableBoxLength(boxStyle.value(QStringLiteral("width")), points, true)},
        {QStringLiteral("max_width"), tableBoxLength(policy.value(QStringLiteral("max_width")), points, true)},
        {QStringLiteral("border_box"), policy.value(QStringLiteral("box_sizing")) == QStringLiteral("border_box")},
        {QStringLiteral("autos"), autoMargins.value(QStringLiteral("autos"))}, {QStringLiteral("margins"), margins},
        {QStringLiteral("direction"), autoMargins.value(QStringLiteral("direction"))},
        {QStringLiteral("grid_direction"), int(policy.value(QStringLiteral("grid_direction")) == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)}};
    if (cornerSeparate)
        allocation.insert(QStringLiteral("focus_paint"), policy.value(QStringLiteral("focus_paint")).toObject());
    if (paired || intrinsic) {
        allocation.insert(intrinsic ? QStringLiteral("intrinsic") : QStringLiteral("paired"), true);
        allocation.insert(QStringLiteral("focus_paint"), policy.value(QStringLiteral("focus_paint")).toObject());
        allocation.insert(QStringLiteral("width"), QVariantMap{{QStringLiteral("unit"), QStringLiteral("fit_content")}, {QStringLiteral("value"), 0.0}});
    }
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
    applyTableCorners(box, boxStyle, document, true);
    QTextFrameFormat narrow = table->frameFormat();
    for (int property : {int(QTextFormat::BackgroundBrush), int(QTextFormat::BlockAlignment), tableAutoMarginsProperty,
                         tablePhysicalEdgesProperty, tableCornerRadiiProperty, tableBoxWidthProperty, tableBoxPaddingProperty,
                         tableDisplayProperty, tableVerticalAlignProperty, tableLineHeightProperty}) narrow.clearProperty(property);
    narrow.setMargin(0); narrow.setPadding(0); narrow.setBorder(0); narrow.setBorderStyle(QTextFrameFormat::BorderStyle_None);
    narrow.setProperty(QTextFormat::TableCellPadding, gridPadding); narrow.setProperty(QTextFormat::TableCellSpacing, gridSpacing);
    narrow.setProperty(QTextFormat::TableBorderCollapse, !cornerSeparate);
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
    if (paired || intrinsic) {
        wideOwner.setPosition(paired ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
        wideOwner.setLayoutDirection(box.layoutDirection());
        wideOwner.setLeftMargin(wide.leftMargin()); wideOwner.setRightMargin(wide.rightMargin());
        wide.setMargin(0); wide.setPosition(QTextFrameFormat::InFlow);
        wide.setLayoutDirection(Qt::LayoutDirection(allocation.value(QStringLiteral("grid_direction")).toInt()));
        narrow.setPosition(QTextFrameFormat::InFlow);
    }
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
                    {QStringLiteral("authored"), present(authored)},
                    {QStringLiteral("present"), cell.format().hasProperty(QTextFormat::BackgroundBrush)},
                    {QStringLiteral("brush"), cell.format().background()}});
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
        emptyNarrow.clearProperty(tableCornerRadiiProperty);
        emptyNarrow.setProperty(QTextFormat::TableBorderCollapse, !cornerSeparate);
        emptyNarrow.setProperty(QTextFormat::TableCellPadding, gridPadding);
        emptyNarrow.setProperty(QTextFormat::TableCellSpacing, gridSpacing);
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
    // The endpoint is the following source block, outside the selected table.
    // Qt splits it with a default exterior format when inserting the frame.
    QTextCursor following(document); following.setPosition(table->lastPosition() + 1);
    const auto followingBlock = following.block();
    if (!followingBlock.isValid() || followingBlock.position() != following.position()
        || following.currentFrame() != parent)
        throw std::runtime_error("invalid following table viewport boundary");
    const auto followingFormat = followingBlock.blockFormat();
    const auto followingCharacter = followingBlock.charFormat();
    const auto followingText = followingBlock.text();
    const bool followingVisible = followingBlock.isVisible();
    const int followingLines = followingBlock.lineCount();
    const QPointer<QTextList> followingList(followingBlock.textList());
    const bool followsList = followingList;
    QTextCursor selection(document); selection.setPosition(start);
    selection.setPosition(following.position(), QTextCursor::KeepAnchor);
    const QPointer<QTextFrame> owner(selection.insertFrame(wideOwner));
    if (!live || !native || !grid || !owner || !parent || live->documentLayout() != native
        || owner->parentFrame() != parent || grid->parentFrame() != owner
        || owner->childFrames().size() != stagedCaptions.size() + 1)
        throw std::runtime_error("invalid native table viewport association");
    const auto currentBoundary = [&] {
        return live && native && grid && owner && parent && live->documentLayout() == native
            && owner->parentFrame() == parent && grid->parentFrame() == owner
            && (!followsList || followingList);
    };
    const auto interiorFollowing = following.block();
    auto exteriorFollowing = document->findBlock(owner->lastPosition() + 1);
    if (following.position() != owner->lastPosition() || following.currentFrame() != owner
        || !interiorFollowing.isValid() || interiorFollowing.position() != following.position()
        || interiorFollowing.length() != 1 || interiorFollowing.blockFormat() != followingFormat
        || document->characterAt(following.position()) != QChar(0xfdd1)
        || !exteriorFollowing.isValid() || exteriorFollowing.position() != owner->lastPosition() + 1
        || document->frameAt(exteriorFollowing.position()) != parent || exteriorFollowing.text() != followingText)
        throw std::runtime_error("changed following block during viewport wrapping");
    // Add the real exterior item before removing its generated interior prefix:
    // removing a list's only item first would destroy the source list object.
    QTextCursor exteriorBoundary(exteriorFollowing); exteriorBoundary.setBlockFormat(followingFormat);
    if (!currentBoundary()) throw std::runtime_error("replaced following viewport block");
    exteriorBoundary.setBlockCharFormat(followingCharacter);
    if (!currentBoundary()) throw std::runtime_error("replaced following viewport strut");
    exteriorFollowing = exteriorBoundary.block();
    exteriorFollowing.setVisible(followingVisible); exteriorFollowing.setLineCount(followingLines);
    following.setBlockFormat(QTextBlockFormat());
    if (!currentBoundary()) throw std::runtime_error("replaced trailing viewport storage");
    // The public setter retains the grid/frame separator's structural ObjectIndex.
    following.setBlockCharFormat(QTextCharFormat());
    if (!currentBoundary() || exteriorBoundary.currentFrame() != parent
        || exteriorBoundary.block().blockFormat() != followingFormat
        || exteriorBoundary.block().text() != followingText
        || exteriorBoundary.block().textList() != followingList.data())
        throw std::runtime_error("changed following viewport source ownership");
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
    for (const TableInfo &record : records)
        if (present(record.value.value(QStringLiteral("style")).toObject().value(QStringLiteral("min_width")))) {
            requireTableMinimumWidthLayout(document);
            break;
        }
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
        const bool intrinsicViewport = intrinsicTableViewport(record.value.value(QStringLiteral("block_viewport")).toObject());
        bool resolvedBorders = hasResolvedBorder(record.value.value(QStringLiteral("style")).toObject());
        for (const auto &row : rows) for (const auto &cell : row.toArray())
            resolvedBorders |= hasResolvedBorder(cell.toObject().value(QStringLiteral("style")).toObject());
        if (resolvedBorders) {
            const auto style = record.value.value(QStringLiteral("style")).toObject();
            if (!table || tableDisplay(style) != 0 || present(style.value(QStringLiteral("float_side")))
                || present(style.value(QStringLiteral("corner_radii")))
                || present(record.value.value(QStringLiteral("block_viewport"))) || floatViewport)
                throw std::runtime_error("unsupported resolved table border holder");
            styleColor(record.value.value(QStringLiteral("resolved_owner_ink")));
            for (const auto &row : rows) for (const auto &cellValue : row.toArray()) {
                const auto cell = cellValue.toObject();
                if (compiledTableSpan(cell.value(QStringLiteral("rowspan")), false) != 1
                    || compiledTableSpan(cell.value(QStringLiteral("colspan")), false) != 1
                    || (hasResolvedBorder(cell.value(QStringLiteral("style")).toObject())
                        && present(cell.value(QStringLiteral("style")).toObject().value(QStringLiteral("border_edges")))))
                    throw std::runtime_error("unsupported resolved table cell holder");
                styleColor(cell.value(QStringLiteral("resolved_owner_ink")));
            }
            QPointer<QTextDocument> live(document);
            QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
            const int revision = document->revision(), count = document->characterCount();
            const auto capability = native ? native->property("_wikidictResolvedTableBordersCapability") : QVariant();
            if (!live || !native || live->documentLayout() != native || live->revision() != revision
                || live->characterCount() != count || capability.metaType().id() != QMetaType::QString
                || capability != QVariant(resolvedTableBordersCapability))
                throw std::runtime_error("missing paired resolved table border layout");
        } else if (record.value.contains(QStringLiteral("resolved_owner_ink"))) {
            throw std::runtime_error("unused resolved table owner ink");
        }
        const auto length = [&](const QJsonValue &value) {
            return floatViewport || intrinsicViewport ? tableBoxLength(value, points, false).value(QStringLiteral("value")).toDouble()
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
        const auto resolvedBorder = [&](const QJsonValue &value) {
            const auto object = value.toObject();
            if (!value.isObject() || object.size() != 1 || !object.contains(QStringLiteral("resolved_edges")))
                throw std::runtime_error("invalid resolved border union");
            const auto physical = typedStyle(object.value(QStringLiteral("resolved_edges")), {"top", "right", "bottom", "left"});
            if (physical.size() != 4) throw std::runtime_error("incomplete resolved border");
            QVariantList result;
            for (const QString &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")}) {
                const auto edge = physical.value(side).toObject();
                if (!physical.value(side).isObject() || edge.size() != 1)
                    throw std::runtime_error("invalid resolved border edge");
                const QString kind = edge.keys().first();
                const int mode = QStringList{"none", "hidden", "solid", "dotted", "inset", "outset"}.indexOf(kind);
                const auto payload = edge.value(kind);
                if (mode < 0 || !payload.isObject() || payload.toObject().size() != (mode < 2 ? 0 : 2))
                    throw std::runtime_error("invalid resolved border line");
                if (mode < 2) { result.append(QVariantMap{{QStringLiteral("style"), mode}}); continue; }
                const auto line = payload.toObject();
                const qreal width = tableBoxLength(line.value(QStringLiteral("width")), points, false).value(QStringLiteral("value")).toDouble();
                const auto paintValue = line.value(QStringLiteral("paint"));
                const auto paint = paintValue.toObject();
                if (!paintValue.isObject() || paint.size() != 1) throw std::runtime_error("invalid resolved border paint");
                QVariant ink;
                if (paint.contains(QStringLiteral("rgb"))) ink = styleColor(paint.value(QStringLiteral("rgb")));
                else if (paint.contains(QStringLiteral("owner_current_color"))
                    && paint.value(QStringLiteral("owner_current_color")).isObject()
                    && paint.value(QStringLiteral("owner_current_color")).toObject().isEmpty()) ink = QStringLiteral("owner_current_color");
                else throw std::runtime_error("unsupported resolved border paint");
                result.append(QVariantMap{{QStringLiteral("style"), mode}, {QStringLiteral("width"), width}, {QStringLiteral("paint"), ink}});
            }
            return result;
        };
        QTextTableFormat format = table ? table->format() : record.empty >= 0 ? emptyTableDefaults(record, indent) : QTextTableFormat();
        if (resolvedBorders) {
            format.setProperty(resolvedTableBordersProperty, resolvedTableBordersCapability);
            format.setProperty(cellStylePolicyProperty, cellStyleCapability);
            format.setProperty(resolvedBorderOwnerInkProperty, styleColor(record.value.value(QStringLiteral("resolved_owner_ink"))));
        }
        if (present(record.value.value(QStringLiteral("block_viewport")))) {
            const bool cornerSeparate = cornerSeparateTableViewport(record.value.value(QStringLiteral("block_viewport")).toObject());
            const auto geometry = intrinsicViewport ? intrinsicTableGridGeometry(record.value.value(QStringLiteral("empty_geometry")))
                : cornerSeparate ? cornerTableGridGeometry(record.value.value(QStringLiteral("empty_geometry"))) : QJsonObject();
            format.setCellPadding(cornerSeparate || intrinsicViewport ? geometry.value(QStringLiteral("cell_padding")).toDouble() : 0);
            format.setCellSpacing(cornerSeparate || intrinsicViewport ? geometry.value(QStringLiteral("cell_spacing")).toDouble() : 0);
            if (intrinsicViewport && table) {
                // Preserve the imported legacy hint before source TABLE CSS can
                // replace the outer border. Explicit Cell CSS is applied below.
                const qreal hint = geometry.value(QStringLiteral("border")).toDouble() > 0 ? 1 : 0;
                const QBrush hintBrush = table->format().borderBrush();
                for (int row = 0; row < table->rows(); ++row) for (int column = 0; column < table->columns(); ++column) {
                    auto cell = table->cellAt(row, column);
                    if (cell.row() != row || cell.column() != column) continue;
                    auto cellFormat = cell.format().toTableCellFormat();
                    cellFormat.setBorder(hint); cellFormat.setBorderStyle(hint > 0 ? QTextFrameFormat::BorderStyle_Solid : QTextFrameFormat::BorderStyle_None);
                    cellFormat.setBorderBrush(hintBrush); cell.setFormat(cellFormat);
                }
                format.setProperty(cellStylePolicyProperty, cellStyleCapability);
            }
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
        const QJsonObject style = typedStyle(record.value.value(QStringLiteral("style")), {"background", "border", "collapse", "margins", "margin_values", "containing_direction", "float_side", "width", "min_width", "padding", "clear", "display", "vertical_align", "line_height", "corner_radii"});
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
            if (spec.contains(QStringLiteral("resolved_edges"))) {
                format.setProperty(resolvedBorderEdgesProperty, resolvedBorder(style.value(QStringLiteral("border"))));
                format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
            } else if (spec.contains(QStringLiteral("edges"))) {
                if (spec.size() != 1 || !table) throw std::runtime_error("physical table border requires a real table owner");
                format.setProperty(tablePhysicalEdgesProperty, QVariantMap{
                    {QStringLiteral("padding"), QVariantList{0.0, 0.0, 0.0, 0.0}},
                    {QStringLiteral("borders"), physicalBorder(spec.value(QStringLiteral("edges")))}});
                format.setProperty(cellStylePolicyProperty, cellStyleCapability);
                format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
            } else {
                const Border b = border(style.value(QStringLiteral("border")));
                if (table && !present(style.value(QStringLiteral("corner_radii")))) {
                    // The ordinary Qt border also allocates legacy grid borders.
                    // Typed TABLE CSS owns only the physical outer edges; imported
                    // cell formats retain their independent hint or CellStyle policy.
                    QJsonObject physical;
                    for (const QString &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")})
                        physical.insert(side, style.value(QStringLiteral("border")));
                    format.setProperty(tablePhysicalEdgesProperty, QVariantMap{
                        {QStringLiteral("padding"), QVariantList{0.0, 0.0, 0.0, 0.0}},
                        {QStringLiteral("borders"), physicalBorder(physical)}});
                    format.setProperty(cellStylePolicyProperty, cellStyleCapability);
                    format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
                    format.setBorderBrush(b.color);
                } else {
                    format.setBorder(b.width); format.setBorderStyle(b.style); format.setBorderBrush(b.color);
                }
            }
        }
        if (present(style.value(QStringLiteral("collapse")))) {
            const QString collapse = style.value(QStringLiteral("collapse")).toString();
            if (collapse != QStringLiteral("separate") && collapse != QStringLiteral("collapse")) throw std::runtime_error("invalid border collapse");
            format.setBorderCollapse(collapse == QStringLiteral("collapse"));
        }
        applyTableCorners(format, style, document);
        if (present(style.value(QStringLiteral("margins")))) {
            const auto e = edges(style.value(QStringLiteral("margins")));
            const qreal maximum = maximumFontPoints(document) * QFontMetricsF(QFont()).fontDpi() / 72;
            format.setTopMargin(e[0]); format.setRightMargin(e[1]); format.setBottomMargin(e[2]); format.setLeftMargin(floatViewport || intrinsicViewport ? e[3] : qMin(maximum, e[3] + indent));
        }
        if (present(style.value(QStringLiteral("margin_values")))) {
            const auto capability = document->documentLayout()->property("_wikidictTableAutoMarginsCapability");
            if (capability.metaType().id() != QMetaType::QString
                || capability.toString() != QStringLiteral("wikidict.table-auto-margins/1"))
                throw std::runtime_error("missing paired table automatic margin layout");
        }
        applyTableAutoMargins(format, style, points, indent);
        applyTableBoxStyle(format, style, points);
        const auto geometry = record.value.value(QStringLiteral("empty_geometry")).toObject();
        const auto legacyWidth = geometry.value(QStringLiteral("width"));
        if (table && hasTableBoxStyle(style) && !present(style.value(QStringLiteral("width"))) && present(legacyWidth)) {
            // A legacy width is the requested table border box. Keep its HTML
            // frame field and use the same grid allocation as a CSS width.
            format.setProperty(tableBoxWidthProperty, tableBoxLength(legacyWidth, points, true));
        }
        const auto minimumSource = record.value.value(QStringLiteral("minimum_source"));
        if (present(style.value(QStringLiteral("min_width")))) {
            if (!table || !minimumSource.isObject() || minimumSource.toObject().value(QStringLiteral("style")) != QJsonValue(style)
                || present(record.value.value(QStringLiteral("block_viewport")))
                || present(record.value.value(QStringLiteral("float_viewport"))))
                throw std::runtime_error("invalid table minimum source ownership");
            format.setProperty(tableMinimumWidthProperty, tableMinimumWidthPolicy(minimumSource.toObject(), points));
        } else if (present(minimumSource)) throw std::runtime_error("unexpected table minimum source");
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
                const int alignment = QStringList{"baseline", "middle", "top", "bottom"}.indexOf(value.toString());
                if (!value.isString() || alignment < 0) throw std::runtime_error("invalid inline table alignment");
                if (alignment >= 2 && format.intProperty(tableDisplayProperty) == 0)
                    throw std::runtime_error("top/bottom alignment requires an inline table");
                if (alignment == 3
                    && native->property("_wikidictInlineTableBottomCapability") != QVariant(QStringLiteral("wikidict.inline-table-bottom/1")))
                    throw std::runtime_error("missing paired inline table bottom layout");
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
        const auto covered = record.value.value(QStringLiteral("covered_cell")).toObject();
        if (!covered.isEmpty()) {
            const auto front = table->cellAt(table->rows()-1, 0);
            if (!front.isValid() || covered.value("front_row").toInt(-1) != table->rows()-1
                || front.columnSpan() != table->columns() || covered.value("front_columns").toInt(-1) != front.columnSpan())
                throw std::runtime_error("invalid covering table cell geometry");
            format.setProperty(QTextFormat::UserProperty + 0x5881, covered.toVariantMap());
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
        const auto legacyCellBorder = record.value.value(QStringLiteral("empty_geometry")).toObject().value(QStringLiteral("border"));
        const bool generatedZeroCellBorder = (present(style.value(QStringLiteral("border")))
            || format.hasProperty(tablePhysicalEdgesProperty) || format.hasProperty(resolvedBorderEdgesProperty))
            && (!present(legacyCellBorder) || (legacyCellBorder.isDouble() && legacyCellBorder.toDouble() == 0));
        bool cellFormatsChanged = false;
        const auto materializeZeroCellBorder = [&](QTextTableCell cell) {
            // HTML import omits zero widths while retaining border styles. Restore
            // only missing widths; explicit CellStyle policy is applied afterward.
            auto imported = cell.format().toTableCellFormat();
            bool changed = false;
            for (const int property : {QTextFormat::TableCellTopBorder, QTextFormat::TableCellRightBorder,
                    QTextFormat::TableCellBottomBorder, QTextFormat::TableCellLeftBorder}) {
                if (!imported.hasProperty(property)) { imported.setProperty(property, qreal(0)); changed = true; }
            }
            if (changed) { cell.setFormat(imported); cellFormatsChanged = true; }
        };
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
                    // A validated implicit empty cell has no authored border.
                    if (format.hasProperty(tablePhysicalEdgesProperty) || resolvedBorders) materializeZeroCellBorder(cell);
                    if (floatViewport || intrinsicViewport) {
                        auto filler = cell.format().toTableCellFormat();
                        filler.setPadding(0); filler.setBorder(0);
                        filler.setBorderStyle(QTextFrameFormat::BorderStyle_None);
                        filler.setBorderBrush(QColor(Qt::transparent));
                        for (const int property : {cellWidthProperty, cellMinimumWidthProperty,
                                cellLineHeightProperty, cellOwnerFontProperty, cellHiddenEdgesProperty})
                            filler.clearProperty(property);
                        filler.setProperty(tableFloatViewportFillerProperty, true);
                        filler.setProperty(tableSourceLanguageProperty,
                            record.value.value(intrinsicViewport ? QStringLiteral("block_viewport") : QStringLiteral("float_viewport")).toObject().value(QStringLiteral("language")).toString());
                        cell.setFormat(filler);
                    }
                    // Collapsed Qt tables paint cell backgrounds, not the frame
                    // background. The missing source slot still exposes that
                    // table color; preserve every other filler format property.
                    if (format.background().style() != Qt::NoBrush && !format.hasProperty(tableCornerRadiiProperty)) {
                        QTextTableCellFormat fillerFormat = cell.format().toTableCellFormat();
                        fillerFormat.setBackground(format.background());
                        cell.setFormat(fillerFormat);
                    }
                    continue;
                }
                const QJsonObject expected = cells[index++].toObject();
                const int declaredRows = compiledTableSpan(expected.value(QStringLiteral("rowspan")), false);
                const int declaredColumns = compiledTableSpan(expected.value(QStringLiteral("colspan")), false);
                // QTextHtmlImporter allocates the source's real rows; mergeCells
                // bounds the used span to that allocation. Preserve the declared
                // metadata and require exactly this result, not an arbitrary match.
                const int remainingSourceRows = int(rows.size()) - row;
                int usedRows = qMin(declaredRows, remainingSourceRows);
                if (!covered.isEmpty() && row == covered.value("row").toInt(-1) && index-1 == covered.value("cell").toInt(-1)) {
                    if (declaredColumns != 1 || declaredRows != covered.value("declared_rows").toInt(-1)
                        || column != covered.value("column").toInt(-1) || usedRows != remainingSourceRows)
                        throw std::runtime_error("invalid covered source cell geometry");
                    usedRows = covered.value("front_row").toInt(-1) - row;
                }
                if (((floatViewport || intrinsicViewport) && declaredRows > remainingSourceRows)
                    || usedRows != cell.rowSpan() || declaredColumns != cell.columnSpan())
                    throw std::runtime_error("table style span mismatch");
                if ((floatViewport || intrinsicViewport) && present(record.value.value(QStringLiteral("block_viewport")))) {
                    const auto empty = expected.value(QStringLiteral("empty_content"));
                    if (!empty.isBool()) throw std::runtime_error("missing paired cell content identity");
                    auto cellFormat = cell.format().toTableCellFormat();
                    if (empty.toBool()) cellFormat.setProperty(pairedTableEmptyCellProperty, true);
                    else cellFormat.clearProperty(pairedTableEmptyCellProperty);
                    cell.setFormat(cellFormat);
                }
                if (format.hasProperty(tableCornerRadiiProperty)) {
                    // HTML import can copy a Table background into cells. Keep
                    // authored cell paint, including an explicit equal color.
                    if (!expected.contains(QStringLiteral("background")))
                        throw std::runtime_error("missing source cell background identity");
                    auto cellFormat = cell.format().toTableCellFormat();
                    const auto background = expected.value(QStringLiteral("background"));
                    if (present(background)) cellFormat.setBackground(styleColor(background));
                    else cellFormat.clearBackground();
                    cell.setFormat(cellFormat);
                }
                if (generatedZeroCellBorder) materializeZeroCellBorder(cell);
                const QJsonObject cellStyle = typedStyle(expected.value(QStringLiteral("style")), {"border", "padding", "text_align", "border_edges", "letter_spacing", "width", "min_width", "vertical_align", "line_height", "opacity"});
                if (cellStyle.isEmpty()) continue;
                QTextTableCellFormat cellFormat = cell.format().toTableCellFormat();
                const auto opacity = cellStyle.value(QStringLiteral("opacity"));
                if (present(opacity)) {
                    if (!opacity.isDouble() || !std::isfinite(opacity.toDouble()) || opacity.toDouble() < 0 || opacity.toDouble() > 1
                        || document->documentLayout()->property("_wikidictCellOpacityCapability").toString() != QStringLiteral("wikidict.cell-opacity/1"))
                        throw std::runtime_error("invalid or unsupported cell opacity");
                    if (!expected.contains(QStringLiteral("background"))) throw std::runtime_error("missing cell background ownership");
                    if (opacity.toDouble() < 1) {
                        const auto source = expected.value(QStringLiteral("background"));
                        if (present(source)) cellFormat.setBackground(styleColor(source)); else cellFormat.clearBackground();
                    }
                    cellFormat.setProperty(cellOpacityProperty, opacity.toDouble());
                }
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
                    if (!line.ownerFont.isEmpty()) {
                        font.setBold(line.ownerFont.value("bold").toBool());
                        font.setItalic(line.ownerFont.value("italic").toBool());
                        applyFontFamily(font, line.ownerFont.value("font_family"));
                        applyFontFeatures(font, fontFeaturePolicy(line.ownerFont.value("font_features")));
                    }
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
                    if (spec.contains(QStringLiteral("resolved_edges"))) {
                        const auto physical = resolvedBorder(cellStyle.value(QStringLiteral("border")));
                        const QColor ownerInk = styleColor(expected.value(QStringLiteral("resolved_owner_ink")));
                        cellFormat.setProperty(resolvedBorderEdgesProperty, physical);
                        cellFormat.setProperty(resolvedBorderOwnerInkProperty, ownerInk);
                        for (int i = 0; i < 4; ++i) {
                            const auto edge = physical[i].toMap();
                            const int mode = edge.value(QStringLiteral("style")).toInt();
                            const qreal width = mode < 2 ? 0 : edge.value(QStringLiteral("width")).toDouble();
                            const auto style = mode == 2 ? QTextFrameFormat::BorderStyle_Solid : mode == 3
                                ? QTextFrameFormat::BorderStyle_Dotted : mode == 4 ? QTextFrameFormat::BorderStyle_Inset
                                : mode == 5 ? QTextFrameFormat::BorderStyle_Outset : QTextFrameFormat::BorderStyle_None;
                            const auto paint = edge.value(QStringLiteral("paint"));
                            const QColor color = mode < 2 ? QColor(Qt::transparent)
                                : paint.metaType().id() == QMetaType::QColor ? paint.value<QColor>() : ownerInk;
                            if (i == 0) { cellFormat.setTopBorder(width); cellFormat.setTopBorderStyle(style); cellFormat.setTopBorderBrush(color); }
                            else if (i == 1) { cellFormat.setRightBorder(width); cellFormat.setRightBorderStyle(style); cellFormat.setRightBorderBrush(color); }
                            else if (i == 2) { cellFormat.setBottomBorder(width); cellFormat.setBottomBorderStyle(style); cellFormat.setBottomBorderBrush(color); }
                            else { cellFormat.setLeftBorder(width); cellFormat.setLeftBorderStyle(style); cellFormat.setLeftBorderBrush(color); }
                        }
                    } else if (spec.contains(QStringLiteral("edges"))) {
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
    for (const auto &record : records) if (present(record.value.value(QStringLiteral("float_viewport")))
        && !present(record.value.value(QStringLiteral("block_viewport")))) {
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
inline constexpr int inlineImageAlignmentProperty = QTextFormat::UserProperty + 0x5811;
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
            && it.key() != QStringLiteral("static_poster") && it.key() != QStringLiteral("vertical_align")) throw std::runtime_error("unknown inline image field");
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
    const auto alignment = image.value(QStringLiteral("vertical_align"));
    if (present(alignment) && (!alignment.isString()
        || (alignment != QStringLiteral("middle") && alignment != QStringLiteral("baseline"))
        || present(image.value(QStringLiteral("static_poster")))))
        throw std::runtime_error("invalid inline image alignment");
    checkedStaticPoster(image);
    return image;
}
inline QJsonObject checkedBlockMediaResource(const QJsonValue &value) {
    const auto object = CompiledContent::containerObject(value,
        {QStringLiteral("natural_width"), QStringLiteral("natural_height"), QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x")},
        {QStringLiteral("natural_width"), QStringLiteral("natural_height"), QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x")});
    for (const auto &key : {QStringLiteral("natural_width"), QStringLiteral("natural_height")}) {
        const auto axis = object.value(key); const double n = axis.toDouble(-1);
        if (!axis.isDouble() || !std::isfinite(n) || n < 1 || n > 2147483647.0 || std::floor(n) != n)
            throw std::runtime_error("invalid block image natural dimensions");
    }
    for (const auto &key : {QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x")}) {
        const auto rendition = CompiledContent::containerObject(object.value(key), {QStringLiteral("url"), QStringLiteral("sha256")}, {QStringLiteral("url"), QStringLiteral("sha256")});
        if (!rendition.value("url").isString() || !rendition.value("sha256").isString())
            throw std::runtime_error("invalid block image rendition");
        const QString url = rendition.value("url").toString(), hash = rendition.value("sha256").toString();
        if (url.size() > 8192 || !url.startsWith(QStringLiteral("https://")) || hash.size() != 64)
            throw std::runtime_error("invalid block image rendition");
        for (QChar ch : hash) if (!((ch >= QChar('0') && ch <= QChar('9')) || (ch >= QChar('a') && ch <= QChar('f'))))
            throw std::runtime_error("invalid block image digest");
        const int slash = url.indexOf(QChar('/'), 8);
        if (slash <= 8 || slash + 1 >= url.size()) throw std::runtime_error("invalid block image URL");
        const QString host = url.mid(8, slash - 8);
        if (host.startsWith(QChar('.')) || host.endsWith(QChar('.')) || !host.contains(QChar('.')))
            throw std::runtime_error("invalid block image URL");
        for (QChar ch : host) if (!((ch >= QChar('a') && ch <= QChar('z')) || (ch >= QChar('A') && ch <= QChar('Z'))
            || (ch >= QChar('0') && ch <= QChar('9')) || ch == QChar('.') || ch == QChar('-')))
            throw std::runtime_error("invalid block image URL");
        for (QChar ch : url) if (ch.unicode() <= 0x20 || ch.unicode() >= 0x7f || ch == QChar('\\') || ch == QChar('#'))
            throw std::runtime_error("invalid block image URL");
    }
    const auto one = object.value("rendition_1x").toObject(), two = object.value("rendition_2x").toObject();
    if (one.value("url") == two.value("url") || one.value("sha256") == two.value("sha256"))
        throw std::runtime_error("ambiguous block image density renditions");
    return object;
}
inline QJsonObject blockMediaResource(const QJsonObject &figure) {
    const auto layout = figure.value(QStringLiteral("block_media_layout")).toObject();
    QJsonObject result;
    for (const auto &key : {QStringLiteral("natural_width"), QStringLiteral("natural_height"), QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x")})
        result.insert(key, layout.value(key));
    return checkedBlockMediaResource(result);
}
inline QJsonObject blockMediaRendition(const QJsonObject &resource, qreal density) {
    const auto checked = checkedBlockMediaResource(resource);
    if (!std::isfinite(density) || density <= 0) throw std::runtime_error("invalid image density");
    const int multiplier = density <= 1 ? 1 : 2;
    auto selected = checked.value(multiplier == 1 ? "rendition_1x" : "rendition_2x").toObject();
    selected.insert("width", checked.value("natural_width").toDouble() * multiplier);
    selected.insert("height", checked.value("natural_height").toDouble() * multiplier);
    return selected;
}

inline QUrl inlineImageUrl(const QJsonObject &image) {
    return QUrl(inlineImageScheme + QChar(':') + QString::fromLatin1(QJsonDocument(image).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
}
inline QJsonObject inlineImagePayload(const QUrl &url) {
    if (url.scheme() != inlineImageScheme || url.hasQuery() || url.hasFragment() || !url.host().isEmpty())
        throw std::runtime_error("invalid inline image resource");
    const QByteArray encoded = url.path().toLatin1();
    const QByteArray bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error; const QJsonDocument value = QJsonDocument::fromJson(bytes, &error);
    if (bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) != encoded || error.error != QJsonParseError::NoError || !value.isObject())
        throw std::runtime_error("invalid inline image metadata");
    return value.object();
}
inline QJsonObject inlineImageData(const QUrl &url) {
    const auto value = inlineImagePayload(url);
    if (!value.contains(QStringLiteral("block_media"))) return checkedImage(value);
    if (value.size() != 2 || !value.value(QStringLiteral("image")).isObject()) throw std::runtime_error("invalid block image resource");
    checkedBlockMediaResource(value.value(QStringLiteral("block_media")));
    return checkedImage(value.value(QStringLiteral("image")));
}
inline QJsonObject inlineImageBlockResource(const QUrl &url) {
    const auto value = inlineImagePayload(url);
    if (!value.contains(QStringLiteral("block_media"))) return {};
    inlineImageData(url);
    return checkedBlockMediaResource(value.value(QStringLiteral("block_media")));
}
inline QUrl inlineBlockMediaUrl(const QJsonObject &figure) {
    const auto image = checkedImage(figure.value(QStringLiteral("image_span")).toObject().value(QStringLiteral("image")));
    return inlineImageUrl(QJsonObject{{QStringLiteral("image"), image}, {QStringLiteral("block_media"), blockMediaResource(figure)}});
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
            const auto alignment = image.value(QStringLiteral("vertical_align"));
            if (present(alignment)) {
                QPointer<QTextDocument> live(document);
                QPointer<QAbstractTextDocumentLayout> native(document->documentLayout());
                const int revision = document->revision();
                const auto capability = native ? native->property("_wikidictInlineImageAlignmentCapability") : QVariant();
                if (!live || !native || live->documentLayout() != native || live->revision() != revision
                    || capability.metaType().id() != QMetaType::QString
                    || capability.toString() != QStringLiteral("wikidict.inline-image-alignment/1"))
                    throw std::runtime_error("missing paired inline image alignment");
                format.setProperty(inlineImageAlignmentProperty, alignment.toString());
            }
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

inline constexpr int clippedAbsoluteProperty = QTextFormat::UserProperty + 0x58d3;
inline constexpr int rubyImportProperty = QTextFormat::UserProperty + 0x5813;
inline constexpr int actionImportProperty = QTextFormat::UserProperty + 0x5814;
inline constexpr int inlineStyleProperty = QTextFormat::UserProperty + 0x5804;
inline constexpr int inlineEmptyOwnersProperty = QTextFormat::UserProperty + 0x5805;
inline const QString inlineStyleCapability = QStringLiteral("wikidict.inline-text/1");
inline QJsonObject inlineObject(const QJsonValue &value, const QStringList &keys, const QStringList &required = {}) {
    if (!value.isObject()) throw std::runtime_error("invalid inline text policy object");
    const auto object = value.toObject();
    for (auto it = object.begin(); it != object.end(); ++it)
        if (!keys.contains(it.key())) throw std::runtime_error("unknown inline text policy field");
    for (const auto &key : required)
        if (!object.contains(key)) throw std::runtime_error("missing inline text policy field");
    return object;
}
inline double inlineNumber(const QJsonValue &value, bool signedValue = false) {
    if (!value.isDouble() || !std::isfinite(value.toDouble())
        || (!signedValue && value.toDouble() < 0) || std::abs(value.toDouble()) > std::numeric_limits<float>::max())
        throw std::runtime_error("invalid inline text metric");
    return value.toDouble();
}
inline void inlineComputed(const QJsonValue &value, bool signedValue = false) {
    const auto v = inlineObject(value, {"value", "font_scale_basis"}, {"value", "font_scale_basis"});
    inlineNumber(v.value("value"), signedValue);
    if (v.value("font_scale_basis") != QStringLiteral("normal_body") && v.value("font_scale_basis") != QStringLiteral("css_px"))
        throw std::runtime_error("inline metric requires explicit font basis");
}
inline QJsonObject inlineFontSnapshot(const QJsonValue &value) {
    return CompiledContent::fontSnapshot(value);
}
inline QJsonObject inlineTextStyle(const QJsonObject &span) {
    const auto raw = span.value("inline_style");
    if (!present(raw)) return {};
    const auto style = inlineObject(raw, {"decoration", "line_height", "baseline_shift", "font_normalized", "cursor", "wrap", "dark_foreground"});
    if (style.contains("dark_foreground")) {
        for (const auto &source : {span.value("foreground"),style.value("dark_foreground")}) {
            const QString value=source.toString();const QColor color(value);
            if (value.size()!=7 || !color.isValid() || color.name()!=value || span.value("kind")!="text"
                || !span.value("target").toString().isEmpty()) throw std::runtime_error("invalid paired source foreground");
        }
    }
    if (!span.value("kind").isString() || !span.value("text").isString()
        || (present(span.value("trail")) && !span.value("trail").isString())
        || (present(span.value("target")) && !span.value("target").isString()))
        throw std::runtime_error("invalid inline text policy content");
    for (const auto &flag : {"small", "superscript", "subscript", "bold", "italic", "code"})
        if (span.contains(flag) && !span.value(flag).isBool()) throw std::runtime_error("invalid inline size flag");
    const auto kind = span.value("kind").toString();
    const bool action = kind == QStringLiteral("link") || kind == QStringLiteral("external_link");
    if ((kind != QStringLiteral("text") && !action) || present(span.value("image"))
        || (action && (span.value("text").toString().isEmpty() || span.value("target").toString().isEmpty()))
        || (!action && !span.value("target").toString().isEmpty())) throw std::runtime_error("invalid inline text policy owner");
    if (present(style.value("cursor")) && (style.value("cursor") != QStringLiteral("help")
        || span.value("text").toString().isEmpty())) throw std::runtime_error("invalid authored inline cursor");
    if (present(style.value("wrap")) && ((style.value("wrap") != QStringLiteral("normal")
            && style.value("wrap") != QStringLiteral("break_word")) || span.value("text").toString().isEmpty()))
        throw std::runtime_error("invalid authored inline wrap");
    if (style.contains("font_normalized") && !style.value("font_normalized").isBool())
        throw std::runtime_error("invalid inline normalized font flag");
    if (style.value("font_normalized").toBool()) {
        inlineNumber(span.value("font_scale"));
        if (span.value("font_scale_basis") != QStringLiteral("normal_body") && span.value("font_scale_basis") != QStringLiteral("css_px"))
            throw std::runtime_error("normalized inline text needs explicit basis");
    }
    if (present(style.value("decoration"))) {
        const auto decoration = inlineObject(style.value("decoration"), {"style", "color", "thickness"}, {"style"});
        if (decoration.value("style") != QStringLiteral("solid") && decoration.value("style") != QStringLiteral("dotted"))
            throw std::runtime_error("invalid inline underline style");
        if (present(decoration.value("color"))) styleColor(decoration.value("color"));
        if (present(decoration.value("thickness"))) {
            const auto length = inlineObject(decoration.value("thickness"), {"unit", "value"}, {"unit", "value"});
            inlineNumber(length.value("value"));
            if (length.value("unit") != QStringLiteral("px") && length.value("unit") != QStringLiteral("em"))
                throw std::runtime_error("invalid inline underline thickness unit");
        }
    }
    if (present(style.value("line_height"))) {
        const auto line = inlineObject(style.value("line_height"), {"computed", "font_relative"});
        if (line.size() != 1) throw std::runtime_error("invalid inline line-height tag");
        if (line.contains("computed")) inlineComputed(line.value("computed"));
        else {
            const auto relative = inlineObject(line.value("font_relative"), {"factor", "font"}, {"factor", "font"});
            inlineNumber(relative.value("factor")); inlineFontSnapshot(relative.value("font"));
        }
    }
    if (present(style.value("baseline_shift"))) inlineComputed(style.value("baseline_shift"), true);
    QJsonObject ownFont;
    for (const auto &key : {"font_scale", "font_scale_basis", "small", "superscript", "subscript",
            "bold", "italic", "code", "language", "classes", "role", "font_features", "font_family"})
        if (span.contains(key)) ownFont.insert(key, span.value(key));
    ownFont.insert("font_normalized", style.value("font_normalized").toBool());
    ownFont = inlineFontSnapshot(ownFont);
    const auto line = style.value("line_height").toObject();
    if (present(style.value("baseline_shift")) && line.contains("font_relative")) {
        const auto snapshot = inlineFontSnapshot(line.value("font_relative").toObject().value("font"));
        if (snapshot != ownFont) throw std::runtime_error("explicit shift cannot cross a distinct inline font owner");
    }
    if (!present(style.value("decoration")) && !present(style.value("line_height"))
        && !present(style.value("baseline_shift")) && !present(style.value("cursor"))
        && !present(style.value("wrap")) && !present(style.value("dark_foreground")) && !style.value("font_normalized").toBool())
        throw std::runtime_error("empty inline text policy");
    if (span.value("text").toString().isEmpty() && span.value("trail").toString().isEmpty()
        && !present(style.value("line_height"))) throw std::runtime_error("empty inline text requires a metric owner");
    return style;
}
inline QTextCharFormat inlineSnapshotFormat(QTextDocument *, const QJsonObject &, const QString &, qreal);
inline QVariantMap resolveInlineStyle(QTextDocument *document, const QJsonObject &span, qreal bodyPoints, qreal contextPoints, const QString &ownerHtml) {
    const auto style = inlineTextStyle(span);
    if (style.isEmpty()) return {};
    if (document->documentLayout()->property("_wikidictInlineTextCapability").toString() != inlineStyleCapability)
        throw std::runtime_error("authored inline text needs paired native support");
    const qreal dpi = QFontMetricsF(QFont()).fontDpi();
    const auto metric = [&](const QJsonValue &value) {
        const auto v = value.toObject();
        const qreal base = v.value("font_scale_basis") == QStringLiteral("css_px") ? cssPixelFontBase(bodyPoints) : bodyPoints;
        const qreal resolved = v.value("value").toDouble() * base * dpi / 72.0;
        if (!std::isfinite(resolved) || std::abs(resolved) >= (1 << 23)) throw std::runtime_error("unrepresentable inline metric");
        return resolved;
    };
    QVariantMap policy{{"policy", inlineStyleCapability}, {"normalized", style.value("font_normalized").toBool()}};
    if (present(style.value("cursor"))) {
        if (document->documentLayout()->property("_wikidictInlineHelpCursorCapability") != QVariant(QStringLiteral("wikidict.inline-help-cursor/1")))
            throw std::runtime_error("authored Help cursor needs paired native support");
        policy.insert("cursor", QStringLiteral("help"));
    }
    if (present(style.value("wrap"))) {
        if (document->documentLayout()->property("_wikidictInlineWrapCapability") != QVariant(QStringLiteral("wikidict.inline-wrap/1")))
            throw std::runtime_error("authored inline wrap needs paired native support");
        policy.insert("wrap", style.value("wrap").toString());
    }
    if (present(style.value("line_height"))) {
        const auto line = style.value("line_height").toObject();
        if (line.contains("computed")) policy.insert("height", metric(line.value("computed")));
        else {
            const auto relative = line.value("font_relative").toObject();
            const auto font = inlineFontSnapshot(relative.value("font"));
            if (present(font.value("font_scale")) && font.value("font_scale").toDouble() == 0) policy.insert("height", 0.0);
            else {
                const auto owner = inlineSnapshotFormat(document, font, ownerHtml, contextPoints);
                if (owner.fontFamilies().toStringList().contains(zeroFontFamilyName)) policy.insert("height", 0.0);
                else {
                    policy.insert("height_factor", relative.value("factor").toDouble());
                    policy.insert("height_font", QVariant::fromValue(QTextFormat(owner)));
                }
            }
        }
    }
    if (present(style.value("baseline_shift"))) policy.insert("shift", metric(style.value("baseline_shift")));
    if (present(style.value("decoration"))) {
        const auto d = style.value("decoration").toObject();
        QVariantMap decoration{{"style", d.value("style").toString()}};
        if (present(d.value("color"))) decoration.insert("color", d.value("color").toString());
        if (present(d.value("thickness"))) {
            const auto length = d.value("thickness").toObject();
            const qreal base = length.value("unit") == QStringLiteral("em") ? bodyPoints * dpi / 72.0 : 1.0;
            const qreal width = base * length.value("value").toDouble();
            if (!std::isfinite(width) || width >= (1 << 23)) throw std::runtime_error("unrepresentable inline underline width");
            decoration.insert("thickness", width);
        }
        policy.insert("decoration", decoration);
    }
    return policy;
}

inline bool hasInlineFamily(const QJsonArray &spans) {
    for (const auto &value : spans) {
        const auto span = value.toObject();
        if (present(span.value("font_family")) || present(span.value("inline_style").toObject()
            .value("line_height").toObject().value("font_relative").toObject()
            .value("font").toObject().value("font_family"))) return true;
    }
    return false;
}

inline bool hasInlineText(const QTextDocument *document) {
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        if (block.blockFormat().hasProperty(inlineEmptyOwnersProperty)) return true;
        for (auto it = block.begin(); !it.atEnd(); ++it)
            if (it.fragment().isValid() && it.fragment().charFormat().hasProperty(inlineStyleProperty)) return true;
    }
    return false;
}

inline QString scaledText(const QString &html, double scale, const QString &tooltip,
                          Basis basis = Basis::Context, qreal normalBodyPoints = 0,
                          bool small = false, bool superscript = false, bool subscript = false, qreal contextPoints = 0,
                          const QJsonValue &advisory = QJsonValue(), bool metadataOnly = false, int sourceRun = -1, const QJsonObject &linkPaint = {}, qint64 linkOwner = -1, qreal linkEm = 0, bool linkUnderline = false, const QJsonValue &fontFeatures = {}, bool ordinaryLink = false, const QJsonObject &inlineSpan = {}, qreal inlineBodyPoints = 0, qreal inlineContextPoints = 0, const QString &inlineOwnerHtml = {}, const QJsonValue &fontFamily = {}, const QJsonObject &compiledRuby = {}, const QJsonObject &compiledAction = {}, const QJsonObject &compiledCitation = {}, const QString &clippedLiteral = {}) {
    if (!compiledRuby.isEmpty() && (!inlineSpan.isEmpty() || !linkPaint.isEmpty()))
        throw std::runtime_error("Ruby import metadata cannot enter an ordinary inline split");
    if (!compiledAction.isEmpty() && (!inlineSpan.isEmpty() || !linkPaint.isEmpty() || !compiledRuby.isEmpty()))
        throw std::runtime_error("inline action import metadata cannot enter an ordinary inline split");
    if (present(inlineSpan.value("inline_style").toObject().value("wrap"))) {
        inlineTextStyle(inlineSpan);
        const auto source = inlineSpan.value("text").toString(), trail = inlineSpan.value("trail").toString();
        if (html != (source + trail).toHtmlEscaped())
            throw std::runtime_error("inline wrap lost its exact source text range");
        if (!trail.isEmpty()) {
            auto textSpan = inlineSpan; textSpan.insert("trail", QString());
            auto trailSpan = inlineSpan; trailSpan.insert("text", trail); trailSpan.insert("trail", QString());
            auto trailStyle = trailSpan.value("inline_style").toObject(); trailStyle.remove("wrap");
            const bool otherStyle = trailStyle.value("font_normalized").toBool()
                || present(trailStyle.value("decoration")) || present(trailStyle.value("line_height"))
                || present(trailStyle.value("baseline_shift")) || present(trailStyle.value("cursor"));
            if (otherStyle) trailSpan.insert("inline_style", trailStyle); else trailSpan = {};
            const auto run = [&](const QString &text, const QJsonObject &owner) {
                return scaledText(text.toHtmlEscaped(), scale, tooltip, basis, normalBodyPoints,
                    small, superscript, subscript, contextPoints, advisory, metadataOnly, sourceRun,
                    linkPaint, linkOwner, linkEm, linkUnderline, fontFeatures, ordinaryLink, owner,
                    inlineBodyPoints, inlineContextPoints, owner.isEmpty() ? QString() : inlineOwnerHtml, fontFamily);
            };
            // Two adjacent markers keep every existing font/action field. Only
            // source text receives wrap; neither trail nor outer bidi isolates do.
            return run(source, textSpan) + run(trail, trailSpan);
        }
    }
    QJsonObject metadata{{"scale", scale}, {"tooltip", tooltip}};
    if (!clippedLiteral.isEmpty()) {
        if (!metadataOnly || html != clippedLiteral.toHtmlEscaped() || !compiledRuby.isEmpty() ||
            !compiledAction.isEmpty() || !compiledCitation.isEmpty() || !inlineSpan.isEmpty() || !linkPaint.isEmpty())
            throw std::runtime_error("invalid clipped literal owner");
        metadata.insert("clipped_literal",clippedLiteral);
    }
    if (!compiledCitation.isEmpty()) {
        ReferencePolicy::citationImport(compiledCitation);
        if (!compiledRuby.isEmpty() || !compiledAction.isEmpty()) throw std::runtime_error("citation cannot replace another inline owner");
        metadata.insert("compiled_citation", compiledCitation);
    }
    if (!compiledAction.isEmpty()) {
        if (html != QStringLiteral("&#xe000;") || !metadataOnly || !inlineSpan.isEmpty()
            || !linkPaint.isEmpty() || !compiledRuby.isEmpty())
            throw std::runtime_error("invalid generated inline action anchor");
        metadata.insert("compiled_action", compiledAction);
    }
    if (!compiledRuby.isEmpty()) {
        if (html != QStringLiteral("&#xe000;") || !metadataOnly || !inlineSpan.isEmpty())
            throw std::runtime_error("invalid generated Ruby import anchor");
        metadata.insert("compiled_ruby", compiledRuby);
    }
    CompiledContent::containerFontFamily(fontFamily);
    if (present(fontFamily)) metadata.insert("font_family", fontFamily);
    if (!inlineSpan.isEmpty()) {
        inlineTextStyle(inlineSpan);
        if (!std::isfinite(inlineBodyPoints) || inlineBodyPoints <= 0
            || !std::isfinite(inlineContextPoints) || inlineContextPoints <= 0)
            throw std::runtime_error("inline policy lost its original font context");
        metadata.insert("inline_span", inlineSpan);
        metadata.insert("inline_body_points", inlineBodyPoints);
        metadata.insert("inline_context_points", inlineContextPoints);
        const bool relative = inlineSpan.value("inline_style").toObject().value("line_height").toObject().contains("font_relative");
        if (relative != !inlineOwnerHtml.isEmpty()) throw std::runtime_error("inline owner font probe missing or unexpected");
        if (relative) metadata.insert("inline_owner_html", inlineOwnerHtml);
    }
    if (fontFeaturePolicy(fontFeatures) != FontFeaturePolicy::Legacy) metadata.insert("font_features", fontFeatures);
    if (!linkPaint.isEmpty()) {
        if (ordinaryLink) MissingFigurePaint::validateOrdinary(linkPaint, linkEm);
        else MissingFigurePaint::validate(linkPaint, linkEm);
        if (linkOwner < (qint64(1) << 32) || linkOwner >= (qint64(1) << 33))
            throw std::runtime_error("invalid compiled link span owner");
        metadata.insert("link_paint", linkPaint); metadata.insert("link_owner", double(linkOwner)); metadata.insert("link_em", linkEm); metadata.insert("link_underline", linkUnderline);
        if (ordinaryLink) metadata.insert("ordinary_link", true);
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
    bool ordinaryLink = false;
    FontFeaturePolicy fontFeatures = FontFeaturePolicy::Legacy;
    QJsonObject inlineSpan;
    QString clippedLiteral;
    QJsonObject compiledRuby;
    QJsonObject compiledAction;
    QVariantMap citation;
    int generatedIsolate = 0;
    qreal inlineBodyPoints = 0;
    qreal inlineContextPoints = 0;
    QString inlineOwnerHtml;
    QJsonValue fontFamily;
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
        const bool hasInline = present(value.value("inline_span"));
        const bool hasRuby = value.contains("compiled_ruby");
        const bool hasAction = value.contains("compiled_action");
        const bool hasCitation = value.contains("compiled_citation");
        const bool hasGeneratedIsolate = value.contains("generated_isolate");
        const auto fontFamily = CompiledContent::containerFontFamily(value.value("font_family"));
        const bool hasFamily = present(fontFamily);
        const auto fontFeatures = fontFeaturePolicy(value.value("font_features"));
        const double run = sourceRun.toDouble(-1);
        if (error.error != QJsonParseError::NoError || !payload.isObject()
            || !value.value(QStringLiteral("scale")).isDouble() || !std::isfinite(scale)
            || scale < 0 || (!absolute && scale == 1 && !metadataOnly) || !value.value(QStringLiteral("tooltip")).isString()
            || (!metadataValue.isUndefined() && !metadataValue.isBool())
            || (present(advisory) && !advisory.isString())
            || (hasSourceRun && (!sourceRun.isDouble() || !std::isfinite(run)
                || run < 0 || run > std::numeric_limits<int>::max() || std::floor(run) != run))
            || (metadataOnly && (scale != 1 || absolute || (!present(advisory) && !hasSourceRun && !hasLinkPaint && !hasInline && !hasRuby && !hasAction && !hasCitation && !value.contains("clipped_literal") && !hasGeneratedIsolate && !hasFamily && fontFeatures == FontFeaturePolicy::Legacy)
                || value.contains(QStringLiteral("context_points")) || value.contains(QStringLiteral("legacy_flags"))))
            || (!basisValue.isUndefined() && (!basisValue.isString()
                || (basisValue.toString() != QStringLiteral("context") && !absolute))))
            throw std::runtime_error("invalid renderer font-scale metadata");
        ScaleInfo info{scale, value.value(QStringLiteral("tooltip")).toString()};
        if (value.contains("clipped_literal")) {
            info.clippedLiteral = value.value("clipped_literal").toString();
            if (info.clippedLiteral.isEmpty() || !metadataOnly || hasRuby || hasAction || hasCitation || hasInline || hasLinkPaint)
                throw std::runtime_error("invalid clipped literal metadata");
        }
        if (hasCitation) {
            if (hasRuby || hasAction || hasGeneratedIsolate || !value.value("compiled_citation").isObject())
                throw std::runtime_error("invalid citation import owner");
            info.citation = ReferencePolicy::citationImport(value.value("compiled_citation").toObject());
        }
        if (hasGeneratedIsolate) {
            const auto scalar = value.value("generated_isolate");
            if (!metadataOnly || value.size() != 4 || !scalar.isDouble()
                || scalar.toDouble() != scalar.toInt() || !isGeneratedIsolateScalar(scalar.toInt())
                || !info.tooltip.isEmpty())
                throw std::runtime_error("invalid generated isolate metadata");
            info.generatedIsolate = scalar.toInt();
        }
        if (hasAction) {
            if (!metadataOnly || !value.value("compiled_action").isObject()
                || value.value("compiled_action").toObject().isEmpty() || hasInline || hasLinkPaint || hasRuby)
                throw std::runtime_error("invalid generated inline action metadata");
            info.compiledAction = value.value("compiled_action").toObject();
        }
        if (hasRuby) {
            if (!metadataOnly || !value.value("compiled_ruby").isObject()
                || value.value("compiled_ruby").toObject().isEmpty() || hasInline || hasLinkPaint)
                throw std::runtime_error("invalid generated Ruby metadata");
            info.compiledRuby = value.value("compiled_ruby").toObject();
        }
        if (hasLinkPaint) {
            const auto owner = value.value("link_owner"); const auto em = value.value("link_em");
            const double id = owner.toDouble(-1);
            if (!owner.isDouble() || !std::isfinite(id) || std::floor(id) != id
                || id < double(qint64(1) << 32) || id >= double(qint64(1) << 33) || !em.isDouble())
                throw std::runtime_error("invalid compiled link span identity");
            info.linkPaint = value.value("ordinary_link").toBool()
                ? MissingFigurePaint::validateOrdinary(value.value("link_paint"), em.toDouble())
                : MissingFigurePaint::validate(value.value("link_paint"), em.toDouble());
            info.linkOwner = qint64(id); info.linkEm = em.toDouble();
            if (!value.value("link_underline").isBool()) throw std::runtime_error("invalid compiled link decoration");
            info.linkUnderline = value.value("link_underline").toBool();
            if (value.contains("ordinary_link")) {
                if (!value.value("ordinary_link").isBool() || !value.value("ordinary_link").toBool()
                    || info.linkUnderline != info.linkPaint.value("normal").toObject().value("underline").toBool())
                    throw std::runtime_error("invalid ordinary link decoration metadata");
                info.ordinaryLink = true;
            }
        } else if (value.contains("link_owner") || value.contains("link_em") || value.contains("link_underline") || value.contains("ordinary_link"))
            throw std::runtime_error("unowned compiled link span metadata");
        if (hasInline) {
            if (!value.value("inline_span").isObject()) throw std::runtime_error("invalid inline marker owner");
            info.inlineSpan = value.value("inline_span").toObject();
            inlineTextStyle(info.inlineSpan);
            for (const auto &key : {"inline_body_points", "inline_context_points"})
                if (!value.value(key).isDouble() || !std::isfinite(value.value(key).toDouble()) || value.value(key).toDouble() <= 0)
                    throw std::runtime_error("invalid inline marker typography context");
            info.inlineBodyPoints = value.value("inline_body_points").toDouble();
            info.inlineContextPoints = value.value("inline_context_points").toDouble();
            const bool relative = info.inlineSpan.value("inline_style").toObject().value("line_height").toObject().contains("font_relative");
            if (relative) {
                if (!value.value("inline_owner_html").isString() || value.value("inline_owner_html").toString().isEmpty())
                    throw std::runtime_error("invalid inline owner semantic probe");
                info.inlineOwnerHtml = value.value("inline_owner_html").toString();
            } else if (value.contains("inline_owner_html")) throw std::runtime_error("unowned inline font probe");
        } else if (value.contains("inline_body_points") || value.contains("inline_context_points") || value.contains("inline_owner_html"))
            throw std::runtime_error("unowned inline marker typography");
        info.fontFeatures = fontFeatures;
        info.fontFamily = fontFamily;
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
    struct EmptyInline { QTextBlock block; int offset; QTextCharFormat format; QStringList names; };
    QVector<EmptyInline> emptyInlines;
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
                            if ((marker->legacyFlags & 1)
                                && !marker->inlineSpan.value("inline_style").toObject().value("font_normalized").toBool()) {
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
                if (present(marker->fontFamily) && !format.fontFamilies().toStringList().contains(zeroFontFamilyName)) {
                    auto font = format.font().resolve(document->defaultFont());
                    applyFontFamily(font, marker->fontFamily);
                    format.setFontFamilies(font.families());
                    format.setFontStyleHint(font.styleHint(), font.styleStrategy());
                }
                applyFontFeatures(format, marker->fontFeatures, document->defaultFont());
                if (!marker->inlineSpan.isEmpty()) {
                    format.setProperty(inlineStyleProperty, resolveInlineStyle(document, marker->inlineSpan,
                        marker->inlineBodyPoints, marker->inlineContextPoints, marker->inlineOwnerHtml));
                    if (marker->inlineSpan.value("text").toString().isEmpty() && marker->inlineSpan.value("trail").toString().isEmpty()) {
                        for (int i = 0; i < fragment.length(); ++i) {
                            if (fragment.text().at(i) != QChar(0xe000)) throw std::runtime_error("empty inline marker changed");
                            auto owner = format;
                            owner.clearProperty(QTextFormat::TextToolTip);
                            owner.setAnchor(false); owner.clearProperty(QTextFormat::AnchorHref); owner.clearProperty(QTextFormat::AnchorName);
                            emptyInlines.append({block, fragment.position() - block.position() + i, owner, i == 0 ? format.anchorNames() : QStringList{}});
                        }
                    }
                }
                if (!marker->linkPaint.isEmpty()) {
                    if (!format.isAnchor() || format.anchorHref().isEmpty() || (format.isImageFormat() && !marker->ordinaryLink))
                        throw std::runtime_error("compiled link span lost its action");
                    if (marker->ordinaryLink && document->documentLayout()->property("_wikidictOrdinaryLinkStateCapability").toString() != MissingFigurePaint::ordinaryPolicy)
                        throw std::runtime_error("ordinary link paint requires paired native support");
                    if (format.isImageFormat()) {
                        const auto image = checkedImage(inlineImageData(QUrl(format.toImageFormat().name())));
                        if (!image.value("alt").toString().isEmpty() || present(image.value("map")) || present(image.value("static_poster"))
                            || document->documentLayout()->property("_wikidictOrdinaryImageLinkStateCapability").toString() != MissingFigurePaint::ordinaryImageCapability)
                            throw std::runtime_error("ordinary image link paint requires paired simple image support");
                    }
                    format.setProperty(MissingFigurePaint::policyProperty, marker->ordinaryLink ? MissingFigurePaint::ordinaryPolicy : MissingFigurePaint::fixedPolicy);
                    format.setProperty(MissingFigurePaint::ownerProperty, marker->linkOwner);
                    format.setProperty(MissingFigurePaint::fixedPolicyProperty, marker->linkPaint.toVariantMap());
                    format.setProperty(MissingFigurePaint::outlineProperty, MissingFigurePaint::outline(marker->linkPaint, marker->linkEm));
                    format.setProperty(MissingFigurePaint::underlineProperty, marker->linkUnderline);
                    const bool zeroLink = marker->scale == 0 || format.fontFamilies().toStringList().contains(zeroFontFamilyName);
                    format.setProperty(MissingFigurePaint::zeroFontProperty, zeroLink);
                    if (!format.isImageFormat())
                        format.setForeground(zeroLink ? QColor(Qt::transparent)
                            : QColor(marker->linkPaint.value("normal").toObject().value("foreground").toString()));
                    format.setUnderlineStyle(!format.isImageFormat() && !zeroLink
                        && ((!marker->ordinaryLink && marker->linkUnderline) || marker->linkPaint.value("normal").toObject().value("underline").toBool())
                        ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
                }
                if (!marker->citation.isEmpty()) {
                    if (!format.isAnchor() || format.anchorHref().isEmpty() || format.objectType() != QTextFormat::NoObject
                        || document->documentLayout()->property("_wikidictReferenceLayoutCapability") != QVariant(ReferencePolicy::capability))
                        throw std::runtime_error("compiled citation lost its native source owner");
                    format.setProperty(ReferencePolicy::citationProperty, marker->citation);
                    const auto span = ReferencePolicy::source(marker->citation.value("source"));
                    auto names = format.anchorNames();
                    const auto anchor = span.value("citation_marker").toObject().value("anchor").toString();
                    if (!names.contains(anchor)) names.append(anchor);
                    format.setAnchorNames(names);
                }
                if (marker->generatedIsolate) {
                    for (const QChar character : fragment.text())
                        if (character.unicode() != marker->generatedIsolate)
                            throw std::runtime_error("generated isolate changed during HTML import");
                    format.setProperty(generatedIsolateProperty, marker->generatedIsolate);
                }
                if (marker->sourceRun >= 0) format.setProperty(sourceRunProperty, marker->sourceRun);
                if (!marker->clippedLiteral.isEmpty()) {
                    if (fragment.text()!=marker->clippedLiteral) throw std::runtime_error("clipped source text changed");
                    format.setProperty(clippedAbsoluteProperty,marker->clippedLiteral);
                }
                if (!marker->compiledRuby.isEmpty()) {
                    for (QChar c : fragment.text()) if (c != QChar(0xe000))
                        throw std::runtime_error("generated Ruby anchor changed during HTML import");
                    format.setProperty(rubyImportProperty, QVariant::fromValue(marker->compiledRuby));
                }
                if (!marker->compiledAction.isEmpty()) {
                    for (QChar c : fragment.text()) if (c != QChar(0xe000))
                        throw std::runtime_error("generated inline action anchor changed during HTML import");
                    format.setProperty(actionImportProperty, QVariant::fromValue(marker->compiledAction));
                }
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
    for (auto it = emptyInlines.crbegin(); it != emptyInlines.crend(); ++it) {
        cursor.setPosition(it->block.position() + it->offset);
        cursor.setPosition(cursor.position() + 1, QTextCursor::KeepAnchor);
        if (cursor.selectedText() != QString(QChar(0xe000))) throw std::runtime_error("empty inline marker position changed");
        cursor.removeSelectedText();
    }
    int oldBlock = -1, removed = 0;
    QVariantList owners;
    QTextBlock ownerBlock;
    const auto finishOwners = [&] {
        if (!ownerBlock.isValid()) return;
        auto blockFormat = ownerBlock.blockFormat();
        blockFormat.setProperty(inlineEmptyOwnersProperty, QVariantMap{{"text", ownerBlock.text()}, {"owners", owners}});
        QTextCursor(ownerBlock).setBlockFormat(blockFormat);
    };
    for (const auto &empty : emptyInlines) {
        if (empty.block.blockNumber() != oldBlock) {
            finishOwners(); owners.clear(); removed = 0; oldBlock = empty.block.blockNumber(); ownerBlock = empty.block;
        }
        const int offset = empty.offset - removed++;
        if (offset < 0 || offset > ownerBlock.text().size()) throw std::runtime_error("empty inline source offset escaped block");
        owners.append(QVariantMap{{"offset", offset}, {"format", QVariant::fromValue(QTextFormat(empty.format))}});
        if (!empty.names.isEmpty()) {
            // Named destinations attached by Qt to our temporary first scalar
            // belong to the next real scalar, exactly as in the ordinary importer.
            if (offset == 0 && ownerBlock.text().isEmpty()) {
                // The existing anchor lookup already reads block.charFormat()
                // for empty paragraphs. Merge only names, preserving cell markers.
                auto names = ownerBlock.charFormat().anchorNames();
                for (const auto &name : empty.names) if (!names.contains(name)) names.append(name);
                QTextCharFormat named; named.setAnchor(true); named.setAnchorNames(names);
                QTextCursor(ownerBlock).mergeBlockCharFormat(named);
                continue;
            }
            if (offset >= ownerBlock.text().size()) throw std::runtime_error("empty named inline destination has no real scalar");
            QTextCursor target(document); target.setPosition(ownerBlock.position() + offset);
            const int units = ownerBlock.text().at(offset).isHighSurrogate() ? 2 : 1;
            target.setPosition(target.position() + units, QTextCursor::KeepAnchor);
            auto format = target.charFormat(); auto names = format.anchorNames();
            for (const auto &name : empty.names) if (!names.contains(name)) names.append(name);
            format.setAnchor(true); format.setAnchorNames(names); target.setCharFormat(format);
        }
    }
    finishOwners();
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
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(paragraphRunOpen) && !html.contains(authoredRuleMarkerOpen) && !html.contains(inlineImageScheme + QChar(':'))) { document->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    QHash<int, int> paragraphRuns; QHash<int, QVariantMap> rules;
    const QString fontHtml = prepare(prepareParagraphRuns(prepareAuthoredRules(html, rules), paragraphRuns), markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    document->setHtml(prepared);
    if (!normalizeParagraphRuns(document, paragraphRuns) || !normalizeAuthoredRules(document, rules)) return;
    normalize(document, markers);
    normalizeTables(document, tables, tableCount);
    normalizeImages(document);
    registerInlineTableOwners(document);
    finishFloatingLayout(document);
}

inline void requireBrowserInlineSupport(QTextBrowser *browser) {
    if (browser->property("_wikidictHelpCursorOverrideCapability") == QVariant(QStringLiteral("wikidict.help-cursor-override/1"))) return;
    // Inspect every currently materialized range. Callers that expand nested
    // Flow owners later must repeat this check after that expansion.
    for (auto block = browser->document()->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (fragment.isValid() && fragment.charFormat().property(inlineStyleProperty).toMap().contains("cursor"))
                throw std::runtime_error("authored Help cursor needs paired browser support");
        }
    }
}
template <typename AfterImport>
inline void setHtml(QTextBrowser *browser, const QString &html, AfterImport afterImport) {
    const QPointer<QTextBrowser> browserGuard(browser);
    const QPointer<QTextDocument> document(browser->document());
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(paragraphRunOpen) && !html.contains(authoredRuleMarkerOpen) && !html.contains(inlineImageScheme + QChar(':'))) {
        browser->setHtml(html); afterImport();
        if (browserGuard && document && browser->document() == document) requireBrowserInlineSupport(browser);
        return;
    }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    QHash<int, int> paragraphRuns; QHash<int, QVariantMap> rules;
    const QString fontHtml = prepare(prepareParagraphRuns(prepareAuthoredRules(html, rules), paragraphRuns), markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    for (const auto &marker : std::as_const(markers))
        if (present(marker.inlineSpan.value("inline_style").toObject().value("cursor"))
            && browser->property("_wikidictHelpCursorOverrideCapability") != QVariant(QStringLiteral("wikidict.help-cursor-override/1")))
            throw std::runtime_error("authored Help cursor needs paired browser support");
    browser->setHtml(prepared);
    // The owning compositor completes its structural edit before table
    // traversal, then may batch the following format normalization separately.
    afterImport();
    if (!browserGuard || !document || browser->document() != document) return;
    if (!normalizeParagraphRuns(document, paragraphRuns)
        || !browserGuard || !document || browser->document() != document) return;
    if (!normalizeAuthoredRules(document, rules)
        || !browserGuard || !document || browser->document() != document) return;
    normalize(browser->document(), markers);
    normalizeTables(browser->document(), tables, tableCount);
    normalizeImages(browser->document());
    requireBrowserInlineSupport(browser);
    finishFloatingLayout(browser->document());
}
inline void setHtml(QTextBrowser *browser, const QString &html) {
    setHtml(browser, html, [] {});
}
inline QTextCharFormat inlineSnapshotFormat(QTextDocument *document, const QJsonObject &snapshot,
    const QString &ownerHtml, qreal contextPoints) {
    inlineFontSnapshot(snapshot);
    if (!std::isfinite(contextPoints) || contextPoints <= 0 || ownerHtml.isEmpty())
        throw std::runtime_error("inline font snapshot lost its semantic context");
    // MainWindow renders this closed semantic snapshot through the ordinary
    // span path. Start from its original document context, never the child's font.
    QFont base = document->defaultFont();
    base.setPointSizeF(contextPoints);
    QTextDocument control;
    control.setDefaultFont(base);
    control.setDefaultStyleSheet(document->defaultStyleSheet());
    control.setDefaultTextOption(document->defaultTextOption());
    control.documentLayout()->setPaintDevice(document->documentLayout()->paintDevice());
    setHtml(&control, ownerHtml);
    if (control.toPlainText() != QStringLiteral("X")) throw std::runtime_error("inline owner probe changed its text");
    const auto found = control.find(QStringLiteral("X"));
    if (found.isNull()) throw std::runtime_error("unresolved inline owner font snapshot");
    auto format = found.charFormat();
    // A stored format must retain its declaring document's inherited font after
    // this independent owner probe is destroyed.
    format.setFont(format.font().resolve(control.defaultFont()));
    format.setAnchor(false); format.clearProperty(QTextFormat::AnchorHref); format.clearProperty(QTextFormat::AnchorName);
    return format;
}

} // namespace SemanticHtml
