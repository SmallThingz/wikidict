#pragma once

#include "CompiledContent.hpp"
#include <QHash>
#include <QSet>
#include <QVector>

// Reference positions keep the original reference array and citation identities.
// The layout projection below is made only from a complete typed batch owner.
namespace CompiledReferences {
using CompiledContent::present;
using CompiledContent::require;
using CompiledContent::containerObject;
inline constexpr qsizetype itemLimit = 1 << 20;

inline quint32 integer(const QJsonValue &value, bool positive = false, bool fullCounter = false) {
    require(value.isDouble());
    const double number = value.toDouble();
    require(std::isfinite(number) && number >= (positive ? 1 : 0)
        && (fullCounter ? number <= double(std::numeric_limits<quint32>::max()) : number < double(std::numeric_limits<quint32>::max()))
        && std::floor(number) == number);
    return quint32(number);
}
inline QString fragment(const QJsonValue &value) {
    require(value.isString()); const auto text = value.toString();
    require(!text.isEmpty() && !text.contains(QChar(0)));
    for (QChar c : text) require(c.unicode() >= 0x20 && c.unicode() != 0x7f);
    return text;
}
inline QString referenceAnchor(const QJsonObject &reference) {
    return QStringLiteral("reference-%1").arg(integer(reference.value("number"), true));
}
inline QJsonObject typography(const QJsonValue &value) {
    if (!present(value)) return {};
    const auto result = containerObject(value, {"owner_font", "line_height", "direction"}, {"owner_font"});
    auto body = result; body.remove("direction"); CompiledContent::bodyTypography(body);
    const auto direction = result.value("direction");
    require(!present(direction) || direction == QStringLiteral("ltr") || direction == QStringLiteral("rtl"));
    return result;
}
inline QJsonObject citationLink(const QJsonValue &value) {
    const auto span = CompiledContent::object(value);
    require(span.value("kind") == QStringLiteral("link") && span.value("text").isString()
        && !span.value("text").toString().isEmpty() && span.value("target").toString().isEmpty()
        && span.value("trail").toString().isEmpty());
    fragment(span.value("target_fragment"));
    for (const auto key : {"audio_control", "image", "ruby", "inline_padding_group", "inline_action_group",
                           "inline_box_group", "clipped_absolute", "pending_container"})
        require(!present(span.value(key)));
    return span;
}
inline QJsonObject marker(const QJsonObject &span) {
    const auto value = span.value("citation_marker");
    if (!present(value)) return {};
    citationLink(span);
    // The native owned-nowrap range is one paragraph of ordinary text. It does
    // not replace structural breaks, tab stops or embedded objects.
    for (QChar character : span.value("text").toString()) {
        const auto scalar = character.unicode();
        require(scalar >= 0x20 && scalar != 0x7f && scalar != 0x2028
            && scalar != 0x2029 && scalar != 0xfffc);
    }
    const auto result = containerObject(value,
        {"reference", "occurrence", "anchor", "nowrap", "isolation", "target_style"},
        {"reference", "occurrence", "anchor"});
    const auto number = integer(result.value("reference"), true);
    integer(result.value("occurrence"), true); fragment(result.value("anchor"));
    require(span.value("role") == QStringLiteral("reference")
        && span.value("target_fragment") == QStringLiteral("reference-%1").arg(number));
    require(!result.contains("nowrap") || result.value("nowrap").isBool());
    const auto isolation = result.value("isolation");
    require(!present(isolation) || ((isolation == QStringLiteral("ltr") || isolation == QStringLiteral("rtl"))
        && span.value("direction").toString().isEmpty()));
    if (present(result.value("target_style"))) {
        const auto target = containerObject(result.value("target_style"), {"paint", "background"}, {"paint"});
        require(present(span.value("link_paint")) && target.value("paint").isObject());
        if (present(target.value("background"))) {
            const auto background = containerObject(target.value("background"), {"kind", "value"}, {"kind"});
            require(background.value("kind") == QStringLiteral("rgb") || background.value("kind") == QStringLiteral("transparent"));
        }
    }
    return result;
}
inline QJsonObject backlink(const QJsonValue &value) {
    const auto result = containerObject(value, {"occurrence", "span"}, {"occurrence", "span"});
    integer(result.value("occurrence"), true);
    const auto span = citationLink(result.value("span"));
    require(!present(span.value("citation_marker")));
    return result;
}
inline QJsonObject layoutStyle(const QJsonValue &value) {
    const auto result = CompiledContent::containerStyle(value);
    for (const auto key : {"margins", "padding", "border", "background", "owner_font"}) require(present(result.value(key)));
    require(CompiledContent::containerOwnerFont(result).value("font_normalized").toBool());
    const auto defaulted = [&](const char *key, const char *fallback) {
        return present(result.value(key)) ? result.value(key).toString() : QString::fromLatin1(fallback);
    };
    require(defaulted("layout", "flow") == QStringLiteral("flow")
        && defaulted("clear", "none") == QStringLiteral("none")
        && defaulted("overflow", "visible") == QStringLiteral("visible"));
    for (const auto key : {"width", "float_side", "max_width", "align_items", "flex_item", "text_align",
            "screen_max_width", "height", "columns", "positioning", "min_height", "margin_values",
            "absolute_position", "text_wrap", "absolute_static"}) require(!present(result.value(key)));
    return result;
}
inline bool bodyStartsText(const QJsonArray &spans) {
    if (spans.isEmpty() || !spans.first().isObject()) return false;
    const auto first = spans.first().toObject(); const auto kind = first.value("kind").toString();
    const auto text = first.value("text").toString();
    if ((kind != "text" && kind != "link" && kind != "external_link") || text.isEmpty()) return false;
    const auto c = text.front().unicode();
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f') return false;
    for (const auto key : {"audio_control", "image", "ruby", "inline_padding_group", "inline_action_group",
            "inline_box_group", "clipped_absolute", "pending_container"}) if (present(first.value(key))) return false;
    return true;
}
inline QJsonObject batchLayout(const QJsonValue &value, const QJsonArray &indices, const QJsonArray &references) {
    if (!present(value)) return {};
    const auto result = containerObject(value, {"wrapper", "list", "items"}, {"wrapper", "list", "items"});
    layoutStyle(result.value("wrapper")); layoutStyle(result.value("list"));
    require(result.value("items").isArray()); const auto items = result.value("items").toArray();
    require(!items.isEmpty() && items.size() == indices.size() && items.size() <= itemLimit);
    for (qsizetype i = 0; i < items.size(); ++i) {
        const auto item = containerObject(items.at(i), {"box", "marker", "marker_foreground", "backlink_prefix", "target_background"},
            {"box", "marker_foreground"});
        const auto box = layoutStyle(item.value("box"));
        require(!item.contains("marker") || item.value("marker") == QStringLiteral("decimal_outside"));
        require(!item.contains("backlink_prefix") || item.value("backlink_prefix") == QStringLiteral("single_space"));
        const auto color = containerObject(item.value("marker_foreground"), {"kind", "value"}, {"kind", "value"});
        require(color.value("kind") == QStringLiteral("rgb"));
        CompiledContent::containerColor(QJsonObject{{"rgb", color.value("value")}});
        if (present(item.value("target_background"))) CompiledContent::containerColor(item.value("target_background"));
        const auto index = integer(indices.at(i)); require(index < references.size());
        const auto reference = CompiledContent::object(references.at(index));
        require(reference.value("kind").toString("note") == QStringLiteral("note")
            && integer(reference.value("group_number"), true, true) > 0 && !present(reference.value("blocks"))
            && reference.value("spans").isArray() && bodyStartsText(reference.value("spans").toArray()));
        const auto font = typography(reference.value("body_typography"));
        require(!font.isEmpty() && present(font.value("direction"))
            && CompiledContent::fontSnapshot(font.value("owner_font")) == CompiledContent::containerOwnerFont(box)
            && (font.value("line_height") == box.value("line_height")
                || (!present(font.value("line_height")) && !present(box.value("line_height")))));
        const auto back = CompiledContent::array(reference.value("backlinks")); require(back.size() == 1); backlink(back.first());
    }
    return result;
}

struct Batch {
    int section = -1;
    int before = -1;
    QJsonObject source;
    QJsonArray indices;
    QJsonObject layout;
};
struct Plan {
    bool explicitPlacement = false;
    QVector<Batch> batches;
    QHash<QString, int> citationSections;
    QHash<QString, int> referenceSections;
};
inline Plan placement(const QJsonObject &entry) {
    Plan result;
    const auto value = entry.value("reference_batches");
    if (!present(value)) return result;
    result.explicitPlacement = true;
    require(value.isArray()); const auto batches = value.toArray();
    const auto sections = CompiledContent::array(entry.value("sections"));
    const auto references = CompiledContent::array(entry.value("references"));
    require(!batches.isEmpty() && batches.size() <= itemLimit && !references.isEmpty() && references.size() <= itemLimit);
    QSet<quint32> seen;
    bool complete = true;
    for (const auto &raw : batches) {
        const auto source = containerObject(raw, {"section_index", "before_block_index", "reference_indices", "layout"},
            {"section_index", "before_block_index", "reference_indices"});
        const auto section = integer(source.value("section_index")); const auto before = integer(source.value("before_block_index"));
        require(section < sections.size() && before <= CompiledContent::array(sections.at(section).toObject().value("blocks")).size());
        require(source.value("reference_indices").isArray()); const auto indices = source.value("reference_indices").toArray();
        require(!indices.isEmpty() && indices.size() <= references.size() - seen.size());
        if (!result.batches.isEmpty()) {
            const auto &prior = result.batches.last();
            require(section > quint32(prior.section) || (section == quint32(prior.section) && before >= quint32(prior.before)));
        }
        for (const auto &rawIndex : indices) {
            const auto index = integer(rawIndex);
            require(index < references.size() && !seen.contains(index)
                && references.at(index).toObject().value("kind").toString("note") == QStringLiteral("note"));
            seen.insert(index);
        }
        const auto layout = batchLayout(source.value("layout"), indices, references);
        complete &= !layout.isEmpty();
        result.batches.append({int(section), int(before), source, indices, layout});
        for (const auto &index : indices)
            result.referenceSections.insert(referenceAnchor(references.at(integer(index)).toObject()), int(section));
    }
    require(seen.size() == references.size() && (!present(entry.value("body_adjoining")) || complete));
    return result;
}

inline Plan validate(const QJsonObject &entry) {
    Plan result = placement(entry);
    const auto references = CompiledContent::array(entry.value("references"));
    bool typed = result.explicitPlacement;
    QHash<quint64, QString> markers, returns;
    QSet<QString> markerAnchors, reserved, referenceAnchors;
    QSet<quint32> numbers;
    QSet<quint32> layoutReferences;
    for (const auto &batch : result.batches) if (!batch.layout.isEmpty())
        for (const auto &index : batch.indices) layoutReferences.insert(integer(index));
    quint32 referenceIndex = 0;
    for (const auto &raw : references) {
        const auto reference = CompiledContent::object(raw);
        typed |= present(reference.value("body_typography"));
        typography(reference.value("body_typography"));
        // A legacy prefix is not a typed LI owner. Its independent strut cannot
        // be restyled by borrowing a reference-body typography declaration.
        require(!present(reference.value("body_typography")) || layoutReferences.contains(referenceIndex));
        ++referenceIndex;
        const auto backlinks = CompiledContent::array(reference.value("backlinks"));
        typed |= !backlinks.isEmpty();
        for (const auto &rawBacklink : backlinks) {
            require(reference.value("kind").toString("note") == QStringLiteral("note"));
            const auto back = backlink(rawBacklink);
            const auto number = integer(reference.value("number"), true);
            const auto key = (quint64(number) << 32) | integer(back.value("occurrence"), true);
            require(!returns.contains(key)); returns.insert(key, back.value("span").toObject().value("target_fragment").toString());
        }
    }
    struct Node { QJsonValue value; int section; };
    QVector<Node> pending{{entry.value("display_title"), -1}, {entry.value("preamble_spans"), -1},
                          {entry.value("references"), -1}};
    const auto sections = CompiledContent::array(entry.value("sections"));
    for (qsizetype i = 0; i < sections.size(); ++i) pending.append({sections.at(i), int(i)});
    while (!pending.isEmpty()) {
        const auto node = pending.takeLast();
        if (node.value.isArray()) {
            for (const auto &child : node.value.toArray()) pending.append({child, node.section});
        } else if (node.value.isObject()) {
            const auto object = node.value.toObject();
            // Citation-marker records have no kind; their own anchor is not an
            // authored section/block identity reserved against citation names.
            if (object.contains("kind") || object.contains("blocks"))
                for (const auto key : {"anchor", "anchor_fallback"})
                    if (present(object.value(key)) && !object.value(key).toString().isEmpty())
                        reserved.insert(object.value(key).toString());
            if (present(object.value("citation_marker"))) {
                typed = true; const auto policy = marker(object);
                const auto key = (quint64(integer(policy.value("reference"), true)) << 32)
                    | integer(policy.value("occurrence"), true);
                const auto anchor = policy.value("anchor").toString();
                require(!markers.contains(key) && !markerAnchors.contains(anchor) && markers.size() < itemLimit);
                markers.insert(key, anchor); markerAnchors.insert(anchor);
                result.citationSections.insert(anchor, node.section);
            }
            for (auto it = object.begin(); it != object.end(); ++it)
                if (it->isArray() || it->isObject()) pending.append({*it, node.section});
        }
    }
    if (!typed) return result;
    for (const auto &anchor : reserved) fragment(anchor);
    for (const auto &raw : references) {
        const auto number = integer(raw.toObject().value("number"), true);
        require(!numbers.contains(number)); numbers.insert(number);
        const auto anchor = QStringLiteral("reference-%1").arg(number);
        require(!reserved.contains(anchor)); referenceAnchors.insert(anchor);
    }
    require(markers.size() == returns.size());
    for (auto it = markers.begin(); it != markers.end(); ++it) {
        require(numbers.contains(quint32(it.key() >> 32)) && returns.value(it.key()) == it.value()
            && !reserved.contains(it.value()));
        require(!referenceAnchors.contains(it.value()));
    }
    return result;
}

inline QJsonObject paragraph(const QJsonArray &spans) {
    return {{"kind", "paragraph"}, {"spans", spans}};
}
inline QJsonObject container(const QJsonObject &style, const QJsonArray &blocks) {
    return {{"kind", "container"}, {"spans", QJsonArray{}}, {"container", QJsonObject{{"style", style}, {"blocks", blocks}}}};
}
inline QJsonObject prefixSpan(const QJsonObject &ownerFont) {
    auto span = CompiledContent::fontSnapshot(ownerFont);
    span.remove("font_normalized"); span.insert("inline_style", QJsonObject{{"font_normalized", true}});
    span.insert("kind", "text"); span.insert("text", " "); span.insert("target", ""); span.insert("trail", "");
    return span;
}
inline QJsonObject itemProjection(const QJsonObject &reference, const QJsonObject &item) {
    const auto box = item.value("box").toObject();
    QJsonArray spans{reference.value("backlinks").toArray().first().toObject().value("span"), prefixSpan(box.value("owner_font").toObject())};
    for (const auto &span : reference.value("spans").toArray()) spans.append(span);
    return container(box, QJsonArray{paragraph(spans)});
}
inline QJsonObject itemSource(const QJsonValue &value) {
    const auto source = containerObject(value, {"reference", "item"}, {"reference", "item"});
    const auto reference = CompiledContent::object(source.value("reference"));
    const auto item = CompiledContent::object(source.value("item"));
    const auto box = item.value("box");
    batchLayout(QJsonObject{{"wrapper", box}, {"list", box}, {"items", QJsonArray{item}}}, QJsonArray{0}, QJsonArray{reference});
    return source;
}
inline QJsonObject project(const Batch &batch, const QJsonArray &references) {
    require(!batch.layout.isEmpty()); QJsonArray children;
    const auto items = batch.layout.value("items").toArray();
    for (qsizetype i = 0; i < batch.indices.size(); ++i) {
        const auto reference = references.at(integer(batch.indices.at(i))).toObject();
        children.append(itemProjection(reference, items.at(i).toObject()));
    }
    return container(batch.layout.value("wrapper").toObject(), QJsonArray{
        container(batch.layout.value("list").toObject(), children)});
}
}
