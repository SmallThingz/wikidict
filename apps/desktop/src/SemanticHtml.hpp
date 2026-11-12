#pragma once

#include "CompiledImageMap.hpp"
#include "LogicalFlow.hpp"
#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QHash>
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
inline constexpr int emptyTableRoleProperty = QTextFormat::UserProperty + 0x57d4;
inline constexpr int emptyTableBoundaryProperty = QTextFormat::UserProperty + 0x57d5;
inline constexpr int tableDisplayProperty = QTextFormat::UserProperty + 0x57d6;
inline constexpr int tableVerticalAlignProperty = QTextFormat::UserProperty + 0x57d7;
inline constexpr int tableLineHeightProperty = QTextFormat::UserProperty + 0x57d8;
inline constexpr int generatedParentStrutProperty = QTextFormat::UserProperty + 0x57d9;
inline constexpr int cellStylePolicyProperty = QTextFormat::UserProperty + 0x57da;
inline constexpr int cellWidthProperty = QTextFormat::UserProperty + 0x57db;
inline const QString cellStyleCapability = QStringLiteral("wikidict.cell-style/1");
inline bool hasExtendedCellStyle(const QJsonObject &style) {
    return present(style.value(QStringLiteral("border_edges")))
        || present(style.value(QStringLiteral("letter_spacing")))
        || present(style.value(QStringLiteral("width")));
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
inline QHash<QString, bool> inlineTableAudioOwners(const QJsonArray &media) {
    QHash<QString, bool> owners;
    for (const auto &value : media) {
        if (!value.isObject()) throw std::runtime_error("invalid inline table media catalog");
        const auto item = value.toObject();
        const QString key = QStringLiteral("wikidict-media-file-") + QString::fromLatin1(item.value(QStringLiteral("file")).toString().toUtf8().toHex());
        const bool audio = !item.value(QStringLiteral("file")).toString().isEmpty() && !owners.contains(key)
            && item.value(QStringLiteral("kind")).toString() == QStringLiteral("audio");
        owners.insert(key, audio);
    }
    return owners;
}
inline void validateInlineTableDomain(const QJsonObject &table, int tableDepth, int contentDepth,
                                     bool inReference, const QHash<QString, bool> &audioOwners) {
    if (!tableDisplay(table.value(QStringLiteral("style")).toObject())) return;
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
                if (present(span.value(QStringLiteral("image")))) throw std::runtime_error("unsupported inline table image");
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
                    if (!audioOwners.value(owner, false)) throw std::runtime_error("unresolved inline table audio owner");
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
        || present(style.value(QStringLiteral("clear"))) || hasTableFlowStyle(style);
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
inline QString tableStyleMarker(const QJsonObject &table, qreal containerPoints, int indent, bool resetTextAlignment = false,
                                const QString &listMarker = {}, int tableDepth = 1, qreal tableOriginPoints = -1) {
    bool hasCell = false;
    for (const auto &row : table.value(QStringLiteral("rows")).toArray())
        hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
    bool styled = !listMarker.isEmpty() || resetTextAlignment || present(table.value(QStringLiteral("style")))
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
            cells.append(shape);
        }
        rows.append(cells);
    }
    if (!styled && !hasCell) return {};
    QJsonObject metadata{{"container_points", containerPoints}, {"indent", indent}, {"rows", rows}};
    metadata.insert(QStringLiteral("empty_nested"), tableDepth > 1);
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
                || present(table.value.value(QStringLiteral("empty_geometry"))))) {
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

inline void materializeEmptyTable(QTextDocument *document, const TableInfo &record, const QTextTableFormat &format) {
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
}

inline void normalizeTables(QTextDocument *document, const QVector<TableInfo> &records, int expectedTables) {
    if (records.isEmpty()) return;
    bool needsTableBoxLayout = false;
    bool needsCellStyleLayout = false;
    for (const TableInfo &record : records)
        for (const QJsonValue &row : record.value.value(QStringLiteral("rows")).toArray())
            for (const QJsonValue &cell : row.toArray())
                needsCellStyleLayout |= hasExtendedCellStyle(cell.toObject().value(QStringLiteral("style")).toObject());
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
        const auto length = [&](const QJsonValue &value) { return styleLengthUnits(value, document, points); };
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
        QTextTableFormat format = table ? table->format() : record.empty >= 0 ? emptyTableDefaults(record, indent) : QTextTableFormat();
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
        const QJsonObject style = typedStyle(record.value.value(QStringLiteral("style")), {"background", "border", "collapse", "margins", "float_side", "width", "padding", "clear", "display", "vertical_align", "line_height"});
        if (present(style.value(QStringLiteral("float_side")))) {
            const QJsonValue side = style.value(QStringLiteral("float_side"));
            if (!side.isString() || (side.toString() != QStringLiteral("left") && side.toString() != QStringLiteral("right")))
                throw std::runtime_error("invalid table float side");
            // Public frame positioning participates in normal text flow and
            // preserves the original QTextTable cells, offsets and selection.
            format.setPosition(side.toString() == QStringLiteral("left") ? QTextFrameFormat::FloatLeft : QTextFrameFormat::FloatRight);
        }
        if (present(style.value(QStringLiteral("background")))) format.setBackground(styleColor(style.value(QStringLiteral("background"))));
        if (present(style.value(QStringLiteral("border")))) { const Border b = border(style.value(QStringLiteral("border"))); format.setBorder(b.width); format.setBorderStyle(b.style); format.setBorderBrush(b.color); }
        if (present(style.value(QStringLiteral("collapse")))) {
            const QString collapse = style.value(QStringLiteral("collapse")).toString();
            if (collapse != QStringLiteral("separate") && collapse != QStringLiteral("collapse")) throw std::runtime_error("invalid border collapse");
            format.setBorderCollapse(collapse == QStringLiteral("collapse"));
        }
        if (present(style.value(QStringLiteral("margins")))) {
            const auto e = edges(style.value(QStringLiteral("margins")));
            const qreal maximum = maximumFontPoints(document) * QFontMetricsF(QFont()).fontDpi() / 72;
            format.setTopMargin(e[0]); format.setRightMargin(e[1]); format.setBottomMargin(e[2]); format.setLeftMargin(qMin(maximum, e[3] + indent));
        }
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
                const int alignment = QStringList{"baseline", "middle"}.indexOf(value.toString());
                if (!value.isString() || alignment < 0) throw std::runtime_error("invalid inline table alignment");
                format.setProperty(tableVerticalAlignProperty, alignment);
            }
            if (present(style.value(QStringLiteral("line_height"))))
                format.setProperty(tableLineHeightProperty, tableComputedLineHeight(style.value(QStringLiteral("line_height")),
                    points, record.value.value(QStringLiteral("table_origin_points")).toDouble(-1)));
        }
        if (!table) {
            for (const QJsonValue &row : rows)
                if (!row.isArray() || !row.toArray().isEmpty()) throw std::runtime_error("unexpected nonempty elided table");
            if (record.empty >= 0) materializeEmptyTable(document, record, format);
            else if (hasTableBoxStyle(style)) throw std::runtime_error("unmapped empty table box");
            continue;
        }
        if (format.intProperty(tableDisplayProperty) > 0) {
            format.setLeftMargin(format.leftMargin() - indent);
            if (!present(style.value(QStringLiteral("margins")))) {
                format.setTopMargin(0); format.setBottomMargin(0);
            }
        }
        table->setFormat(format);
        if (format.hasProperty(tableLineHeightProperty)) {
            for (QTextBlock block = document->findBlock(table->firstPosition()); block.isValid() && block.position() < table->lastPosition(); block = block.next()) {
                auto inherited = block.blockFormat();
                // Existing explicit paragraph policies override inherited table line height.
                if (inherited.lineHeightType() != QTextBlockFormat::SingleHeight
                    && !inherited.boolProperty(generatedParentStrutProperty) && !inherited.hasProperty(tableLineHeightProperty)) continue;
                inherited.setProperty(tableLineHeightProperty, format.property(tableLineHeightProperty));
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
                const QJsonObject cellStyle = typedStyle(expected.value(QStringLiteral("style")), {"border", "padding", "text_align", "border_edges", "letter_spacing", "width"});
                if (cellStyle.isEmpty()) continue;
                QTextTableCellFormat cellFormat = cell.format().toTableCellFormat();
                if (present(cellStyle.value(QStringLiteral("border")))) { const Border b = border(cellStyle.value(QStringLiteral("border"))); cellFormat.setBorder(b.width); cellFormat.setBorderStyle(b.style); cellFormat.setBorderBrush(b.color); }
                if (present(cellStyle.value(QStringLiteral("padding")))) { const auto e = edges(cellStyle.value(QStringLiteral("padding"))); cellFormat.setTopPadding(e[0]); cellFormat.setRightPadding(e[1]); cellFormat.setBottomPadding(e[2]); cellFormat.setLeftPadding(e[3]); }
                if (present(cellStyle.value(QStringLiteral("border_edges")))) {
                    const auto physical = typedStyle(cellStyle.value(QStringLiteral("border_edges")), {"top", "right", "bottom", "left"});
                    for (const QString &edge : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")}) {
                        if (!present(physical.value(edge))) continue;
                        const Border b = cellBorder(physical.value(edge));
                        if (edge == QStringLiteral("top")) { cellFormat.setTopBorder(b.width); cellFormat.setTopBorderStyle(b.style); cellFormat.setTopBorderBrush(b.color); }
                        else if (edge == QStringLiteral("right")) { cellFormat.setRightBorder(b.width); cellFormat.setRightBorderStyle(b.style); cellFormat.setRightBorderBrush(b.color); }
                        else if (edge == QStringLiteral("bottom")) { cellFormat.setBottomBorder(b.width); cellFormat.setBottomBorderStyle(b.style); cellFormat.setBottomBorderBrush(b.color); }
                        else { cellFormat.setLeftBorder(b.width); cellFormat.setLeftBorderStyle(b.style); cellFormat.setLeftBorderBrush(b.color); }
                    }
                }
                if (present(cellStyle.value(QStringLiteral("width"))))
                    cellFormat.setProperty(cellWidthProperty, tableBoxLength(cellStyle.value(QStringLiteral("width")), points, true));
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
            && it.key() != QStringLiteral("dark_mode_filter") && it.key() != QStringLiteral("svg_language")) throw std::runtime_error("unknown inline image field");
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
    const bool framed = figure.value(QStringLiteral("format")).toString() == QStringLiteral("framed");
    const bool hasWidth = !framed && present(image.value(QStringLiteral("width_px")));
    const bool hasHeight = !framed && present(image.value(QStringLiteral("height_px")));
    const qreal width = hasWidth ? image.value(QStringLiteral("width_px")).toDouble() : (intrinsic.isValid() ? intrinsic.width() : 1);
    const qreal height = hasHeight ? image.value(QStringLiteral("height_px")).toDouble() : (intrinsic.isValid() ? intrinsic.height() : 1);
    qreal w = qMin(maximum, width), h = qMin(maximum, height);
    qreal layoutWidth = w, layoutHeight = h;
    if (intrinsic.isValid()) {
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
                          const QJsonValue &advisory = QJsonValue(), bool metadataOnly = false, int sourceRun = -1) {
    QJsonObject metadata{{"scale", scale}, {"tooltip", tooltip}};
    if (present(advisory)) {
        if (!advisory.isString()) throw std::runtime_error("invalid span advisory");
        metadata.insert(QStringLiteral("advisory"), advisory);
    }
    if (sourceRun < -1) throw std::runtime_error("invalid renderer source run");
    if (sourceRun >= 0) metadata.insert(QStringLiteral("source_run"), sourceRun);
    if (metadataOnly) metadata.insert(QStringLiteral("metadata_only"), true);
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
    QJsonValue advisory;
    bool metadataOnly = false;
    int sourceRun = -1;
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
        const QJsonValue metadataValue = value.value(QStringLiteral("metadata_only"));
        const bool metadataOnly = metadataValue.toBool();
        const QJsonValue advisory = value.value(QStringLiteral("advisory"));
        const QJsonValue sourceRun = value.value(QStringLiteral("source_run"));
        const bool hasSourceRun = !sourceRun.isUndefined();
        const double run = sourceRun.toDouble(-1);
        if (error.error != QJsonParseError::NoError || !payload.isObject()
            || !value.value(QStringLiteral("scale")).isDouble() || !std::isfinite(scale)
            || scale < 0 || (!normalBody && scale == 1 && !metadataOnly) || !value.value(QStringLiteral("tooltip")).isString()
            || (!metadataValue.isUndefined() && !metadataValue.isBool())
            || (present(advisory) && !advisory.isString())
            || (hasSourceRun && (!sourceRun.isDouble() || !std::isfinite(run)
                || run < 0 || run > std::numeric_limits<int>::max() || std::floor(run) != run))
            || (metadataOnly && (scale != 1 || normalBody || (!present(advisory) && !hasSourceRun)
                || value.contains(QStringLiteral("context_points")) || value.contains(QStringLiteral("legacy_flags"))))
            || (!basisValue.isUndefined() && (!basisValue.isString()
                || (basisValue.toString() != QStringLiteral("context") && !normalBody))))
            throw std::runtime_error("invalid renderer font-scale metadata");
        ScaleInfo info{scale, value.value(QStringLiteral("tooltip")).toString()};
        info.advisory = advisory;
        info.metadataOnly = metadataOnly;
        if (hasSourceRun) info.sourceRun = int(run);
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
                // Advisory-only metadata must not resolve or reset any font property.
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
