#pragma once

#include "CompiledContent.hpp"
#include "SemanticHtml.hpp"
#include <QPointer>
#include <QColor>
#include <QTextCursor>
#include <QTextDocumentFragment>
#include <QTextFrame>
#include <QScopeGuard>
#include <limits>
#include <algorithm>

namespace FlowConstruction {
inline const QString scheme = QStringLiteral("wikidict-flow");
inline constexpr int sourceRunProperty = SemanticHtml::sourceRunProperty;

// The HTML is imported as one fragment. Source-run metadata records its actual
// imported ranges; it never replaces source characters with projected offsets.
struct Rendered { QString html; QJsonArray parts; };
struct RenderContext {
    QString language;
    QString alignment;
    qreal pointSize = 0;
    qreal normalBodyEm = 0;
    qreal legacyVerticalScale = 1;
    QColor inheritedInk;
    int contentDepth = 0;
    bool languageKnown = false;
    bool zeroFontContext = false;
};

template <typename InlineRenderer, typename FigureRenderer>
Rendered render(const QJsonArray &parts, CompiledContent::Depth depth, RenderContext context,
                InlineRenderer &inlineRenderer, FigureRenderer &figureRenderer, int &nextRun) {
    Rendered result;
    const auto allocateRun = [&] {
        CompiledContent::require(nextRun >= 0 && nextRun < std::numeric_limits<int>::max());
        return nextRun++;
    };
    for (const QJsonValue &value : parts) {
        const auto part = CompiledContent::object(value);
        const QString kind = part.value(QStringLiteral("kind")).toString();
        const auto spans = CompiledContent::array(part.value(QStringLiteral("spans")));
        if (kind == QStringLiteral("inline")) {
            CompiledContent::require(!CompiledContent::present(part.value(QStringLiteral("figure")))
                && !CompiledContent::present(part.value(QStringLiteral("scope"))));
            const int run = allocateRun();
            result.html += inlineRenderer(spans, run, context);
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("run"), run}});
        } else if (kind == QStringLiteral("figure")) {
            CompiledContent::require(spans.isEmpty() && !CompiledContent::present(part.value(QStringLiteral("scope"))));
            const int run = allocateRun();
            result.html += figureRenderer(CompiledContent::object(part.value(QStringLiteral("figure"))), run, context, depth);
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("run"), run}});
        } else {
            CompiledContent::require(kind == QStringLiteral("scope") && spans.isEmpty()
                && !CompiledContent::present(part.value(QStringLiteral("figure"))));
            const auto scope = CompiledContent::scope(part.value(QStringLiteral("scope")));
            auto nestedContext = context;
            if (!scope.value(QStringLiteral("language")).isNull()) {
                nestedContext.language = scope.value(QStringLiteral("language")).toString();
                nestedContext.languageKnown = true;
            }
            nestedContext.contentDepth = depth.nestedContent().content;
            const auto nested = render(scope.value(QStringLiteral("parts")).toArray(), depth.nestedContent(),
                nestedContext, inlineRenderer, figureRenderer, nextRun);
            result.html += nested.html;
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind},
                {QStringLiteral("mode"), scope.value(QStringLiteral("mode"))},
                {QStringLiteral("direction"), scope.value(QStringLiteral("resolved_direction"))},
                {QStringLiteral("language"), scope.value(QStringLiteral("language"))},
                {QStringLiteral("parts"), nested.parts}});
        }
    }
    return result;
}

inline QString placeholder(const QJsonObject &block, const Rendered &rendered, const RenderContext &context) {
    CompiledContent::require(CompiledContent::contentRole(block));
    const QJsonObject metadata{{QStringLiteral("block"), block}, {QStringLiteral("html"), rendered.html},
        {QStringLiteral("parts"), rendered.parts}, {QStringLiteral("language"), context.language},
        {QStringLiteral("alignment"), context.alignment},
        {QStringLiteral("normal_body_em"), context.normalBodyEm},
        {QStringLiteral("legacy_vertical_scale"), context.legacyVerticalScale},
        {QStringLiteral("context_points"), context.pointSize}};
    const auto payload = QJsonDocument(metadata).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    // The caller supplies the existing block's role/prefix/indent exactly once.
    return QStringLiteral("<img src='%1:%2'>").arg(scheme, QString::fromLatin1(payload));
}

