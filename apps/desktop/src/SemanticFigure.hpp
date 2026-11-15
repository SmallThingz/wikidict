#pragma once

#include "SemanticHtml.hpp"
#include "FlowConstruction.hpp"
#include "FigureSizing.hpp"
#include "MissingFigurePaint.hpp"
#include <QPalette>
#include <QPointer>
#include <QTextDocumentFragment>
#include <QTextTable>
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
inline constexpr int missingWrapProperty = ownerProperty + 12;
inline const QString missingWrapCapability = QStringLiteral("wikidict.figure-missing-word-wrap/1");
inline bool missing(const QJsonObject &figure) { return figure.contains(QStringLiteral("missing_content")); }
inline QJsonObject contentSpan(const QJsonObject &figure) {
    return CompiledContent::figureSpan(figure);
}
inline QJsonObject missingContent(const QJsonObject &figure, qreal em) {
    require(missing(figure) && !figure.contains(QStringLiteral("image_span")) && !figure.contains(QStringLiteral("sizing")));
    const auto value = figure.value(QStringLiteral("missing_content")); require(value.isObject());
    const auto object = value.toObject();
    for (auto it = object.begin(); it != object.end(); ++it)
        require(QStringList{"label", "width", "line_height", "link_paint"}.contains(it.key()));
    require(object.contains("label") && object.contains("width") && object.contains("line_height"));
    require(length(object.value("width"), em) > 0 && length(object.value("line_height"), em) > 0);
    const auto label = CompiledContent::object(object.value("label"));
    const QString kind = label.value("kind").toString(), target = label.value("target").toString();
    require(label.value("text").isString() && !label.value("text").toString().isEmpty()
        && label.value("trail").toString().isEmpty() && !SemanticHtml::present(label.value("image"))
        && ((kind == "text" && target.isEmpty()) || ((kind == "link" || kind == "external_link") && !target.isEmpty())));
    const auto classes = SemanticHtml::inlineTableClasses(label.value("classes").toString());
    require(!classes.contains(QStringLiteral("wikidict-media")));
    if (SemanticHtml::present(object.value("link_paint")))
        require(object.value("link_paint").isString() && object.value("link_paint").toString() == MissingFigurePaint::policy
            && (kind == "link" || kind == "external_link") && !SemanticHtml::present(label.value("foreground"))
            && !SemanticHtml::present(label.value("link_paint")));
    return object;
}
inline QString missingLabelText(QString text) {
    text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
    text.replace(QChar('\r'), QChar('\n'));
    text.replace(QChar::LineSeparator, QChar('\n'));
    text.replace(QChar::ParagraphSeparator, QChar('\n'));
    return text;
}
inline QString missingLabelHref(const QJsonObject &label) {
    const QString target = label.value("target").toString();
    if (label.value("kind") == QStringLiteral("link")) {
        QString href = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target));
        if (SemanticHtml::present(label.value("target_fragment")))
            href += QChar('#') + QString::fromLatin1(QUrl::toPercentEncoding(label.value("target_fragment").toString()));
        return href;
    }
    QUrl url(target);
    if (target.startsWith(QStringLiteral("//")) && url.scheme().isEmpty()) url.setScheme(QStringLiteral("https"));
    return url.isValid() && !url.host().isEmpty() && (url.scheme() == "http" || url.scheme() == "https")
        ? url.toString(QUrl::FullyEncoded) : QString();
}
inline bool missingLabelFragments(QTextFrame *frame, const QJsonObject &label) {
    if (!frame || !frame->childFrames().isEmpty()) return false;
    const auto direction = label.value("direction").toString();
    const ushort opening = direction == "ltr" ? 0x2066 : direction == "rtl" ? 0x2067 : direction == "auto" ? 0x2068 : 0;
    const QString prefix = opening ? QString(QChar(opening)) : QString();
    const QString suffix = opening ? QString(QChar(0x2069)) : QString();
    QTextCursor source(frame->document()); source.setPosition(frame->firstPosition());
    source.setPosition(frame->lastPosition(), QTextCursor::KeepAnchor);
    if (missingLabelText(source.selectedText()) != prefix + missingLabelText(label.value("text").toString()) + suffix) return false;
    const QString href = missingLabelHref(label);
    if (href.isEmpty()) return false;
    int anchors = 0, controls = 0;
    for (auto it = frame->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock(); if (!block.isValid()) return false;
        for (auto part = block.begin(); !part.atEnd(); ++part) {
            const auto fragment = part.fragment(); if (!fragment.isValid() || fragment.charFormat().isImageFormat()) return false;
            const auto format = fragment.charFormat();
            if (format.isAnchor()) {
                if (format.anchorHref() != href || fragment.position() < frame->firstPosition() + prefix.size()
                    || fragment.position() + fragment.length() > frame->lastPosition() - suffix.size()) return false;
                ++anchors;
            } else {
                const bool first = opening && fragment.position() == frame->firstPosition() && fragment.text() == prefix;
                const bool last = opening && fragment.position() == frame->lastPosition() - 1 && fragment.text() == suffix;
                if (!first && !last) return false;
                ++controls;
            }
        }
    }
    return anchors > 0 && controls == (opening ? 2 : 0);
}
inline void markMissingLabel(QTextFrame *frame, int owner, const QJsonObject &content,
                             qreal normalBodyEm, const QPalette &palette, const QJsonObject &fixedPaint = {}) {
    const QPointer<QTextFrame> guard(frame);
    const QPointer<QTextDocument> document(frame ? frame->document() : nullptr);
    const QPointer<QAbstractTextDocumentLayout> layout(document ? document->documentLayout() : nullptr);
    require(guard && document && layout && frame->childFrames().isEmpty() && !document->isLayoutEnabled());
    const QString source = document->toRawText();
    const int count = document->characterCount();
    const auto current = [&] { return guard && document && layout && guard->document() == document
        && document->documentLayout() == layout && !document->isLayoutEnabled()
        && document->characterCount() == count && document->toRawText() == source; };
    const auto *device = layout->paintDevice();
    const qreal scaling = device ? qreal(device->logicalDpiY()) / QFontMetricsF(QFont()).fontDpi() : 1;
    require(std::isfinite(scaling) && scaling > 0);
    const qreal lineHeight = length(content.value("line_height"), normalBodyEm) / scaling;
    require(std::isfinite(lineHeight) && lineHeight > 0 && lineHeight < 1e6);
    const auto label = content.value("label").toObject();
    const bool fixed = !fixedPaint.isEmpty();
    const bool paint = fixed || SemanticHtml::present(content.value("link_paint"));
    if (paint) require(missingLabelFragments(frame, label));
    auto frameFormat = frame->frameFormat();
    if (paint && !fixed) {
        frameFormat.setProperty(MissingFigurePaint::policyProperty, MissingFigurePaint::policy);
        frameFormat.setProperty(MissingFigurePaint::ownerProperty, owner);
        frame->setFrameFormat(frameFormat);
        require(current());
    }
    struct Character { int start, end; QTextCharFormat format; };
    struct Block { int position; QTextBlockFormat format; };
    QVector<Character> characters;
    QVector<Block> blocks;
    for (auto it = frame->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock(); require(block.isValid());
        auto format = block.blockFormat();
        format.setProperty(missingWrapProperty, missingWrapCapability);
        // Reuse the paired native computed-length/half-leading mechanism. The
        // explicit Missing length is resolved at normal-body origin, not 94% twice.
        format.setProperty(SemanticHtml::tableLineHeightProperty, lineHeight);
        format.setAlignment(Qt::AlignHCenter);
        format.setTopMargin(0); format.setBottomMargin(0);
        blocks.append({block.position(), format});
        for (auto span = block.begin(); !span.atEnd(); ++span) {
            const auto fragment = span.fragment(); require(fragment.isValid() && !fragment.charFormat().isImageFormat());
            if (!paint) continue;
            auto character = fragment.charFormat();
            // The complete source/action/boundary inventory was validated above;
            // generated isolation controls remain outside the actual link paint.
            if (!character.isAnchor()) continue;
            const bool zero = character.fontFamilies().toStringList().contains(SemanticHtml::zeroFontFamilyName);
            if (fixed) {
                require(character.stringProperty(MissingFigurePaint::policyProperty) == MissingFigurePaint::fixedPolicy
                    && QJsonObject::fromVariantMap(character.property(MissingFigurePaint::fixedPolicyProperty).toMap()) == fixedPaint);
                character.setProperty(MissingFigurePaint::atomicProperty, true);
                frameFormat.setProperty(MissingFigurePaint::policyProperty, MissingFigurePaint::fixedPolicy);
                frameFormat.setProperty(MissingFigurePaint::ownerProperty, character.property(MissingFigurePaint::ownerProperty));
                frameFormat.setProperty(MissingFigurePaint::outlineProperty, character.property(MissingFigurePaint::outlineProperty));
                frameFormat.setProperty(MissingFigurePaint::fixedPolicyProperty, fixedPaint.toVariantMap());
                character.setForeground(zero ? QColor(Qt::transparent) : QColor(fixedPaint.value("normal").toObject().value("foreground").toString()));
                character.setUnderlineStyle(!zero && (label.value("underline").toBool() || fixedPaint.value("normal").toObject().value("underline").toBool())
                    ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
                characters.append({fragment.position(), fragment.position() + fragment.length(), character});
                continue;
            }
            character.setProperty(MissingFigurePaint::policyProperty, MissingFigurePaint::policy);
            character.setProperty(MissingFigurePaint::ownerProperty, owner);
            character.setProperty(MissingFigurePaint::underlineProperty, label.value("underline").toBool());
            character.setProperty(MissingFigurePaint::zeroFontProperty, zero);
            character.setForeground(zero ? QColor(Qt::transparent)
                : MissingFigurePaint::foreground(palette.color(QPalette::Base).lightness() < 128, false, MissingFigurePaint::Interaction::Rest));
            character.setUnderlineStyle(!zero && label.value("underline").toBool()
                ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
            characters.append({fragment.position(), fragment.position() + fragment.length(), character});
        }
    }
    if (fixed) { frame->setFrameFormat(frameFormat); require(current()); }
    for (const auto &block : blocks) {
        require(current());
        QTextCursor change(document); change.setPosition(block.position); change.setBlockFormat(block.format);
        require(current());
    }
    for (const auto &character : characters) {
        require(current());
        QTextCursor change(document); change.setPosition(character.start); change.setPosition(character.end, QTextCursor::KeepAnchor);
        change.setCharFormat(character.format);
        require(current());
    }
}

// API03: these are source-resolved values, not a second CSS evaluator.
inline constexpr int tableCaptionProperty = ownerProperty + 14;
inline const QString tableCaptionCapability = QStringLiteral("wikidict.figure-table-caption/4");
struct TableCaptionInput {
    QVariantList tableBorders;
    QVariantList captionBorders;
    std::optional<qreal> mediaLimitSubtract;
    QJsonObject media;
    QJsonObject wrapper;
    std::optional<QJsonObject> before;
    bool viewportState = false;
};
inline QJsonObject captionWrapperStyle(const QJsonValue &value, qreal em) {
    const auto style = CompiledContent::containerStyle(value);
    for (auto it = style.begin(); it != style.end(); ++it)
        require(!CompiledContent::present(it.value()) || QStringList{
            QStringLiteral("margins"), QStringLiteral("margin_values"),
            QStringLiteral("float_side"), QStringLiteral("clear")}.contains(it.key()));
    if (CompiledContent::present(style.value(QStringLiteral("margins"))))
        edges(style.value(QStringLiteral("margins")), em);
    if (CompiledContent::present(style.value(QStringLiteral("margin_values")))) {
        const auto values = style.value(QStringLiteral("margin_values")).toObject();
        for (const auto &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")}) {
            const auto tagged = values.value(side).toObject();
            if (tagged.contains(QStringLiteral("auto")))
                require(side == QStringLiteral("left") || side == QStringLiteral("right"));
            else length(tagged.value(QStringLiteral("length")), em);
        }
    }
    return style;
}
inline std::optional<QJsonObject> captionBeforeStyle(const QJsonValue &value, qreal em) {
    if (!CompiledContent::present(value)) return std::nullopt;
    const auto style = CompiledContent::containerStyle(value);
    for (auto it = style.begin(); it != style.end(); ++it)
        require(!CompiledContent::present(it.value()) || QStringList{
            QStringLiteral("width"), QStringLiteral("height"), QStringLiteral("float_side"),
            QStringLiteral("margins"), QStringLiteral("layout"), QStringLiteral("box_sizing"),
            QStringLiteral("background"), QStringLiteral("border")}.contains(it.key()));
    const auto width = style.value(QStringLiteral("width")).toObject();
    require(width.size() == 1 && width.contains(QStringLiteral("length")));
    length(width.value(QStringLiteral("length")), em);
    length(style.value(QStringLiteral("height")), em);
    require(style.value(QStringLiteral("float_side")) == QStringLiteral("left")
        || style.value(QStringLiteral("float_side")) == QStringLiteral("right"));
    if (CompiledContent::present(style.value(QStringLiteral("margins"))))
        edges(style.value(QStringLiteral("margins")), em);
    require(!CompiledContent::present(style.value(QStringLiteral("layout")))
        || style.value(QStringLiteral("layout")) == QStringLiteral("flow"));
    require(!CompiledContent::present(style.value(QStringLiteral("box_sizing")))
        || style.value(QStringLiteral("box_sizing")) == QStringLiteral("content_box"));
    if (CompiledContent::present(style.value(QStringLiteral("background"))))
        require(CompiledContent::containerUnion(style.value(QStringLiteral("background")),
            {QStringLiteral("transparent")}) == QStringLiteral("transparent"));
    if (CompiledContent::present(style.value(QStringLiteral("border"))))
        require(CompiledContent::containerUnion(style.value(QStringLiteral("border")),
            {QStringLiteral("none")}) == QStringLiteral("none"));
    return style;
}
inline QVariantList captionPhysicalBorders(const QJsonValue &value, qreal em, const QPalette &palette) {
    const QStringList sides{QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
    const auto physical = CompiledContent::containerObject(value, sides, sides);
    QVariantList result;
    for (const auto &side : sides) {
        const auto edge = physical.value(side).toObject();
        require(physical.value(side).isObject() && edge.size() == 1);
        const QString kind = edge.keys().first();
        const int mode = QStringList{QStringLiteral("none"), QStringLiteral("hidden"),
            QStringLiteral("solid"), QStringLiteral("dotted")}.indexOf(kind);
        const auto payload = edge.value(kind);
        require(mode >= 0 && payload.isObject() && payload.toObject().size() == (mode < 2 ? 0 : 2));
        qreal width = 0; QColor ink(Qt::transparent);
        if (mode >= 2) {
            const auto line = CompiledContent::containerObject(payload,
                {QStringLiteral("width"), QStringLiteral("color")},
                {QStringLiteral("width"), QStringLiteral("color")});
            width = length(line.value(QStringLiteral("width")), em);
            ink = color(line.value(QStringLiteral("color")), palette, QPalette::Mid);
        }
        result.append(QVariantMap{{QStringLiteral("style"), mode},
            {QStringLiteral("width"), width}, {QStringLiteral("color"), ink}});
    }
    return result;
}
inline qreal captionSignedLength(const QJsonValue &value, qreal em) {
    const auto spec = CompiledContent::containerObject(value,
        {QStringLiteral("unit"), QStringLiteral("value")}, {QStringLiteral("unit"), QStringLiteral("value")});
    require(spec.value(QStringLiteral("value")).isDouble());
    const qreal n = spec.value(QStringLiteral("value")).toDouble();
    const auto unit = spec.value(QStringLiteral("unit")).toString();
    require((unit == QStringLiteral("px") || unit == QStringLiteral("em")) && std::isfinite(n));
    const qreal result = n * (unit == QStringLiteral("em") ? em : 1);
    require(std::isfinite(result) && qAbs(result) < 8388607.0);
    return result;
}
inline QJsonObject captionMedia(const QJsonValue &value, const QJsonObject &figure, qreal em, const QPalette &palette) {
    const auto media = CompiledContent::containerObject(value,
        {QStringLiteral("strut"), QStringLiteral("vertical_align"), QStringLiteral("max_width"), QStringLiteral("positioning"),
         QStringLiteral("after"), QStringLiteral("focus_outline")}, {QStringLiteral("strut"), QStringLiteral("vertical_align")});
    const auto strut = CompiledContent::containerObject(media.value(QStringLiteral("strut")),
        {QStringLiteral("font_scale"), QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code"),
         QStringLiteral("language"), QStringLiteral("direction"), QStringLiteral("font_features")}, {QStringLiteral("font_scale"), QStringLiteral("direction")});
    SemanticHtml::fontFeaturePolicy(strut.value(QStringLiteral("font_features")));
    require(strut.value(QStringLiteral("font_scale")).isDouble());
    const qreal scale = strut.value(QStringLiteral("font_scale")).toDouble();
    require(std::isfinite(scale) && scale >= 0 && std::isfinite(scale * em) && scale * em < 8388607.0);
    for (const auto &key : {QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code")})
        require(!strut.contains(key) || strut.value(key).isBool());
    require(!strut.contains(QStringLiteral("language")) || strut.value(QStringLiteral("language")).isString());
    const QString language = strut.value(QStringLiteral("language")).toString();
    const auto bytes = language.toUtf8();
    require(bytes.size() <= 32 * 1024 * 1024 && QString::fromUtf8(bytes) == language);
    require(strut.value(QStringLiteral("direction")) == QStringLiteral("ltr") || strut.value(QStringLiteral("direction")) == QStringLiteral("rtl"));
    const bool missingMedia = CompiledContent::present(figure.value(QStringLiteral("missing_content")));
    require(media.value(QStringLiteral("vertical_align")) == (missingMedia ? QStringLiteral("baseline") : QStringLiteral("middle")));
    const auto span = figure.value(QStringLiteral("image_span")).toObject();
    const auto image = span.value(QStringLiteral("image")).toObject();
    require(!CompiledContent::present(image.value(QStringLiteral("map"))));
    const bool action = (span.value(QStringLiteral("kind")) == QStringLiteral("link")
        || span.value(QStringLiteral("kind")) == QStringLiteral("external_link"))
        && span.value(QStringLiteral("target")).isString() && !span.value(QStringLiteral("target")).toString().isEmpty();
    const bool positioned = CompiledContent::present(media.value(QStringLiteral("positioning")));
    if (positioned) require(!missingMedia && media.value(QStringLiteral("positioning")) == QStringLiteral("relative_auto"));
    if (CompiledContent::present(media.value(QStringLiteral("max_width")))) {
        require(!missingMedia);
        const auto cap = CompiledContent::containerObject(media.value(QStringLiteral("max_width")),
            {QStringLiteral("percent"), QStringLiteral("subtract")}, {QStringLiteral("percent"), QStringLiteral("subtract")});
        require(cap.value(QStringLiteral("percent")).isDouble() && cap.value(QStringLiteral("percent")).toDouble() == 100);
        length(cap.value(QStringLiteral("subtract")), em);
    }
    if (CompiledContent::present(media.value(QStringLiteral("after")))) {
        require(!missingMedia && positioned && action);
        const auto after = CompiledContent::containerObject(media.value(QStringLiteral("after")),
            {QStringLiteral("width"), QStringLiteral("height"), QStringLiteral("side"), QStringLiteral("inset"),
             QStringLiteral("bottom"), QStringLiteral("paint")},
            {QStringLiteral("width"), QStringLiteral("height"), QStringLiteral("side"), QStringLiteral("inset"), QStringLiteral("bottom")});
        const auto fixed = [&](const char *key, qreal expected) {
            const auto n = after.value(QLatin1StringView(key));
            require(n.isObject() && n.toObject().value(QStringLiteral("unit")) == QStringLiteral("px"));
            require(captionSignedLength(n, em) == expected);
        };
        fixed("width", 15); fixed("height", 11); fixed("inset", 6); fixed("bottom", -11);
        require(after.value(QStringLiteral("side")) == QStringLiteral("left") || after.value(QStringLiteral("side")) == QStringLiteral("right"));
        if (CompiledContent::present(after.value(QStringLiteral("paint")))) {
            const auto paint = CompiledContent::containerObject(after.value(QStringLiteral("paint")),
                {QStringLiteral("graphic"), QStringLiteral("invert")}, {QStringLiteral("graphic")});
            require(paint.value(QStringLiteral("graphic")) == QStringLiteral("magnify_clip_ltr_v1")
                || paint.value(QStringLiteral("graphic")) == QStringLiteral("magnify_clip_rtl_v1"));
            require(!paint.contains(QStringLiteral("invert")) || paint.value(QStringLiteral("invert")).isBool());
        }
    }
    if (CompiledContent::present(media.value(QStringLiteral("focus_outline")))) {
        require(!CompiledContent::present(span.value(QStringLiteral("link_paint"))));
        require(!missingMedia && action);
        const auto focus = CompiledContent::containerObject(media.value(QStringLiteral("focus_outline")),
            {QStringLiteral("width"), QStringLiteral("color"), QStringLiteral("radius"), QStringLiteral("offset")},
            {QStringLiteral("width"), QStringLiteral("color"), QStringLiteral("radius"), QStringLiteral("offset")});
        length(focus.value(QStringLiteral("width")), em); length(focus.value(QStringLiteral("radius")), em);
        captionSignedLength(focus.value(QStringLiteral("offset")), em);
        color(focus.value(QStringLiteral("color")), palette, QPalette::Text);
    }
    return media;
}
inline std::optional<TableCaptionInput> tableCaptionInput(const QJsonObject &figure,
                                                        qreal em, const QPalette &palette,
                                                        qreal rootViewportCssPixels) {
    const auto value = figure.value(QStringLiteral("table_caption_layout"));
    if (!CompiledContent::present(value)) return std::nullopt;
    require(std::isfinite(rootViewportCssPixels) && rootViewportCssPixels >= 0);
    const auto layout = CompiledContent::containerObject(value,
        {QStringLiteral("collapse"), QStringLiteral("table_border"), QStringLiteral("caption_border"),
         QStringLiteral("media"), QStringLiteral("caption_before"), QStringLiteral("viewport_states"), QStringLiteral("wrapper"), QStringLiteral("missing_link_paint"), QStringLiteral("caption_link_paint")},
        {QStringLiteral("collapse"), QStringLiteral("table_border"), QStringLiteral("caption_border"), QStringLiteral("media"), QStringLiteral("wrapper")});
    require(layout.value(QStringLiteral("collapse")) == QStringLiteral("collapse"));
    require(figure.value(QStringLiteral("frame_border")).isObject()
        && figure.value(QStringLiteral("frame_border")).toObject().size() == 1
        && figure.value(QStringLiteral("frame_border")).toObject().value(QStringLiteral("kind")) == QStringLiteral("none"));
    const auto image = figure.value(QStringLiteral("image_span")).toObject().value(QStringLiteral("image")).toObject();
    require(!CompiledContent::present(image.value(QStringLiteral("static_poster"))));
    const auto missingPaint = MissingFigurePaint::validate(layout.value("missing_link_paint"), em);
    MissingFigurePaint::validate(layout.value("caption_link_paint"), em);
    if (!missingPaint.isEmpty()) {
        require(missing(figure) && !SemanticHtml::present(figure.value("missing_content").toObject().value("link_paint")));
        const auto label = figure.value("missing_content").toObject().value("label").toObject();
        require((label.value("kind") == "link" || label.value("kind") == "external_link") && !label.value("target").toString().isEmpty());
        require(!SemanticHtml::present(label.value("foreground")) || label.value("foreground") == missingPaint.value("normal").toObject().value("foreground"));
    }
    TableCaptionInput input;
    input.wrapper = captionWrapperStyle(layout.value(QStringLiteral("wrapper")), em);
    input.tableBorders = captionPhysicalBorders(layout.value(QStringLiteral("table_border")), em, palette);
    input.captionBorders = captionPhysicalBorders(layout.value(QStringLiteral("caption_border")), em, palette);
    input.media = captionMedia(layout.value(QStringLiteral("media")), figure, em, palette);
    input.before = captionBeforeStyle(layout.value(QStringLiteral("caption_before")), em);
    const auto states = layout.value(QStringLiteral("viewport_states"));
    require(states.isUndefined() || states.isArray());
    require(states.toArray().size() <= 16);
    double previous = 4294967296.0;
    for (const auto &stateValue : states.toArray()) {
        const auto state = CompiledContent::containerObject(stateValue,
            {QStringLiteral("max_width_px"), QStringLiteral("wrapper"), QStringLiteral("media"), QStringLiteral("caption_before")},
            {QStringLiteral("max_width_px"), QStringLiteral("wrapper"), QStringLiteral("media")});
        const auto maximum = state.value(QStringLiteral("max_width_px"));
        require(maximum.isDouble() && std::isfinite(maximum.toDouble())
            && maximum.toDouble() >= 0 && maximum.toDouble() < previous
            && std::floor(maximum.toDouble()) == maximum.toDouble());
        previous = maximum.toDouble();
        const auto wrapper = captionWrapperStyle(state.value(QStringLiteral("wrapper")), em);
        const auto media = captionMedia(state.value(QStringLiteral("media")), figure, em, palette);
        const auto before = captionBeforeStyle(state.value(QStringLiteral("caption_before")), em);
        if (rootViewportCssPixels <= maximum.toDouble()) {
            input.viewportState = true; input.wrapper = wrapper; input.before = before; input.media = media;
        }
    }
    if (CompiledContent::present(input.media.value(QStringLiteral("max_width"))))
        input.mediaLimitSubtract = length(input.media.value(QStringLiteral("max_width")).toObject().value(QStringLiteral("subtract")), em);
    return input;
}

inline constexpr int blockMediaProperty = QTextFormat::UserProperty + 0x57fd;
inline const QString blockMediaCapability = QStringLiteral("wikidict.figure-block-media/1");
struct BlockMediaInput {
    QJsonObject source, wrapper, media;
    qreal preferredWidth = 0, viewport = 0;
    quint32 naturalWidth = 0, naturalHeight = 0;
    int state = -1;
};
inline QJsonObject blockMediaRendition(const QJsonValue &value) {
    const auto source = CompiledContent::containerObject(value,
        {QStringLiteral("url"), QStringLiteral("sha256")}, {QStringLiteral("url"), QStringLiteral("sha256")});
    require(source.value("url").isString() && source.value("sha256").isString());
    const QString url = source.value("url").toString(), sha = source.value("sha256").toString();
    require(url.size() <= 8192 && url.startsWith(QStringLiteral("https://")) && sha.size() == 64);
    for (QChar ch : sha) require((ch >= QChar('0') && ch <= QChar('9')) || (ch >= QChar('a') && ch <= QChar('f')));
    const int path = url.indexOf(QChar('/'), 8);
    require(path > 8 && path + 1 < url.size());
    const QString host = url.mid(8, path - 8);
    require(!host.startsWith(QChar('.')) && !host.endsWith(QChar('.')) && host.contains(QChar('.')));
    for (QChar ch : host) require((ch >= QChar('a') && ch <= QChar('z')) || (ch >= QChar('A') && ch <= QChar('Z'))
        || (ch >= QChar('0') && ch <= QChar('9')) || ch == QChar('.') || ch == QChar('-'));
    for (QChar ch : url) require(ch.unicode() > 0x20 && ch.unicode() < 0x7f && ch != QChar('\\') && ch != QChar('#'));
    return source;
}
inline QJsonObject blockMediaWrapper(const QJsonValue &value, const QJsonObject &media, qreal em) {
    const auto wrapper = CompiledContent::containerStyle(value);
    for (auto it = wrapper.begin(); it != wrapper.end(); ++it)
        require(!CompiledContent::present(it.value()) || QStringList{"width", "line_height", "text_align",
            "owner_font_scale", "margins", "margin_values"}.contains(it.key()));
    require(CompiledContent::containerUnion(wrapper.value("width"), {QStringLiteral("auto")}) == QStringLiteral("auto"));
    require(CompiledContent::present(wrapper.value("line_height")) && CompiledContent::present(wrapper.value("text_align"))
        && wrapper.value("owner_font_scale").isDouble()
        && wrapper.value("owner_font_scale") == media.value("strut").toObject().value("font_scale")
        && (CompiledContent::present(wrapper.value("margins")) || CompiledContent::present(wrapper.value("margin_values"))));
    if (CompiledContent::present(wrapper.value("margins")))
        for (const auto &side : {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")})
            captionSignedLength(wrapper.value("margins").toObject().value(side), em);
    return wrapper;
}
inline std::optional<BlockMediaInput> blockMediaInput(const QJsonObject &figure, qreal em,
                                                     const QPalette &palette, qreal viewport) {
    const auto value = figure.value(QStringLiteral("block_media_layout"));
    if (!CompiledContent::present(value)) return std::nullopt;
    require(std::isfinite(viewport) && viewport >= 0 && !missing(figure)
        && !CompiledContent::present(figure.value("table_caption_layout"))
        && !CompiledContent::present(figure.value("frame_min_width"))
        && figure.value("placement") == QStringLiteral("none") && figure.value("clear") == QStringLiteral("none")
        && figure.value("caption").isArray() && figure.value("caption").toArray().isEmpty()
        && (!CompiledContent::present(figure.value("caption_blocks"))
            || (figure.value("caption_blocks").isArray() && figure.value("caption_blocks").toArray().isEmpty()))
        && !CompiledContent::present(figure.value("caption_text_align")));
    for (const QString &key : {QStringLiteral("frame_background"), QStringLiteral("image_background"), QStringLiteral("caption_background")})
        require(figure.value(key).toObject() == QJsonObject{{"kind", "transparent"}});
    for (const QString &key : {QStringLiteral("frame_border"), QStringLiteral("image_border")})
        require(figure.value(key).toObject() == QJsonObject{{"kind", "none"}});
    for (const QString &key : {QStringLiteral("margins"), QStringLiteral("image_insets"), QStringLiteral("caption_padding")}) {
        const auto e = edges(figure.value(key), em); require(e.top == 0 && e.right == 0 && e.bottom == 0 && e.left == 0);
    }
    const auto span = figure.value("image_span").toObject(), image = span.value("image").toObject();
    require(span.value("kind") == QStringLiteral("text") && span.value("target").toString().isEmpty()
        && !CompiledContent::present(image.value("static_poster")) && !CompiledContent::present(image.value("map")));
    const auto source = CompiledContent::containerObject(value,
        {QStringLiteral("wrapper"), QStringLiteral("media"), QStringLiteral("preferred_width_px"), QStringLiteral("natural_width"),
         QStringLiteral("natural_height"), QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x"), QStringLiteral("viewport_states")},
        {QStringLiteral("wrapper"), QStringLiteral("media"), QStringLiteral("preferred_width_px"), QStringLiteral("natural_width"),
         QStringLiteral("natural_height"), QStringLiteral("rendition_1x"), QStringLiteral("rendition_2x")});
    const auto axis = [&](const char *key, double maximum) {
        const auto n = source.value(QLatin1StringView(key));
        require(n.isDouble() && std::isfinite(n.toDouble()) && n.toDouble() >= 1
            && n.toDouble() <= maximum && std::floor(n.toDouble()) == n.toDouble());
        return quint32(n.toDouble());
    };
    BlockMediaInput input; input.source = source; input.viewport = viewport;
    input.preferredWidth = metric(axis("preferred_width_px", 4294967295.0));
    input.naturalWidth = axis("natural_width", 2147483647.0); input.naturalHeight = axis("natural_height", 2147483647.0);
    const auto one = blockMediaRendition(source.value("rendition_1x")), two = blockMediaRendition(source.value("rendition_2x"));
    require(one.value("url") != two.value("url") && one.value("sha256") != two.value("sha256"));
    const auto stateInput = [&](const QJsonObject &state, QJsonObject &wrapper, QJsonObject &media) {
        media = captionMedia(state.value("media"), figure, em, palette);
        require(!CompiledContent::present(media.value("positioning")) && !CompiledContent::present(media.value("after"))
            && !CompiledContent::present(media.value("focus_outline")));
        if (CompiledContent::present(media.value("max_width")))
            require(length(media.value("max_width").toObject().value("subtract"), em) == 0);
        wrapper = blockMediaWrapper(state.value("wrapper"), media, em);
    };
    stateInput(source, input.wrapper, input.media);
    const auto states = source.value("viewport_states"); require(states.isUndefined() || states.isArray());
    require(states.toArray().size() <= 16); double previous = 4294967296.0; int index = 0;
    for (const auto &item : states.toArray()) {
        const auto state = CompiledContent::containerObject(item,
            {QStringLiteral("max_width_px"), QStringLiteral("wrapper"), QStringLiteral("media")},
            {QStringLiteral("max_width_px"), QStringLiteral("wrapper"), QStringLiteral("media")});
        const auto maximum = state.value("max_width_px");
        require(maximum.isDouble() && std::isfinite(maximum.toDouble()) && maximum.toDouble() >= 0
            && maximum.toDouble() < previous && std::floor(maximum.toDouble()) == maximum.toDouble());
        previous = maximum.toDouble(); QJsonObject wrapper, media; stateInput(state, wrapper, media);
        if (viewport <= maximum.toDouble()) { input.wrapper = wrapper; input.media = media; input.state = index; }
        ++index;
    }
    metric(input.preferredWidth * qreal(input.naturalHeight) / input.naturalWidth);
    return input;
}
inline QJsonObject blockMediaSelectedRendition(const BlockMediaInput &input, qreal density) {
    require(std::isfinite(density) && density > 0);
    const int multiple = density <= 1 ? 1 : 2;
    auto rendition = blockMediaRendition(input.source.value(multiple == 1 ? "rendition_1x" : "rendition_2x"));
    rendition.insert("width", double(input.naturalWidth) * multiple);
    rendition.insert("height", double(input.naturalHeight) * multiple);
    return rendition;
}

inline QJsonObject validate(const QJsonValue &value, qreal em, const QPalette &palette) {
    require(value.isObject());
    const auto object = value.toObject();
    QStringList required{"format", "placement", "clear", "margins", "image_insets",
        "caption_padding", "caption_font_scale", "caption_line_height", "frame_background", "frame_border",
        "image_background", "image_border", "caption_foreground", "caption_background", "caption"};
    if (missing(object)) required.append(QStringLiteral("missing_content"));
    else required.append({QStringLiteral("image_span"), QStringLiteral("sizing")});
    for (const auto &key : required) require(object.contains(key));
    for (auto it = object.begin(); it != object.end(); ++it)
        require(required.contains(it.key()) || it.key() == "caption_blocks" || it.key() == "caption_text_align" || it.key() == "frame_min_width" || it.key() == "table_caption_layout" || it.key() == "block_media_layout");
    require(QStringList{"thumbnail", "framed"}.contains(object.value("format").toString())
        && QStringList{"none", "center", "float_left", "float_right"}.contains(object.value("placement").toString())
        && QStringList{"none", "left", "right", "both"}.contains(object.value("clear").toString()));
    if (missing(object)) missingContent(object, em);
    else {
        const auto spanValue = object.value("image_span");
        require(spanValue.isObject());
        const auto span = spanValue.toObject();
        // Primary image link paint uses the existing table-caption media action
        // geometry. Other Figure geometry remains outside this native owner.
        if (SemanticHtml::present(span.value(QStringLiteral("link_paint"))))
            require(SemanticHtml::present(object.value(QStringLiteral("table_caption_layout"))));
        require(span.value("text").toString().isEmpty() && span.value("trail").toString().isEmpty()
            && span.value("kind").toString() != "line_break");
        const auto image = SemanticHtml::checkedImage(span.value("image"));
        require(!CompiledContent::present(image.value(QStringLiteral("vertical_align"))));
        FigureSizing::request(object);
    }
    frameMinWidth(object.value(QStringLiteral("frame_min_width")));
    tableCaptionInput(object, em, palette, 0);
    blockMediaInput(object, em, palette, 0);
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
    const QJsonValue alignment = captionAlignment.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(captionAlignment);
    SemanticHtml::textAlignment(alignment);
    const QString authored = SemanticHtml::textAlignment(figure.value("caption_text_align"));
    require(authored.isEmpty() || authored == captionAlignment);
    const QJsonObject metadata{{"figure", figure}, {"image_html", imageHtml}, {"caption_html", captionHtml},
        {"caption_present", present}, {"normal_body_em", normalBodyEm}, {"caption_points", captionPoints},
        {"caption_alignment", alignment}};
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
        && (result.value("caption_alignment").isNull() || result.value("caption_alignment").isString()));
    return result;
}
inline void margins(QTextFrameFormat &format, Edges values) {
    format.setTopMargin(values.top); format.setRightMargin(values.right);
    format.setBottomMargin(values.bottom); format.setLeftMargin(values.left);
}
inline constexpr int posterCaptionProperty = ownerProperty + 13;
inline const QString posterCaptionCapability = QStringLiteral("wikidict.stl-caption-exclusion/1");
inline bool staticPoster(const QJsonObject &figure) {
    return !missing(figure) && !SemanticHtml::checkedStaticPoster(
        figure.value("image_span").toObject().value("image").toObject()).isEmpty();
}
inline bool posterNarrow(const QJsonObject &figure, qreal rootViewportWidth) {
    if (!staticPoster(figure)) return false;
    require(figure.value("format") == QStringLiteral("thumbnail")
        && figure.value("sizing") == QStringLiteral("requested_fit"));
    require(std::isfinite(rootViewportWidth) && rootViewportWidth > 0);
    return rootViewportWidth <= 639;
}
inline void posterPlacement(QTextFrameFormat &format, const QJsonObject &figure,
                            qreal normalBodyEm, qreal rootViewportWidth) {
    if (!staticPoster(figure)) return;
    const bool narrow = posterNarrow(figure, rootViewportWidth);
    margins(format, narrow ? Edges{0, 0, 0, 0} : edges(figure.value("margins"), normalBodyEm));
    const int placement = narrow ? 1 : QStringList{"none", "center", "float_left", "float_right"}
        .indexOf(figure.value("placement").toString());
    format.setPosition(placement == 2 ? QTextFrameFormat::FloatLeft
        : placement == 3 ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
    format.setProperty(placementProperty, placement);
    // The narrow source rule does not reset authored clearance.
}

inline QTextFrameFormat ownedFormat(const QString &role, int owner = -1) {
    QTextFrameFormat format; format.setMargin(0); format.setPadding(0); format.setBorder(0);
    format.setProperty(ownerProperty, capability); format.setProperty(clearProperty, 0);
    format.setProperty(placementProperty, 0); format.setProperty(roleProperty, role);
    if (owner >= 0) format.setProperty(helperOwnerProperty, owner);
    return format;
}
inline QVariantMap tableCaptionMarker() {
    return {{QStringLiteral("capability"), tableCaptionCapability}};
}
inline QVariantMap tableCaptionBefore(const std::optional<QJsonObject> &source, qreal em) {
    if (!source) return {};
    const auto &style = *source;
    const auto margin = CompiledContent::present(style.value(QStringLiteral("margins")))
        ? edges(style.value(QStringLiteral("margins")), em) : Edges{0, 0, 0, 0};
    return {{QStringLiteral("width"), length(style.value(QStringLiteral("width")).toObject().value(QStringLiteral("length")), em)},
        {QStringLiteral("height"), length(style.value(QStringLiteral("height")), em)},
        {QStringLiteral("margins"), QVariantList{margin.top, margin.right, margin.bottom, margin.left}},
        {QStringLiteral("side"), style.value(QStringLiteral("float_side")) == QStringLiteral("left") ? 2 : 3}};
}
inline QFont tableCaptionStrutFont(const QJsonObject &media, qreal em, const QFont &body) {
    const auto strut = media.value(QStringLiteral("strut")).toObject();
    const qreal pixels = em * strut.value(QStringLiteral("font_scale")).toDouble();
    QFont font = body;
    if (strut.value(QStringLiteral("code")).toBool()) {
        font.setFamilies(QStringList{QStringLiteral("monospace")}); font.setStyleHint(QFont::Monospace);
    }
    if (pixels == 0) { font.setFamilies(QStringList{SemanticHtml::zeroFontFamilyName}); font.setPointSizeF(1); }
    else font.setPointSizeF(pixels * 72 / QFontMetricsF(QFont()).fontDpi());
    font.setWeight(strut.value(QStringLiteral("bold")).toBool() ? QFont::Bold : QFont::Normal);
    font.setItalic(strut.value(QStringLiteral("italic")).toBool());
    SemanticHtml::applyFontFeatures(font, SemanticHtml::fontFeaturePolicy(strut.value(QStringLiteral("font_features"))));
    return font;
}
inline QVariantMap tableCaptionMediaPolicy(const TableCaptionInput &input, const QJsonObject &figure,
                                           qreal em, const QPalette &palette, const QFont &body, qreal sourceWidth) {
    auto policy = tableCaptionMarker();
    const auto &media = input.media;
    const auto strut = media.value(QStringLiteral("strut")).toObject();
    policy.insert(QStringLiteral("source_media"), media);
    policy.insert(QStringLiteral("source_width"), sourceWidth);
    policy.insert(QStringLiteral("strut_font"), tableCaptionStrutFont(media, em, body));
    policy.insert(QStringLiteral("strut_zero"), strut.value(QStringLiteral("font_scale")).toDouble() == 0);
    policy.insert(QStringLiteral("direction"), strut.value(QStringLiteral("direction")) == QStringLiteral("rtl") ? int(Qt::RightToLeft) : int(Qt::LeftToRight));
    policy.insert(QStringLiteral("language"), strut.value(QStringLiteral("language")).toString());
    policy.insert(QStringLiteral("middle"), media.value(QStringLiteral("vertical_align")) == QStringLiteral("middle"));
    policy.insert(QStringLiteral("positioned"), media.value(QStringLiteral("positioning")) == QStringLiteral("relative_auto"));
    const auto inset = edges(figure.value(QStringLiteral("image_insets")), em);
    const qreal border = borderWidth(figure.value(QStringLiteral("image_border")), em);
    policy.insert(QStringLiteral("box"), QVariantList{inset.top + border, inset.right + border, inset.bottom + border, inset.left + border});
    const auto sourceBorder = figure.value(QStringLiteral("image_border")).toObject();
    policy.insert(QStringLiteral("image_paint"), QVariantMap{{QStringLiteral("border_width"), border},
        {QStringLiteral("border_color"), sourceBorder.value(QStringLiteral("kind")) == QStringLiteral("solid")
            ? color(sourceBorder.value(QStringLiteral("color")), palette, QPalette::Mid) : QColor(Qt::transparent)},
        {QStringLiteral("background"), color(figure.value(QStringLiteral("image_background")), palette, QPalette::Base)}});
    if (input.mediaLimitSubtract) policy.insert(QStringLiteral("subtract"), *input.mediaLimitSubtract);
    QVariantMap after;
    if (CompiledContent::present(media.value(QStringLiteral("after")))) {
        const auto source = media.value(QStringLiteral("after")).toObject();
        after = {{QStringLiteral("width"), length(source.value(QStringLiteral("width")), em)},
            {QStringLiteral("height"), length(source.value(QStringLiteral("height")), em)},
            {QStringLiteral("inset"), length(source.value(QStringLiteral("inset")), em)},
            {QStringLiteral("bottom"), captionSignedLength(source.value(QStringLiteral("bottom")), em)},
            {QStringLiteral("right"), source.value(QStringLiteral("side")) == QStringLiteral("right")}};
        if (CompiledContent::present(source.value(QStringLiteral("paint")))) {
            const auto paint = source.value(QStringLiteral("paint")).toObject();
            after.insert(QStringLiteral("graphic"), paint.value(QStringLiteral("graphic")).toString());
            after.insert(QStringLiteral("invert"), paint.value(QStringLiteral("invert")).toBool());
        }
    }
    policy.insert(QStringLiteral("after"), after);
    QVariantMap focus;
    if (CompiledContent::present(media.value(QStringLiteral("focus_outline")))) {
        const auto source = media.value(QStringLiteral("focus_outline")).toObject();
        focus = {{QStringLiteral("width"), length(source.value(QStringLiteral("width")), em)},
            {QStringLiteral("radius"), length(source.value(QStringLiteral("radius")), em)},
            {QStringLiteral("offset"), captionSignedLength(source.value(QStringLiteral("offset")), em)},
            {QStringLiteral("color"), color(source.value(QStringLiteral("color")), palette, QPalette::Text)}};
    }
    policy.insert(QStringLiteral("focus"), focus);
    return policy;
}
inline QVariantMap blockMediaPolicy(const BlockMediaInput &input, const QJsonObject &figure,
                                    qreal em, const QPalette &palette, const QFont &body) {
    // Reuse the existing media metrics serialization; this remains a distinct
    // block capability and creates no table or caption owner.
    TableCaptionInput metrics; metrics.media = input.media;
    if (CompiledContent::present(input.media.value(QStringLiteral("max_width")))) metrics.mediaLimitSubtract = 0;
    auto policy = tableCaptionMediaPolicy(metrics, figure, em, palette, body, input.preferredWidth);
    policy.insert(QStringLiteral("capability"), blockMediaCapability);
    policy.insert(QStringLiteral("source"), input.source);
    policy.insert(QStringLiteral("wrapper"), input.wrapper);
    policy.insert(QStringLiteral("state"), input.state);
    policy.insert(QStringLiteral("viewport"), input.viewport);
    policy.insert(QStringLiteral("normal_body_em"), em);
    policy.insert(QStringLiteral("natural_width"), double(input.naturalWidth));
    policy.insert(QStringLiteral("natural_height"), double(input.naturalHeight));
    const auto line = input.wrapper.value(QStringLiteral("line_height")).toObject();
    int lineMode = 0; qreal lineValue = 0;
    if (line.contains(QStringLiteral("multiplier"))) {
        lineMode = 1; lineValue = line.value(QStringLiteral("multiplier")).toDouble();
    } else if (line.contains(QStringLiteral("length"))) {
        lineMode = 2; lineValue = length(line.value(QStringLiteral("length")), em);
    } else require(line.contains(QStringLiteral("normal")));
    require(std::isfinite(lineValue) && lineValue >= 0);
    policy.insert(QStringLiteral("line_mode"), lineMode);
    policy.insert(QStringLiteral("line_value"), lineValue);
    policy.insert(QStringLiteral("owner_pixels"), metric(em * input.media.value(QStringLiteral("strut")).toObject()
        .value(QStringLiteral("font_scale")).toDouble()));
    const QString align = input.wrapper.value(QStringLiteral("text_align")).toString();
    policy.insert(QStringLiteral("alignment"), int(align == QStringLiteral("center") ? Qt::AlignHCenter
        : align == QStringLiteral("right") ? Qt::AlignRight | Qt::AlignAbsolute : Qt::AlignLeft | Qt::AlignAbsolute));
    return policy;
}
inline void blockMediaPlacement(QTextFrameFormat &format, const BlockMediaInput &input,
                                qreal em, const QPalette &palette) {
    Edges margin{0, 0, 0, 0}; QVariantList autos{false, false, false, false};
    if (CompiledContent::present(input.wrapper.value(QStringLiteral("margins")))) {
        const auto values = input.wrapper.value(QStringLiteral("margins")).toObject();
        margin = {captionSignedLength(values.value("top"), em), captionSignedLength(values.value("right"), em),
            captionSignedLength(values.value("bottom"), em), captionSignedLength(values.value("left"), em)};
    }
    if (CompiledContent::present(input.wrapper.value(QStringLiteral("margin_values")))) {
        const auto values = input.wrapper.value(QStringLiteral("margin_values")).toObject();
        qreal *sides[]{&margin.top, &margin.right, &margin.bottom, &margin.left};
        const QStringList names{"top", "right", "bottom", "left"};
        for (int i = 0; i < 4; ++i) {
            const auto tagged = values.value(names[i]).toObject();
            autos[i] = tagged.contains(QStringLiteral("auto"));
            *sides[i] = autos[i].toBool() ? 0 : captionSignedLength(tagged.value(QStringLiteral("length")), em);
        }
    }
    margins(format, margin);
    format.setPosition(QTextFrameFormat::InFlow);
    format.setProperty(placementProperty, 0); format.setProperty(clearProperty, 0);
    format.setWidth(QTextLength(QTextLength::VariableLength, 0));
    format.setProperty(blockMediaProperty, QVariantMap{{QStringLiteral("capability"), blockMediaCapability},
        {QStringLiteral("source"), input.source}, {QStringLiteral("wrapper"), input.wrapper},
        {QStringLiteral("state"), input.state}, {QStringLiteral("viewport"), input.viewport}, {QStringLiteral("normal_body_em"), em},
        {QStringLiteral("autos"), autos}, {QStringLiteral("palette"), palette}});
}
inline bool blockMediaImageStorage(QTextFrame *image, int position) {
    if (!image || position < image->firstPosition() || position > image->lastPosition()) return false;
    QTextFragment object;
    for (auto it = image->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock(); if (!block.isValid()) continue;
        for (auto piece = block.begin(); !piece.atEnd(); ++piece) {
            const auto fragment = piece.fragment();
            if (!fragment.isValid() || fragment.length() != 1 || !fragment.charFormat().isImageFormat()
                || fragment.position() != position || object.isValid()) return false;
            object = fragment;
        }
    }
    if (!object.isValid()) return false;
    const auto children = image->childFrames(); const int index = object.charFormat().objectIndex();
    if (children.isEmpty()) return index == -1;
    if (children.size() != 1 || index < 0) return false;
    const auto *helper = children.first(); QTextFrameFormat neutral;
    neutral.setPosition(QTextFrameFormat::InFlow);
    // Fragment copies may retain Qt's empty image-object frame at the ORC.
    // It is storage for this exact object, not an additional semantic child.
    return helper->document() == image->document() && helper->parentFrame() == image
        && !qobject_cast<const QTextTable *>(helper) && helper->childFrames().isEmpty()
        && image->document()->object(index) == helper && helper->objectIndex() == index
        && helper->firstPosition() == position + 1 && helper->lastPosition() == position
        && helper->frameFormat() == neutral;
}
inline void blockMediaFrame(QTextFrame *image, const QVariantMap &policy, QTextDocument *document) {
    auto format = image->frameFormat();
    format.setMargin(0); format.setPadding(0); format.setBorder(0);
    format.setBorderStyle(QTextFrameFormat::BorderStyle_None); format.setBackground(Qt::transparent);
    format.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    format.setProperty(blockMediaProperty, policy);
    format.setLayoutDirection(Qt::LayoutDirection(policy.value(QStringLiteral("direction")).toInt()));
    if (format != image->frameFormat()) image->setFrameFormat(format);
    for (auto it = image->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock(); if (!block.isValid()) continue;
        auto blockFormat = block.blockFormat();
        blockFormat.setAlignment(Qt::Alignment(policy.value(QStringLiteral("alignment")).toInt()));
        blockFormat.clearProperty(QTextFormat::LineHeight); blockFormat.clearProperty(QTextFormat::LineHeightType);
        blockFormat.setLayoutDirection(format.layoutDirection());
        QTextCursor edit(block);
        if (blockFormat != block.blockFormat()) edit.setBlockFormat(blockFormat);
        auto character = block.charFormat(); character.setFont(policy.value(QStringLiteral("strut_font")).value<QFont>());
        if (character != block.charFormat()) edit.setBlockCharFormat(character);
        for (auto fragment = block.begin(); !fragment.atEnd(); ++fragment) {
            const auto run = fragment.fragment();
            if (!run.isValid() || !run.charFormat().isImageFormat()) continue;
            auto object = run.charFormat(); object.setVerticalAlignment(QTextCharFormat::AlignNormal);
            QTextCursor change(document); change.setPosition(run.position());
            change.setPosition(run.position() + run.length(), QTextCursor::KeepAnchor);
            if (object != run.charFormat()) change.setCharFormat(object);
        }
    }
    document->markContentsDirty(image->firstPosition(), image->lastPosition() - image->firstPosition() + 1);
}

inline void tableCaptionMediaFrame(QTextFrame *image, const QVariantMap &policy, QTextDocument *document) {
    auto format = image->frameFormat(); format.setMargin(0); format.setPadding(0); format.setBorder(0);
    format.setBorderStyle(QTextFrameFormat::BorderStyle_None); format.setBackground(Qt::transparent);
    format.setProperty(tableCaptionProperty, policy);
    format.setLayoutDirection(Qt::LayoutDirection(policy.value(QStringLiteral("direction")).toInt()));
    if (format != image->frameFormat()) image->setFrameFormat(format);
    for (auto it = image->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock(); if (!block.isValid()) continue;
        if (!policy.value(QStringLiteral("middle")).toBool()) continue;
        auto blockFormat = block.blockFormat(); blockFormat.setAlignment(Qt::AlignHCenter | Qt::AlignAbsolute);
        blockFormat.clearProperty(QTextFormat::LineHeight); blockFormat.clearProperty(QTextFormat::LineHeightType);
        blockFormat.setLayoutDirection(format.layoutDirection());
        QTextCursor edit(block);
        if (blockFormat != block.blockFormat()) edit.setBlockFormat(blockFormat);
        auto character = block.charFormat(); character.setFont(policy.value(QStringLiteral("strut_font")).value<QFont>());
        if (character != block.charFormat()) edit.setBlockCharFormat(character);
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            auto object = fragment.charFormat(); object.setVerticalAlignment(QTextCharFormat::AlignNormal);
            QTextCursor change(document); change.setPosition(fragment.position());
            change.setPosition(fragment.position() + fragment.length(), QTextCursor::KeepAnchor);
            if (object != fragment.charFormat()) change.setCharFormat(object);
        }
    }
    document->markContentsDirty(image->firstPosition(), image->lastPosition() - image->firstPosition() + 1);
}
inline void tableCaptionPlacement(QTextFrameFormat &format, const TableCaptionInput &input,
                                  const QJsonObject &figure, qreal em) {
    Q_UNUSED(figure);
    Edges margin{0, 0, 0, 0};
    int placement = 0, clear = 0;
    QVariantList autos{false, false, false, false};
    {
        // Base and selected viewport wrappers are complete physical states.
        const auto &style = input.wrapper;
        if (CompiledContent::present(style.value(QStringLiteral("margins"))))
            margin = edges(style.value(QStringLiteral("margins")), em);
        if (CompiledContent::present(style.value(QStringLiteral("margin_values")))) {
            const auto values = style.value(QStringLiteral("margin_values")).toObject();
            qreal *sides[]{&margin.top, &margin.right, &margin.bottom, &margin.left};
            const QStringList names{"top", "right", "bottom", "left"};
            for (int i = 0; i < 4; ++i) {
                const auto tagged = values.value(names[i]).toObject();
                autos[i] = tagged.contains(QStringLiteral("auto"));
                *sides[i] = autos[i].toBool() ? 0 : length(tagged.value(QStringLiteral("length")), em);
            }
        }
        if (style.value(QStringLiteral("float_side")) == QStringLiteral("left")) placement = 2;
        else if (style.value(QStringLiteral("float_side")) == QStringLiteral("right")) placement = 3;
        if (CompiledContent::present(style.value(QStringLiteral("clear"))))
            clear = QStringList{"none", "left", "right", "both"}.indexOf(style.value(QStringLiteral("clear")).toString());
    }
    margins(format, margin);
    format.setPosition(placement == 2 ? QTextFrameFormat::FloatLeft
        : placement == 3 ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
    format.setProperty(placementProperty, placement); format.setProperty(clearProperty, clear);
    auto policy = tableCaptionMarker(); policy.insert(QStringLiteral("autos"), autos);
    const auto oldPolicy = format.property(tableCaptionProperty).toMap();
    if (oldPolicy.contains(QStringLiteral("palette"))) policy.insert(QStringLiteral("palette"), oldPolicy.value(QStringLiteral("palette")));
    format.setProperty(tableCaptionProperty, policy);
}
inline QTextTableFormat tableCaptionTableFormat(const QString &role, int owner,
                                                const QVariantList &physical, bool collapse) {
    QTextTableFormat format;
    format.merge(ownedFormat(role, owner));
    format.setProperty(tableCaptionProperty, tableCaptionMarker());
    format.setProperty(SemanticHtml::tableBoxOwnerProperty, SemanticHtml::tableBoxCapability);
    format.setProperty(SemanticHtml::tableBoxClearProperty, 0);
    format.setProperty(SemanticHtml::cellStylePolicyProperty, SemanticHtml::cellStyleCapability);
    format.setProperty(SemanticHtml::tablePhysicalEdgesProperty, QVariantMap{
        {QStringLiteral("padding"), QVariantList{0.0, 0.0, 0.0, 0.0}},
        {QStringLiteral("borders"), physical}});
    // The existing allocator resolves this request after its intrinsic pass.
    format.setProperty(SemanticHtml::tableBoxWidthProperty, QVariantMap{
        {QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100.0}});
    format.setProperty(SemanticHtml::tableBoxPaddingProperty, QVariantList{0.0, 0.0, 0.0, 0.0});
    format.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
    format.setCellPadding(0); format.setCellSpacing(0); format.setBorderCollapse(collapse);
    format.setAlignment(Qt::AlignLeft | Qt::AlignAbsolute);
    return format;
}
inline void initializeCaptionCell(QTextTable *table) {
    require(table && table->rows() == 1 && table->columns() == 1);
    auto cell = table->cellAt(0, 0); auto format = cell.format().toTableCellFormat();
    format.setPadding(0); format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
    format.setVerticalAlignment(QTextCharFormat::AlignTop); cell.setFormat(format);
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
    if (CompiledContent::present(figure.value(QStringLiteral("block_media_layout")))) {
        const auto source = figure.value(QStringLiteral("block_media_layout")).toObject();
        const auto resource = SemanticHtml::blockMediaResource(figure);
        require(source.value(QStringLiteral("preferred_width_px")).isDouble());
        const qreal preferred = metric(source.value(QStringLiteral("preferred_width_px")).toDouble());
        require(preferred > 0 && std::floor(preferred) == preferred);
        const QSizeF size(preferred, metric(preferred * resource.value("natural_height").toDouble() / resource.value("natural_width").toDouble()));
        const bool ready = asset.state == MediaPanel::InlineImageState::Ready;
        if (ready) {
            require(!asset.vector && asset.originalMime == QStringLiteral("image/png")
                && (asset.pinnedRendition == SemanticHtml::blockMediaRendition(resource, 1)
                    || asset.pinnedRendition == SemanticHtml::blockMediaRendition(resource, 2))
                && asset.image.width() == asset.pinnedRendition.value("width").toDouble()
                && asset.image.height() == asset.pinnedRendition.value("height").toDouble()
                && asset.intrinsic == QSizeF(asset.image.size()));
            format.setProperty(SemanticHtml::imageOriginalSizeProperty, asset.intrinsic);
        } else format.clearProperty(SemanticHtml::imageOriginalSizeProperty);
        // Resource availability does not replace the source ratio or strut.
        format.setWidth(size.width()); format.setHeight(size.height());
        format.setProperty(SemanticHtml::imageLayoutSizeProperty, size);
        format.setProperty(sizingReadyProperty, ready);
        format.clearProperty(SemanticHtml::inlineImageBorderProperty);
        return ready;
    }
    const auto fallback = format.property(placeholderSizeProperty).toSizeF();
    require(std::isfinite(fallback.width()) && fallback.width() > 0
        && std::isfinite(fallback.height()) && fallback.height() >= 0);
    const auto posterImage = figure.value("image_span").toObject().value("image").toObject();
    const auto poster = SemanticHtml::checkedStaticPoster(posterImage);
    const auto resolved = !poster.isEmpty()
        ? (asset.state == MediaPanel::InlineImageState::Ready
            ? std::optional<QSizeF>(QSizeF(posterImage.value("width_px").toDouble(), posterImage.value("height_px").toDouble()))
            : std::nullopt)
        : asset.originalVerified
        ? FigureSizing::resolveOriginal(FigureSizing::request(figure), asset.intrinsic)
        : FigureSizing::resolve(FigureSizing::request(figure), asset);
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
inline void reflow(QTextDocument *document, qreal rootViewportWidth = std::numeric_limits<qreal>::quiet_NaN());
// Initial construction only, before registration. The caller recursively expands
// caption flows and registers the complete inventory after construction finishes.
inline QVector<QPointer<QTextFrame>> materialize(QTextDocument *document,
        QVector<FlowConstruction::Owner> &owners, const QPalette &palette,
        qreal rootViewportWidth = std::numeric_limits<qreal>::quiet_NaN()) {
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
        const auto tableCaption = tableCaptionInput(figure, em, palette, rootViewportWidth);
        const auto blockMedia = blockMediaInput(figure, em, palette, rootViewportWidth);
        if (blockMedia) require(layout->property("_wikidictFigureBlockMediaCapability").toString() == blockMediaCapability);
        const auto sourceLayout = figure.value("table_caption_layout").toObject();
        if (SemanticHtml::present(sourceLayout.value("missing_link_paint")) || SemanticHtml::present(sourceLayout.value("caption_link_paint")))
            require(layout->property("_wikidictFigureLinkStateCapability").toString() == MissingFigurePaint::fixedPolicy);
        if (tableCaption) require(layout->property("_wikidictFigureTableCaptionCapability").toString() == tableCaptionCapability);
        if (missing(figure)) require(layout->property("_wikidictFigureMissingWrapCapability").toString() == missingWrapCapability);
        require(meta.value("caption_present").toBool() == captionPresent(figure) && std::isfinite(points) && points >= 0);
        const auto alignmentName = SemanticHtml::textAlignment(meta.value("caption_alignment"));
        const auto authoredAlignment = SemanticHtml::textAlignment(figure.value("caption_text_align"));
        require(authoredAlignment.isEmpty() || authoredAlignment == alignmentName);
        const Qt::Alignment align = alignmentName == "right" ? Qt::AlignRight | Qt::AlignAbsolute
            : alignmentName == "center" ? Qt::AlignHCenter
            : alignmentName == "left" ? Qt::AlignLeft | Qt::AlignAbsolute : document->defaultTextOption().alignment();
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
        posterPlacement(outer, figure, em, rootViewportWidth);
        if (tableCaption) {
            tableCaptionPlacement(outer, *tableCaption, figure, em);
            auto policy = outer.property(tableCaptionProperty).toMap(); policy.insert(QStringLiteral("palette"), palette);
            outer.setProperty(tableCaptionProperty, policy);
        }
        if (blockMedia) blockMediaPlacement(outer, *blockMedia, em, palette);
        outer.setProperty(dataProperty, QJsonDocument(meta).toJson(QJsonDocument::Compact)); outer.setProperty(pointsProperty, points);
        const auto frame = FlowConstruction::insertFigure(owners[item.owner], item.cursor, item.run, outer, [&](QTextFrame *rawFrame) {
            const QPointer<QTextFrame> frame(rawFrame);
            const int ownerIndex = frame->objectIndex();
            auto imageFormat = ownedFormat("image", ownerIndex); margins(imageFormat, edges(figure.value("image_insets"), em));
            border(imageFormat, figure.value("image_border"), em, palette);
            imageFormat.setBackground(color(figure.value("image_background"), palette, QPalette::Base));
            auto cursor = frame->firstCursorPosition();
            QPointer<QTextTable> mediaGrid;
            if (tableCaption) {
                mediaGrid = cursor.insertTable(1, 1, tableCaptionTableFormat(
                    QStringLiteral("media-grid"), ownerIndex, tableCaption->tableBorders, true));
                initializeCaptionCell(mediaGrid);
                cursor = mediaGrid->cellAt(0, 0).firstCursorPosition();
                imageFormat.setProperty(tableCaptionProperty, tableCaptionMarker());
            }
            const QPointer<QTextFrame> imageFrame(cursor.insertFrame(imageFormat));
            require(guard && frame && imageFrame);
            if (missing(figure)) {
                const auto content = missingContent(figure, em);
                auto labelFormat = ownedFormat("missing-label", ownerIndex);
                labelFormat.setWidth(QTextLength(QTextLength::FixedLength, length(content.value("width"), em)));
                const QPointer<QTextFrame> label(imageFrame->firstCursorPosition().insertFrame(labelFormat));
                require(guard && frame && imageFrame && label);
                insertHtml(label->firstCursorPosition(), meta.value("image_html").toString(), -1, Qt::AlignHCenter);
                require(guard && frame && imageFrame && label);
                markMissingLabel(label, ownerIndex, content, em, palette,
                    figure.value("table_caption_layout").toObject().value("missing_link_paint").toObject());
                hideGeneratedEmptyBlocks(imageFrame);
            } else {
                insertHtml(imageFrame->firstCursorPosition(), meta.value("image_html").toString(),
                    -1, Qt::AlignLeft | Qt::AlignAbsolute);
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
                if (blockMedia) {
                    format.setName(SemanticHtml::inlineBlockMediaUrl(figure).toString(QUrl::FullyEncoded));
                    format.setWidth(blockMedia->preferredWidth);
                    format.setHeight(blockMedia->preferredWidth * qreal(blockMedia->naturalHeight) / blockMedia->naturalWidth);
                }
                format.clearProperty(SemanticHtml::imageOriginalSizeProperty); format.clearProperty(SemanticHtml::imageLayoutSizeProperty);
                format.clearProperty(SemanticHtml::inlineImageBorderProperty); format.clearBackground();
                QTextCursor change(document); change.setPosition(image.position()); change.setPosition(image.position() + 1, QTextCursor::KeepAnchor); change.setCharFormat(format);
                if (blockMedia) blockMediaFrame(imageFrame,
                    blockMediaPolicy(*blockMedia, figure, em, palette, document->defaultFont()), document);
            }
            const auto padding = edges(figure.value("caption_padding"), em);
            if (mediaGrid) hideGeneratedEmptyBlocks(mediaGrid);
            if (tableCaption || staticPoster(figure) || meta.value("caption_present").toBool() || padding.top || padding.right || padding.bottom || padding.left) {
                cursor.setPosition(mediaGrid ? mediaGrid->lastPosition() + 1 : imageFrame->lastPosition() + 1);
                auto captionFormat = ownedFormat("caption", ownerIndex);
                captionFormat.setBackground(color(figure.value("caption_background"), palette, QPalette::AlternateBase));
                QPointer<QTextFrame> caption;
                if (tableCaption) {
                    auto format = tableCaptionTableFormat(QStringLiteral("caption"), ownerIndex, tableCaption->captionBorders, false);
                    format.setBackground(captionFormat.background());
                    auto *table = cursor.insertTable(1, 1, format);
                    initializeCaptionCell(table); caption = table;
                } else caption = cursor.insertFrame(captionFormat);
                require(guard && frame && caption);
                cursor = caption->firstCursorPosition();
                auto contentFormat = ownedFormat("caption-content", ownerIndex); margins(contentFormat, padding);
                if (tableCaption) {
                    auto policy = tableCaptionMarker();
                    policy.insert(QStringLiteral("before"), tableCaptionBefore(tableCaption->before, em));
                    contentFormat.setProperty(tableCaptionProperty, policy);
                }
                if (staticPoster(figure)) {
                    require(layout->property("_wikidictPosterCaptionCapability").toString() == posterCaptionCapability);
                    if (!posterNarrow(figure, rootViewportWidth))
                        contentFormat.setProperty(posterCaptionProperty, posterCaptionCapability);
                }
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
inline void reflow(QTextDocument *document, qreal rootViewportWidth) {
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
        const auto savedBlockPalette = outer.property(blockMediaProperty).toMap().value(QStringLiteral("palette"));
        const auto blockMedia = blockMediaInput(figure, em,
            savedBlockPalette.metaType().id() == QMetaType::QPalette ? savedBlockPalette.value<QPalette>() : QPalette(), rootViewportWidth);
        if (blockMedia) require(savedBlockPalette.metaType().id() == QMetaType::QPalette
            && layout->property("_wikidictFigureBlockMediaCapability").toString() == blockMediaCapability);
        const auto savedPalette = outer.property(tableCaptionProperty).toMap().value(QStringLiteral("palette"));
        const auto tableCaption = tableCaptionInput(figure, em,
            savedPalette.metaType().id() == QMetaType::QPalette ? savedPalette.value<QPalette>() : QPalette(), rootViewportWidth);
        if (tableCaption) require(savedPalette.metaType().id() == QMetaType::QPalette);
        if (tableCaption) {
            require(layout->property("_wikidictFigureTableCaptionCapability").toString() == tableCaptionCapability);
            tableCaptionPlacement(outer, *tableCaption, figure, em);
        }
        posterPlacement(outer, figure, em, rootViewportWidth);
        const auto outside = Edges{outer.topMargin(), outer.rightMargin(), outer.bottomMargin(), outer.leftMargin()};
        const auto inset = edges(figure.value("image_insets"), em), padding = edges(figure.value("caption_padding"), em);
        const qreal outerBorder = borderWidth(figure.value("frame_border"), em), imageBorder = borderWidth(figure.value("image_border"), em);
        QPointer<QTextFrame> imageFrame, captionFrame, contentFrame;
        QPointer<QTextTable> mediaGrid;
        for (auto *child : frame->childFrames()) {
            if (belongs(child, "image", frame->objectIndex())) { require(!imageFrame); imageFrame = child; }
            if (belongs(child, "caption", frame->objectIndex())) { require(!captionFrame); captionFrame = child; }
            if (tableCaption && belongs(child, "media-grid", frame->objectIndex())) {
                require(!mediaGrid); mediaGrid = qobject_cast<QTextTable *>(child); require(mediaGrid);
                for (auto *plane : mediaGrid->childFrames()) if (belongs(plane, "image", frame->objectIndex())) {
                    require(!imageFrame); imageFrame = plane;
                }
            }
        }
        require(bool(mediaGrid) == bool(tableCaption));
        require(imageFrame);
        if (captionFrame) for (auto *child : captionFrame->childFrames())
            if (belongs(child, "caption-content", frame->objectIndex())) { require(!contentFrame); contentFrame = child; }
        qreal width = 0, height = 0;
        int imagePosition = -1; bool imageSizingReady = false;
        if (missing(figure)) {
            require(layout->property("_wikidictFigureMissingWrapCapability").toString() == missingWrapCapability);
            const auto content = missingContent(figure, em); width = length(content.value("width"), em);
            QPointer<QTextFrame> label;
            for (auto *child : imageFrame->childFrames()) if (belongs(child, "missing-label", frame->objectIndex())) { require(!label); label = child; }
            require(label); auto labelFormat = label->frameFormat();
            if (tableCaption) {
                margins(labelFormat, inset);
                border(labelFormat, figure.value("image_border"), em, savedPalette.value<QPalette>());
                labelFormat.setBackground(color(figure.value("image_background"), savedPalette.value<QPalette>(), QPalette::Base));
            }
            labelFormat.setWidth(QTextLength(QTextLength::FixedLength,
                tableCaption ? metric(width + inset.left + inset.right + 2 * imageBorder) : width));
            if (labelFormat != label->frameFormat()) label->setFrameFormat(labelFormat);
            require(guard && label && frame && imageFrame);
        } else {
            QTextFragment image;
            for (auto it = imageFrame->begin(); !it.atEnd(); ++it) {
                const auto block = it.currentBlock(); if (!block.isValid()) continue;
                for (auto fragment = block.begin(); !fragment.atEnd(); ++fragment)
                    if (fragment.fragment().isValid() && fragment.fragment().charFormat().isImageFormat()) {
                        require(!image.isValid()); image = fragment.fragment();
                    }
            }
            require(image.isValid());
            imagePosition = image.position();
            const auto format = image.charFormat().toImageFormat();
            width = metric(format.width()); height = metric(format.height()); require(width > 0);
            imageSizingReady = format.boolProperty(sizingReadyProperty);
        }
        if (blockMedia) {
            require(!captionFrame && !contentFrame && !mediaGrid && frame->childFrames().size() == 1
                && blockMediaImageStorage(imageFrame, imagePosition));
            blockMediaPlacement(outer, *blockMedia, em, savedBlockPalette.value<QPalette>());
            if (outer != frame->frameFormat()) frame->setFrameFormat(outer);
            require(guard && layout && frame && imageFrame && document->documentLayout() == layout);
            blockMediaFrame(imageFrame, blockMediaPolicy(*blockMedia, figure, em,
                savedBlockPalette.value<QPalette>(), document->defaultFont()), document);
            continue;
        }
        const qreal imageBox = metric(width + inset.left + inset.right + 2 * imageBorder);
        qreal contentWidth = qMax(imageBox, metric(padding.left + padding.right));
        if (const auto minimum = frameMinWidth(figure.value(QStringLiteral("frame_min_width")))) {
            require(layout->property("_wikidictFigureMinWidthCapability").toString() == frameMinWidthCapability);
            if (tableCaption) outer.clearProperty(frameMinWidthProperty);
            else outer.setProperty(frameMinWidthProperty, *minimum);
            contentWidth = qMax(contentWidth, *minimum);
        } else outer.clearProperty(frameMinWidthProperty);
        outer.setWidth(QTextLength(QTextLength::FixedLength, metric(contentWidth + outside.left + outside.right + 2 * outerBorder)));
        if (tableCaption) {
            // Rebuild from the original media dimensions; a previous caption
            // floor must never become the next resource/font/viewport baseline.
            const auto policy = tableCaptionMediaPolicy(*tableCaption, figure, em, savedPalette.value<QPalette>(), document->defaultFont(), width);
            tableCaptionMediaFrame(imageFrame, policy, document);
            auto cell = mediaGrid->cellAt(0, 0); auto cellFormat = cell.format().toTableCellFormat();
            if (const auto minimum = frameMinWidth(figure.value(QStringLiteral("frame_min_width"))))
                cellFormat.setProperty(SemanticHtml::cellMinimumWidthProperty,
                    QVariantMap{{QStringLiteral("unit"), QStringLiteral("fixed")}, {QStringLiteral("value"), *minimum}});
            else cellFormat.clearProperty(SemanticHtml::cellMinimumWidthProperty);
            if (cellFormat != cell.format()) cell.setFormat(cellFormat);
            require(contentFrame);
            auto contentFormat = contentFrame->frameFormat(); auto beforePolicy = tableCaptionMarker();
            beforePolicy.insert(QStringLiteral("before"), tableCaptionBefore(tableCaption->before, em));
            contentFormat.setProperty(tableCaptionProperty, beforePolicy);
            if (contentFormat != contentFrame->frameFormat()) contentFrame->setFrameFormat(contentFormat);
        }
        if (outer != frame->frameFormat()) frame->setFrameFormat(outer);
        require(guard && layout && frame && imageFrame && document->documentLayout() == layout);
        // Only our three structural helpers follow the outer content width.
        // Authored rich-caption tables and nested figures retain their formats.
        for (const auto &helper : {imageFrame, captionFrame, contentFrame}) if (helper) {
            auto helperFormat = helper->frameFormat(); helperFormat.setWidth(QTextLength(QTextLength::PercentageLength, 100));
            if (helper == contentFrame && staticPoster(figure)) {
                require(layout->property("_wikidictPosterCaptionCapability").toString() == posterCaptionCapability);
                if (!posterNarrow(figure, rootViewportWidth))
                    helperFormat.setProperty(posterCaptionProperty, posterCaptionCapability);
                else helperFormat.clearProperty(posterCaptionProperty);
            }
            if (helperFormat != helper->frameFormat()) helper->setFrameFormat(helperFormat);
            require(guard && layout && frame && imageFrame && document->documentLayout() == layout);
        }
        if (tableCaption) {
            document->markContentsDirty(frame->firstPosition(), frame->lastPosition() - frame->firstPosition() + 1);
        }
        if (missing(figure)) continue;
        if (!tableCaption && height == 0 && imageSizingReady) {
            auto block = document->findBlock(imagePosition); auto blockFormat = block.blockFormat();
            blockFormat.setLineHeight(0, QTextBlockFormat::FixedHeight);
            QTextCursor change(block); change.setBlockFormat(blockFormat);
        } else if (!tableCaption) {
            auto block = document->findBlock(imagePosition); auto blockFormat = block.blockFormat();
            if (blockFormat.lineHeightType() == QTextBlockFormat::FixedHeight && blockFormat.lineHeight() == 0) {
                blockFormat.clearProperty(QTextFormat::LineHeight); blockFormat.clearProperty(QTextFormat::LineHeightType);
                QTextCursor change(block); change.setBlockFormat(blockFormat);
            }
        }
    }
}
}
