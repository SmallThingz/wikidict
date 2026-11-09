#pragma once

#include "SemanticHtml.hpp"
#include "FlowConstruction.hpp"
#include "FigureSizing.hpp"
#include <QPalette>
#include <QPointer>
#include <QTextDocumentFragment>
#include <QScopeGuard>
#include <optional>

namespace SemanticFigure {
inline constexpr int ownerProperty = QTextFormat::UserProperty + 0x57a0;
inline constexpr int clearProperty = ownerProperty + 1;
inline constexpr int placementProperty = ownerProperty + 2;
inline constexpr int dataProperty = ownerProperty + 3;
inline constexpr int roleProperty = ownerProperty + 4;
inline constexpr int pointsProperty = ownerProperty + 5;
inline constexpr int listOwnerProperty = ownerProperty + 6; // Retained old-format reservation.
inline constexpr int sizingReadyProperty = ownerProperty + 7;
inline constexpr int helperOwnerProperty = ownerProperty + 8;
inline constexpr int placeholderSizeProperty = ownerProperty + 9;
inline constexpr int placeholderPixelsProperty = ownerProperty + 10;
// Physical CONTENT-box floor, logical px; absent and explicit zero are distinct.
inline constexpr int frameMinWidthProperty = ownerProperty + 11;
inline const QString frameMinWidthCapability = QStringLiteral("wikidict.figure-content-min-width/1");
inline const QString capability = QStringLiteral("wikidict.figure-layout/1");
inline const QString placeholderScheme = QStringLiteral("wikidict-figure");
struct Edges { qreal top, right, bottom, left; };
inline void require(bool value) {
    if (!value) throw std::runtime_error("invalid or unrepresentable compiled figure");
}
inline qreal metric(double value) {
    require(std::isfinite(value) && value >= 0 && value < 8388607.0);
    return qreal(value);
}
// normalBodyEm is supplied in actual document coordinates, never a child font or DPR.
inline qreal length(const QJsonValue &value, qreal normalBodyEm) {
    require(value.isObject());
    const auto object = value.toObject();
    const auto number = object.value(QStringLiteral("value"));
    const QString unit = object.value(QStringLiteral("unit")).toString();
    require(object.size() == 2 && number.isDouble() && std::isfinite(number.toDouble())
        && number.toDouble() >= 0 && number.toDouble() <= std::numeric_limits<float>::max()
        && (unit == QStringLiteral("px") || unit == QStringLiteral("em"))
        && std::isfinite(normalBodyEm) && normalBodyEm > 0);
    return metric(number.toDouble() * (unit == QStringLiteral("em") ? normalBodyEm : 1));
}
inline std::optional<qreal> frameMinWidth(const QJsonValue &value) {
    if (value.isUndefined() || value.isNull()) return std::nullopt;
    require(value.isObject());
    const auto object = value.toObject();
    const auto number = object.value(QStringLiteral("value"));
    // Initial contract is physical content-box px only, never em/% or a box shim.
    require(object.size() == 2 && object.value(QStringLiteral("unit")) == QStringLiteral("px")
        && number.isDouble() && std::isfinite(number.toDouble()) && number.toDouble() >= 0
        && number.toDouble() <= std::numeric_limits<float>::max());
    return metric(number.toDouble());
}
inline Edges edges(const QJsonValue &value, qreal em) {
    require(value.isObject() && value.toObject().size() == 4);
    const auto object = value.toObject();
    return {length(object.value("top"), em), length(object.value("right"), em),
        length(object.value("bottom"), em), length(object.value("left"), em)};
}
inline QColor color(const QJsonValue &value, const QPalette &palette, QPalette::ColorRole role) {
    require(value.isObject());
    const auto object = value.toObject();
    const QString kind = object.value("kind").toString();
    if (kind == "rgb") { require(object.size() == 2); return SemanticHtml::styleColor(object.value("value")); }
    require(object.size() == 1 && (kind == "native_theme" || kind == "transparent"));
    return kind == "transparent" ? QColor(Qt::transparent) : palette.color(role);
}
inline qreal borderWidth(const QJsonValue &value, qreal em) {
    require(value.isObject());
    const auto object = value.toObject();
    const QString kind = object.value("kind").toString();
    if (kind == "none") { require(object.size() == 1); return 0; }
    require(kind == "solid" && object.size() == 3);
    return length(object.value("width"), em);
}
inline void border(QTextFrameFormat &format, const QJsonValue &value, qreal em, const QPalette &palette) {
    format.setBorder(borderWidth(value, em));
    const auto object = value.toObject();
    format.setBorderStyle(object.value("kind").toString() == "none"
        ? QTextFrameFormat::BorderStyle_None : QTextFrameFormat::BorderStyle_Solid);
    if (object.value("kind").toString() == "solid")
        format.setBorderBrush(color(object.value("color"), palette, QPalette::Mid));
}
inline bool captionPresent(const QJsonObject &figure) {
    const auto blocks = figure.value(QStringLiteral("caption_blocks"));
    return SemanticHtml::present(blocks) ? !blocks.toArray().isEmpty()
        : !figure.value(QStringLiteral("caption")).toArray().isEmpty();
}
inline QJsonObject validate(const QJsonValue &value, qreal em, const QPalette &palette) {
    require(value.isObject());
    const auto object = value.toObject();
    const QStringList required{"image_span", "format", "sizing", "placement", "clear", "margins", "image_insets",
        "caption_padding", "caption_font_scale", "caption_line_height", "frame_background", "frame_border",
        "image_background", "image_border", "caption_foreground", "caption_background", "caption"};
    for (const auto &key : required) require(object.contains(key));
    for (auto it = object.begin(); it != object.end(); ++it)
        require(required.contains(it.key()) || it.key() == "caption_blocks" || it.key() == "caption_text_align" || it.key() == "frame_min_width");
    require(QStringList{"thumbnail", "framed"}.contains(object.value("format").toString())
        && QStringList{"none", "center", "float_left", "float_right"}.contains(object.value("placement").toString())
        && QStringList{"none", "left", "right", "both"}.contains(object.value("clear").toString()));
    const auto spanValue = object.value("image_span");
    require(spanValue.isObject());
    const auto span = spanValue.toObject();
    require(span.value("text").toString().isEmpty() && span.value("trail").toString().isEmpty()
        && span.value("kind").toString() != "line_break");
    SemanticHtml::checkedImage(span.value("image"));
    FigureSizing::request(object);
    frameMinWidth(object.value(QStringLiteral("frame_min_width")));
    require(object.value("caption").isArray());
    if (SemanticHtml::present(object.value("caption_blocks")))
        require(object.value("caption_blocks").isArray() && object.value("caption").toArray().isEmpty());
    SemanticHtml::textAlignment(object.value("caption_text_align"));
    for (const QString &key : {QStringLiteral("margins"), QStringLiteral("image_insets"), QStringLiteral("caption_padding")})
        edges(object.value(key), em);
    const auto scale = object.value("caption_font_scale");
    require(scale.isDouble() && std::isfinite(scale.toDouble()) && scale.toDouble() >= 0
        && scale.toDouble() <= std::numeric_limits<float>::max());
    metric(scale.toDouble() * em);
    length(object.value("caption_line_height"), em);
    for (const QString &key : {QStringLiteral("frame_background"), QStringLiteral("image_background"),
            QStringLiteral("caption_foreground"), QStringLiteral("caption_background")}) color(object.value(key), palette, QPalette::Base);
    for (const QString &key : {QStringLiteral("frame_border"), QStringLiteral("image_border")}) {
        QTextFrameFormat format; border(format, object.value(key), em, palette);
    }
    return object;
}
inline QString placeholder(const QJsonObject &figure, const QString &imageHtml, const QString &captionHtml,
                           bool present, qreal normalBodyEm, qreal captionPoints,
                           const QString &captionAlignment, const QPalette &palette) {
    validate(figure, normalBodyEm, palette);
    require(present == captionPresent(figure) && std::isfinite(captionPoints) && captionPoints >= 0);
    SemanticHtml::textAlignment(captionAlignment);
    const QString authored = SemanticHtml::textAlignment(figure.value("caption_text_align"));
    require(authored.isEmpty() || authored == captionAlignment);
    const QJsonObject metadata{{"figure", figure}, {"image_html", imageHtml}, {"caption_html", captionHtml},
        {"caption_present", present}, {"normal_body_em", normalBodyEm}, {"caption_points", captionPoints},
        {"caption_alignment", captionAlignment}};
    const auto payload = QJsonDocument(metadata).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    // The owning flow alone emits its role/prefix. This is one object, no paragraph.
    return QStringLiteral("<img src=\"%1:%2\">").arg(placeholderScheme, QString::fromLatin1(payload));
}
inline QJsonObject metadata(const QString &name) {
    const QUrl url(name);
    require(url.scheme() == placeholderScheme && url.host().isEmpty() && !url.hasQuery() && !url.hasFragment());
    const auto encoded = url.path().toLatin1();
    const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error;
    const auto decoded = QJsonDocument::fromJson(bytes, &error);
    require(error.error == QJsonParseError::NoError && decoded.isObject()
        && bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded);
    const auto result = decoded.object();
    require(result.size() == 7 && result.value("figure").isObject() && result.value("image_html").isString()
        && result.value("caption_html").isString() && result.value("caption_present").isBool()
        && result.value("normal_body_em").isDouble() && result.value("caption_points").isDouble()
        && result.value("caption_alignment").isString());
    return result;
}
inline void margins(QTextFrameFormat &format, Edges values) {
    format.setTopMargin(values.top); format.setRightMargin(values.right);
    format.setBottomMargin(values.bottom); format.setLeftMargin(values.left);
}
inline QTextFrameFormat ownedFormat(const QString &role, int owner = -1) {
    QTextFrameFormat format; format.setMargin(0); format.setPadding(0); format.setBorder(0);
    format.setProperty(ownerProperty, capability); format.setProperty(clearProperty, 0);
    format.setProperty(placementProperty, 0); format.setProperty(roleProperty, role);
    if (owner >= 0) format.setProperty(helperOwnerProperty, owner);
    return format;
}
inline bool belongs(QTextFrame *frame, const QString &role, int owner) {
    const auto format = frame->frameFormat();
    return format.stringProperty(ownerProperty) == capability && format.stringProperty(roleProperty) == role
        && format.hasProperty(helperOwnerProperty) && format.intProperty(helperOwnerProperty) == owner;
}
inline void hideGeneratedEmptyBlocks(QTextFrame *frame) {
    for (auto it = frame->begin(); !it.atEnd(); ++it) {
        auto block = it.currentBlock();
        if (block.isValid() && block.length() == 1) block.setVisible(false);
    }
}
inline QString cssColor(const QColor &value) {
    return QStringLiteral("rgba(%1,%2,%3,%4)").arg(value.red()).arg(value.green()).arg(value.blue()).arg(value.alphaF(), 0, 'g', 17);
}
// Copy one complete fragment. The first block needs explicit transfer even in a
// non-first cell; later blocks retain their imported formatting and source IDs.
inline void insertHtml(QTextCursor cursor, const QString &html, qreal points,
                       Qt::Alignment alignment, const QColor *ink = nullptr, qreal strut = -1) {
    const QPointer<QTextDocument> document(cursor.document());
    require(document && !cursor.hasSelection() && std::isfinite(points) && points >= -1);
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    const QPointer<QTextFrame> target(cursor.currentFrame());
    require(document && layout && target && document->documentLayout() == layout);
    QString expected = document->toRawText();
    const int insertionPosition = cursor.position();
    const auto current = [&] {
        return document && layout && target && document->documentLayout() == layout
            && target->document() == document && document->toRawText() == expected;
    };
    QTextDocument temporary;
    QFont font = document->defaultFont();
    if (points > 0) font.setPointSizeF(points);
    temporary.setDefaultFont(font); temporary.setDocumentMargin(0);
    auto option = document->defaultTextOption(); option.setAlignment(alignment);
    temporary.setDefaultTextOption(option);
    QString inherited;
    if (ink) inherited += QStringLiteral("color:%1;").arg(cssColor(*ink));
    if (points > 0) inherited += QStringLiteral("font-size:%1pt;").arg(points, 0, 'g', 17);
    QString body = points == 0 ? SemanticHtml::scaledText(html, 0, {}) : html;
    if (!inherited.isEmpty()) body = QStringLiteral("<body style=\"%1\">%2</body>").arg(inherited, body);
    // One ordinary import with the existing semantic normalizers. Retain the
    // original paragraph policies before zero-font normalization supplies its
    // usual surrounding-font strut: an inherited zero caption has its own strut.
    QHash<QString, SemanticHtml::ScaleInfo> markers;
    QVector<SemanticHtml::TableInfo> tables; int tableCount = 0;
    QHash<int, int> paragraphRuns;
    const QString prepared = SemanticHtml::prepare(SemanticHtml::prepareParagraphRuns(body, paragraphRuns), markers);
    temporary.setHtml(body.contains(SemanticHtml::tableMarkerOpen)
        ? SemanticHtml::prepareTables(prepared, tables, tableCount) : prepared);
    struct Paragraph { QTextCursor cursor; QTextBlockFormat format; QTextCharFormat character; };
    QVector<Paragraph> paragraphs;
    for (auto block = temporary.begin(); block.isValid(); block = block.next())
        paragraphs.append({QTextCursor(block), block.blockFormat(), block.charFormat()});
    require(SemanticHtml::normalizeParagraphRuns(&temporary, paragraphRuns));
    SemanticHtml::normalize(&temporary, markers);
    require(current());
    const auto *device = layout->paintDevice();
    const qreal scale = device ? qreal(device->logicalDpiY()) / QFontMetricsF(QFont()).fontDpi() : 1;
    require(std::isfinite(scale) && scale > 0);
    for (const auto &paragraph : paragraphs) {
        auto block = paragraph.cursor.block();
        auto format = block.blockFormat();
        if (!format.hasProperty(QTextFormat::BlockAlignment)) format.setAlignment(alignment);
        const bool explicitParentSize = paragraph.character.hasProperty(QTextFormat::FontPointSize)
            || paragraph.character.hasProperty(QTextFormat::FontPixelSize)
            || paragraph.character.hasProperty(QTextFormat::FontSizeAdjustment);
        if (strut >= 0 && points == 0 && !explicitParentSize
            && (paragraph.format.lineHeightType() == QTextBlockFormat::SingleHeight
                || paragraph.format.lineHeightType() == QTextBlockFormat::MinimumHeight)) {
            const qreal minimum = qMax(strut / scale, paragraph.format.lineHeightType() == QTextBlockFormat::MinimumHeight
                ? paragraph.format.lineHeight() : qreal(0));
            // Empty zero-context lines still own the explicit caption strut,
            // without a fallback document-font line or a synthetic character.
            format.setLineHeight(minimum, block.length() == 1 ? QTextBlockFormat::FixedHeight : QTextBlockFormat::MinimumHeight);
        } else if (strut >= 0 && !format.hasProperty(QTextFormat::LineHeight)) {
            format.setLineHeight(strut / scale, QTextBlockFormat::MinimumHeight);
        }
        QTextCursor edit(block); edit.setBlockFormat(format);
    }
    SemanticHtml::normalizeTables(&temporary, tables, tableCount);
    SemanticHtml::normalizeImages(&temporary);
    SemanticHtml::finishFloatingLayout(&temporary);
    const auto firstFormat = temporary.begin().blockFormat();
    const auto firstCharacter = temporary.begin().charFormat();
    require(current());
    expected.insert(insertionPosition, temporary.toRawText());
    QTextCursor first(cursor); first.setKeepPositionOnInsert(true);
    cursor.insertFragment(QTextDocumentFragment(&temporary));
    require(current() && first.document() == document && first.currentFrame() == target);
    // keepPositionOnInsert fixes position only; Qt advances the anchor across
    // the inserted fragment. Transfer the first block without selecting later
    // authored paragraphs, empty lines, cells or their character formats.
    first.clearSelection();
    first.setBlockFormat(firstFormat);
    require(current() && first.currentFrame() == target);
    first.setBlockCharFormat(firstCharacter);
    require(current() && first.currentFrame() == target);
}
inline bool applyAsset(QTextImageFormat &format, const QJsonObject &figure, const MediaPanel::InlineImageAsset &asset) {
    require(format.hasProperty(SemanticHtml::figureImageProperty)
        && QJsonDocument::fromJson(format.property(SemanticHtml::figureImageProperty).toByteArray()).object() == figure);
    const auto fallback = format.property(placeholderSizeProperty).toSizeF();
    require(std::isfinite(fallback.width()) && fallback.width() > 0
        && std::isfinite(fallback.height()) && fallback.height() >= 0);
    const auto resolved = FigureSizing::resolve(FigureSizing::request(figure), asset);
    const bool ready = resolved && std::isfinite(resolved->width()) && resolved->width() > 0 && resolved->width() < 8388607.0
        && std::isfinite(resolved->height()) && resolved->height() >= 0 && resolved->height() < 8388607.0;
    format.setProperty(sizingReadyProperty, ready);
    const auto size = ready ? *resolved : fallback;
    format.setWidth(size.width()); format.setHeight(size.height());
    if (ready) {
        format.setProperty(SemanticHtml::imageOriginalSizeProperty, asset.intrinsic);
        format.setProperty(SemanticHtml::imageLayoutSizeProperty, size);
    } else {
        format.clearProperty(SemanticHtml::imageOriginalSizeProperty);
        format.clearProperty(SemanticHtml::imageLayoutSizeProperty);
    }
    format.clearProperty(SemanticHtml::inlineImageBorderProperty);
    return ready;
}
inline void reflow(QTextDocument *document);
// Initial construction only, before registration. The caller recursively expands
// caption flows and registers the complete inventory after construction finishes.
inline QVector<QPointer<QTextFrame>> materialize(QTextDocument *document,
        QVector<FlowConstruction::Owner> &owners, const QPalette &palette) {
    const QPointer<QTextDocument> guard(document);
    require(guard && !document->isLayoutEnabled());
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    require(guard && layout && document->documentLayout() == layout);
    require(layout->property("_wikidictFigureLayoutCapability").toString() == capability
        && layout->metaObject()->indexOfMethod("wikidictFigureContentWidth(int)") >= 0);
    bool registered = false;
    require(QMetaObject::invokeMethod(layout, "wikidictHasLogicalFlows", Qt::DirectConnection, Q_RETURN_ARG(bool, registered)) && !registered);
    struct Pending { QTextCursor cursor; int owner, run; QJsonObject data; };
    QVector<Pending> pending;
    for (auto block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto span = it.fragment(); if (!span.isValid() || !span.charFormat().isImageFormat()) continue;
            const auto format = span.charFormat().toImageFormat();
            if (QUrl(format.name()).scheme() != placeholderScheme) continue;
            require(span.length() == 1 && format.property(FlowConstruction::sourceRunProperty).metaType().id() == QMetaType::Int);
            QTextCursor cursor(document); cursor.setPosition(span.position()); cursor.setPosition(span.position() + 1, QTextCursor::KeepAnchor);
            int ownerIndex = -1;
            for (int index = 0; index < owners.size(); ++index) {
                const auto &owner = owners[index];
                if (owner.first.document() == document && cursor.currentFrame() == owner.first.currentFrame()
                    && span.position() >= owner.prefixEnd.position() && span.position() < owner.last.position()) {
                    require(ownerIndex < 0); ownerIndex = index;
                }
            }
            // A nested caption flow has its own expansion pass and owner.
            if (ownerIndex < 0) continue;
            pending.append({cursor, ownerIndex, format.intProperty(FlowConstruction::sourceRunProperty), metadata(format.name())});
        }
    QVector<QPointer<QTextFrame>> created;
    for (auto &item : pending) {
        require(guard && layout && document->documentLayout() == layout);
        const auto meta = item.data;
        const qreal em = meta.value("normal_body_em").toDouble();
        const qreal points = meta.value("caption_points").toDouble();
        const auto figure = validate(meta.value("figure"), em, palette);
        require(meta.value("caption_present").toBool() == captionPresent(figure) && std::isfinite(points) && points >= 0);
        const auto alignmentName = SemanticHtml::textAlignment(meta.value("caption_alignment"));
        const auto authoredAlignment = SemanticHtml::textAlignment(figure.value("caption_text_align"));
        require(authoredAlignment.isEmpty() || authoredAlignment == alignmentName);
        const Qt::Alignment align = alignmentName == "right" ? Qt::AlignRight | Qt::AlignAbsolute
            : alignmentName == "center" ? Qt::AlignHCenter : Qt::AlignLeft | Qt::AlignAbsolute;
        auto outer = ownedFormat("figure"); margins(outer, edges(figure.value("margins"), em));
        if (const auto minimum = frameMinWidth(figure.value(QStringLiteral("frame_min_width")))) {
            require(layout->property("_wikidictFigureMinWidthCapability").toString() == frameMinWidthCapability);
            outer.setProperty(frameMinWidthProperty, *minimum);
        }
        border(outer, figure.value("frame_border"), em, palette);
        outer.setBackground(color(figure.value("frame_background"), palette, QPalette::AlternateBase));
        const int placement = QStringList{"none", "center", "float_left", "float_right"}.indexOf(figure.value("placement").toString());
        outer.setPosition(placement == 2 ? QTextFrameFormat::FloatLeft : placement == 3 ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
        outer.setProperty(placementProperty, placement);
        const int clear = QStringList{"none", "left", "right", "both"}.indexOf(figure.value("clear").toString());
        outer.setProperty(clearProperty, clear);
        outer.setProperty(dataProperty, QJsonDocument(meta).toJson(QJsonDocument::Compact)); outer.setProperty(pointsProperty, points);
        const auto frame = FlowConstruction::insertFigure(owners[item.owner], item.cursor, item.run, outer, [&](QTextFrame *rawFrame) {
            const QPointer<QTextFrame> frame(rawFrame);
            const int ownerIndex = frame->objectIndex();
            auto imageFormat = ownedFormat("image", ownerIndex); margins(imageFormat, edges(figure.value("image_insets"), em));
            border(imageFormat, figure.value("image_border"), em, palette);
            imageFormat.setBackground(color(figure.value("image_background"), palette, QPalette::Base));
            auto cursor = frame->firstCursorPosition();
            const QPointer<QTextFrame> imageFrame(cursor.insertFrame(imageFormat));
            require(guard && frame && imageFrame);
            insertHtml(imageFrame->firstCursorPosition(), meta.value("image_html").toString(), -1, Qt::AlignLeft | Qt::AlignAbsolute);
            require(guard && frame && imageFrame);
            QTextFragment image;
            for (auto it = imageFrame->begin(); !it.atEnd(); ++it) {
                const auto block = it.currentBlock(); if (!block.isValid()) continue;
                for (auto frag = block.begin(); !frag.atEnd(); ++frag) {
                    const auto candidate = frag.fragment();
                    require(candidate.isValid() && candidate.charFormat().isImageFormat() && candidate.length() == 1 && !image.isValid());
                    image = candidate;
                }
            }
            require(image.isValid() && imageFrame->childFrames().isEmpty());
            auto format = image.charFormat().toImageFormat();
            require(SemanticHtml::inlineImageData(QUrl(format.name())) == figure.value("image_span").toObject().value("image").toObject());
            format.setProperty(SemanticHtml::figureImageProperty, QJsonDocument(figure).toJson(QJsonDocument::Compact));
            format.setProperty(placeholderSizeProperty, QSizeF(metric(format.width()), metric(format.height())));
            require(format.width() > 0);
            format.setProperty(sizingReadyProperty, false);
            format.clearProperty(SemanticHtml::imageOriginalSizeProperty); format.clearProperty(SemanticHtml::imageLayoutSizeProperty);
            format.clearProperty(SemanticHtml::inlineImageBorderProperty); format.clearBackground();
            QTextCursor change(document); change.setPosition(image.position()); change.setPosition(image.position() + 1, QTextCursor::KeepAnchor); change.setCharFormat(format);
            const auto padding = edges(figure.value("caption_padding"), em);
            if (meta.value("caption_present").toBool() || padding.top || padding.right || padding.bottom || padding.left) {
                cursor.setPosition(imageFrame->lastPosition() + 1);
                auto captionFormat = ownedFormat("caption", ownerIndex);
                captionFormat.setBackground(color(figure.value("caption_background"), palette, QPalette::AlternateBase));
                const QPointer<QTextFrame> caption(cursor.insertFrame(captionFormat));
                require(guard && frame && caption);
                cursor = caption->firstCursorPosition();
                auto contentFormat = ownedFormat("caption-content", ownerIndex); margins(contentFormat, padding);
                const QPointer<QTextFrame> content(cursor.insertFrame(contentFormat));
                require(guard && frame && caption && content);
                if (meta.value("caption_present").toBool()) {
                    const auto ink = color(figure.value("caption_foreground"), palette, QPalette::Text);
                    insertHtml(content->firstCursorPosition(), meta.value("caption_html").toString(), points, align,
                        &ink, length(figure.value("caption_line_height"), em));
                    require(guard && frame && caption && content);
                } else hideGeneratedEmptyBlocks(content);
                hideGeneratedEmptyBlocks(caption);
            }
            hideGeneratedEmptyBlocks(frame);
        });
        require(guard && layout && frame && document->documentLayout() == layout);
        created.append(frame);
    }
    return created;
}
// Format edits only. The caller owns the editFormats batch and re-registration;
// this function never enables layout or starts a second registration lifecycle.
inline void reflow(QTextDocument *document) {
    const QPointer<QTextDocument> guard(document);
    require(guard && !document->isLayoutEnabled());
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    require(guard && layout && layout->property("_wikidictFigureLayoutCapability").toString() == capability);
    QVector<QPointer<QTextFrame>> frames;
    const auto collect = [&](auto &&visit, QTextFrame *parent) -> void {
        for (auto *child : parent->childFrames()) {
            if (child->frameFormat().stringProperty(ownerProperty) == capability
                && child->frameFormat().stringProperty(roleProperty) == "figure") frames.append(child);
            visit(visit, child);
        }
    };
    collect(collect, document->rootFrame());
    for (const auto &frame : frames) {
        require(guard && layout && frame && document->documentLayout() == layout);
        auto outer = frame->frameFormat();
        const auto meta = QJsonDocument::fromJson(outer.property(dataProperty).toByteArray()).object();
        const auto figure = meta.value("figure").toObject();
        const qreal em = meta.value("normal_body_em").toDouble();
        const auto outside = edges(figure.value("margins"), em), inset = edges(figure.value("image_insets"), em), padding = edges(figure.value("caption_padding"), em);
        const qreal outerBorder = borderWidth(figure.value("frame_border"), em), imageBorder = borderWidth(figure.value("image_border"), em);
        QPointer<QTextFrame> imageFrame, captionFrame, contentFrame;
        for (auto *child : frame->childFrames()) {
            if (belongs(child, "image", frame->objectIndex())) { require(!imageFrame); imageFrame = child; }
            if (belongs(child, "caption", frame->objectIndex())) { require(!captionFrame); captionFrame = child; }
        }
        require(imageFrame);
        if (captionFrame) for (auto *child : captionFrame->childFrames())
            if (belongs(child, "caption-content", frame->objectIndex())) { require(!contentFrame); contentFrame = child; }
        QTextFragment image;
        for (auto it = imageFrame->begin(); !it.atEnd(); ++it) {
            const auto block = it.currentBlock(); if (!block.isValid()) continue;
            for (auto fragment = block.begin(); !fragment.atEnd(); ++fragment)
                if (fragment.fragment().isValid() && fragment.fragment().charFormat().isImageFormat()) {
                    require(!image.isValid()); image = fragment.fragment();
                }
        }
        require(image.isValid());
        const int imagePosition = image.position();
        const auto format = image.charFormat().toImageFormat();
        const qreal width = metric(format.width()), height = metric(format.height()); require(width > 0);
        const qreal imageBox = metric(width + inset.left + inset.right + 2 * imageBorder);
        qreal contentWidth = qMax(imageBox, metric(padding.left + padding.right));
        if (const auto minimum = frameMinWidth(figure.value(QStringLiteral("frame_min_width")))) {
            require(layout->property("_wikidictFigureMinWidthCapability").toString() == frameMinWidthCapability);
            outer.setProperty(frameMinWidthProperty, *minimum);
            contentWidth = qMax(contentWidth, *minimum);
        } else outer.clearProperty(frameMinWidthProperty);
        outer.setWidth(QTextLength(QTextLength::FixedLength, metric(contentWidth + outside.left + outside.right + 2 * outerBorder)));
        if (outer != frame->frameFormat()) frame->setFrameFormat(outer);
        require(guard && layout && frame && imageFrame && document->documentLayout() == layout);
        // Only our three structural helpers follow the outer content width.
        // Authored rich-caption tables and nested figures retain their formats.
        for (const auto &helper : {imageFrame, captionFrame, contentFrame}) if (helper) {
            auto helperFormat = helper->frameFormat(); helperFormat.setWidth(QTextLength(QTextLength::PercentageLength, 100));
            if (helperFormat != helper->frameFormat()) helper->setFrameFormat(helperFormat);
            require(guard && layout && frame && imageFrame && document->documentLayout() == layout);
        }
        if (height == 0 && format.boolProperty(sizingReadyProperty)) {
            auto block = document->findBlock(imagePosition); auto blockFormat = block.blockFormat();
            blockFormat.setLineHeight(0, QTextBlockFormat::FixedHeight);
            QTextCursor change(block); change.setBlockFormat(blockFormat);
        } else {
            auto block = document->findBlock(imagePosition); auto blockFormat = block.blockFormat();
            if (blockFormat.lineHeightType() == QTextBlockFormat::FixedHeight && blockFormat.lineHeight() == 0) {
                blockFormat.clearProperty(QTextFormat::LineHeight); blockFormat.clearProperty(QTextFormat::LineHeightType);
                QTextCursor change(block); change.setBlockFormat(blockFormat);
            }
        }
    }
}
}