struct AuthoredBoundary {
    QTextCursor character;
    int sourceRun = -1;
    QTextBlockFormat precedingFormat;
    QTextBlockFormat followingFormat;
};
struct Paragraph {
    QTextCursor first;
    QTextBlockFormat intrinsicFormat;
    QTextCharFormat intrinsicCharacter;
};
struct Owner {
    QTextCursor first;
    QTextCursor prefixEnd;
    QTextCursor last;
    QJsonObject metadata;
    QTextBlockFormat roleFormat;
    QTextCharFormat roleCharacter;
    QVector<AuthoredBoundary> authoredBoundaries;
    QVector<QTextCursor> figureJoins;
    QVector<Paragraph> paragraphs;
};

inline QJsonObject decode(const QString &name) {
    const QUrl url(name);
    CompiledContent::require(url.scheme() == scheme);
    const auto encoded = url.path().toLatin1();
    const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    CompiledContent::require(error.error == QJsonParseError::NoError && document.isObject()
        && bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded);
    const auto metadata = document.object();
    CompiledContent::require(metadata.value(QStringLiteral("block")).isObject()
        && metadata.value(QStringLiteral("html")).isString() && metadata.value(QStringLiteral("parts")).isArray()
        && metadata.value(QStringLiteral("language")).isString() && metadata.value(QStringLiteral("alignment")).isString());
    return metadata;
}

