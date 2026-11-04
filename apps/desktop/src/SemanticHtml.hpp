#pragma once

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QHash>
#include <QSet>
#include <QFontMetricsF>
#include <QJsonArray>
#include <QTextTable>
#include <QTextImageFormat>
#include <QUrl>
#include <QImage>
#include <limits>
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

// Table metadata belongs only to generated semantic HTML, never authored text.
inline const QString tableMarkerOpen = QStringLiteral("<!--wikidict-table-style:");
struct TableInfo { int ordinal; QJsonObject value; };
inline bool present(const QJsonValue &value) { return !value.isUndefined() && !value.isNull(); }
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
inline QString tableStyleMarker(const QJsonObject &table, qreal containerPoints, int indent) {
    bool styled = present(table.value(QStringLiteral("style")));
    if (!styled) {
        for (const QJsonValue &row : table.value(QStringLiteral("rows")).toArray())
            for (const QJsonValue &cell : row.toObject().value(QStringLiteral("cells")).toArray())
                styled = styled || present(cell.toObject().value(QStringLiteral("style")));
    }
    if (!styled) return {};
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
    if (!styled) return {};
    QJsonObject metadata{{"container_points", containerPoints}, {"indent", indent}, {"rows", rows}};
    if (present(table.value(QStringLiteral("style")))) metadata.insert(QStringLiteral("style"), table.value(QStringLiteral("style")));
    return tableMarkerOpen + QString::fromLatin1(QJsonDocument(metadata).toJson(QJsonDocument::Compact).toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)) + QStringLiteral("-->");
}
inline QString prepareTables(const QString &html, QVector<TableInfo> &tables, int &tableCount) {
    QString out; out.reserve(html.size()); tableCount = 0;
    QVector<bool> materialized; QVector<int> stack;
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
        if (tag(i, QStringLiteral("<table"))) { stack.append(int(materialized.size())); materialized.append(false); }
        else if (tag(i, QStringLiteral("<td")) || tag(i, QStringLiteral("<th"))) {
            if (stack.isEmpty()) throw std::runtime_error("table style cell outside table");
            materialized[stack.last()] = true;
        } else if (tag(i, QStringLiteral("</table"))) {
            if (stack.isEmpty()) throw std::runtime_error("unbalanced table style HTML");
            stack.removeLast();
        }
        out += html[i++];
    }
    if (!stack.isEmpty()) throw std::runtime_error("unbalanced table style HTML");
    QVector<int> ordinals;
    for (const bool exists : materialized) ordinals.append(exists ? tableCount++ : -1);
    for (TableInfo &table : tables) {
        if (table.ordinal >= ordinals.size()) throw std::runtime_error("unmatched table style metadata");
        table.ordinal = ordinals[table.ordinal];
    }
    return out;
}
inline void normalizeTables(QTextDocument *document, const QVector<TableInfo> &records, int expectedTables) {
    if (records.isEmpty()) return;
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
        QTextTableFormat format = table ? table->format() : QTextTableFormat();
        const QJsonObject style = typedStyle(record.value.value(QStringLiteral("style")), {"background", "border", "collapse", "margins"});
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
        if (!table) {
            // Qt6.12 scanTable omits frames for zero-row/zero-column tables.
            // Preserve their caption/text/actions and source fields; there is no
            // table box to style. Do not invent a cell or shift later ordinals.
            for (const QJsonValue &row : rows)
                if (!row.isArray() || !row.toArray().isEmpty()) throw std::runtime_error("unexpected nonempty elided table");
            continue;
        }
        table->setFormat(format);
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
                    continue;
                }
                const QJsonObject expected = cells[index++].toObject();
                if (expected.value(QStringLiteral("rowspan")).toInt() != cell.rowSpan() || expected.value(QStringLiteral("colspan")).toInt() != cell.columnSpan()) throw std::runtime_error("table style span mismatch");
                const QJsonObject cellStyle = typedStyle(expected.value(QStringLiteral("style")), {"border", "padding", "text_align"});
                if (cellStyle.isEmpty()) continue;
                QTextTableCellFormat cellFormat = cell.format().toTableCellFormat();
                if (present(cellStyle.value(QStringLiteral("border")))) { const Border b = border(cellStyle.value(QStringLiteral("border"))); cellFormat.setBorder(b.width); cellFormat.setBorderStyle(b.style); cellFormat.setBorderBrush(b.color); }
                if (present(cellStyle.value(QStringLiteral("padding")))) { const auto e = edges(cellStyle.value(QStringLiteral("padding"))); cellFormat.setTopPadding(e[0]); cellFormat.setRightPadding(e[1]); cellFormat.setBottomPadding(e[2]); cellFormat.setLeftPadding(e[3]); }
                cell.setFormat(cellFormat);
                if (present(cellStyle.value(QStringLiteral("text_align")))) {
                    const QString alignment = cellStyle.value(QStringLiteral("text_align")).toString();
                    if (alignment != QStringLiteral("left") && alignment != QStringLiteral("center") && alignment != QStringLiteral("right")) throw std::runtime_error("invalid cell alignment");
                    const Qt::Alignment align = alignment == QStringLiteral("center") ? Qt::AlignHCenter : alignment == QStringLiteral("right") ? Qt::AlignRight : Qt::AlignLeft;
                    for (QTextBlock block = cell.firstCursorPosition().block(); block.isValid() && block.position() <= cell.lastCursorPosition().position(); block = block.next()) {
                        QTextCursor cursor(block);
                        if (cursor.currentTable() != table) continue;
                        QTextBlockFormat blockFormat = block.blockFormat(); blockFormat.setAlignment(align); cursor.setBlockFormat(blockFormat);
                    }
                }
            }
            if (index != cells.size()) throw std::runtime_error("table style cell count mismatch");
        }
    }
}

