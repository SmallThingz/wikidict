#pragma once

#include "FlowConstruction.hpp"
#include "ParagraphBox.hpp"
#include <QAbstractTextDocumentLayout>
#include <QPointer>
#include <QTextTable>
#include <algorithm>

namespace ParagraphProjection {
inline constexpr int ownerProperty = QTextFormat::UserProperty + 0x5760;
inline constexpr int startProperty = QTextFormat::UserProperty + 0x5761;
inline constexpr int endProperty = QTextFormat::UserProperty + 0x5762;
inline constexpr int emptyProperty = QTextFormat::UserProperty + 0x5763;

namespace Detail {
inline qreal metric(qreal n) {
    CompiledContent::require(std::isfinite(n) && n >= 0 && n <= 8388607.0);
    return n;
}
inline qreal add(qreal a, qreal b) {
    const auto result = ParagraphBox::sum(a, b);
    CompiledContent::require(result.has_value());
    return *result;
}
inline bool ordinary(const QJsonObject &block) {
    return block.value(QStringLiteral("kind")).toString() == QStringLiteral("paragraph")
        && block.value(QStringLiteral("depth")).toInt() == 0
        && block.value(QStringLiteral("list_path")).toString().isEmpty()
        && !CompiledContent::present(block.value(QStringLiteral("figure")))
        && !CompiledContent::present(block.value(QStringLiteral("table")))
        && !CompiledContent::present(block.value(QStringLiteral("feature")));
}
struct Placement {
    FlowConstruction::Owner *owner = nullptr;
    QPointer<QTextFrame> container;
    int cellFirst = -1;
    int cellLast = -1;
    bool ordinary = false;
    bool empty = false;
    qreal scale = 1;
    ParagraphBox::Resolved box;
    qreal intrinsicTop = 0;
    qreal intrinsicBottom = 0;
    qreal defaultTop = 0;
    qreal defaultBottom = 0;
    qreal start = 0;
    qreal end = 0;
    qreal publishedBottom = 0;
    bool publishStorageTail = false;
};
struct Node {
    int owner = -1;
    QTextBlock block;
    QPointer<QTextFrame> frame;
};
inline int position(const QTextFrame::iterator &it) {
    if (auto *frame = it.currentFrame()) return frame->firstPosition() - 1;
    CompiledContent::require(it.currentBlock().isValid());
    return it.currentBlock().position();
}
inline qreal top(const Placement &p) {
    return p.box.authoredMargins ? add(p.intrinsicTop, p.box.margins[ParagraphBox::Top]) : p.defaultTop;
}
inline qreal bottom(const Placement &p) {
    return p.box.authoredMargins ? add(p.intrinsicBottom, p.box.margins[ParagraphBox::Bottom]) : p.defaultBottom;
}
// Null margins retain the existing native max. Across a semantic barrier only
// explicitly authored outside margins become additive contributions.
inline qreal barrier(const Placement &a, const Placement &b) {
    const qreal retainedA = a.box.authoredMargins ? a.intrinsicBottom : bottom(a);
    const qreal retainedB = b.box.authoredMargins ? b.intrinsicTop : top(b);
    qreal gap = qMax(retainedA, retainedB);
    if (a.box.authoredMargins) gap = add(gap, a.box.margins[ParagraphBox::Bottom]);
    if (b.box.authoredMargins) gap = add(gap, b.box.margins[ParagraphBox::Top]);
    return add(add(a.box.padding[ParagraphBox::Bottom], gap), b.box.padding[ParagraphBox::Top]);
}
inline qreal between(const Placement &a, const Placement &b) {
    if (!a.ordinary || !b.ordinary) return barrier(a, b);
    return add(add(a.box.padding[ParagraphBox::Bottom], qMax(bottom(a), top(b))),
        b.box.padding[ParagraphBox::Top]);
}
}

// Mutation only: the caller owns the disabled-layout composition transaction,
// browser/document identity check, full logical registration and final enabling.
// Intrinsic formats and typed source edges remain in Owner; resolved v2 metrics
// do not replace them. A false result must abort that composition.
inline bool project(QTextDocument *document, QVector<FlowConstruction::Owner> &owners) {
    using namespace Detail;
    const QPointer<QTextDocument> guard(document);
    CompiledContent::require(guard && !document->isLayoutEnabled());
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    CompiledContent::require(guard && layout && document->documentLayout() == layout
        && !document->isLayoutEnabled());
    CompiledContent::require(layout->property("_wikidictParagraphBoxLayoutCapability").toString()
        == QStringLiteral("wikidict.paragraph-box/2"));
    const QString raw = document->toRawText();
    const int count = document->characterCount();
    QVector<Placement> plans;
    plans.reserve(owners.size());
    for (auto &owner : owners) {
        CompiledContent::require(owner.first.document() == document && owner.last.document() == document
            && owner.first.position() <= owner.last.position() && !owner.paragraphs.isEmpty());
        Placement p;
        p.owner = &owner;
        p.container = owner.first.currentFrame();
        CompiledContent::require(p.container && owner.last.currentFrame() == p.container);
        if (auto *table = qobject_cast<QTextTable *>(p.container.data())) {
            const auto cell = table->cellAt(owner.first.position());
            const auto last = table->cellAt(owner.last.position());
            CompiledContent::require(cell.isValid() && last.isValid() && cell == last);
            p.cellFirst = cell.firstPosition(); p.cellLast = cell.lastPosition();
        }
        const QJsonObject block = CompiledContent::object(owner.metadata.value(QStringLiteral("block")));
        p.ordinary = ordinary(block);
        const auto scaleValue = owner.metadata.value(QStringLiteral("legacy_vertical_scale"));
        CompiledContent::require(scaleValue.isDouble() && scaleValue.toDouble() > 0);
        p.scale = metric(scaleValue.toDouble());
        int previous = -1;
        for (const auto &paragraph : owner.paragraphs) {
            CompiledContent::require(paragraph.first.document() == document
                && paragraph.first.position() > previous && paragraph.first.currentFrame() == p.container
                && paragraph.first.position() >= owner.first.position()
                && paragraph.first.position() <= owner.last.position()
                && paragraph.first.block().position() == paragraph.first.position());
            if (p.cellFirst >= 0)
                CompiledContent::require(paragraph.first.position() >= p.cellFirst && paragraph.first.position() <= p.cellLast);
            previous = paragraph.first.position();
        }
        CompiledContent::require(owner.paragraphs.first().first.position() == owner.first.position());
        const auto parentFormat = p.container->frameFormat();
        const bool containerParagraph = parentFormat.hasProperty(FlowConstruction::containerPolicyProperty);
        if (containerParagraph) {
            const auto policy = parentFormat.property(FlowConstruction::containerPolicyProperty);
            CompiledContent::require(p.container != document->rootFrame()
                && policy.metaType().id() == QMetaType::QString
                && policy.toString() == QStringLiteral("wikidict.plain-container/1")
                && layout->property("_wikidictPlainContainerCapability").toString()
                    == QStringLiteral("wikidict.plain-container/1"));
        }
        // A real Container child paragraph retains its authored empty line.
        // Renderer storage has no Owner; standalone ordinary empty boxes keep
        // their existing zero-line policy.
        p.empty = !containerParagraph && p.ordinary && owner.first.position() == owner.last.position()
            && owner.paragraphs.size() == 1 && owner.first.block().text().isEmpty()
            && !owner.paragraphs.first().intrinsicFormat.hasProperty(SemanticHtml::sourceRunProperty);
        p.intrinsicTop = metric(owner.paragraphs.first().intrinsicFormat.topMargin() * p.scale);
        p.intrinsicBottom = metric(owner.paragraphs.last().intrinsicFormat.bottomMargin() * p.scale);
        p.defaultTop = metric(add(metric(owner.roleFormat.topMargin()),
            metric(owner.paragraphs.first().intrinsicFormat.topMargin())) * p.scale);
        p.defaultBottom = metric(add(metric(owner.roleFormat.bottomMargin()),
            metric(owner.paragraphs.last().intrinsicFormat.bottomMargin())) * p.scale);
        p.publishedBottom = metric(owner.paragraphs.last().intrinsicFormat.bottomMargin());
        ParagraphBox::Edges legacy{metric(owner.roleFormat.topMargin() * p.scale),
            metric(owner.roleFormat.rightMargin()), metric(owner.roleFormat.bottomMargin() * p.scale),
            metric(owner.roleFormat.leftMargin())};
        if (p.empty) {
            legacy[ParagraphBox::Top] = legacy[ParagraphBox::Bottom] = 0;
            p.intrinsicTop = p.intrinsicBottom = 0;
            p.defaultTop = p.defaultBottom = 0;
            p.publishedBottom = 0;
        }
        const auto source = ParagraphBox::source(block);
        if (source) {
            const auto em = owner.metadata.value(QStringLiteral("normal_body_em"));
            CompiledContent::require(em.isDouble());
            const auto resolved = ParagraphBox::resolve(*source, legacy, em.toDouble());
            CompiledContent::require(resolved.has_value());
            p.box = *resolved;
        } else {
            p.box = {legacy, {}, false};
        }
        plans.append(p);
    }

    // A table's cell range is a separate flow even though QTextCursor exposes
    // the same parent QTextTable for every cell. Never collapse across cells.
    QSet<int> visited;
    for (int seed = 0; seed < plans.size(); ++seed) {
        if (visited.contains(seed)) continue;
        const auto container = plans[seed].container;
        CompiledContent::require(container);
        QVector<int> group;
        for (int i = seed; i < plans.size(); ++i)
            if (plans[i].container == container && plans[i].cellFirst == plans[seed].cellFirst) group.append(i);
        std::sort(group.begin(), group.end(), [&](int a, int b) {
            return plans[a].owner->first.position() < plans[b].owner->first.position();
        });
        auto it = container->begin(), finish = container->end();
        if (auto *table = qobject_cast<QTextTable *>(container.data())) {
            const auto cell = table->cellAt(plans[seed].cellFirst);
            CompiledContent::require(cell.isValid());
            it = cell.begin(); finish = cell.end();
        }
        QVector<Node> nodes;
        int nextOwner = 0;
        while (it != finish && !it.atEnd()) {
            const int at = position(it);
            if (nextOwner < group.size() && plans[group[nextOwner]].owner->first.position() == at) {
                const int index = group[nextOwner++];
                CompiledContent::require(it.currentBlock().isValid() && !visited.contains(index));
                visited.insert(index);
                nodes.append({index, {}, {}});
                const int last = plans[index].owner->last.position();
                ++it;
                while (it != finish && !it.atEnd()) {
                    const int next = position(it);
                    if (next > last || (it.currentFrame() && next == last)) break;
                    CompiledContent::require(nextOwner >= group.size()
                        || plans[group[nextOwner]].owner->first.position() > next);
                    ++it;
                }
            } else {
                CompiledContent::require(nextOwner >= group.size() || plans[group[nextOwner]].owner->first.position() > at);
                nodes.append({-1, it.currentBlock(), it.currentFrame()});
                ++it;
            }
        }
        CompiledContent::require(nextOwner == group.size());
        for (int n = 0; n < nodes.size(); ++n) {
            const int index = nodes[n].owner;
            if (index < 0) continue;
            auto &p = plans[index];
            const Node *before = n ? &nodes[n - 1] : nullptr;
            const Node *after = n + 1 < nodes.size() ? &nodes[n + 1] : nullptr;
            if (before && before->owner >= 0) {
                p.start = between(plans[before->owner], p);
            } else if (before && before->block.isValid()) {
                const qreal prior = metric(before->block.blockFormat().bottomMargin() * p.scale);
                p.start = qMax(prior, p.box.authoredMargins ? p.intrinsicTop : top(p));
                if (p.box.authoredMargins) p.start = add(p.start, p.box.margins[ParagraphBox::Top]);
                p.start = add(p.start, p.box.padding[ParagraphBox::Top]);
            } else {
                // Stock root/cell start and directly-after-frame top defaults
                // are ignored. Explicit own edges and padding still occupy space.
                p.start = p.box.padding[ParagraphBox::Top];
                if (p.box.authoredMargins) p.start = add(p.start, p.box.margins[ParagraphBox::Top]);
            }
            if (after && after->owner >= 0) {
                p.end = 0; // The next owned start consumes this boundary once.
            } else if (after && after->block.isValid()) {
                // Leave null/default spacing with the native max consumer,
                // including its QFixed rounding. Explicit outside margins are
                // independent, while intrinsic paragraph spacing stays native.
                if (!p.box.authoredMargins && !p.empty)
                    p.publishedBottom = add(p.publishedBottom, metric(p.owner->roleFormat.bottomMargin()));
                p.end = p.box.authoredMargins ? p.box.margins[ParagraphBox::Bottom] : 0;
                p.end = add(p.end, p.box.padding[ParagraphBox::Bottom]);
                if (n + 2 < nodes.size() && nodes[n + 2].frame
                    && qobject_cast<QTextTable *>(nodes[n + 2].frame.data())) {
                    const auto format = after->block.blockFormat();
                    p.publishStorageTail = after->block.length() == 1
                        && !format.hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)
                        && !format.hasProperty(QTextFormat::BackgroundBrush)
                        && nodes[n + 2].frame->firstPosition() == after->block.position() + 1;
                }
            } else {
                p.end = p.box.padding[ParagraphBox::Bottom];
                if (p.box.authoredMargins) p.end = add(p.end, p.box.margins[ParagraphBox::Bottom]);
            }
            metric(p.start); metric(p.end);
        }
    }
    CompiledContent::require(visited.size() == plans.size());

