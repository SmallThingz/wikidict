#pragma once
#include <QColor>
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QList>
#include <array>
#include <cmath>
#include <limits>
#include <optional>
#include <stdexcept>
// Data-only local JSON view; the shared decoder owns duplicate-key/wire validation.
namespace CompiledDisclosure {
inline void require(bool value) { if (!value) throw std::runtime_error("invalid compiled disclosure"); }
inline bool present(const QJsonValue &value) { return !value.isNull() && !value.isUndefined(); }
inline QJsonObject containerObject(const QJsonValue &value, const QStringList &allowed, const QStringList &required = {}) {
    require(value.isObject()); const auto object = value.toObject();
    for (auto it = object.begin(); it != object.end(); ++it) require(allowed.contains(it.key()));
    for (const auto &key : required) require(object.contains(key));
    return object;
}
inline void canonicalRgb(const QJsonValue &value) {
    require(value.isString()); const auto color = value.toString();
    require(color.size() == 7 && color[0] == QChar('#'));
    for (const auto c : color.mid(1)) require((c >= QChar('0') && c <= QChar('9')) || (c >= QChar('a') && c <= QChar('f')));
}

inline qreal pixels(const QJsonValue &value, bool positive = false, bool signedValue = false) {
    const auto object = containerObject(value, {"unit", "value"}, {"unit", "value"});
    const auto number = object.value("value");
    require(object.value("unit") == QStringLiteral("px") && number.isDouble());
    const double result = number.toDouble();
    require(std::isfinite(result) && std::abs(result) <= std::numeric_limits<float>::max());
    require((signedValue || result >= 0) && (!positive || result > 0));
    return result;
}

inline QColor figureColor(const QJsonValue &value, bool rgbOnly = false) {
    const auto object = containerObject(value, {"kind", "value"}, {"kind"});
    const auto kind = object.value("kind");
    if (kind == QStringLiteral("rgb")) {
        canonicalRgb(object.value("value"));
        return QColor(object.value("value").toString());
    }
    require(!rgbOnly && kind == QStringLiteral("transparent") && !present(object.value("value")));
    return QColor(Qt::transparent);
}

inline QString namedFont(const QJsonValue &value) {
    const auto object = containerObject(value, {"name"}, {"name"});
    require(object.value("name").isString());
    const auto name = object.value("name").toString();
    require(!name.isEmpty() && name.size() <= 128 && name.front() != QChar(' ') && name.back() != QChar(' '));
    for (const auto ch : name) require(ch.unicode() >= 0x20 && ch.unicode() <= 0x7e && ch != QChar('[') && ch != QChar(']'));
    const QStringList aliases{"serif", "sans-serif", "sans serif", "sans", "monospace", "cursive", "fantasy",
        "system", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "emoji", "math", "fangsong"};
    require(!aliases.contains(name.simplified().toLower()));
    return name;
}

enum class BorderKind { None, Hidden, Solid, Dotted, Inset, Outset };
struct Border {
    BorderKind kind = BorderKind::None;
    qreal width = 0;
    QColor color;
};
struct State {
    QColor background;
    std::array<Border, 4> border;
};
struct Outline {
    qreal width = 0;
    QColor color;
    qreal radius = 0;
    qreal offset = 0;
};
struct OutlineColors { QColor unfocused, focused; };
struct ButtonModel {
    QString appearance;
    QString fontFamily;
    qreal fontSize = 0;
    int fontWeight = 400;
    bool fontItalic = false;
    std::optional<qreal> lineHeight;
    std::array<qreal, 4> padding;
    std::array<State, 4> states;
    std::optional<Outline> focusVisible;
    std::optional<OutlineColors> outlineColors;
};
inline int stateIndex(bool hover, bool active) { return (active ? 2 : 0) + (hover ? 1 : 0); }

inline ButtonModel buttonModel(const QJsonValue &value) {
    const QStringList required{"appearance", "font_family", "font_size", "font_weight", "font_italic",
        "line_height", "padding", "normal", "hover", "active", "hover_active"};
    const auto object = containerObject(value, required + QStringList{"focus_visible", "outline_colors"}, required);
    ButtonModel result;
    result.appearance = object.value("appearance").toString();
    // A present ButtonModel paints the declared states directly for either appearance.
    require(result.appearance == QStringLiteral("native_button") || result.appearance == QStringLiteral("none"));
    result.fontFamily = namedFont(object.value("font_family"));
    result.fontSize = pixels(object.value("font_size"), true);
    require(object.value("font_weight").isDouble() && object.value("font_weight").toDouble() == 400);
    require(object.value("font_italic").isBool() && !object.value("font_italic").toBool());
    const auto height = containerObject(object.value("line_height"), {"normal", "length"});
    require(height.size() == 1);
    if (height.contains("normal")) require(containerObject(height.value("normal"), {}).isEmpty());
    else result.lineHeight = pixels(height.value("length"), true);
    const QStringList sides{"top", "right", "bottom", "left"};
    const auto padding = containerObject(object.value("padding"), sides, sides);
    for (int i = 0; i < 4; ++i) result.padding[i] = pixels(padding.value(sides[i]));
    const QStringList states{"normal", "hover", "active", "hover_active"};
    const QStringList styles{"none", "hidden", "solid", "dotted", "inset", "outset"};
    for (int i = 0; i < 4; ++i) {
        const auto state = containerObject(object.value(states[i]), {"background", "border"}, {"background", "border"});
        result.states[i].background = figureColor(state.value("background"));
        const auto edges = containerObject(state.value("border"), sides, sides);
        for (int side = 0; side < 4; ++side) {
            const auto edge = containerObject(edges.value(sides[side]), styles);
            require(edge.size() == 1);
            const int kind = styles.indexOf(edge.begin().key());
            require(kind >= 0);
            auto &border = result.states[i].border[side];
            border.kind = static_cast<BorderKind>(kind);
            if (kind < 2) require(containerObject(edge.begin().value(), {}).isEmpty());
            else {
                const auto line = containerObject(edge.begin().value(), {"width", "paint"}, {"width", "paint"});
                border.width = pixels(line.value("width"));
                const auto paint = containerObject(line.value("paint"), {"rgb"}, {"rgb"});
                canonicalRgb(paint.value("rgb"));
                border.color = QColor(paint.value("rgb").toString());
            }
        }
    }
    if (present(object.value("focus_visible"))) {
        const auto focus = containerObject(object.value("focus_visible"), {"mode", "outline"}, {"mode", "outline"});
        require(focus.value("mode") == QStringLiteral("ua_auto"));
        const auto outline = containerObject(focus.value("outline"), {"width", "color", "radius", "offset"},
            {"width", "color", "radius", "offset"});
        result.focusVisible = Outline{pixels(outline.value("width"), true), figureColor(outline.value("color"), true),
            pixels(outline.value("radius")), pixels(outline.value("offset"), false, true)};
        require(result.focusVisible->radius == 0);
    }
    if (present(object.value("outline_colors"))) {
        const auto colors = containerObject(object.value("outline_colors"), {"unfocused", "focused"}, {"unfocused", "focused"});
        result.outlineColors = OutlineColors{figureColor(colors.value("unfocused"), true), figureColor(colors.value("focused"), true)};
    }
    return result;
}

inline std::optional<QColor> outlineColor(const ButtonModel &model, bool focused, bool focusVisible) {
    require(!focusVisible || focused);
    if (focusVisible && model.focusVisible) return model.focusVisible->color;
    if (model.outlineColors) return focused ? model.outlineColors->focused : model.outlineColors->unfocused;
    return {};
}

struct LabelPaint { QColor foreground; bool underline = false; };
struct LabelRun {
    quint32 start = 0, end = 0;
    int utf16Start = 0, utf16Length = 0;
    std::array<LabelPaint, 4> states;
    bool underlineOnFocus = false;
    bool pointerOnRun = false;
};
inline LabelPaint labelPaint(const LabelRun &run, bool hover, bool active, bool focused) {
    auto result = run.states[stateIndex(hover, active)];
    result.underline = result.underline || (focused && run.underlineOnFocus);
    return result;
}
inline quint32 unsignedIndex(const QJsonValue &value) {
    require(value.isDouble());
    const double number = value.toDouble();
    require(std::isfinite(number) && number >= 0 && number <= std::numeric_limits<quint32>::max() && std::floor(number) == number);
    return static_cast<quint32>(number);
}
inline QString label(const QJsonValue &value) {
    require(value.isString());
    const auto text = value.toString();
    require(text.isValidUtf16() && !text.isEmpty() && text.toUtf8().size() <= 32 * 1024 * 1024);
    for (const auto ch : text) require(ch.unicode() >= 0x20 && ch.unicode() != 0x7f);
    return text;
}
inline std::optional<LabelRun> labelRun(const QJsonValue &value, const QString &text) {
    if (!present(value)) return {};
    const auto object = containerObject(value, {"start", "end", "paint", "pointer_on_run"}, {"start", "end", "paint"});
    LabelRun result;
    if (object.contains("pointer_on_run")) {
        require(object.value("pointer_on_run").isBool());
        result.pointerOnRun = object.value("pointer_on_run").toBool();
    }
    result.start = unsignedIndex(object.value("start")); result.end = unsignedIndex(object.value("end"));
    const auto bytes = text.toUtf8();
    require(result.start < result.end && result.end <= quint64(bytes.size()));
    require((result.start == 0 || (static_cast<unsigned char>(bytes[result.start]) & 0xc0) != 0x80)
        && (result.end == quint64(bytes.size()) || (static_cast<unsigned char>(bytes[result.end]) & 0xc0) != 0x80));
    result.utf16Start = QString::fromUtf8(bytes.left(result.start)).size();
    result.utf16Length = QString::fromUtf8(bytes.mid(result.start, result.end - result.start)).size();
    const QStringList states{"normal", "hover", "active", "hover_active"};
    const auto paint = containerObject(object.value("paint"), states + QStringList{"underline_on_focus"}, states);
    for (int i = 0; i < 4; ++i) {
        const auto state = containerObject(paint.value(states[i]), {"foreground", "underline"}, {"foreground", "underline"});
        canonicalRgb(state.value("foreground"));
        require(state.value("underline").isBool());
        result.states[i] = {QColor(state.value("foreground").toString()), state.value("underline").toBool()};
    }
    if (paint.contains("underline_on_focus")) {
        require(paint.value("underline_on_focus").isBool());
        result.underlineOnFocus = paint.value("underline_on_focus").toBool();
    }
    return result;
}

struct Model {
    QJsonObject source;
    quint32 contentIndex = 0;
    bool initiallyCollapsed = false;
    QString expandLabel, collapseLabel, placement;
    std::optional<QColor> foreground;
    std::optional<Qt::LayoutDirection> direction;
    std::optional<LabelRun> expandRun, collapseRun;
    std::optional<ButtonModel> button;
    QJsonValue legacyFocus;
};
inline Model parse(const QJsonObject &owner) {
    const auto object = containerObject(owner.value("disclosure"), {"content_index", "initially_collapsed", "expand_label",
        "collapse_label", "focus", "placement", "foreground", "direction", "expand_run", "collapse_run", "button"},
        {"content_index", "initially_collapsed", "expand_label", "collapse_label"});
    Model result;
    result.source = owner;
    result.contentIndex = unsignedIndex(object.value("content_index"));
    require(owner.value("blocks").isArray());
    const auto blocks = owner.value("blocks").toArray();
    require(result.contentIndex < quint64(blocks.size()));
    require(blocks[result.contentIndex].isObject());
    const auto child = blocks[result.contentIndex].toObject();
    require(child.value("kind") == QStringLiteral("container") && child.value("container").isObject());
    require(object.value("initially_collapsed").isBool());
    result.initiallyCollapsed = object.value("initially_collapsed").toBool();
    result.expandLabel = label(object.value("expand_label")); result.collapseLabel = label(object.value("collapse_label"));
    result.placement = object.value("placement").isUndefined() ? QStringLiteral("inline_flow") : object.value("placement").toString();
    require(QStringList{"inline_flow", "float_left", "float_right"}.contains(result.placement));
    if (present(object.value("foreground"))) result.foreground = figureColor(object.value("foreground"));
    if (present(object.value("direction"))) {
        const auto direction = object.value("direction");
        require(direction == QStringLiteral("ltr") || direction == QStringLiteral("rtl"));
        result.direction = direction == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight;
    }
    result.expandRun = labelRun(object.value("expand_run"), result.expandLabel);
    result.collapseRun = labelRun(object.value("collapse_run"), result.collapseLabel);
    if ((result.expandRun && result.expandRun->pointerOnRun) || (result.collapseRun && result.collapseRun->pointerOnRun))
        require(present(object.value("button")));
    result.legacyFocus = object.value("focus");
    if (present(object.value("button"))) {
        require(!present(result.legacyFocus));
        result.button = buttonModel(object.value("button"));
    } else if (present(result.legacyFocus)) {
        const auto focus = containerObject(result.legacyFocus, {"mode", "color"}, {"mode"});
        const auto mode = focus.value("mode");
        require(mode == QStringLiteral("authored_none") || mode == QStringLiteral("ua_auto"));
        if (present(focus.value("color"))) {
            require(mode == QStringLiteral("ua_auto"));
            figureColor(focus.value("color"));
        }
    }
    // Full block/style validation remains with the existing public decoder and
    // CompiledContent host. This helper validates disclosure and child custody.
    return result;
}

struct Child { qsizetype index; QJsonObject block; };
inline QList<Child> visibleChildren(const Model &model, bool expanded) {
    const auto children = model.source.value("blocks").toArray();
    QList<Child> result;
    for (qsizetype index = 0; index < children.size(); ++index)
        if (expanded || index != model.contentIndex) {
            require(children[index].isObject()); result.append({index, children[index].toObject()});
        }
    return result;
}

}