inline QVector<Owner> expand(QTextDocument *document) {
    const QPointer<QTextDocument> guard(document);
    CompiledContent::require(guard);
    struct Pending { QTextCursor character; QJsonObject metadata; };
    QVector<Pending> pending;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            const QString name = fragment.charFormat().toImageFormat().name();
            if (QUrl(name).scheme() != scheme) continue;
            CompiledContent::require(fragment.length() == 1);
            QTextCursor character(document); character.setPosition(fragment.position());
            character.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor);
            pending.append({character, decode(name)});
        }
    }
    if (pending.isEmpty()) return {};
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    CompiledContent::require(guard && layout && document->documentLayout() == layout);
    CompiledContent::require(layout->property("_wikidictSourceProvenanceCapability").toString()
        == QStringLiteral("wikidict.source-provenance/1"));
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    CompiledContent::require(guard && layout && document->documentLayout() == layout);
    bool restored = false, finished = false;
    const auto restore = qScopeGuard([&] { if (!restored && guard) guard->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (!finished && guard) transaction.endEditBlock(); });
    QVector<Owner> owners;
    for (const auto &item : pending) {
        CompiledContent::require(guard);
        QTextCursor insertion = item.character;
        Owner owner;
        owner.metadata = item.metadata;
        owner.roleFormat = insertion.blockFormat();
        owner.roleCharacter = insertion.block().charFormat();
        owner.first = insertion;
        owner.first.clearSelection(); owner.first.setPosition(insertion.block().position());
        owner.first.setKeepPositionOnInsert(true);
        owner.prefixEnd = insertion;
        owner.prefixEnd.clearSelection(); owner.prefixEnd.setPosition(insertion.selectionStart());
        owner.prefixEnd.setKeepPositionOnInsert(true);
        QTextDocument temporary;
        temporary.setDefaultFont(insertion.charFormat().font().resolve(document->defaultFont()));
        temporary.setDefaultTextOption(document->defaultTextOption());
        temporary.setDocumentMargin(0);
        SemanticHtml::setHtml(&temporary, item.metadata.value(QStringLiteral("html")).toString());
        CompiledContent::require(guard);
        const auto sourceFirst = temporary.begin();
        const QTextBlockFormat firstFormat = sourceFirst.blockFormat();
        const QTextCharFormat firstCharacter = sourceFirst.charFormat();
        const QTextDocumentFragment fragment(&temporary);
        // Qt skips empty fragments before replacing the selected placeholder.
        if (fragment.isEmpty()) insertion.removeSelectedText();
        else insertion.insertFragment(fragment);
        CompiledContent::require(guard);
        owner.last = insertion;
        owner.last.clearSelection(); owner.last.movePosition(QTextCursor::EndOfBlock);
        // Restore the outer role at position zero as well as nonzero insertions.
        // Keep the imported paragraph's own metrics separately for the native
        // whole-owner projection; prefix character formats are never rewritten.
        auto merged = owner.roleFormat;
        const auto firstProperties = firstFormat.properties();
        for (auto it = firstProperties.cbegin(); it != firstProperties.cend(); ++it) {
            if (it.key() != QTextFormat::ObjectIndex && it.key() != QTextFormat::BlockTopMargin
                && it.key() != QTextFormat::BlockBottomMargin && it.key() != QTextFormat::BlockLeftMargin
                && it.key() != QTextFormat::BlockRightMargin && it.key() != QTextFormat::LayoutDirection)
                merged.setProperty(it.key(), it.value());
        }
        if (firstFormat.hasProperty(QTextFormat::LayoutDirection))
            merged.setLayoutDirection(firstFormat.layoutDirection());
        merged.setTopMargin(owner.roleFormat.topMargin() + firstFormat.topMargin());
        merged.setBottomMargin(owner.roleFormat.bottomMargin() + firstFormat.bottomMargin());
        merged.setLeftMargin(owner.roleFormat.leftMargin() + firstFormat.leftMargin());
        merged.setRightMargin(owner.roleFormat.rightMargin() + firstFormat.rightMargin());
        QTextCursor first(owner.first.block());
        first.setBlockFormat(merged);
        auto character = owner.roleCharacter;
        character.merge(firstCharacter);
        first.setBlockCharFormat(character);
        first.setKeepPositionOnInsert(true);
        owner.paragraphs.append({first, firstFormat, firstCharacter});
        // Fragment insertion also omits the first separator association at a
        // nonzero destination, even when that paragraph is not a poem line.
        if (firstFormat.hasProperty(SemanticHtml::sourceBoundaryProperty)) {
            QTextCursor first(owner.first.block());
            auto format = first.blockFormat();
            format.setProperty(SemanticHtml::sourceBoundaryProperty,
                firstFormat.property(SemanticHtml::sourceBoundaryProperty));
            first.setBlockFormat(format);
        }
        // This is the pre-figure authored paragraph inventory. Raw U+2029
        // paragraphs need the role inset too, even without a poem block marker.
        for (auto block = owner.first.block().next(); block.isValid()
             && block.position() <= owner.last.position(); block = block.next()) {
            auto format = block.blockFormat();
            QTextCursor paragraph(block); paragraph.setKeepPositionOnInsert(true);
            owner.paragraphs.append({paragraph, format, block.charFormat()});
            format.setLeftMargin(owner.roleFormat.leftMargin() + format.leftMargin());
            format.setRightMargin(owner.roleFormat.rightMargin() + format.rightMargin());
            paragraph.setBlockFormat(format);
        }
        // These boundaries predate figure insertion. They are authored storage
        // paragraphs, including poem/empty lines, and may never become joins.
        for (auto block = owner.first.block(); block.isValid() && block.position() < owner.last.position(); block = block.next()) {
            const int position = block.position() + block.length() - 1;
            if (position >= owner.last.position()) break;
            QTextCursor boundary(document); boundary.setPosition(position);
            CompiledContent::require(document->characterAt(position) == QChar::ParagraphSeparator);
            const auto format = block.blockFormat();
            const int separatorRun = format.hasProperty(SemanticHtml::sourceBoundaryProperty)
                ? format.intProperty(SemanticHtml::sourceBoundaryProperty)
                : format.hasProperty(sourceRunProperty) ? format.intProperty(sourceRunProperty) : -1;
            owner.authoredBoundaries.append({boundary, separatorRun, format, block.next().blockFormat()});
        }
        owners.append(owner);
    }
    const int revision = document->revision(), count = document->characterCount();
    finished = true;
    transaction.endEditBlock();
    CompiledContent::require(guard && layout && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    restored = true;
    document->setLayoutEnabled(enabled);
    CompiledContent::require(guard && layout && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    return owners;
}

// Only this operation may journal a renderer-created parent separator. Caption
// construction runs afterwards; unrelated paragraphs introduced there cannot be
// relabelled as removable joins.
template <typename Populate>
QPointer<QTextFrame> insertFigure(Owner &owner, QTextCursor placeholder, int run,
                                 QTextFrameFormat format, Populate &&populate) {
    const QPointer<QTextDocument> document(owner.first.document());
    CompiledContent::require(document && owner.last.document() == document && placeholder.document() == document
        && placeholder.hasSelection() && placeholder.selectionEnd() == placeholder.selectionStart() + 1 && run >= 0);
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    CompiledContent::require(document && layout && document->documentLayout() == layout);
    const int revisionBefore = document->revision(), countBefore = document->characterCount();
    const int position = placeholder.selectionStart();
    const bool replacesOwnerTail = placeholder.selectionEnd() == owner.last.position();
    const QPointer<QTextFrame> parent(placeholder.currentFrame());
    CompiledContent::require(parent && parent == owner.first.currentFrame()
        && position >= owner.prefixEnd.position() && position < owner.last.position()
        && document->characterAt(position) == QChar::ObjectReplacementCharacter);
    const auto character = placeholder.charFormat();
    CompiledContent::require(character.isImageFormat()
        && character.property(sourceRunProperty).metaType().id() == QMetaType::Int
        && character.intProperty(sourceRunProperty) == run);
    const int selectedEnd = placeholder.selectionEnd();
    QVector<int> boundaryEnds, joinEnds;
    for (int i = 0; i < owner.authoredBoundaries.size(); ++i)
        if (owner.authoredBoundaries[i].character.position() == selectedEnd) boundaryEnds.append(i);
    for (int i = 0; i < owner.figureJoins.size(); ++i)
        if (owner.figureJoins[i].position() == selectedEnd) joinEnds.append(i);
    QVector<QPair<QTextCursor, bool>> before;
    for (auto it = parent->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock();
        if (!block.isValid()) continue;
        const int separator = block.position() + block.length() - 1;
        if (separator < owner.first.position() || separator >= owner.last.position()
            || document->characterAt(separator) != QChar::ParagraphSeparator) continue;
        QTextCursor cursor(document); cursor.setPosition(separator); before.append({cursor, separator == selectedEnd});
    }
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    CompiledContent::require(document && layout && parent && document->documentLayout() == layout
        && document->revision() == revisionBefore && document->characterCount() == countBefore);
    bool restored = false, finished = false;
    const auto restore = qScopeGuard([&] { if (!restored && document) document->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (!finished && document) transaction.endEditBlock(); });
    format.setProperty(sourceRunProperty, run);
    const QPointer<QTextFrame> frame(placeholder.insertFrame(format));
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && frame->document() == document && frame->parentFrame() == parent);
    QTextCursor inside = frame->firstCursorPosition();
    CompiledContent::require(document->characterAt(inside.position()) == QChar::ObjectReplacementCharacter);
    inside.deleteChar();
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout);
    if (replacesOwnerTail) {
        owner.last.setPosition(frame->lastPosition() + 1);
        owner.last.movePosition(QTextCursor::EndOfBlock);
    }
    // insertFrame uses KeepCursor for its closing marker. A cursor on the
    // original separator at the selection end stays on that new FDD1; restore
    // only identities recorded at that exact boundary before this operation.
    const auto restoreSeparator = [&](QTextCursor &cursor) {
        CompiledContent::require(cursor.document() == document
            && cursor.position() == frame->lastPosition()
            && document->characterAt(cursor.position()) == QChar(0xfdd1)
            && document->characterAt(frame->lastPosition() + 1) == QChar::ParagraphSeparator);
        cursor.setPosition(frame->lastPosition() + 1);
        CompiledContent::require(cursor.currentFrame() == parent);
    };
    for (int index : boundaryEnds) restoreSeparator(owner.authoredBoundaries[index].character);
    for (int index : joinEnds) restoreSeparator(owner.figureJoins[index]);
    QSet<int> retained;
    for (auto &saved : before) {
        auto &cursor = saved.first;
        if (saved.second) restoreSeparator(cursor);
        CompiledContent::require(cursor.document() == document && cursor.currentFrame() == parent
            && document->characterAt(cursor.position()) == QChar::ParagraphSeparator);
        retained.insert(cursor.position());
    }
    QVector<QTextCursor> joins;
    for (auto it = parent->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock();
        if (!block.isValid()) continue;
        const int separator = block.position() + block.length() - 1;
        if (separator < owner.first.position() || separator >= owner.last.position()
            || document->characterAt(separator) != QChar::ParagraphSeparator || retained.contains(separator)) continue;
        QTextCursor cursor(document); cursor.setPosition(separator);
        auto blockFormat = cursor.blockFormat();
        blockFormat.clearProperty(SemanticHtml::sourceBoundaryProperty);
        cursor.setBlockFormat(blockFormat);
        joins.append(cursor);
    }
    populate(frame.data());
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && frame->parentFrame() == parent && frame->frameFormat().intProperty(sourceRunProperty) == run);
    for (const auto &cursor : joins)
        CompiledContent::require(cursor.document() == document && cursor.currentFrame() == parent
            && document->characterAt(cursor.position()) == QChar::ParagraphSeparator);
    const int revision = document->revision(), count = document->characterCount();
    finished = true; transaction.endEditBlock();
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    restored = true; document->setLayoutEnabled(enabled);
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    owner.figureJoins += joins;
    return frame;
}