    struct Mutation { QTextCursor cursor; QTextBlockFormat format; };
    QVector<Mutation> mutations;
    for (const auto &p : plans) {
        for (int i = 0; i < p.owner->paragraphs.size(); ++i) {
            const auto &paragraph = p.owner->paragraphs[i];
            auto format = paragraph.first.blockFormat();
            const auto &intrinsic = paragraph.intrinsicFormat;
            format.setTopMargin(intrinsic.topMargin());
            format.setBottomMargin(i + 1 == p.owner->paragraphs.size() ? p.publishedBottom : intrinsic.bottomMargin());
            format.setLeftMargin(add(metric(intrinsic.leftMargin()),
                add(p.box.margins[ParagraphBox::Left], p.box.padding[ParagraphBox::Left])));
            format.setRightMargin(add(metric(intrinsic.rightMargin()),
                add(p.box.margins[ParagraphBox::Right], p.box.padding[ParagraphBox::Right])));
            for (const int key : {ownerProperty, startProperty, endProperty, emptyProperty}) format.clearProperty(key);
            if (i == 0) {
                format.setProperty(ownerProperty, QStringLiteral("wikidict.paragraph-box/2"));
                format.setProperty(startProperty, double(p.start));
                format.setProperty(endProperty, double(p.end));
                format.setProperty(emptyProperty, p.empty);
            }
            mutations.append({paragraph.first, format});
        }
        // The stock hidden-empty-before-table branch reads the preceding
        // physical block rather than previousBlockFormat, and uses unscaled
        // margins. A generated continuation is owned storage, not a new box.
        if (p.publishStorageTail && p.owner->last.block()
            != p.owner->paragraphs.last().first.block()) {
            auto format = p.owner->last.blockFormat();
            format.setBottomMargin(p.publishedBottom);
            mutations.append({QTextCursor(p.owner->last.block()), format});
        }
    }
    // Plan fully before mutation. Own only block geometry/protocol properties;
    // character fragments, source metadata, text, frames and prefixes stay put.
    QTextCursor transaction(document); transaction.beginEditBlock();
    bool ended = false;
    const auto endEdit = qScopeGuard([&] { if (!ended && guard) transaction.endEditBlock(); });
    for (const auto &mutation : mutations) {
        QTextCursor cursor(mutation.cursor);
        cursor.setBlockFormat(mutation.format);
    }
    const int revision = document->revision();
    ended = true; transaction.endEditBlock();
    return guard && layout && document->documentLayout() == layout && !document->isLayoutEnabled()
        && document->revision() == revision && document->characterCount() == count && document->toRawText() == raw;
}
}