inline const QString inlineImageScheme = QStringLiteral("wikidict-inline-image");
inline constexpr int inlineImageStateProperty = QTextFormat::UserProperty + 0x5744;
inline constexpr int inlineImageStatusProperty = inlineImageStateProperty + 1;
inline constexpr int inlineImageExplanationProperty = inlineImageStateProperty + 2;
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
            && it.key() != QStringLiteral("alt") && it.key() != QStringLiteral("tooltip")) throw std::runtime_error("unknown inline image field");
    for (const QString &key : {QStringLiteral("width_px"), QStringLiteral("height_px")}) {
        const QJsonValue axis = image.value(key); if (!present(axis)) continue;
        const double n = axis.toDouble(-1);
        if (!axis.isDouble() || !std::isfinite(n) || n <= 0 || n > 4294967295.0 || std::floor(n) != n)
            throw std::runtime_error("invalid inline image dimension");
    }
    for (const QString &key : {QStringLiteral("alt"), QStringLiteral("tooltip")})
        if (present(image.value(key)) && !image.value(key).isString()) throw std::runtime_error("invalid inline image text");
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
inline void imageDimensions(QTextImageFormat &format, const QJsonObject &image, const QTextDocument *document, const QSizeF &intrinsic = {}) {
    const qreal maximum = maximumFontPoints(document) * QFontMetricsF(QFont()).fontDpi() / 72;
    const bool hasWidth = present(image.value(QStringLiteral("width_px"))), hasHeight = present(image.value(QStringLiteral("height_px")));
    const qreal width = hasWidth ? image.value(QStringLiteral("width_px")).toDouble() : (intrinsic.isValid() ? intrinsic.width() : 1);
    const qreal height = hasHeight ? image.value(QStringLiteral("height_px")).toDouble() : (intrinsic.isValid() ? intrinsic.height() : 1);
    qreal w = qMin(maximum, width), h = qMin(maximum, height);
    if (intrinsic.isValid()) {
        const auto fitBoxWidth = [&](qreal boundHeight) {
            const qreal ideal = intrinsic.width() * boundHeight / intrinsic.height();
            const qreal up = std::ceil(ideal);
            return qMax(1.0, std::round(up * intrinsic.height() / intrinsic.width()) > boundHeight ? std::floor(ideal) : up);
        };
        qreal displayWidth = width, displayHeight = height;
        if (!hasHeight || width * intrinsic.height() <= height * intrinsic.width())
            displayHeight = qMax(1.0, std::round(intrinsic.height() * width / intrinsic.width()));
        else if (hasHeight) displayWidth = fitBoxWidth(height);
        // Bound both authored axes before display, retaining MediaWiki's integer
        // client sizing rather than imposing a fractional generic contain-fit.
        const qreal factor = qMin(1.0, qMin(maximum / displayWidth, maximum / displayHeight));
        w = displayWidth * factor; h = displayHeight * factor;
    } else if (hasWidth && !hasHeight) h = w;
    else if (hasHeight && !hasWidth) w = h;
    format.setWidth(w); format.setHeight(h);
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
            format.setProperty(inlineImageExplanationProperty, format.toolTip());
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
    for (const ImageEdit &edit : edits) { QTextCursor cursor(document); cursor.setPosition(edit.position); cursor.setPosition(edit.position + 1, QTextCursor::KeepAnchor); cursor.setCharFormat(edit.format); }
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
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(inlineImageScheme + QChar(':'))) { document->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    const QString fontHtml = prepare(html, markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    document->setHtml(prepared);
    normalize(document, markers);
    normalizeTables(document, tables, tableCount);
    normalizeImages(document);
}

inline void setHtml(QTextBrowser *browser, const QString &html) {
    if (!html.contains(markerOpen) && !html.contains(tableMarkerOpen) && !html.contains(inlineImageScheme + QChar(':'))) { browser->setHtml(html); return; }
    QHash<QString, ScaleInfo> markers;
    QVector<TableInfo> tables; int tableCount = 0;
    const QString fontHtml = prepare(html, markers);
    const QString prepared = html.contains(tableMarkerOpen) ? prepareTables(fontHtml, tables, tableCount) : fontHtml;
    browser->setHtml(prepared);
    normalize(browser->document(), markers);
    normalizeTables(browser->document(), tables, tableCount);
    normalizeImages(browser->document());
}
} // namespace SemanticHtml