// Called after actual figure-frame insertion. The intervals are discovered from
// the renderer's run metadata and frame objects, never by matching visible text.
struct SourceRanges {
    QHash<int, QVector<QPair<int, int>>> text;
    QHash<int, int> frames;
    QHash<int, int> frameStarts;
    QVector<int> structuralJoins;
    QVector<AuthoredBoundary> authoredBoundaries;
    int first = -1;
    int last = -1;
};
inline SourceRanges ranges(const Owner &owner) {
    auto *document = owner.first.document();
    CompiledContent::require(document && owner.last.document() == document);
    SourceRanges result;
    result.first = owner.first.block().position();
    result.last = owner.last.block().position() + owner.last.block().length() - 1;
    result.authoredBoundaries = owner.authoredBoundaries;
    const auto parent = owner.first.currentFrame();
    QSet<int> authored;
    for (const auto &boundary : owner.authoredBoundaries) {
        CompiledContent::require(boundary.character.document() == document
            && document->characterAt(boundary.character.position()) == QChar::ParagraphSeparator);
        authored.insert(boundary.character.position());
    }
    QSet<int> joins;
    for (const auto &cursor : owner.figureJoins) {
        const int position = cursor.position();
        CompiledContent::require(cursor.document() == document && position >= result.first && position < result.last
            && cursor.currentFrame() == parent && document->characterAt(position) == QChar::ParagraphSeparator
            && !authored.contains(position) && !joins.contains(position));
        joins.insert(position);
        result.structuralJoins.append(position);
    }
    for (auto block = document->findBlock(result.first); block.isValid() && block.position() <= result.last; block = block.next()) {
        if (QTextCursor(block).currentFrame() != parent) continue;
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().hasProperty(sourceRunProperty)) continue;
            const QVariant run = fragment.charFormat().property(sourceRunProperty);
            CompiledContent::require(run.metaType().id() == QMetaType::Int && run.toInt() >= 0);
            result.text[run.toInt()].append({fragment.position(), fragment.position() + fragment.length()});
        }
        const int separator = block.position() + block.length() - 1;
        if (separator < result.last && !authored.contains(separator)
            && document->characterAt(separator) == QChar::ParagraphSeparator)
            CompiledContent::require(joins.contains(separator));
    }
    for (auto *frame : parent->childFrames()) {
        if (frame->firstPosition() - 1 < result.first || frame->lastPosition() + 1 > result.last) continue;
        const QVariant run = frame->frameFormat().property(sourceRunProperty);
        if (!run.isValid()) continue;
        CompiledContent::require(run.metaType().id() == QMetaType::Int && run.toInt() >= 0
            && !result.frames.contains(run.toInt()));
        result.frames.insert(run.toInt(), frame->objectIndex());
        result.frameStarts.insert(frame->objectIndex(), frame->firstPosition() - 1);
    }
    return result;
}

