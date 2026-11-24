#pragma once
#include "CompiledContent.hpp"
#include "SemanticHtml.hpp"
#include <QFont>

namespace SectionHeading {
inline constexpr int property = QTextFormat::UserProperty + 0x5807;
// The body remains a sibling of the outer frame. Only the real heading
// companion can acquire the two source-declared ancestors.
inline QJsonObject companionContainer(const QJsonObject &style, const QJsonObject &child) {
    return {{"kind", "container"}, {"depth", 0}, {"spans", QJsonArray{}},
        {"container", QJsonObject{{"style", style}, {"blocks", QJsonArray{child}}}}};
}
inline QJsonObject companionWrappers(const QJsonValue &value) {
    using namespace CompiledContent;
    const QStringList keys{"outer", "inner", "title_block_padding_right"};
    const auto wrappers = containerObject(value, keys, keys);
    const auto outer = containerStyle(wrappers.value("outer"));
    const auto inner = containerStyle(wrappers.value("inner"));
    for (auto it = outer.begin(); it != outer.end(); ++it)
        require(!present(it.value()) || it.key() == "margins" || it.key() == "border" || it.key() == "overflow");
    for (auto it = inner.begin(); it != inner.end(); ++it)
        require(!present(it.value()) || it.key() == "padding");
    require(outer.value("overflow") == QStringLiteral("visible_x_clip_y"));
    const auto edges = outer.value("border").toObject().value("edges").toObject();
    const auto dash = edges.value("top").toObject().value("dashed").toObject();
    require(dash.value("width").toObject().value("unit") == QStringLiteral("px")
        && dash.value("width").toObject().value("value").toDouble() > 0
        && (dash.value("color").toObject().contains("rgb") || dash.value("color").toObject().contains("light_dark")));
    containerColor(dash.value("color"));
    const auto positiveEm = [](const QJsonValue &v) {
        containerLength(v);
        require(v.toObject().value("unit") == QStringLiteral("em") && v.toObject().value("value").toDouble() > 0);
    };
    positiveEm(wrappers.value("title_block_padding_right"));
    for (const auto &sides : {outer.value("margins").toObject(), inner.value("padding").toObject()}) {
        positiveEm(sides.value("top"));
        for (const auto key : {"right", "bottom", "left"})
            require(sides.value(QLatin1String(key)).toObject().value("value").toDouble(-1) == 0);
    }
    for (const auto key : {"right", "bottom", "left"})
        require(edges.value(QLatin1String(key)).toObject() == QJsonObject{{"none", QJsonObject{}}});
    return wrappers;
}
inline QJsonObject validate(const QJsonObject &section) {
    using namespace CompiledContent;
    const auto style = containerObject(section.value(QStringLiteral("heading_style")),
        {QStringLiteral("box"), QStringLiteral("font"), QStringLiteral("direction"), QStringLiteral("wrappers")},
        {QStringLiteral("box"), QStringLiteral("font"), QStringLiteral("direction")});
    const auto box = containerStyle(style.value(QStringLiteral("box")));
    for (const auto &key : {"margins", "padding", "border", "owner_font_scale", "line_height", "font_family", "clear"})
        require(present(box.value(QLatin1String(key))));
    for (const auto &key : {"float_side", "flex_item", "align_items", "columns", "screen_max_width", "height", "min_height", "margin_values", "owner_font"})
        require(!present(box.value(QLatin1String(key))));
    require(!present(box.value("width")) || box.value("width").toObject() == QJsonObject{{"auto", QJsonObject{}}});
    require(!present(box.value("max_width")) || box.value("max_width").toObject() == QJsonObject{{"none", QJsonObject{}}});
    require(!present(box.value("layout")) || box.value("layout") == QStringLiteral("flow"));
    require(!present(box.value("overflow")) || box.value("overflow") == QStringLiteral("visible"));
    if (present(style.value("wrappers"))) {
        companionWrappers(style.value("wrappers"));
        require(box.value("positioning") == QStringLiteral("relative_auto") && section.value("level").toInt() == 3
            && box.value("border").toObject() == QJsonObject{{"none", QJsonObject{}}});
        for (const auto key : {"margins", "padding"}) {
            const auto sides = box.value(QLatin1StringView(key)).toObject();
            for (auto it = sides.begin(); it != sides.end(); ++it) require(it.value().toObject().value("value").toDouble(-1) == 0);
        }
    } else require(!present(box.value("positioning")));
    const auto font = SemanticHtml::inlineFontSnapshot(style.value("font"));
    require(!present(font.value("font_family")) || font.value("font_family") == box.value("font_family"));
    require(font.value("font_scale_basis") == QStringLiteral("normal_body") && font.value("font_scale").isDouble()
        && font.value("font_scale") == box.value("owner_font_scale") && font.value("role") == QStringLiteral("normal")
        && font.value("classes").toString().isEmpty() && SemanticHtml::sourceLanguageTag(font.value("language").toString())
        && !font.value("language").toString().isEmpty() && font.value("language").toString().toUtf8().size() <= 1024);
    for (const auto &key : {"small", "superscript", "subscript", "font_normalized", "code"}) require(!font.value(QLatin1String(key)).toBool());
    require(style.value("direction") == QStringLiteral("ltr") || style.value("direction") == QStringLiteral("rtl"));
    const auto level = section.value("level");
    require(level.isDouble() && level.toDouble() >= 1 && level.toDouble() <= 6 && std::floor(level.toDouble()) == level.toDouble()
        && section.value("title").isString() && !section.value("title").toString().isEmpty()
        && section.value("blocks").isArray() && !section.value("blocks").toArray().isEmpty());
    const auto first = object(section.value("blocks").toArray().first());
    const auto depth = first.value("depth");
    require(!present(depth) || (depth.isDouble() && depth.toDouble() == 0));
    for (const auto &key : {"list_path", "number"}) {
        const auto value = first.value(QLatin1String(key));
        require(!present(value) || (value.isString() && value.toString().isEmpty()));
    }
    require(first.value("kind") == QStringLiteral("heading") && first.value("level") == level
        && first.value("depth").toInt() == 0 && first.value("list_path").toString().isEmpty() && first.value("number").toString().isEmpty());
    for (const auto &key : {"anchor", "anchor_fallback"}) {
        const auto a = first.value(QLatin1String(key)), b = section.value(QLatin1String(key));
        require((!present(a) || a.isString()) && (!present(b) || b.isString()) && a.toString() == b.toString());
    }
    for (const auto &key : {"feature", "table", "flow", "container", "figure", "style", "rule_style", "text_align"}) require(!present(first.value(QLatin1String(key))));
    require(first.value("spans").isArray() && !first.value("spans").toArray().isEmpty());
    QString text;
    for (const auto &value : first.value("spans").toArray()) {
        const auto span = object(value); const auto kind = span.value("kind");
        require(kind == QStringLiteral("text") || kind == QStringLiteral("link") || kind == QStringLiteral("external_link"));
        require(!present(span.value("image")) && span.value("text").isString() && !span.value("text").toString().isEmpty());
        const auto direction = span.value("direction");
        require(!present(direction) || (direction.isString() && direction.toString().isEmpty()));
        const auto tail = span.value("trail"); require(!present(tail) || (tail.isString() && tail.toString().isEmpty()));
        text += span.value("text").toString();
    }
    require(text == section.value("title").toString());
    return style;
}
inline QJsonObject identity(const QJsonObject &section) {
    validate(section);
    QJsonObject result;
    for (const auto &key : {"level", "title", "anchor", "anchor_fallback", "heading_style"})
        if (section.contains(QLatin1String(key))) result.insert(QLatin1String(key), section.value(QLatin1String(key)));
    // The owner binds its heading, not a second copy of every following body block.
    result.insert("blocks", QJsonArray{section.value("blocks").toArray().first()});
    return result;
}
inline QJsonObject projection(const QJsonObject &section) {
    const auto style = validate(section);
    auto paragraph = section.value("blocks").toArray().first().toObject();
    paragraph.insert("kind", QStringLiteral("paragraph")); paragraph.insert("level", 0);
    return QJsonObject{{"kind", "container"}, {"depth", 0}, {"spans", QJsonArray{}},
        {"container", QJsonObject{{"style", style.value("box")}, {"blocks", QJsonArray{paragraph}}}}};
}
inline QFont ownerFont(const QJsonObject &section, const QFont &context, qreal normalBodyPoints) {
    const auto style = validate(section); const auto owner = SemanticHtml::inlineFontSnapshot(style.value("font"));
    QFont font = context;
    const qreal points = normalBodyPoints * owner.value("font_scale").toDouble();
    CompiledContent::require(std::isfinite(points) && points >= 0);
    if (points > 0) font.setPointSizeF(points);
    font.setBold(owner.value("bold").toBool()); font.setItalic(owner.value("italic").toBool());
    SemanticHtml::applyFontFamily(font, style.value("box").toObject().value("font_family"));
    QTextCharFormat format; format.setFont(font);
    SemanticHtml::applyFontFeatures(format, SemanticHtml::fontFeaturePolicy(owner.value("font_features")), context);
    return format.font().resolve(font);
}
}
