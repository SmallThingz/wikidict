#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <stdexcept>

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
        if (present(flow)) {
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
