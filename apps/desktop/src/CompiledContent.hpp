#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <stdexcept>
#include <cmath>
#include <limits>

// Walk semantic containers in authored order. A non-null block array is
// authoritative even when empty; captions and scopes never borrow Block.spans.
namespace CompiledContent {
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
inline QString containerUnion(const QJsonValue &value, const QStringList &keys) {
    const auto tagged = containerObject(value, keys);
    require(tagged.size() == 1);
    return tagged.begin().key();
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
inline void containerLineHeight(const QJsonValue &value) {
    const auto kind = containerUnion(value, {QStringLiteral("normal"), QStringLiteral("multiplier"), QStringLiteral("length")});
    const auto data = value.toObject().value(kind);
    if (kind == QStringLiteral("normal")) require(containerObject(data, {}).isEmpty());
    else if (kind == QStringLiteral("multiplier")) containerNumber(data);
    else containerLength(data);
}
inline QJsonObject containerStyle(const QJsonValue &value) {
    if (value.isUndefined()) return {};
    const auto style = containerObject(value, {QStringLiteral("margins"), QStringLiteral("padding"),
        QStringLiteral("width"), QStringLiteral("float_side"), QStringLiteral("clear"), QStringLiteral("max_width"),
        QStringLiteral("box_sizing"), QStringLiteral("layout"), QStringLiteral("align_items"), QStringLiteral("flex_item"),
        QStringLiteral("background"), QStringLiteral("border"), QStringLiteral("line_height"),
        QStringLiteral("text_align"), QStringLiteral("screen_max_width")});
    const auto enumeration = [](const QJsonObject &owner, const QString &key, const QStringList &choices) {
        const auto field = owner.value(key);
        if (present(field)) require(field.isString() && choices.contains(field.toString()));
    };
    for (const auto &key : {QStringLiteral("margins"), QStringLiteral("padding")})
        if (present(style.value(key))) containerEdges(style.value(key));
    if (present(style.value(QStringLiteral("width")))) containerWidth(style.value(QStringLiteral("width")));
    if (present(style.value(QStringLiteral("max_width")))) containerWidth(style.value(QStringLiteral("max_width")), true);
    enumeration(style, QStringLiteral("float_side"), {QStringLiteral("left"), QStringLiteral("right")});
    enumeration(style, QStringLiteral("clear"), {QStringLiteral("none"), QStringLiteral("left"), QStringLiteral("right"), QStringLiteral("both")});
    enumeration(style, QStringLiteral("box_sizing"), {QStringLiteral("content_box"), QStringLiteral("border_box")});
    enumeration(style, QStringLiteral("layout"), {QStringLiteral("flow"), QStringLiteral("flex_row")});
    enumeration(style, QStringLiteral("align_items"), {QStringLiteral("stretch"), QStringLiteral("start"), QStringLiteral("center"), QStringLiteral("end")});
    enumeration(style, QStringLiteral("flex_item"), {QStringLiteral("none")});
    enumeration(style, QStringLiteral("text_align"), {QStringLiteral("left"), QStringLiteral("center"), QStringLiteral("right")});
    require(!present(style.value(QStringLiteral("align_items"))) || style.value(QStringLiteral("layout")) == QStringLiteral("flex_row"));
    if (present(style.value(QStringLiteral("background")))) containerColor(style.value(QStringLiteral("background")));
    if (present(style.value(QStringLiteral("border")))) {
        const auto border = style.value(QStringLiteral("border"));
        const auto kind = containerUnion(border, {QStringLiteral("none"), QStringLiteral("solid")});
        if (kind == QStringLiteral("none")) require(containerObject(border.toObject().value(kind), {}).isEmpty());
        else {
            const auto solid = containerObject(border.toObject().value(kind), {QStringLiteral("width"), QStringLiteral("color")},
                                               {QStringLiteral("width"), QStringLiteral("color")});
            containerLength(solid.value(QStringLiteral("width"))); containerColor(solid.value(QStringLiteral("color")));
        }
    }
    if (present(style.value(QStringLiteral("line_height")))) containerLineHeight(style.value(QStringLiteral("line_height")));
    if (present(style.value(QStringLiteral("screen_max_width")))) {
        const auto screen = containerObject(style.value(QStringLiteral("screen_max_width")),
            {QStringLiteral("max_width_px"), QStringLiteral("width"), QStringLiteral("max_width"),
             QStringLiteral("box_sizing"), QStringLiteral("line_height")}, {QStringLiteral("max_width_px")});
        const auto bound = screen.value(QStringLiteral("max_width_px"));
        require(bound.isDouble() && std::isfinite(bound.toDouble()) && bound.toDouble() >= 0
            && bound.toDouble() <= 4294967295.0 && std::floor(bound.toDouble()) == bound.toDouble());
        bool hasOverride = false;
        for (const auto &key : {QStringLiteral("width"), QStringLiteral("max_width"), QStringLiteral("box_sizing"), QStringLiteral("line_height")})
            hasOverride |= present(screen.value(key));
        require(hasOverride);
        if (present(screen.value(QStringLiteral("width")))) containerWidth(screen.value(QStringLiteral("width")));
        if (present(screen.value(QStringLiteral("max_width")))) containerWidth(screen.value(QStringLiteral("max_width")), true);
        enumeration(screen, QStringLiteral("box_sizing"), {QStringLiteral("content_box"), QStringLiteral("border_box")});
        if (present(screen.value(QStringLiteral("line_height")))) containerLineHeight(screen.value(QStringLiteral("line_height")));
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
    require(present(style.value(QStringLiteral("float_side"))) || !containerVerticalMargins(style.value(QStringLiteral("margins"))));
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
    Depth nestedTable() const { require(tables < 16); return {content, tables + 1}; }
};

enum class TableSpans { Stored, VisibleBody };

struct Context { QString language; };
inline QString languageForSpan(const QJsonObject &span, const Context &context) {
    // Empty Span.language is the legacy default; only Scope.language can reset.
    const QString explicitLanguage = span.value(QStringLiteral("language")).toString();
    return explicitLanguage.isEmpty() ? context.language : explicitLanguage;
}

template <typename Visitor> class Walker {
public:
    Walker(Visitor &visitor, TableSpans tableSpans) : visit_(visitor), tableSpans_(tableSpans) {}
    void blocks(const QJsonArray &values, Depth depth = {}, Context context = {}) {
        for (const QJsonValue &value : values) block(object(value), depth, context);
    }
    void block(const QJsonObject &value, Depth depth = {}, Context context = {}) {
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
                if (tableSpans_ == TableSpans::Stored) visit_(spans, context);
                table(object(tableValue), depth.nestedTable(), context);
            }
            else visit_(spans, context);
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
                visit_(spans, context);
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
        visit_(QJsonArray{figureSpan(value)}, context);
        caption(value, depth, context);
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
                } else visit_(spans, context);
            }
        }
    }
    void reference(const QJsonObject &value, Context context = {}) {
        const QJsonArray spans = array(value.value(QStringLiteral("spans")));
        const QJsonValue owned = value.value(QStringLiteral("blocks"));
        if (present(owned)) {
            require(owned.isArray() && spans.isEmpty());
            blocks(owned.toArray(), {}, context);
        } else visit_(spans, context);
    }
    void entry(const QJsonObject &value) {
        QString language = value.value(QStringLiteral("language_code")).toString();
        if (language.isEmpty()) language = value.value(QStringLiteral("language")).toString();
        const Context context{language};
        visit_(array(value.value(QStringLiteral("display_title"))), context);
        visit_(array(value.value(QStringLiteral("preamble_spans"))), context);
        for (const QJsonValue &section : array(value.value(QStringLiteral("sections"))))
            blocks(array(object(section).value(QStringLiteral("blocks"))), {}, context);
        for (const QJsonValue &ref : array(value.value(QStringLiteral("references")))) reference(object(ref), context);
    }
private:
    void caption(const QJsonObject &value, Depth depth, Context context = {}) {
        const QJsonArray spans = array(value.value(QStringLiteral("caption")));
        const QJsonValue owned = value.value(QStringLiteral("caption_blocks"));
        if (present(owned)) {
            require(owned.isArray() && spans.isEmpty());
            blocks(owned.toArray(), depth.nestedContent(), context);
        } else visit_(spans, context);
    }
    Visitor &visit_;
    TableSpans tableSpans_;
};
}
