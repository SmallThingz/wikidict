#pragma once

#include <QAbstractTextDocumentLayout>
#include <QMetaObject>
#include <QPointer>
#include <QTextDocument>
#include <QTextCursor>
#include <QTextFrame>
#include <QScopeGuard>
#include <QVariant>
#include <QPainterPath>
#include <cmath>
#include <optional>

// App boundary for the paired private Gui/Widgets original-offset API. This
// never substitutes projected indices for stored text, actions or AX ranges.
namespace LogicalFlow {
inline constexpr auto capabilityProperty = "_wikidictLogicalFlowCapability";
inline const QString capability = QStringLiteral("wikidict.logical-flow/1");
enum class Status { Stock, Handled, Refused };
struct Position {
    Status status = Status::Refused;
    int error = -1;
    QVariantMap values;
};
inline bool finiteRect(const QVariant &value) {
    if (value.metaType().id() != QMetaType::QRectF) return false;
    const QRectF rect = value.toRectF();
    return std::isfinite(rect.x()) && std::isfinite(rect.y())
        && std::isfinite(rect.width()) && std::isfinite(rect.height())
        && rect.width() >= 0 && rect.height() >= 0;
}
inline Position position(QTextDocument *document, int originalOffset) {
    const QPointer<QTextDocument> guard(document);
    if (!guard || originalOffset < 0 || originalOffset >= document->characterCount()) return {};
    const int revision = document->revision();
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    if (!guard || !layout) return {};
    const QVariant present = layout->property(capabilityProperty);
    if (!present.isValid()) return {Status::Stock, 0, {}};
    if (present.metaType().id() != QMetaType::QString || present.toString() != capability) return {};
    QVariantMap values;
    const bool invoked = QMetaObject::invokeMethod(layout, "wikidictLogicalPosition", Qt::DirectConnection,
        Q_RETURN_ARG(QVariantMap, values), Q_ARG(int, originalOffset));
    if (!guard || !layout || document->documentLayout() != layout || document->revision() != revision
        || !invoked || values.value(QStringLiteral("handled")).metaType().id() != QMetaType::Bool
        || values.value(QStringLiteral("error")).metaType().id() != QMetaType::Int) return {};
    const int error = values.value(QStringLiteral("error")).toInt();
    if (error != 0) return {Status::Refused, error, values};
    if (values.contains(QStringLiteral("lineBaseline"))
        && (values.value(QStringLiteral("lineBaseline")).metaType().id() != QMetaType::Double
            || !std::isfinite(values.value(QStringLiteral("lineBaseline")).toDouble()))) return {};
    // Optional whole-link geometry is valid on stock and projected paragraphs.
    // It never replaces the original character/caret rectangle.
    if (values.contains(QStringLiteral("actionRect")) && !finiteRect(values.value(QStringLiteral("actionRect")))) return {};
    if (values.contains(QStringLiteral("inlineBoxActionPath"))) {
        const auto value = values.value(QStringLiteral("inlineBoxActionPath"));
        if (value.metaType().id() != qMetaTypeId<QPainterPath>() || !values.contains(QStringLiteral("actionRect"))) return {};
        const auto first = values.value(QStringLiteral("inlineBoxActionFirst"));
        const auto last = values.value(QStringLiteral("inlineBoxActionLast"));
        const auto href = values.value(QStringLiteral("inlineBoxActionHref"));
        if (first.metaType().id() != QMetaType::Int || last.metaType().id() != QMetaType::Int
            || href.metaType().id() != QMetaType::QString || href.toString().isEmpty()
            || first.toInt() < 0 || first.toInt() > originalOffset || last.toInt() <= originalOffset
            || last.toInt() >= document->characterCount()) return {};
        const auto path = value.value<QPainterPath>();
        for (int i = 0; i < path.elementCount(); ++i)
            if (!std::isfinite(path.elementAt(i).x) || !std::isfinite(path.elementAt(i).y)) return {};
        if (path.isEmpty() || path.boundingRect() != values.value(QStringLiteral("actionRect")).toRectF()) return {};
    }
    if (!values.value(QStringLiteral("handled")).toBool()) return {Status::Stock, 0, values};
    for (const QString &key : {QStringLiteral("first"), QStringLiteral("last"), QStringLiteral("position")})
        if (values.value(key).metaType().id() != QMetaType::Int) return {};
    if (values.value(QStringLiteral("position")).toInt() != originalOffset
        || values.value(QStringLiteral("first")).toInt() > originalOffset
        || values.value(QStringLiteral("first")).toInt() < 0
        || values.value(QStringLiteral("last")).toInt() < originalOffset
        || values.value(QStringLiteral("last")).toInt() >= document->characterCount()
        ) return {};
    if (values.contains(QStringLiteral("articleClippedRect"))) {
        const auto rect = values.value(QStringLiteral("articleClippedRect"));
        if (!finiteRect(rect) || rect.toRectF().isEmpty() ||
            values.contains(QStringLiteral("actionRect")) || values.contains(QStringLiteral("characterRect")) ||
            values.contains(QStringLiteral("cursorRect")) || values.value(QStringLiteral("projected")).toInt() != -1)
            return {};
        return {Status::Handled, 0, values};
    }
    if (!finiteRect(values.value(QStringLiteral("cursorRect")))) return {};
    if (values.contains(QStringLiteral("characterRect")) && !finiteRect(values.value(QStringLiteral("characterRect")))) return {};
    return {Status::Handled, 0, values};
}

// Inventory presence is queried from the native owner, never mirrored in app
// state. Captions can use stock geometry while their document still owns flows.
inline Status inventory(QTextDocument *document) {
    const QPointer<QTextDocument> guard(document);
    if (!guard) return Status::Refused;
    const int revision = document->revision();
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    if (!guard || !layout) return Status::Refused;
    const QVariant present = layout->property(capabilityProperty);
    if (!present.isValid()) return Status::Stock;
    if (present.metaType().id() != QMetaType::QString || present.toString() != capability)
        return Status::Refused;
    bool hasOwners = false;
    const bool invoked = QMetaObject::invokeMethod(layout, "wikidictHasLogicalFlows", Qt::DirectConnection,
        Q_RETURN_ARG(bool, hasOwners));
    if (!guard || !layout || document->documentLayout() != layout || document->revision() != revision || !invoked)
        return Status::Refused;
    return hasOwners ? Status::Handled : Status::Stock;
}

// The caller must also verify its browser still owns this document afterwards,
// and propagate false when compiled flow requires registration. Missing native
// support is not permission to render a required owner through the stock path.
inline bool registerOwners(QTextDocument *document, const QVariantList &owners) {
    const QPointer<QTextDocument> guard(document);
    if (!guard) return false;
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    if (!guard || !layout || layout->property(capabilityProperty).toString() != capability
        || layout->metaObject()->indexOfMethod("wikidictLogicalBoundary(int,bool)") < 0
        || layout->metaObject()->indexOfMethod("wikidictHasLogicalFlows()") < 0) return false;
    const int revision = document->revision();
    const int count = document->characterCount();
    bool accepted = false;
    const bool invoked = QMetaObject::invokeMethod(layout, "wikidictSetLogicalFlows", Qt::DirectConnection,
        Q_RETURN_ARG(bool, accepted), Q_ARG(QVariantList, owners));
    // Registration invalidates layout and can synchronously notify application
    // code. A replaced/deleted document is not an accepted current projection.
    return guard && layout && document->documentLayout() == layout && document->revision() == revision
        && document->characterCount() == count && invoked && accepted;
}

// Use only for a known image/frame format update to this exact registered
// document. Unknown edits must recompose from compiled content instead. The
// caller retains the returned revision and rechecks browser ownership.
template <typename Mutation>
std::optional<int> editFormats(QTextDocument *document, const QVariantList &owners,
                               int registeredRevision, Mutation &&mutate) {
    const QPointer<QTextDocument> guard(document);
    if (!guard || document->revision() != registeredRevision || owners.isEmpty()) return std::nullopt;
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    if (!guard || !layout || document->documentLayout() != layout
        || document->revision() != registeredRevision || inventory(document) != Status::Handled)
        return std::nullopt;
    if (!guard || !layout || document->documentLayout() != layout
        || document->revision() != registeredRevision) return std::nullopt;
    const QString sourceText = document->toRawText();
    const int count = document->characterCount();
    struct Frame {
        QPointer<QTextFrame> frame;
        QPointer<QTextFrame> parent;
        int object, first, last;
    };
    QVector<Frame> frames;
    const auto collect = [&](auto &&visit, QTextFrame *frame) -> void {
        frames.append({frame, frame->parentFrame(), frame->objectIndex(), frame->firstPosition(), frame->lastPosition()});
        for (auto *child : frame->childFrames()) visit(visit, child);
    };
    collect(collect, document->rootFrame());
    const auto sameSource = [&] {
        if (!guard || !layout || document->documentLayout() != layout
            || document->characterCount() != count || document->toRawText() != sourceText) return false;
        qsizetype visited = 0;
        const auto countFrames = [&](auto &&visit, QTextFrame *frame) -> void {
            ++visited;
            for (auto *child : frame->childFrames()) visit(visit, child);
        };
        countFrames(countFrames, document->rootFrame());
        if (visited != frames.size()) return false;
        for (const auto &value : frames)
            if (!value.frame || value.frame->document() != document || value.frame->parentFrame() != value.parent
                || value.frame->objectIndex() != value.object || value.frame->firstPosition() != value.first
                || value.frame->lastPosition() != value.last) return false;
        return true;
    };
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    bool restored = false;
    const auto restore = qScopeGuard([&] { if (!restored && guard) guard->setLayoutEnabled(enabled); });
    if (!sameSource() || document->revision() != registeredRevision) return std::nullopt;
    QTextCursor transaction(document);
    transaction.beginEditBlock();
    bool finished = false;
    const auto finish = qScopeGuard([&] { if (!finished && guard) transaction.endEditBlock(); });
    mutate();
    if (!sameSource()) return std::nullopt;
    const int revision = document->revision();
    finished = true;
    transaction.endEditBlock();
    if (!sameSource() || document->revision() != revision) return std::nullopt;
    if (!registerOwners(document, owners) || !sameSource() || document->revision() != revision)
        return std::nullopt;
    restored = true;
    document->setLayoutEnabled(enabled);
    if (!sameSource() || document->revision() != revision) return std::nullopt;
    return revision;
}
}