// Produce the private native descriptor from actual imported ranges. The native
// registration independently checks complete, ordered, once-only source coverage.
inline QVariantList nativeParts(const QJsonArray &outline, const SourceRanges &source,
                                QSet<int> &consumedRuns) {
    QVariantList result;
    for (const QJsonValue &value : outline) {
        const QJsonObject part = CompiledContent::object(value);
        const QString kind = part.value(QStringLiteral("kind")).toString();
        if (kind == QStringLiteral("scope")) {
            const QString direction = part.value(QStringLiteral("direction")).toString();
            CompiledContent::require(direction == QStringLiteral("ltr") || direction == QStringLiteral("rtl"));
            const auto nested = nativeParts(CompiledContent::array(part.value(QStringLiteral("parts"))), source, consumedRuns);
            result.append(QVariantMap{{QStringLiteral("kind"), kind},
                {QStringLiteral("mode"), part.value(QStringLiteral("mode")).toString()},
                {QStringLiteral("direction"), int(direction == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)},
                {QStringLiteral("language"), part.value(QStringLiteral("language")).toVariant()},
                {QStringLiteral("parts"), nested}});
            continue;
        }
        const QJsonValue runValue = part.value(QStringLiteral("run"));
        const int run = runValue.toInt(-1);
        CompiledContent::require(runValue.isDouble() && run >= 0 && runValue.toDouble() == run
            && !consumedRuns.contains(run));
        consumedRuns.insert(run);
        if (kind == QStringLiteral("figure")) {
            CompiledContent::require(source.frames.contains(run) && !source.text.contains(run));
            result.append(QVariantMap{{QStringLiteral("kind"), QStringLiteral("frame")},
                {QStringLiteral("object"), source.frames.value(run)}});
            continue;
        }
        CompiledContent::require(kind == QStringLiteral("inline") && !source.frames.contains(run));
        QVector<QPair<int, QVariantMap>> events;
        for (const auto &range : source.text.value(run)) {
            CompiledContent::require(range.first < range.second);
            events.append({range.first, {{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("first"), range.first}, {QStringLiteral("last"), range.second}}});
        }
        for (const auto &boundary : source.authoredBoundaries) {
            if (boundary.sourceRun != run) continue;
            const int position = boundary.character.position();
            events.append({position, {{QStringLiteral("kind"), QStringLiteral("paragraph_break")},
                {QStringLiteral("position"), position}}});
        }
        std::sort(events.begin(), events.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
        for (const auto &event : events) result.append(event.second);
    }
    // Qt can keep an authored paragraph separator after a following figure's
    // storage frame. Its run association remains original, but native coverage
    // must follow the actual source positions. Reorder only separator events
    // among siblings of this exact scope; never split or move a scope node.
    const auto kindOf = [](const QVariant &part) {
        return part.toMap().value(QStringLiteral("kind")).toString();
    };
    const auto positionOf = [&](const QVariant &value) {
        const auto part = value.toMap();
        const auto kind = part.value(QStringLiteral("kind")).toString();
        if (kind == QStringLiteral("text")) return part.value(QStringLiteral("first")).toInt();
        if (kind == QStringLiteral("paragraph_break")) return part.value(QStringLiteral("position")).toInt();
        const int object = part.value(QStringLiteral("object")).toInt();
        CompiledContent::require(kind == QStringLiteral("frame") && source.frameStarts.contains(object));
        return source.frameStarts.value(object);
    };
    for (qsizetype begin = 0; begin < result.size();) {
        if (kindOf(result[begin]) == QStringLiteral("scope")) { ++begin; continue; }
        qsizetype end = begin;
        QVariantList contentBefore;
        while (end < result.size() && kindOf(result[end]) != QStringLiteral("scope")) {
            if (kindOf(result[end]) != QStringLiteral("paragraph_break")) contentBefore.append(result[end]);
            ++end;
        }
        std::stable_sort(result.begin() + begin, result.begin() + end,
            [&](const QVariant &left, const QVariant &right) { return positionOf(left) < positionOf(right); });
        QVariantList contentAfter;
        for (qsizetype index = begin; index < end; ++index)
            if (kindOf(result[index]) != QStringLiteral("paragraph_break")) contentAfter.append(result[index]);
        CompiledContent::require(contentBefore == contentAfter);
        begin = end;
    }
    return result;
}

inline QVariantMap descriptor(const Owner &owner, Qt::LayoutDirection direction = Qt::LayoutDirectionAuto) {
    const SourceRanges source = ranges(owner);
    QSet<int> consumed;
    QVariantList parts = nativeParts(owner.metadata.value(QStringLiteral("parts")).toArray(), source, consumed);
    for (auto it = source.text.cbegin(); it != source.text.cend(); ++it) CompiledContent::require(consumed.contains(it.key()));
    for (auto it = source.frames.cbegin(); it != source.frames.cend(); ++it) CompiledContent::require(consumed.contains(it.key()));
    // Unassociated raw source separators remain an explicit construction error;
    // they must not be guessed into a scope or erased as frame-generated joins.
    for (const auto &boundary : source.authoredBoundaries)
        CompiledContent::require(boundary.sourceRun >= 0 && consumed.contains(boundary.sourceRun));
    CompiledContent::require(owner.prefixEnd.document() == owner.first.document()
        && owner.prefixEnd.position() >= source.first && owner.prefixEnd.position() <= source.last);
    if (owner.prefixEnd.position() > source.first)
        parts.prepend(QVariantMap{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("first"), source.first}, {QStringLiteral("last"), owner.prefixEnd.position()}});
    QVariantList joins;
    for (const int position : source.structuralJoins) joins.append(position);
    return {{QStringLiteral("first"), source.first}, {QStringLiteral("last"), source.last},
        {QStringLiteral("direction"), int(direction)},
        {QStringLiteral("language"), owner.metadata.value(QStringLiteral("language")).toString()},
        {QStringLiteral("joins"), joins}, {QStringLiteral("parts"), parts}};
}
}
