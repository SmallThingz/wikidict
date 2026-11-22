#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <stdexcept>
#include <cmath>
#include <limits>
#include <functional>

// Walk semantic containers in authored order. A non-null block array is
// authoritative even when empty; captions and scopes never borrow Block.spans.
namespace CompiledContent {
// Shared semantic table budget; Container/Flow/Ruby depth remains independent.
inline constexpr int maxTableDepth = 32;
inline bool present(const QJsonValue &value) { return !value.isNull() && !value.isUndefined(); }
inline void require(bool condition) {
    if (!condition) throw std::runtime_error("invalid compiled content ownership");
}
inline QJsonArray array(const QJsonValue &value) {
    require(!present(value) || value.isArray());
    return value.toArray();
}
inline QJsonObject object(const QJsonValue &value) {
    require(value.isObject());
    return value.toObject();
}
inline QJsonObject inlineBoxGroup(const QJsonObject &span);
// A later data-only owner must never disappear into the legacy leaf renderer.
// Null fields keep the complete legacy path, including legacy unknown metadata.
inline void requireSupportedFinalYGeometry(const QJsonValue &value) {
    if (value.isArray()) {
        for (const auto &child : value.toArray()) requireSupportedFinalYGeometry(child);
    } else if (value.isObject()) {
        const auto object = value.toObject();
        if (present(object.value(QStringLiteral("inline_box_group"))))
            inlineBoxGroup(object);
        for (auto it = object.begin(); it != object.end(); ++it)
            if (it->isArray() || it->isObject()) requireSupportedFinalYGeometry(*it);
    }
}

// Current DPRL Container fields only. Later private responsive/overflow fields
// must not be admitted before the matching native layout protocol exists.
inline QJsonObject containerObject(const QJsonValue &value, const QStringList &keys,
                                   const QStringList &required = {}) {
    const auto result = object(value);
    for (auto it = result.begin(); it != result.end(); ++it) require(keys.contains(it.key()));
    for (const auto &key : required) require(result.contains(key));
    return result;
}
inline double containerNumber(const QJsonValue &value) {
    require(value.isDouble());
    const double number = value.toDouble();
    require(std::isfinite(number) && number >= 0 && number <= std::numeric_limits<float>::max());
    return number;
}
inline void containerLength(const QJsonValue &value, bool percentage = false) {
    const auto length = containerObject(value, {QStringLiteral("unit"), QStringLiteral("value")},
                                        {QStringLiteral("unit"), QStringLiteral("value")});
    const auto unit = length.value(QStringLiteral("unit"));
    require(unit.isString() && (unit == QStringLiteral("px") || unit == QStringLiteral("em")
        || (percentage && unit == QStringLiteral("percent"))));
    containerNumber(length.value(QStringLiteral("value")));
}
inline void containerEdges(const QJsonValue &value) {
    const QStringList keys{QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
    const auto edges = containerObject(value, keys, keys);
    for (const auto &key : keys) containerLength(edges.value(key));
}
inline void inlineBoxText(const QString &text) {
    require(text.isValidUtf16());
    for (char32_t scalar : text.toUcs4()) {
        const auto direction = QChar::direction(scalar);
        // Same finite scalar exclusions as the source issuer and native parser.
        // Private-use/unassigned characters keep ordinary Qt fallback shaping.
        require(!(scalar <= 0x1f || (scalar >= 0x7f && scalar <= 0x9f)
            || scalar == 0xfffc || scalar == 0x2028 || scalar == 0x2029
            || scalar == 0x061c || scalar == 0x200e || scalar == 0x200f
            || (scalar >= 0x202a && scalar <= 0x202e)
            || (scalar >= 0x2066 && scalar <= 0x2069)
            || scalar == 0x00ad || scalar == 0x200b || scalar == 0x2060 || scalar == 0xfeff
            || direction == QChar::DirR || direction == QChar::DirAL));
    }
    // The native shaper still proves source custody, LTR runs and real cluster
    // boundaries. Scalar admission does not grant a new layout owner.
}
// A source-bound border owner keeps inherited currentColor unresolved until
// native drawing. Empty overlays contribute paint, never text or advance.
inline bool inlineBoxUsesBorderSource(const QJsonObject &span) {
    const auto group = span.value("inline_box_group").toObject();
    if (!group.value("overlays").toArray().isEmpty()) return true;
    if (present(span.value("foreground"))) return false;
    const auto border = group.value("border").toObject();
    for (const auto key : {"top", "right", "bottom", "left"})
        if (border.value(key).toObject().value("solid").toObject().value("color").toObject().contains("current_color")) return true;
    return false;
}
inline void inlineBoxBorder(const QJsonValue &value, const QJsonObject &span, bool sourceBound, bool rounded = false) {
    const auto border = containerObject(value, {"top", "right", "bottom", "left"},
        {"top", "right", "bottom", "left"});
    for (const auto key : {"top", "right", "bottom", "left"}) {
        const auto edge = object(border.value(key)); require(edge.size() == 1);
        const auto tag = edge.keys().first();
        require((tag == "none" || (!sourceBound && tag == "hidden") || tag == "solid"
            || (rounded && !sourceBound && tag == "dotted")) && edge.value(tag).isObject());
        if (tag == "solid" || tag == "dotted") {
            const auto solid = containerObject(edge.value(tag), {"width", "color"}, {"width", "color"});
            containerLength(solid.value("width"));
            const auto color = object(solid.value("color")); require(color.size() == 1);
            const auto colorTag = color.keys().first();
            if (colorTag == "rgb") {
                const auto rgb = color.value(colorTag); const QString spelling = rgb.toString();
                require(rgb.isString() && spelling.size() == 7 && spelling.front() == '#');
                for (QChar c : spelling.mid(1)) require((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
            } else {
                require((colorTag == "transparent" || colorTag == "current_color")
                    && color.value(colorTag).isObject() && color.value(colorTag).toObject().isEmpty());
                if (colorTag == "current_color" && !sourceBound) require(span.value("foreground").isString());
            }
        } else require(edge.value(tag).toObject().isEmpty());
    }
}
inline bool inlineBoxHelpOnly(const QJsonValue &value) {
    if (!present(value)) return true;
    if (!value.isObject()) return false;
    const auto style = value.toObject();
    const QStringList keys{"cursor", "decoration", "line_height", "baseline_shift", "font_normalized", "wrap"};
    for (auto it = style.begin(); it != style.end(); ++it) if (!keys.contains(it.key())) return false;
    if (style.value("cursor") != QJsonValue(QStringLiteral("help"))) return false;
    if (style.contains("font_normalized") && (!style.value("font_normalized").isBool()
        || style.value("font_normalized").toBool())) return false;
    for (const char *key : {"decoration", "line_height", "baseline_shift", "wrap"})
        if (present(style.value(QLatin1String(key)))) return false;
    return true;
}
inline bool hasNestedPitchChildren(const QJsonObject &owner)
{
    for (const auto &value : owner.value("inline_box_group").toObject().value("spans").toArray())
        if (value.toObject().value("inline_box_group").isObject()) return true;
    return false;
}
// One relative pitch owner, with one or two separated single-character rings.
// The semantic tree stays intact; flattened leaves are only the text import.
inline bool nestedPitchSource(const QJsonObject &owner, QJsonArray *leaves = nullptr,
                              QList<QPair<int, QJsonObject>> *circles = nullptr)
{
    const auto present = [](const QJsonValue &v) { return !v.isUndefined() && !v.isNull(); };
    const auto length = [](const char *unit, double value) {
        return QJsonObject{{"unit", QString::fromLatin1(unit)}, {"value", value}};
    };
    const QJsonObject none{{"none", QJsonObject{}}};
    const QJsonObject stroke{{"solid", QJsonObject{{"width", length("px", 1)},
        {"color", QJsonObject{{"current_color", QJsonObject{}}}}}}};
    const QJsonObject dotted{{"dotted", QJsonObject{{"width", length("px", 1)},
        {"color", QJsonObject{{"rgb", QStringLiteral("#808080")}}}}}};
    const auto ordinary = [&](const QJsonObject &span) {
        if (span.value("kind") != QJsonValue(QStringLiteral("text"))
            || !span.value("text").isString() || span.value("target") != QJsonValue(QString())
            || span.value("trail") != QJsonValue(QString()) || span.value("direction") != QJsonValue(QString())) return false;
        for (const char *key : {"image", "ruby", "inline_padding_group", "inline_action_group", "inline_box",
             "clipped_absolute", "citation_marker", "audio_control", "audio", "inline_style", "link_paint",
             "target_fragment", "background", "tooltip"}) if (present(span.value(QLatin1StringView(key)))) return false;
        for (const char *key : {"underline", "strike", "superscript", "subscript"})
            if (present(span.value(QLatin1StringView(key))) && span.value(QLatin1StringView(key)) != QJsonValue(false)) return false;
        return true;
    };
    const auto text = [&](const QJsonObject &span) {
        const QString s = span.value("text").toString();
        if (!ordinary(span) || present(span.value("inline_box_group")) || s.isEmpty() || !s.isValidUtf16()) return false;
        for (char32_t c : s.toUcs4())
            if (QChar::isSpace(c) || c <= 0x1f || (c >= 0x7f && c <= 0x9f)
                || c == 0xfffc || c == 0x2028 || c == 0x2029 || c == 0x061c || c == 0x200e || c == 0x200f
                || (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)
                || c == 0x00ad || c == 0x200b || c == 0x2060 || c == 0xfeff
                || QChar::direction(c) == QChar::DirR || QChar::direction(c) == QChar::DirAL) return false;
        return true;
    };
    const auto style = [](QJsonObject span) {
        span.remove("text"); span.remove("trail"); span.remove("inline_box_group");
        for (const auto &key : span.keys()) if (span.value(key).isNull()) span.remove(key);
        for (const char *key : {"bold", "italic", "code", "small", "underline", "strike", "superscript", "subscript"})
            if (span.value(QLatin1StringView(key)) == QJsonValue(false)) span.remove(QLatin1StringView(key));
        return span;
    };
    const auto groupShape = [&](const QJsonObject &g, double padding) {
        const QStringList allowed{"padding", "border", "overlays", "spans", "radius"};
        for (const auto &key : g.keys()) if (!allowed.contains(key)) return false;
        if (!g.value("padding").isObject() || g.value("padding").toObject().size() != 4
            || !g.value("border").isObject() || g.value("border").toObject().size() != 4
            || !g.value("overlays").isArray() || !g.value("spans").isArray()) return false;
        for (const char *key : {"top", "right", "bottom", "left"})
            if (g.value("padding").toObject().value(QLatin1StringView(key)) != length("px", padding)) return false;
        return true;
    };
    const auto group = owner.value("inline_box_group").toObject();
    if (!ordinary(owner) || !owner.value("text").toString().isEmpty()
        || present(group.value("radius"))) return false;
    const QJsonObject border{{"top", stroke}, {"right", none}, {"bottom", none}, {"left", none}};
    const QJsonObject indicator{{"insets", QJsonObject{{"top", length("px", 0)}, {"right", length("percent", 0)},
        {"bottom", length("percent", 67)}, {"left", QJsonValue(QJsonValue::Null)}}},
        {"border", QJsonObject{{"top", none}, {"right", stroke}, {"bottom", none}, {"left", none}}}};
    const auto overlays = group.value("overlays").toArray();
    if (group.value("border") != border) return false;
    if (overlays.isEmpty()) {
        // A level pitch has no drop marker or surrounding padding.
        if (!groupShape(group, 0)) return false;
    } else if (!groupShape(group, 1) || overlays.size() != 1 || overlays.first() != indicator) {
        return false;
    }
    QJsonArray flattened; QList<QPair<int, QJsonObject>> nested;
    bool previousCircle = false, plain = false; int offset = 0;
    for (const auto &value : group.value("spans").toArray()) {
        if (!value.isObject()) return false;
        const auto span = value.toObject();
        if (style(span) != style(owner)) return false;
        QJsonObject leaf = span;
        if (present(span.value("inline_box_group"))) {
            const auto child = span.value("inline_box_group").toObject();
            if (previousCircle || nested.size() == 2 || !ordinary(span) || !span.value("text").toString().isEmpty()
                || !groupShape(child, 0) || !child.value("overlays").toArray().isEmpty()
                || child.value("radius") != length("percent", 50) || child.value("spans").toArray().size() != 1) return false;
            for (const char *key : {"top", "right", "bottom", "left"})
                if (child.value("border").toObject().value(QLatin1StringView(key)) != dotted) return false;
            leaf = child.value("spans").toArray().first().toObject();
            if (!text(leaf) || leaf.value("text").toString().size() != 1 || leaf.value("text").toString().front().isSurrogate()
                || style(leaf) != style(owner)) return false;
            nested.append({offset, span}); previousCircle = true;
        } else {
            if (!text(span)) return false;
            plain = true; previousCircle = false;
        }
        const int size = leaf.value("text").toString().size();
        if (size > (1 << 20) - offset) return false;
        offset += size; flattened.append(leaf);
    }
    if (nested.isEmpty() || !plain) return false;
    if (leaves) *leaves = flattened;
    if (circles) *circles = nested;
    return true;
}

inline QJsonObject inlineBoxGroup(const QJsonObject &span) {
    if (hasNestedPitchChildren(span)) {
        require(nestedPitchSource(span));
        return span.value("inline_box_group").toObject();
    }
    // This first native domain keeps ordinary child runs and their actions.
    // More complex owners are rejected before an empty owner can render away.
    const bool wholeLink = span.value("kind") == QStringLiteral("link");
    require((span.value("kind") == QStringLiteral("text") || wholeLink)
        && span.value("text").isString() && span.value("text").toString().isEmpty()
        && span.value("trail").isString() && span.value("trail").toString().isEmpty()
        && (wholeLink ? span.value("target").isString() && !span.value("target").toString().isEmpty()
                      : span.value("target").toString().isEmpty()));
    for (const auto key : {"image", "ruby", "inline_action_group", "inline_padding_group",
                           "link_paint", "target_fragment", "audio_control", "citation_marker"})
        require(!present(span.value(key)));
    require(!span.value("superscript").toBool() && !span.value("subscript").toBool()
        && (!present(span.value("direction")) || span.value("direction").toString().isEmpty()));
    if (present(span.value("background"))) {
        const auto value = span.value("background"); const QString rgb = value.toString();
        require(value.isString() && rgb.size() == 7 && rgb.front() == '#');
        for (QChar c : rgb.mid(1)) require((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
    }
    const auto group = containerObject(span.value("inline_box_group"),
        {"padding", "border", "overlays", "spans", "radius"}, {"padding", "border", "overlays", "spans"});
    const bool rounded = present(group.value("radius"));
    const bool sourceBound = inlineBoxUsesBorderSource(span);
    // Help is metric-free on an ordinary actionless label too. It does not
    // authorize child actions, source-bound overlays or richer inline styles.
    bool plainHelp = !rounded && !wholeLink && !sourceBound
        && present(span.value("inline_style")) && inlineBoxHelpOnly(span.value("inline_style"))
        && group.value("overlays").isArray() && group.value("overlays").toArray().isEmpty();
    if (plainHelp) {
        const auto children = group.value("spans").toArray();
        plainHelp = !children.isEmpty();
        for (const auto &raw : children) {
            const auto child = raw.toObject();
            plainHelp = plainHelp && raw.isObject() && child.value("kind") == QJsonValue(QStringLiteral("text"))
                && child.value("target") == QJsonValue(QString());
        }
    }
    require(inlineBoxHelpOnly(span.value("inline_style"))
        && (rounded || plainHelp || !present(span.value("inline_style"))));
    if (rounded) {
        const auto radius = containerObject(group.value("radius"), {"unit", "value"}, {"unit", "value"});
        require((radius.value("unit") == QStringLiteral("px") || radius.value("unit") == QStringLiteral("percent"))
            && radius.value("value").isDouble()
            && std::isfinite(radius.value("value").toDouble()) && radius.value("value").toDouble() >= 0
            && radius.value("value").toDouble() <= std::numeric_limits<float>::max());
    }
    containerEdges(group.value("padding"));
    require(group.value("overlays").isArray());
    const auto border = group.value("border").toObject();
    inlineBoxBorder(group.value("border"), span, sourceBound, rounded);
    if (sourceBound) {
        require(!rounded && !wholeLink && span.value("target") == QJsonValue(QString())
            && span.value("direction") == QJsonValue(QString()));
        for (const auto key : {"inline_box", "audio"}) require(!present(span.value(key)));
        if (present(span.value("foreground"))) {
            const auto value = span.value("foreground"); const QString rgb = value.toString();
            require(value.isString() && rgb.size() == 7 && rgb.front() == '#');
            for (QChar c : rgb.mid(1)) require((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
        }
        const auto overlays = group.value("overlays").toArray(); require(overlays.size() <= 64);
        for (const auto &raw : overlays) {
            const auto overlay = containerObject(raw, {"insets", "border"}, {"insets", "border"});
            inlineBoxBorder(overlay.value("border"), span, true);
            const auto insets = containerObject(overlay.value("insets"), {"top", "right", "bottom", "left"},
                {"top", "right", "bottom", "left"});
            for (const auto key : {"top", "right", "bottom", "left"}) {
                const auto value = insets.value(key); if (value.isNull()) continue;
                const auto length = containerObject(value, {"unit", "value"}, {"unit", "value"});
                require((length.value("unit") == QStringLiteral("px") || length.value("unit") == QStringLiteral("percent"))
                    && length.value("value").isDouble() && std::isfinite(length.value("value").toDouble())
                    && std::abs(length.value("value").toDouble()) <= std::numeric_limits<float>::max());
            }
            require((!insets.value("top").isNull() || !insets.value("bottom").isNull())
                && (!insets.value("left").isNull() || !insets.value("right").isNull()));
        }
    }
    if (rounded || wholeLink) {
        const auto edge = border.value("top").toObject();
        const QString style = edge.keys().first();
        require((style == "solid" || (rounded && style == "dotted"))
            && edge.value(style).toObject().value("color").toObject().contains("rgb"));
        for (const auto key : {"right", "bottom", "left"}) require(border.value(key) == border.value("top"));
    }
    require(group.value("spans").isArray());
    const auto children = group.value("spans").toArray();
    require(!children.isEmpty() && children.size() <= (1 << 20));
    if (wholeLink || sourceBound) require(children.size() == 1);
    QString source;
    for (const auto &raw : children) {
        const auto child = object(raw); const auto kind = child.value("kind").toString();
        require(kind == "text" || kind == "link" || kind == "external_link");
        if (sourceBound) {
            require(kind == "text" && child.value("target") == QJsonValue(QString())
                && child.value("direction") == QJsonValue(QString()));
            for (const auto key : {"inline_box", "audio", "target_fragment"}) require(!present(child.value(key)));
            require(!present(child.value("foreground")) || child.value("foreground") == span.value("foreground"));
        }
        if (wholeLink) {
            require(kind == "text" && child.value("target") == QJsonValue(QString())
                && !present(child.value("target_fragment")));
            // This branch materializes one owner over its original plain text.
            // It cannot flatten a separately styled or actionable descendant.
            const auto effectiveStyle = [](QJsonObject value) {
                for (const auto key : {"kind", "text", "trail", "target", "inline_box_group"}) value.remove(key);
                for (const auto &key : value.keys()) if (value.value(key).isNull()) value.remove(key);
                return value;
            };
            require(effectiveStyle(child) == effectiveStyle(span));
        }
        require(child.value("text").isString() && child.value("trail").isString());
        for (const auto key : {"image", "ruby", "inline_action_group", "inline_padding_group", "inline_box_group",
                               "link_paint", "audio_control", "citation_marker"}) require(!present(child.value(key)));
        require(inlineBoxHelpOnly(child.value("inline_style"))
            && (rounded || plainHelp || !present(child.value("inline_style"))));
        // Effective child style may repeat its declaring owner's background.
        // Different child paint remains outside this single static box domain.
        if (present(child.value("background")))
            require(present(span.value("background")) && child.value("background") == span.value("background"));
        require(!child.value("superscript").toBool() && !child.value("subscript").toBool()
            && (!present(child.value("direction")) || child.value("direction").toString().isEmpty()));
        const QString text = child.value("text").toString() + child.value("trail").toString();
        require(!text.isEmpty() && text.size() <= (1 << 20) - source.size());
        inlineBoxText(text);
        source += text;
    }
    const bool childLink = !wholeLink && !sourceBound && !rounded && children.size() == 1
        && children.first().toObject().value("kind") == "link";
    if (childLink) {
        const auto child = children.first().toObject();
        require(span.value("target") == QJsonValue(QString()) && child.value("target").isString() && !child.value("target").toString().isEmpty()
            && !present(child.value("target_fragment")));
    } else require(children.first().toObject().value("kind") == "text"
        && children.last().toObject().value("kind") == "text");
    require(!source.front().isSpace() && !source.back().isSpace());
    return group;
}
inline void containerMargins(const QJsonValue &value) {
    const QStringList keys{QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
    const auto edges = containerObject(value, keys, keys);
    for (const auto &key : keys) {
        const auto length = containerObject(edges.value(key), {QStringLiteral("unit"), QStringLiteral("value")},
            {QStringLiteral("unit"), QStringLiteral("value")});
        require(length.value(QStringLiteral("unit")) == QStringLiteral("px")
            || length.value(QStringLiteral("unit")) == QStringLiteral("em"));
        const auto number = length.value(QStringLiteral("value"));
        require(number.isDouble() && std::isfinite(number.toDouble())
            && std::abs(number.toDouble()) <= std::numeric_limits<float>::max());
    }
}
inline QString containerUnion(const QJsonValue &value, const QStringList &keys) {
    const auto tagged = containerObject(value, keys);
    require(tagged.size() == 1);
    return tagged.begin().key();
}
inline void containerMarginValues(const QJsonValue &value) {
    const QStringList keys{QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
    const auto edges = containerObject(value, keys, keys);
    for (const auto &key : keys) {
        const auto tag = containerUnion(edges.value(key), {QStringLiteral("auto"), QStringLiteral("length")});
        const auto payload = edges.value(key).toObject().value(tag);
        if (tag == QStringLiteral("auto")) require(containerObject(payload, {}).isEmpty());
        else {
            const auto length = containerObject(payload, {QStringLiteral("unit"), QStringLiteral("value")},
                {QStringLiteral("unit"), QStringLiteral("value")});
            require(length.value(QStringLiteral("unit")) == QStringLiteral("px")
                || length.value(QStringLiteral("unit")) == QStringLiteral("em"));
            const auto number = length.value(QStringLiteral("value"));
            require(number.isDouble() && std::isfinite(number.toDouble())
                && std::abs(number.toDouble()) <= std::numeric_limits<float>::max());
        }
    }
}
inline void containerWidth(const QJsonValue &value, bool maximum = false) {
    const QString kind = containerUnion(value, maximum
        ? QStringList{QStringLiteral("none"), QStringLiteral("length")}
        : QStringList{QStringLiteral("auto"), QStringLiteral("length"), QStringLiteral("fit_content")});
    if (kind == QStringLiteral("length")) containerLength(value.toObject().value(kind), true);
    else require(containerObject(value.toObject().value(kind), {}).isEmpty());
}
inline void containerRgb(const QJsonValue &value) {
    require(value.isString());
    const auto color = value.toString();
    require(color.size() == 7 && color.front() == QChar('#'));
    for (const auto c : color.mid(1)) require((c >= QChar('0') && c <= QChar('9')) || (c >= QChar('a') && c <= QChar('f')));
}
inline void containerColor(const QJsonValue &value) {
    const auto kind = containerUnion(value, {QStringLiteral("transparent"), QStringLiteral("rgb"), QStringLiteral("light_dark")});
    const auto data = value.toObject().value(kind);
    if (kind == QStringLiteral("transparent")) require(containerObject(data, {}).isEmpty());
    else if (kind == QStringLiteral("rgb")) containerRgb(data);
    else {
        const auto pair = containerObject(data, {QStringLiteral("light"), QStringLiteral("dark")},
                                         {QStringLiteral("light"), QStringLiteral("dark")});
        containerRgb(pair.value(QStringLiteral("light"))); containerRgb(pair.value(QStringLiteral("dark")));
    }
}
inline QJsonObject ruleStyle(const QJsonObject &block) {
    const auto value = block.value(QStringLiteral("rule_style"));
    if (!present(value)) return {};
    containerObject(block, {QStringLiteral("kind"), QStringLiteral("depth"), QStringLiteral("level"),
        QStringLiteral("spans"), QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("anchor"),
        QStringLiteral("anchor_fallback"), QStringLiteral("feature"), QStringLiteral("table"), QStringLiteral("figure"),
        QStringLiteral("flow"), QStringLiteral("container"), QStringLiteral("style"), QStringLiteral("text_align"), QStringLiteral("rule_style")});
    require(block.value(QStringLiteral("kind")) == QStringLiteral("rule"));
    for (const auto &key : {QStringLiteral("depth"), QStringLiteral("level")}) {
        const auto field = block.value(key);
        require(field.isUndefined() || (field.isDouble() && field.toDouble() == 0));
    }
    for (const auto &key : {QStringLiteral("spans")}) {
        const auto field = block.value(key);
        require(field.isUndefined() || (field.isArray() && field.toArray().isEmpty()));
    }
    for (const auto &key : {QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("anchor"), QStringLiteral("anchor_fallback")}) {
        const auto field = block.value(key);
        require(field.isUndefined() || (field.isString() && field.toString().isEmpty()));
    }
    for (const auto &key : {QStringLiteral("feature"), QStringLiteral("table"), QStringLiteral("figure"),
            QStringLiteral("flow"), QStringLiteral("container"), QStringLiteral("style"), QStringLiteral("text_align")})
        require(!present(block.value(key)));
    const QStringList keys{QStringLiteral("height"), QStringLiteral("fill"), QStringLiteral("margins")};
    auto allowed = keys; allowed.append(QStringLiteral("clear"));
    const auto style = containerObject(value, allowed, keys);
    const auto clear = style.value(QStringLiteral("clear"));
    if (present(clear)) require(clear.isString() && QStringList{QStringLiteral("none"), QStringLiteral("left"),
        QStringLiteral("right"), QStringLiteral("both")}.contains(clear.toString()));
    containerLength(style.value(QStringLiteral("height")));
    containerColor(style.value(QStringLiteral("fill")));
    containerEdges(style.value(QStringLiteral("margins")));
    return style;
}

inline void containerLineHeight(const QJsonValue &value) {
    const auto kind = containerUnion(value, {QStringLiteral("normal"), QStringLiteral("multiplier"), QStringLiteral("length")});
    const auto data = value.toObject().value(kind);
    if (kind == QStringLiteral("normal")) require(containerObject(data, {}).isEmpty());
    else if (kind == QStringLiteral("multiplier")) containerNumber(data);
    else containerLength(data);
}
inline void containerBorderEdge(const QJsonValue &value) {
    const auto kind = containerUnion(value, {QStringLiteral("none"), QStringLiteral("hidden"),
        QStringLiteral("solid"), QStringLiteral("dotted")});
    const auto payload = value.toObject().value(kind);
    if (kind == QStringLiteral("none") || kind == QStringLiteral("hidden"))
        require(containerObject(payload, {}).isEmpty());
    else {
        const auto edge = containerObject(payload, {QStringLiteral("width"), QStringLiteral("color")},
            {QStringLiteral("width"), QStringLiteral("color")});
        containerLength(edge.value(QStringLiteral("width"))); containerColor(edge.value(QStringLiteral("color")));
    }
}
inline QJsonValue containerFontFamily(const QJsonValue &value) {
    if (!present(value)) return {};
    if (value.isString()) { require(value.toString() == QStringLiteral("sans_serif")); return value; }
    const auto outer = containerObject(value, {QStringLiteral("stack")}, {QStringLiteral("stack")});
    const auto stack = containerObject(outer.value(QStringLiteral("stack")),
        {QStringLiteral("names"), QStringLiteral("fallback")}, {QStringLiteral("names"), QStringLiteral("fallback")});
    require(stack.value(QStringLiteral("names")).isArray()
        && stack.value(QStringLiteral("names")).toArray().size() <= 16
        && stack.value(QStringLiteral("fallback")).isString()
        && (stack.value(QStringLiteral("fallback")) == QStringLiteral("serif")
            || stack.value(QStringLiteral("fallback")) == QStringLiteral("sans_serif")));
    const QStringList aliases{QStringLiteral("serif"), QStringLiteral("sans-serif"), QStringLiteral("sans serif"),
        QStringLiteral("sans"), QStringLiteral("monospace"), QStringLiteral("cursive"), QStringLiteral("fantasy"),
        QStringLiteral("system"), QStringLiteral("system-ui"), QStringLiteral("ui-serif"), QStringLiteral("ui-sans-serif"),
        QStringLiteral("ui-monospace"), QStringLiteral("ui-rounded"), QStringLiteral("emoji"), QStringLiteral("math"), QStringLiteral("fangsong")};
    for (const auto &item : stack.value(QStringLiteral("names")).toArray()) {
        require(item.isString()); const auto name = item.toString();
        require(!name.isEmpty() && name.size() <= 128 && name.front() != QChar(' ') && name.back() != QChar(' '));
        for (const auto ch : name) require(ch.unicode() >= 0x20 && ch.unicode() <= 0x7e && ch != QChar('[') && ch != QChar(']'));
        require(!aliases.contains(name.simplified().toLower()));
    }
    return value;
}
inline QJsonObject fontSnapshot(const QJsonValue &value) {
    const QStringList keys{"font_scale", "font_scale_basis", "small", "superscript", "subscript", "font_normalized",
        "bold", "italic", "code", "language", "classes", "role", "font_features", "font_family"};
    auto font = containerObject(value, keys);
    for (const auto &key : {"font_scale", "font_features", "font_family"}) if (!font.contains(key)) font.insert(key, QJsonValue());
    if (!font.contains("font_scale_basis")) font.insert("font_scale_basis", "context");
    for (const auto &key : {"small", "superscript", "subscript", "font_normalized", "bold", "italic", "code"})
        if (!font.contains(key)) font.insert(key, false);
    for (const auto &key : {"language", "classes"}) if (!font.contains(key)) font.insert(key, "");
    if (!font.contains("role")) font.insert("role", "normal");
    const auto basis = font.value("font_scale_basis");
    if (basis != QStringLiteral("context") && basis != QStringLiteral("normal_body") && basis != QStringLiteral("css_px"))
        throw std::runtime_error("invalid inline font snapshot basis");
    if (present(font.value("font_scale"))) containerNumber(font.value("font_scale"));
    if (basis != QStringLiteral("context") && !present(font.value("font_scale")))
        throw std::runtime_error("inline font snapshot missing scale");
    for (const auto &key : {"small", "superscript", "subscript", "font_normalized", "bold", "italic", "code"})
        if (!font.value(key).isBool()) throw std::runtime_error("invalid inline font snapshot flag");
    for (const auto &key : {"language", "classes", "role"})
        if (!font.value(key).isString() || font.value(key).toString().contains(QChar(0))) throw std::runtime_error("invalid inline font snapshot string");
    const QStringList roles{"normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference"};
    if (!roles.contains(font.value("role").toString())) throw std::runtime_error("invalid inline font snapshot role");
    const auto features = font.value("font_features");
    require(!present(features) || (features.isString() && (features == QStringLiteral("normal") || features == QStringLiteral("seven_on"))));
    containerFontFamily(font.value("font_family"));
    if (font.value("font_normalized").toBool() && basis == QStringLiteral("context"))
        throw std::runtime_error("normalized inline font snapshot needs explicit basis");
    if (basis == QStringLiteral("context") && present(font.value("font_scale")) && font.value("font_scale").toDouble() == 1)
        font.insert("font_scale", QJsonValue());
    return font;
}
inline QJsonObject containerOwnerFont(const QJsonObject &style) {
    const auto value = style.value(QStringLiteral("owner_font"));
    if (!present(value)) return {};
    const auto font = fontSnapshot(value);
    require(font.value("font_normalized").toBool() && font.value("font_scale").isDouble()
        && (font.value("font_scale_basis") == QStringLiteral("normal_body")
            || font.value("font_scale_basis") == QStringLiteral("css_px")));
    require(!present(style.value("positioning")) || style.value("positioning") == QStringLiteral("relative_auto"));
    if (present(style.value("owner_font_scale")))
        require(font.value("font_scale_basis") == QStringLiteral("normal_body")
            && font.value("font_scale") == style.value("owner_font_scale"));
    if (present(style.value("font_family")))
        require(present(font.value("font_family")) && font.value("font_family") == style.value("font_family"));
    return font;
}
inline QJsonObject bodyTypography(const QJsonValue &value) {
    if (!present(value)) return {};
    const auto body = containerObject(value, {QStringLiteral("owner_font"), QStringLiteral("line_height")},
        {QStringLiteral("owner_font")});
    require(present(body.value("owner_font")));
    containerOwnerFont(QJsonObject{{"owner_font", body.value("owner_font")}});
    if (present(body.value("line_height"))) containerLineHeight(body.value("line_height"));
    return body;
}

// BODY initially admits ordinary root text only. Nearer frame/cell/figure
// typography and non-text inline owners need a separate ownership bridge.
inline void requireBodyTextBlock(const QJsonObject &block) {
    const auto kind = block.value("kind").toString();
    if (kind == "heading" || kind == "rule" || kind == "blank") return;
    require(kind == "paragraph" || kind == "definition" || kind == "list_item"
        || kind == "list_detail" || kind == "indent" || kind == "term"
        || kind == "example" || kind == "quotation");
    for (const auto key : {"flow", "figure", "container", "table", "feature", "style"})
        require(!present(block.value(QLatin1String(key))));
    require(block.value("spans").isArray());
    bool text = false;
    for (const auto &value : block.value("spans").toArray()) {
        require(value.isObject()); const auto span = value.toObject();
        const auto spanKind = span.value("kind").toString();
        require(spanKind == "text" || spanKind == "link" || spanKind == "external_link"
            || spanKind == "line_break");
        for (const auto key : {"image", "ruby", "inline_action_group", "inline_padding_group", "inline_box_group"})
            require(!present(span.value(QLatin1String(key))));
        // Paragraph-marked poem blocks and owner-specific numeric policies are
        // not silently assigned to a root BODY strut by this initial domain.
        require(!span.value("classes").toString().contains("poem"));
        text |= !span.value("text").toString().isEmpty() || !span.value("trail").toString().isEmpty();
    }
    require(text);
}

inline QJsonObject containerStyle(const QJsonValue &value) {
    if (value.isUndefined()) return {};
    const auto style = containerObject(value, {QStringLiteral("margins"), QStringLiteral("padding"),
        QStringLiteral("width"), QStringLiteral("float_side"), QStringLiteral("clear"), QStringLiteral("max_width"),
        QStringLiteral("box_sizing"), QStringLiteral("layout"), QStringLiteral("align_items"), QStringLiteral("flex_item"),
        QStringLiteral("background"), QStringLiteral("border"), QStringLiteral("line_height"),
        QStringLiteral("text_align"), QStringLiteral("screen_max_width"), QStringLiteral("owner_font_scale"), QStringLiteral("height"), QStringLiteral("columns"), QStringLiteral("positioning"), QStringLiteral("min_height"), QStringLiteral("margin_values"), QStringLiteral("overflow"), QStringLiteral("font_family"), QStringLiteral("owner_font"),
        QStringLiteral("absolute_position"), QStringLiteral("text_wrap")});
    const auto enumeration = [](const QJsonObject &owner, const QString &key, const QStringList &choices) {
        const auto field = owner.value(key);
        if (present(field)) require(field.isString() && choices.contains(field.toString()));
    };
    containerFontFamily(style.value(QStringLiteral("font_family")));
    containerOwnerFont(style);
    if (present(style.value(QStringLiteral("margins")))) containerMargins(style.value(QStringLiteral("margins")));
    if (present(style.value(QStringLiteral("margin_values")))) {
        require(!present(style.value(QStringLiteral("margins"))));
        containerMarginValues(style.value(QStringLiteral("margin_values")));
    }
    if (present(style.value(QStringLiteral("padding")))) containerEdges(style.value(QStringLiteral("padding")));
    if (present(style.value(QStringLiteral("width")))) containerWidth(style.value(QStringLiteral("width")));
    if (present(style.value(QStringLiteral("max_width")))) containerWidth(style.value(QStringLiteral("max_width")), true);
    enumeration(style, QStringLiteral("overflow"), {QStringLiteral("visible"), QStringLiteral("auto")});
    enumeration(style, QStringLiteral("float_side"), {QStringLiteral("left"), QStringLiteral("right")});
    enumeration(style, QStringLiteral("clear"), {QStringLiteral("none"), QStringLiteral("left"), QStringLiteral("right"), QStringLiteral("both")});
    enumeration(style, QStringLiteral("box_sizing"), {QStringLiteral("content_box"), QStringLiteral("border_box")});
    enumeration(style, QStringLiteral("layout"), {QStringLiteral("flow"), QStringLiteral("flex_row")});
    enumeration(style, QStringLiteral("align_items"), {QStringLiteral("stretch"), QStringLiteral("start"), QStringLiteral("center"), QStringLiteral("end")});
    enumeration(style, QStringLiteral("flex_item"), {QStringLiteral("none")});
    enumeration(style, QStringLiteral("text_align"), {QStringLiteral("left"), QStringLiteral("center"), QStringLiteral("right")});
    enumeration(style, QStringLiteral("text_wrap"), {QStringLiteral("normal"), QStringLiteral("nowrap")});
    require(!present(style.value(QStringLiteral("align_items"))) || style.value(QStringLiteral("layout")) == QStringLiteral("flex_row"));
    if (present(style.value(QStringLiteral("background")))) containerColor(style.value(QStringLiteral("background")));
    if (present(style.value(QStringLiteral("border")))) {
        const auto border = style.value(QStringLiteral("border"));
        const auto kind = containerUnion(border, {QStringLiteral("none"), QStringLiteral("solid"), QStringLiteral("edges")});
        if (kind == QStringLiteral("none")) require(containerObject(border.toObject().value(kind), {}).isEmpty());
        else if (kind == QStringLiteral("edges")) {
            const QStringList keys{QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
            const auto edges = containerObject(border.toObject().value(kind), keys, keys);
            for (const auto &key : keys) containerBorderEdge(edges.value(key));
        }
        else {
            const auto solid = containerObject(border.toObject().value(kind), {QStringLiteral("width"), QStringLiteral("color")},
                                               {QStringLiteral("width"), QStringLiteral("color")});
            containerLength(solid.value(QStringLiteral("width"))); containerColor(solid.value(QStringLiteral("color")));
        }
    }
    if (present(style.value(QStringLiteral("line_height")))) containerLineHeight(style.value(QStringLiteral("line_height")));
    if (present(style.value(QStringLiteral("owner_font_scale")))) containerNumber(style.value(QStringLiteral("owner_font_scale")));
    if (present(style.value(QStringLiteral("height")))) containerLength(style.value(QStringLiteral("height")));
    if (present(style.value(QStringLiteral("min_height")))) {
        containerLength(style.value(QStringLiteral("min_height")));
        require(!present(style.value(QStringLiteral("columns")))
            && style.value(QStringLiteral("layout")) != QStringLiteral("flex_row"));
    }
    if (present(style.value(QStringLiteral("positioning"))))
        require(style.value(QStringLiteral("positioning")) == QStringLiteral("relative_auto"));
    if (present(style.value(QStringLiteral("absolute_position")))) {
        const auto absolute = containerObject(style.value(QStringLiteral("absolute_position")),
            {QStringLiteral("left"), QStringLiteral("top")}, {QStringLiteral("left"), QStringLiteral("top")});
        for (const auto &key : {QStringLiteral("left"), QStringLiteral("top")}) {
            const auto length = containerObject(absolute.value(key), {QStringLiteral("unit"), QStringLiteral("value")},
                {QStringLiteral("unit"), QStringLiteral("value")});
            const auto number = length.value(QStringLiteral("value"));
            require((length.value(QStringLiteral("unit")) == QStringLiteral("px")
                || length.value(QStringLiteral("unit")) == QStringLiteral("em"))
                && number.isDouble() && std::isfinite(number.toDouble())
                && std::abs(number.toDouble()) <= std::numeric_limits<float>::max());
        }
        for (const auto key : {"positioning", "float_side", "clear", "columns", "layout", "align_items", "flex_item",
                              "max_width", "min_height", "screen_max_width", "overflow"})
            require(!present(style.value(QLatin1String(key))));
        const auto width = style.value(QStringLiteral("width")).toObject();
        require(width.size() == 1 && width.contains(QStringLiteral("length"))
            && width.value(QStringLiteral("length")).toObject().value(QStringLiteral("unit")) != QStringLiteral("percent")
            && present(style.value(QStringLiteral("height"))));
        for (const auto key : {"padding", "margins"}) if (present(style.value(QLatin1String(key))))
            for (const auto &edge : style.value(QLatin1String(key)).toObject())
                require(edge.toObject().value(QStringLiteral("value")).toDouble() == 0);
        if (present(style.value(QStringLiteral("margin_values"))))
            for (const auto &edge : style.value(QStringLiteral("margin_values")).toObject()) {
                const auto tagged = edge.toObject();
                require(tagged.size() == 1 && tagged.contains(QStringLiteral("length"))
                    && tagged.value(QStringLiteral("length")).toObject().value(QStringLiteral("value")).toDouble() == 0);
            }
        require(!present(style.value(QStringLiteral("border"))) || style.value(QStringLiteral("border")).toObject().contains(QStringLiteral("none")));
        require(!present(style.value(QStringLiteral("background"))) || style.value(QStringLiteral("background")).toObject().contains(QStringLiteral("transparent")));
        require(!present(style.value(QStringLiteral("box_sizing"))) || style.value(QStringLiteral("box_sizing")) == QStringLiteral("content_box"));
    }
    if (present(style.value(QStringLiteral("columns")))) {
        const auto columns = containerObject(style.value(QStringLiteral("columns")),
            {QStringLiteral("count"), QStringLiteral("gap")}, {QStringLiteral("count"), QStringLiteral("gap")});
        const auto count = columns.value(QStringLiteral("count"));
        require(count.isDouble() && std::isfinite(count.toDouble()) && count.toDouble() >= 1
            && count.toDouble() <= 65535 && std::floor(count.toDouble()) == count.toDouble());
        containerLength(columns.value(QStringLiteral("gap")));
        require(!present(style.value(QStringLiteral("height")))
            && style.value(QStringLiteral("layout")) != QStringLiteral("flex_row"));
    }
    if (present(style.value(QStringLiteral("screen_max_width")))) {
        const auto root = object(style.value(QStringLiteral("screen_max_width")));
        QJsonArray rules{root};
        const auto following = root.value(QStringLiteral("following_rules"));
        if (present(following)) {
            require(following.isArray());
            for (const auto &rule : following.toArray()) rules.append(rule);
        }
        require(rules.size() <= 16);
        qreal previous = 4294967296.0;
        for (qsizetype index = 0; index < rules.size(); ++index) {
            const auto screen = containerObject(rules[index],
                {QStringLiteral("max_width_px"), QStringLiteral("width"), QStringLiteral("max_width"),
                 QStringLiteral("box_sizing"), QStringLiteral("line_height"), QStringLiteral("float_side"),
                 QStringLiteral("margins"), QStringLiteral("clear"), QStringLiteral("following_rules")}, {QStringLiteral("max_width_px")});
            const auto bound = screen.value(QStringLiteral("max_width_px"));
            require(bound.isDouble() && std::isfinite(bound.toDouble()) && bound.toDouble() >= 0
                && bound.toDouble() < previous && std::floor(bound.toDouble()) == bound.toDouble());
            previous = bound.toDouble();
            if (index && present(screen.value(QStringLiteral("following_rules"))))
                require(screen.value(QStringLiteral("following_rules")).isArray() && screen.value(QStringLiteral("following_rules")).toArray().isEmpty());
            bool hasOverride = false;
            for (const auto &key : {QStringLiteral("width"), QStringLiteral("max_width"), QStringLiteral("box_sizing"),
                    QStringLiteral("line_height"), QStringLiteral("float_side"), QStringLiteral("margins"), QStringLiteral("clear")})
                hasOverride |= present(screen.value(key));
            require(hasOverride);
            if (present(screen.value(QStringLiteral("width")))) containerWidth(screen.value(QStringLiteral("width")));
            if (present(screen.value(QStringLiteral("max_width")))) containerWidth(screen.value(QStringLiteral("max_width")), true);
            if (present(screen.value(QStringLiteral("line_height")))) containerLineHeight(screen.value(QStringLiteral("line_height")));
            if (present(screen.value(QStringLiteral("margins")))) containerMarginValues(screen.value(QStringLiteral("margins")));
            enumeration(screen, QStringLiteral("box_sizing"), {QStringLiteral("content_box"), QStringLiteral("border_box")});
            enumeration(screen, QStringLiteral("float_side"), {QStringLiteral("none"), QStringLiteral("left"), QStringLiteral("right")});
            enumeration(screen, QStringLiteral("clear"), {QStringLiteral("none"), QStringLiteral("left"), QStringLiteral("right"), QStringLiteral("both")});
        }
    }
    return style;
}
inline bool containerVerticalMargins(const QJsonValue &value) {
    if (!present(value)) return false;
    containerEdges(value);
    const auto edges = value.toObject();
    return edges.value(QStringLiteral("top")).toObject().value(QStringLiteral("value")).toDouble() != 0
        || edges.value(QStringLiteral("bottom")).toObject().value(QStringLiteral("value")).toDouble() != 0;
}
inline QJsonObject containerBlock(const QJsonObject &block, int depth = 1) {
    require(depth <= 16);
    containerObject(block, {QStringLiteral("kind"), QStringLiteral("depth"), QStringLiteral("spans"),
        QStringLiteral("feature"), QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("level"),
        QStringLiteral("anchor"), QStringLiteral("anchor_fallback"), QStringLiteral("table"), QStringLiteral("text_align"),
        QStringLiteral("style"), QStringLiteral("figure"), QStringLiteral("flow"), QStringLiteral("container")},
        {QStringLiteral("kind"), QStringLiteral("spans"), QStringLiteral("container")});
    require(block.value(QStringLiteral("kind")) == QStringLiteral("container")
        && block.value(QStringLiteral("spans")).isArray() && block.value(QStringLiteral("spans")).toArray().isEmpty());
    for (const auto &key : {QStringLiteral("depth"), QStringLiteral("level")}) {
        const auto value = block.value(key);
        require(value.isUndefined() || (value.isDouble() && value.toDouble() == 0));
    }
    for (const auto &key : {QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("anchor"), QStringLiteral("anchor_fallback")}) {
        const auto value = block.value(key);
        require(value.isUndefined() || (value.isString() && value.toString().isEmpty()));
    }
    for (const auto &key : {QStringLiteral("feature"), QStringLiteral("table"), QStringLiteral("text_align"),
         QStringLiteral("style"), QStringLiteral("figure"), QStringLiteral("flow")}) require(!present(block.value(key)));
    const auto owned = containerObject(block.value(QStringLiteral("container")), {QStringLiteral("blocks"), QStringLiteral("style")}, {QStringLiteral("blocks")});
    require(owned.value(QStringLiteral("blocks")).isArray() && owned.value(QStringLiteral("blocks")).toArray().size() <= (1 << 20));
    const auto style = containerStyle(owned.value(QStringLiteral("style")));
    // Native admission owns signed ordinary margins; child BlockStyle spacing remains a separate protocol.
    for (const auto &value : owned.value(QStringLiteral("blocks")).toArray()) {
        const auto child = object(value);
        require(child.value(QStringLiteral("kind")) != QStringLiteral("heading"));
        if (present(child.value(QStringLiteral("style")))) {
            const auto childStyle = object(child.value(QStringLiteral("style")));
            require(!containerVerticalMargins(childStyle.value(QStringLiteral("margins"))));
        }
        if (child.value(QStringLiteral("kind")) == QStringLiteral("container") || present(child.value(QStringLiteral("container"))))
            containerBlock(child, depth + 1);
    }
    return owned;
}

inline QJsonObject figureSpan(const QJsonObject &figure) {
    const bool missing = figure.contains(QStringLiteral("missing_content"));
    require(missing != figure.contains(QStringLiteral("image_span"))
        && figure.contains(QStringLiteral("sizing")) == !missing);
    if (!missing) return object(figure.value(QStringLiteral("image_span")));
    return object(object(figure.value(QStringLiteral("missing_content"))).value(QStringLiteral("label")));
}
inline bool listRole(const QString &kind) {
    return QStringList{QStringLiteral("list_item"), QStringLiteral("definition"), QStringLiteral("example"),
        QStringLiteral("quotation"), QStringLiteral("term"), QStringLiteral("list_detail"), QStringLiteral("indent")}.contains(kind);
}
inline bool contentRole(const QJsonObject &block) {
    return listRole(block.value(QStringLiteral("kind")).toString())
        || (block.value(QStringLiteral("kind")).toString() == QStringLiteral("paragraph")
            && block.value(QStringLiteral("depth")).toInt() == 0
            && block.value(QStringLiteral("list_path")).toString().isEmpty());
}
inline QJsonObject scope(const QJsonValue &value) {
    const QJsonObject result = object(value);
    const QStringList keys{QStringLiteral("mode"), QStringLiteral("authored_direction"),
        QStringLiteral("resolved_direction"), QStringLiteral("language"), QStringLiteral("parts")};
    require(result.size() == keys.size());
    for (const QString &key : keys) require(result.contains(key));
    const QString mode = result.value(QStringLiteral("mode")).toString();
    const QString direction = result.value(QStringLiteral("resolved_direction")).toString();
    const QJsonValue authored = result.value(QStringLiteral("authored_direction"));
    const QJsonValue language = result.value(QStringLiteral("language"));
    require((mode == QStringLiteral("isolate") || mode == QStringLiteral("isolate_override"))
        && (direction == QStringLiteral("ltr") || direction == QStringLiteral("rtl"))
        && (language.isNull() || language.isString()) && result.value(QStringLiteral("parts")).isArray());
    require(authored.isNull() || (authored.isString()
        && QStringList{QStringLiteral("ltr"), QStringLiteral("rtl"), QStringLiteral("auto")}.contains(authored.toString())));
    if (authored.toString() == QStringLiteral("ltr") || authored.toString() == QStringLiteral("rtl"))
        require(authored.toString() == direction);
    if (mode == QStringLiteral("isolate_override"))
        require(authored.toString() == QStringLiteral("ltr") || authored.toString() == QStringLiteral("rtl"));
    return result;
}

struct Depth {
    int content = 0;
    int tables = 0;
    Depth nestedContent() const { require(content < 16); return {content + 1, tables}; }
    Depth nestedTable() const { require(tables < maxTableDepth); return {content, tables + 1}; }
};

enum class TableSpans { Stored, VisibleBody };

struct Context {
    QString language;
    // Value-owned because some metadata visitors retain Context after walking.
    // Only the direct Figure-media visit carries this ownership evidence.
    QJsonObject figureMediaOwner;
    int contentDepth = 0;
};
inline QString languageForSpan(const QJsonObject &span, const Context &context) {
    // Empty Span.language is the legacy default; only Scope.language can reset.
    const QString explicitLanguage = span.value(QStringLiteral("language")).toString();
    return explicitLanguage.isEmpty() ? context.language : explicitLanguage;
}

// Opt-in plain fallback/metadata traversal. Container Walker visitors keep their
// existing array ownership; only these side consumers request structural leaves.
// Synthetic Ruby delimiters go to literal, never to the metadata leaf callback.
template <typename Leaf, typename Literal, typename Skip>
inline void visitSpanLeaves(const QJsonArray &spans, Context context,
                            Leaf &leaf, Literal &literal, Skip &skip) {
    qsizetype remaining = 1 << 20;
    const auto charge = [](qsizetype count, qsizetype &budget) {
        require(count >= 0 && count <= budget); budget -= count;
    };
    using LeafFn = std::function<void(const QJsonObject &, const Context &)>;
    using TextFn = std::function<void(const QString &)>;
    const auto walk = [&](auto &&self, const QJsonArray &values, Context inherited,
                          int depth, int rubyDepth, qsizetype &budget,
                          const LeafFn &visitLeaf, const TextFn &text, bool probing) -> void {
        require(depth <= 16 && rubyDepth <= 16);
        charge(values.size(), budget);
        for (const auto &raw : values) {
            const auto span = object(raw);
            if (skip(span)) continue;
            Context local = inherited;
            local.contentDepth = depth;
            if (present(span.value("language"))) require(span.value("language").isString());
            local.language = languageForSpan(span, inherited);
            if (present(span.value("inline_box_group"))) {
                require(depth < 16);
                const auto group = inlineBoxGroup(span);
                self(self, group.value("spans").toArray(), local, depth + 1, rubyDepth, budget, visitLeaf, text, probing);
                continue;
            }
            const bool action = present(span.value("inline_action_group"));
            const bool padding = present(span.value("inline_padding_group"));
            const bool ruby = present(span.value("ruby"));
            require(int(action) + int(padding) + int(ruby) <= 1);
            if (action || padding || ruby) {
                require(depth < 16 && !present(span.value("image"))
                    && span.value("text").isString() && span.value("text").toString().isEmpty()
                    && span.value("trail").isString() && span.value("trail").toString().isEmpty());
            }
            if (action || padding) {
                const auto group = containerObject(span.value(action ? "inline_action_group" : "inline_padding_group"),
                    action ? QStringList{"spans"} : QStringList{"left", "right", "spans"},
                    action ? QStringList{"spans"} : QStringList{"left", "right", "spans"});
                require(group.value("spans").isArray() && !group.value("spans").toArray().isEmpty());
                if (padding) {
                    containerLength(group.value("left")); containerLength(group.value("right"));
                    require(group.value("left").toObject().value("value").toDouble() != 0
                        || group.value("right").toObject().value("value").toDouble() != 0);
                }
                self(self, group.value("spans").toArray(), local, depth + 1, rubyDepth, budget, visitLeaf, text, probing);
            } else if (ruby) {
                require(rubyDepth < 16);
                const auto payload = containerObject(span.value("ruby"), {"segments"}, {"segments"});
                require(payload.value("segments").isArray());
                const auto segments = payload.value("segments").toArray(); charge(segments.size(), budget);
                for (const auto &rawSegment : segments) {
                    const auto segment = object(rawSegment);
                    const auto children = [&](const QJsonObject &owner, const char *key) {
                        require(owner.value(key).isArray()); return owner.value(key).toArray();
                    };
                    self(self, children(segment, "gap_before"), local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                    for (const auto &key : {"bases", "annotations"}) {
                        const auto owners = children(segment, key); charge(owners.size(), budget);
                        for (const auto &rawOwner : owners) {
                            charge(1, budget);
                            const auto owner = object(rawOwner);
                            self(self, children(owner, "gap_before"), local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                            const auto body = children(owner, "spans");
                            if (QLatin1StringView(key) == QLatin1StringView("bases")) {
                                self(self, body, local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                            } else {
                                require(owner.value("explicit_fallback").isBool());
                                if (owner.value("explicit_fallback").toBool()) {
                                    self(self, children(owner, "fallback_before"), local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                                    self(self, body, local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                                    self(self, children(owner, "fallback_after"), local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                                } else {
                                    require(children(owner, "fallback_before").isEmpty()
                                        && children(owner, "fallback_after").isEmpty());
                                    // Probe against a copy of the same remaining budget, not a
                                    // fresh per-sibling allowance. No metadata/actions escape.
                                    auto probeBudget = budget; bool nonempty = false;
                                    auto probeLeaf = [&](const QJsonObject &part, const Context &) {
                                        nonempty |= !part.value("text").toString().isEmpty() || !part.value("trail").toString().isEmpty();
                                    };
                                    auto probeLiteral = [&](const QString &part) { nonempty |= !part.isEmpty(); };
                                    if (!probing) self(self, body, local, depth + 1, rubyDepth + 1, probeBudget, probeLeaf, probeLiteral, true);
                                    if (!probing && nonempty) text(QString(QChar(0xff08)));
                                    self(self, body, local, depth + 1, rubyDepth + 1, budget, visitLeaf, text, probing);
                                    if (!probing && nonempty) text(QString(QChar(0xff09)));
                                }
                            }
                        }
                    }
                }
            } else visitLeaf(span, local);
        }
    };
    const LeafFn visitLeaf = leaf; const TextFn text = literal;
    walk(walk, spans, context, context.contentDepth, 0, remaining, visitLeaf, text, false);
}

template <typename Visitor> class Walker {
public:
    Walker(Visitor &visitor, TableSpans tableSpans) : visit_(visitor), tableSpans_(tableSpans) {}
    void blocks(const QJsonArray &values, Depth depth = {}, Context context = {}) {
        for (const QJsonValue &value : values) block(object(value), depth, context);
    }
    void block(const QJsonObject &value, Depth depth = {}, Context context = {}) {
        ruleStyle(value);
        const QJsonArray spans = array(value.value(QStringLiteral("spans")));
        const QJsonValue flow = value.value(QStringLiteral("flow"));
        const QJsonValue figureValue = value.value(QStringLiteral("figure"));
        const QJsonValue tableValue = value.value(QStringLiteral("table"));
        if (value.value(QStringLiteral("kind")) == QStringLiteral("container") || present(value.value(QStringLiteral("container")))) {
            const auto owned = containerBlock(value);
            blocks(owned.value(QStringLiteral("blocks")).toArray(), depth.nestedContent(), context);
        } else if (present(flow)) {
            require(flow.isArray() && value.value(QStringLiteral("spans")).isArray() && spans.isEmpty() && contentRole(value)
                && !present(tableValue) && !present(figureValue) && !present(value.value(QStringLiteral("feature"))));
            parts(flow.toArray(), depth.nestedContent(), context);
        } else if (present(figureValue)) {
            require(value.value(QStringLiteral("spans")).isArray() && spans.isEmpty() && contentRole(value) && !present(tableValue)
                && !present(value.value(QStringLiteral("feature"))) && !present(value.value(QStringLiteral("style"))));
            figure(object(figureValue), depth, context);
        } else {
            // Old codec records permit both fields. Metadata walkers retain
            // both; visible-body projection keeps the established table priority.
            if (present(tableValue)) {
                if (tableSpans_ == TableSpans::Stored) visitSpans(spans, depth, context);
                table(object(tableValue), depth.nestedTable(), context);
            }
            else visitSpans(spans, depth, context);
        }
    }
    void parts(const QJsonArray &values, Depth depth, Context context = {}) {
        for (const QJsonValue &value : values) {
            const QJsonObject part = object(value);
            const QString kind = part.value(QStringLiteral("kind")).toString();
            require(part.value(QStringLiteral("spans")).isArray());
            const QJsonArray spans = array(part.value(QStringLiteral("spans")));
            const QJsonValue image = part.value(QStringLiteral("figure"));
            const QJsonValue group = part.value(QStringLiteral("scope"));
            if (kind == QStringLiteral("inline")) {
                require(!present(image) && !present(group));
                visitSpans(spans, depth, context);
            } else if (kind == QStringLiteral("figure")) {
                require(spans.isEmpty() && !present(group));
                figure(object(image), depth, context);
            } else {
                require(kind == QStringLiteral("scope") && spans.isEmpty() && !present(image));
                const QJsonObject ownedScope = scope(group);
                Context nested = context;
                if (!ownedScope.value(QStringLiteral("language")).isNull())
                    nested.language = ownedScope.value(QStringLiteral("language")).toString();
                parts(ownedScope.value(QStringLiteral("parts")).toArray(), depth.nestedContent(), nested);
            }
        }
    }
    void figure(const QJsonObject &value, Depth depth, Context context = {}) {
        require(value.value(QStringLiteral("caption")).isArray());
        Context content = context; content.figureMediaOwner = {};
        Context media = content; media.figureMediaOwner = value;
        visitSpans(QJsonArray{figureSpan(value)}, depth, media);
        caption(value, depth, content);
    }
    void table(const QJsonObject &value, Depth depth, Context context = {}) {
        caption(value, depth, context);
        for (const QJsonValue &row : array(value.value(QStringLiteral("rows")))) {
            for (const QJsonValue &cellValue : array(object(row).value(QStringLiteral("cells")))) {
                const QJsonObject cell = object(cellValue);
                const QJsonArray spans = array(cell.value(QStringLiteral("spans")));
                const QJsonValue owned = cell.value(QStringLiteral("blocks"));
                const QJsonValue nested = cell.value(QStringLiteral("nested_table"));
                if (present(owned)) {
                    // Present-empty is authoritative, but inactive legacy
                    // payloads must still obey the shared exclusive cell modes.
                    require(owned.isArray() && spans.isEmpty() && !present(nested));
                    blocks(owned.toArray(), depth, context);
                } else if (present(nested)) {
                    require(spans.isEmpty());
                    table(object(nested), depth.nestedTable(), context);
                } else visitSpans(spans, depth, context);
            }
        }
    }
    void reference(const QJsonObject &value, Context context = {}) {
        const Depth depth;
        const QJsonArray spans = array(value.value(QStringLiteral("spans")));
        const QJsonValue owned = value.value(QStringLiteral("blocks"));
        if (present(owned)) {
            require(owned.isArray() && spans.isEmpty());
            blocks(owned.toArray(), {}, context);
        } else visitSpans(spans, depth, context);
    }
    void entry(const QJsonObject &value) {
        QString language = value.value(QStringLiteral("language_code")).toString();
        if (language.isEmpty()) language = value.value(QStringLiteral("language")).toString();
        const Context context{language};
        visitSpans(array(value.value(QStringLiteral("display_title"))), {}, context);
        visitSpans(array(value.value(QStringLiteral("preamble_spans"))), {}, context);
        for (const QJsonValue &section : array(value.value(QStringLiteral("sections"))))
            blocks(array(object(section).value(QStringLiteral("blocks"))), {}, context);
        for (const QJsonValue &ref : array(value.value(QStringLiteral("references")))) reference(object(ref), context);
    }
private:
    void visitSpans(const QJsonArray &spans, Depth depth, Context context) {
        context.contentDepth = depth.content;
        visit_(spans, context);
    }
    void caption(const QJsonObject &value, Depth depth, Context context = {}) {
        const QJsonArray spans = array(value.value(QStringLiteral("caption")));
        const QJsonValue owned = value.value(QStringLiteral("caption_blocks"));
        if (present(owned)) {
            require(owned.isArray() && spans.isEmpty());
            blocks(owned.toArray(), depth.nestedContent(), context);
        } else visitSpans(spans, depth, context);
    }
    Visitor &visit_;
    TableSpans tableSpans_;
};
}
