#pragma once
#include "CompiledDisclosure.hpp"
#include "FlowConstruction.hpp"
#include "LogicalFlow.hpp"
#include <QApplication>
#include <QImage>
#include <QJsonDocument>
#include <QMap>
#include <QPalette>
#include <QPainterPath>
#include <QPointer>
#include <QRegion>
#include <QScopeGuard>
#include <QSignalBlocker>
#include <QSet>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextFrame>
#include <QTextImageFormat>
#include <QTimer>
#include <QUrl>
#include <algorithm>
#include <memory>
#include <utility>

// Native widgets belong to the viewport; their border boxes belong to the
// document. This uses Qt's image allocation, not an extra wire format or theme.
// The source label has an explicit logical mapping through the one image atom.
namespace CompiledDisclosure {
class Host final : public QObject {
public:
    using States = QMap<QString, QJsonObject>;
    static constexpr int PathProperty = QTextFormat::UserProperty + 0x5890;
    static constexpr int GenerationProperty = QTextFormat::UserProperty + 0x5891;
    static constexpr auto markerScheme = "wikidict-disclosure-marker";
    static constexpr auto resourceScheme = "wikidict-disclosure-allocation";
    // Each shared allocation is a unique activation token. A queued callback
    // keeps its token alive, so cancellation/new activation cannot reuse it.
    struct ToggleTicket {
    private:
        friend class Host;
        QPointer<Host> host;
        QPointer<Button> widget;
        QString path;
        QJsonObject source;
        quint64 generation = 0;
        int expectedRevision = -1;
        bool expanded = false;
    };
    using Toggle = std::shared_ptr<ToggleTicket>;
    struct Occurrence {
        QString path, text, resource;
        QJsonObject block;
        QPointer<Button> widget;
        QPointer<QTextFrame> owner;
        QByteArray ownerBytes;
        QTextBlock caption;
        QTextCursor cursor;
        QSizeF size;
        int basePosition = -1;
        bool pendingToggle = false, metricsQueued = false, expanded = false, focusVisibleBeforeToggle = false;
        Toggle toggle;
    };
    QList<Occurrence> occurrences;
    std::function<void()> requestSync;
    std::function<void(int)> reveal;
    std::function<void(const QString &, const QJsonObject &, bool)> requestToggle;
    std::function<bool(const std::function<void()> &)> editFormats;

    Host(QTextDocument *document, QWidget *viewport)
        : QObject(document), document_(document), layout_(document->documentLayout()), viewport_(viewport) {
        connect(document, &QTextDocument::contentsChanged, this, [this] {
            if (!formatting_ && revision_ >= 0 && !current()) retire();
        });
        connect(document, &QTextDocument::documentLayoutChanged, this, [this] { retire(); });
    }
    ~Host() override { retire(); }
    static Model sourceModel(const QJsonObject &source) {
        if (const auto caption = CompiledContent::tableCaptionDisclosure(source)) return *caption;
        return parse(source.value("container").toObject());
    }
    static bool expanded(const States &states, const QString &path, const QJsonObject &block) {
        const auto model = sourceModel(block);
        const auto state = states.value(path);
        return state.value("source") == block && state.value("expanded").isBool()
            ? state.value("expanded").toBool() : !model.initiallyCollapsed;
    }
    static QString marker(const QString &path) {
        require(!path.isEmpty());
        return QStringLiteral("<img src=\"%1:%2\" />").arg(QLatin1String(markerScheme),
            QString::fromLatin1(path.toUtf8().toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
    }
    bool attached(QTextDocument *document, QWidget *viewport) const {
        return document_ == document && viewport_ == viewport && layout_ && document
            && document->documentLayout() == layout_;
    }
    bool current() const {
        return document_ && viewport_ && layout_ && document_->documentLayout() == layout_
            && revision_ >= 0 && document_->revision() == revision_ && document_->characterCount() == count_;
    }
    bool empty() const { return occurrences.isEmpty(); }
    bool activate() {
        if (!current()) return false;
        const QPointer<Host> self(this); const auto generation = generation_;
        interactive_ = true;
        for (const auto &row : QList<Occurrence>(occurrences)) {
            if (!row.widget) return false;
            row.widget->setEnabled(!row.pendingToggle);
            if (!self || generation_ != generation || !current()) return false;
        }
        return true;
    }
    bool pendingFocusVisible(const QString &path) const {
        for (const auto &row : occurrences) if (row.path == path) return row.focusVisibleBeforeToggle;
        return false;
    }
    Toggle pendingToggle(const QString &path, const QJsonObject &source, Button *widget, bool expanded) const {
        for (const auto &row : occurrences) if (row.path == path && row.block == source && row.widget == widget
            && ownsToggle(row.toggle) && row.toggle->expanded == expanded) return row.toggle;
        return {};
    }
    bool toggleCurrent(const Toggle &ticket) const {
        return !formatting_ && current() && ownsToggle(ticket)
            && document_->revision() == ticket->expectedRevision;
    }
    bool consumeToggle(const Toggle &ticket) {
        if (!toggleCurrent(ticket)) return false;
        for (auto &row : occurrences) if (row.toggle == ticket) {
            row.toggle.reset(); // Keep pending/disabled until composition retires this occurrence.
            return true;
        }
        return false;
    }
    void cancelToggle(const QString &path, Button *widget, const Toggle &ticket) {
        if (!current() || !ownsToggle(ticket)) return;
        for (auto &row : occurrences) if (row.path == path && row.widget == widget && row.toggle == ticket) {
            row.toggle.reset(); row.pendingToggle = false;
            const QSignalBlocker blocked(widget); widget->setChecked(row.expanded);
            widget->setText(row.text); widget->setAccessibleName(row.text); widget->setEnabled(interactive_);
            return;
        }
    }
    Button *button(const QString &path, const QJsonObject &source = {}) const {
        if (!current()) return nullptr;
        for (const auto &row : occurrences)
            if (row.path == path && (source.isEmpty() || row.block == source)) return row.widget;
        return nullptr;
    }
    bool ownsFocusWidget(const QWidget *widget) const {
        if (!current() || !widget) return false;
        for (const auto &row : occurrences) if (row.widget == widget) return true;
        return false;
    }
    QList<QPair<int, QPointer<QWidget>>> focusTargets() const {
        QList<QPair<int, QPointer<QWidget>>> result;
        if (current()) for (const auto &row : occurrences)
            if (row.widget && row.widget->isVisible() && row.widget->isEnabled())
                result.append({row.cursor.position(), row.widget.data()});
        return result;
    }
    void retire() {
        const QPointer<Host> self(this);
        ++generation_; revision_ = -1; count_ = -1; heldRevision_ = -1; formatting_ = false; restoringHeldActivation_ = false; interactive_ = false; semanticText_.clear();
        const auto old = std::exchange(occurrences, {});
        for (const auto &row : old) if (row.widget) {
            row.widget->expandedChanged = {}; row.widget->metricsChanged = {};
            row.widget->removeEventFilter(this);
            row.widget->setEnabled(false); if (!self) return;
            if (row.widget) row.widget->hide(); if (!self) return;
            if (row.widget) row.widget->deleteLater();
            // Remove task-owned raster data; this name is never reused by a new generation.
            if (document_) document_->addResource(QTextDocument::ImageResource, QUrl(row.resource), QVariant());
        }
    }
    void expand(const QMap<QString, QJsonObject> &sources, const States &states) {
        require(document_ && viewport_ && layout_ && document_->documentLayout() == layout_
            && !document_->isLayoutEnabled() && occurrences.isEmpty());
        if (sources.isEmpty()) return;
        require(layout_->property("_wikidictSourceProvenanceCapability") == QVariant(QStringLiteral("wikidict.source-provenance/1"))
            && layout_->property("_wikidictPlainContainerCapability") == QVariant(QStringLiteral("wikidict.plain-container/1")));
        const QPointer<Host> self(this); const auto generation = generation_;
        const auto same = [&] { return self && document_ && viewport_ && layout_ && generation_ == generation
            && document_->documentLayout() == layout_ && !document_->isLayoutEnabled(); };
        struct Marker { QTextCursor cursor; QString path; };
        QList<Marker> markers; QSet<QString> seen;
        for (auto block = document_->begin(); block.isValid(); block = block.next())
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
                const QUrl url(fragment.charFormat().toImageFormat().name());
                if (url.scheme() != QLatin1String(markerScheme)) continue;
                const auto encoded = url.path().toLatin1();
                const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
                const QString path = QString::fromUtf8(bytes);
                require(!path.isEmpty() && path.toUtf8() == bytes && sources.contains(path) && !seen.contains(path)
                    && bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded
                    && fragment.length() == 1 && fragment.text() == QString(QChar::ObjectReplacementCharacter));
                seen.insert(path);
                QTextCursor cursor(document_); cursor.setPosition(fragment.position());
                cursor.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor);
                markers.append({cursor, path});
            }
        require(seen.size() == sources.size());
        for (const auto &marker : markers) {
            require(same());
            Occurrence row; row.path = marker.path; row.block = sources.value(marker.path);
            auto model = sourceModel(row.block);
            if (model.button) {
                CompiledContent::containerBlock(row.block);
                for (auto *frame = marker.cursor.currentFrame(); frame && frame != document_->rootFrame(); frame = frame->parentFrame())
                    if (frame->frameFormat().hasProperty(FlowConstruction::containerSourceProperty)) {
                        row.owner = frame; row.ownerBytes = frame->frameFormat().property(FlowConstruction::containerSourceProperty).toByteArray(); break;
                    }
                require(row.owner && QJsonDocument::fromJson(row.ownerBytes).object() == row.block);
            } else {
                // The unique table path marker was emitted inside this caption.
                // Qt keeps that block even when there is no grid frame.
                require(present(row.block.value("caption_disclosure")));
                const int position = marker.cursor.selectionStart();
                row.caption = document_->findBlock(position);
                row.owner = document_->frameAt(position);
                require(row.caption.isValid() && row.owner);
            }
            const auto inherited = marker.cursor.charFormat();
            auto direction = inherited.layoutDirection();
            if (direction == Qt::LayoutDirectionAuto) direction = marker.cursor.blockFormat().layoutDirection();
            if (direction == Qt::LayoutDirectionAuto) direction = document_->defaultTextOption().textDirection();
            if (direction == Qt::LayoutDirectionAuto) direction = viewport_->layoutDirection();
            const QColor foreground = inherited.foreground().style() == Qt::NoBrush
                ? viewport_->palette().color(QPalette::Text) : inherited.foreground().color();
            row.widget = new Button(std::move(model), foreground, direction, viewport_);
            bool retained = false;
            const auto discard = qScopeGuard([&] { if (!retained && row.widget) row.widget->deleteLater(); });
            require(same() && row.widget);
            row.widget->hide(); require(same() && row.widget);
            row.widget->setEnabled(false); require(same() && row.widget);
            row.expanded = expanded(states, row.path, row.block);
            { QSignalBlocker blocked(row.widget); row.widget->setChecked(row.expanded); }
            // QSignalBlocker suppresses Button's label slot too: refresh the complete label explicitly.
            row.widget->setText(row.widget->isChecked() ? row.widget->model().collapseLabel : row.widget->model().expandLabel);
            row.widget->setAccessibleName(row.widget->text());
            row.widget->setObjectName(QStringLiteral("containerDisclosureButton"));
            row.widget->setProperty("wikidict.disclosure.path", row.path);
            require(same() && row.widget);
            row.size = row.widget->borderBoxSize(); row.text = row.widget->text();
            row.resource = QStringLiteral("%1:%2/%3").arg(QLatin1String(resourceScheme)).arg(generation)
                .arg(QString::fromLatin1(row.path.toUtf8().toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
            QImage transparent(1, 1, QImage::Format_ARGB32_Premultiplied); transparent.fill(Qt::transparent);
            document_->addResource(QTextDocument::ImageResource, QUrl(row.resource), transparent);
            auto format = inherited.toImageFormat();
            for (int key : {QTextFormat::ObjectIndex, QTextFormat::AnchorHref, QTextFormat::AnchorName}) format.clearProperty(key);
            format.setAnchor(false); format.setName(row.resource); format.setWidth(row.size.width()); format.setHeight(row.size.height());
            format.setProperty(PathProperty, row.path); format.setProperty(GenerationProperty, QVariant::fromValue(generation));
            const auto placement = row.widget->model().placement;
            if (!row.widget->model().button) {
                require(same() && row.widget && row.caption.isValid() && placement == QStringLiteral("inline_flow"));
                const auto capability = layout_->property("_wikidictInlineImageAlignmentCapability");
                require(same() && row.widget && capability.metaType().id() == QMetaType::QString
                    && capability.toString() == QStringLiteral("wikidict.inline-image-alignment/1"));
                // The caption control replaces an unstyled inline marker. Its existing
                // baseline allocation needs the paired native image rectangle owner.
                require(format.verticalAlignment() == QTextCharFormat::AlignNormal && format.baselineOffset() == 0
                    && !format.hasProperty(SemanticHtml::inlineStyleProperty)
                    && !format.hasProperty(SemanticHtml::figureImageProperty)
                    && !format.hasProperty(SemanticHtml::inlineImageAlignmentProperty));
                format.setProperty(SemanticHtml::inlineImageAlignmentProperty, QStringLiteral("baseline"));
            }
            auto cursor = marker.cursor;
            cursor.insertImage(format, placement == "float_left" ? QTextFrameFormat::FloatLeft
                : placement == "float_right" ? QTextFrameFormat::FloatRight : QTextFrameFormat::InFlow);
            require(same() && row.widget);
            occurrences.append(row); retained = true;
        }
        // Floating image insertion may add frame boundaries. Find the actual retained atom,
        // rather than guessing its position from the insertion cursor.
        QSet<QString> allocated;
        for (auto block = document_->begin(); block.isValid(); block = block.next())
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment(); const auto format = fragment.charFormat();
                if (!fragment.isValid() || !format.hasProperty(PathProperty)) continue;
                const auto path = format.stringProperty(PathProperty);
                require(!allocated.contains(path) && fragment.length() == 1); allocated.insert(path);
                for (auto &row : occurrences) if (row.path == path) {
                    row.cursor = QTextCursor(document_); row.cursor.setPosition(fragment.position()); row.cursor.setKeepPositionOnInsert(true);
                    const QPointer<Button> widget(row.widget);
                    widget->expandedChanged = [self, widget, generation, path](quint32 index, bool value) {
                        if (!self || !widget || self->generation_ != generation) return;
                        // Button already changed its check/label before this callback.
                        // Reject held activations even while the document is between revisions.
                        if (self->formatting_) {
                            if (!self->restoreHeldActivation(path, widget, generation)
                                && self && self->generation_ == generation && self->formatting_) self->retire();
                            return;
                        }
                        if (!self->current() || !self->interactive_) return;
                        for (auto &entry : self->occurrences) if (entry.path == path && entry.widget == widget) {
                            if (entry.pendingToggle || index != widget->model().contentIndex) return;
                            auto ticket = std::make_shared<ToggleTicket>();
                            ticket->host = self; ticket->widget = widget; ticket->path = path; ticket->source = entry.block;
                            ticket->generation = generation; ticket->expectedRevision = self->document_->revision();
                            ticket->expanded = value; entry.toggle = std::move(ticket);
                            entry.pendingToggle = true;
                            entry.focusVisibleBeforeToggle = widget->focusVisible();
                            const auto source = entry.block; const auto toggle = self->requestToggle;
                            widget->setEnabled(false);
                            if (self && widget && self->current() && self->generation_ == generation && toggle) toggle(path, source, value);
                            return;
                        }
                    };
                    widget->metricsChanged = [self, widget, generation, path] {
                        if (self && widget && self->generation_ == generation) self->queueMetrics(path, widget);
                    };
                    widget->installEventFilter(this);
                }
            }
        require(allocated.size() == occurrences.size());
        std::sort(occurrences.begin(), occurrences.end(), [](const auto &a, const auto &b) { return a.cursor.position() < b.cursor.position(); });
    }
    bool seal(const std::function<int(int)> &baseOffset) {
        // Initial composition is unsealed. An existing binding may be resealed
        // only by the active hold of that exact predecessor revision.
        if (revision_ >= 0 && (!formatting_ || heldRevision_ < 0 || heldRevision_ != revision_)) return false;
        if (!document_ || !layout_ || document_->documentLayout() != layout_) return false;
        int previous = -1;
        for (auto &row : occurrences) {
            if (!row.widget || !row.owner || row.owner->document() != document_
                || document_->object(row.owner->objectIndex()) != row.owner) return false;
            QTextCursor cursor(document_); cursor.setPosition(row.cursor.position()); cursor.setPosition(row.cursor.position() + 1, QTextCursor::KeepAnchor);
            const auto format = cursor.charFormat().toImageFormat();
            if (cursor.selectedText() != QString(QChar::ObjectReplacementCharacter) || !cursor.charFormat().isImageFormat()
                || format.name() != row.resource || format.stringProperty(PathProperty) != row.path
                || format.property(GenerationProperty).toULongLong() != generation_
                || QSizeF(format.width(), format.height()) != row.size) return false;
            if (row.widget->model().button) {
                if (row.owner->frameFormat().property(FlowConstruction::containerSourceProperty).toByteArray() != row.ownerBytes) return false;
                bool inside = false;
                for (auto *frame = cursor.currentFrame(); frame; frame = frame->parentFrame()) inside |= frame == row.owner;
                if (!inside) return false;
            } else if (!row.caption.isValid() || document_->findBlock(row.cursor.position()) != row.caption
                || document_->frameAt(row.cursor.position()) != row.owner) return false;
            row.basePosition = baseOffset(row.cursor.position());
            if (row.basePosition <= previous || baseOffset(row.cursor.position() + 1) != row.basePosition + 1) return false;
            previous = row.basePosition;
        }
        revision_ = document_->revision(); count_ = document_->characterCount(); return true;
    }
    bool holdFormats() {
        if (!current() || formatting_) return false;
        heldRevision_ = revision_; formatting_ = true; return true;
    }
    bool refreshRevision() {
        if (!formatting_ || heldRevision_ < 0 || heldRevision_ != revision_
            || !document_ || document_->characterCount() != count_) return false;
        return seal([&](int position) {
            for (const auto &row : occurrences) {
                if (row.cursor.position() == position) return row.basePosition;
                if (row.cursor.position() + 1 == position) return row.basePosition + 1;
            }
            return -1;
        });
    }
    void releaseFormats(bool accepted) {
        // Only the outer transaction's final RAII acceptance may bridge revisions.
        // refreshRevision() alone never authorizes a pending action.
        if (restoringHeldActivation_ || !formatting_ || !accepted || !current() || heldRevision_ < 0) { retire(); return; }
        for (const auto &row : occurrences) if (row.toggle
            && (!ownsToggle(row.toggle) || row.toggle->expectedRevision != heldRevision_)) { retire(); return; }
        for (const auto &row : occurrences) if (row.toggle) row.toggle->expectedRevision = revision_;
        heldRevision_ = -1; formatting_ = false;
    }
    int toSource(int base) const { int extra = 0; for (const auto &row : occurrences) if (row.basePosition < base) extra += row.text.size() - 1; return base + extra; }
    int toBase(int source, bool after) const {
        int extra = 0;
        for (const auto &row : occurrences) {
            const int first = row.basePosition + extra, last = first + row.text.size();
            if (source < first) break;
            if (source == first) return row.basePosition;
            if (source < last) return row.basePosition + (after ? 1 : 0);
            extra += row.text.size() - 1;
        }
        return source - extra;
    }
    bool cacheText(QString base) {
        if (!current()) return false;
        const int expected = toSource(base.size());
        for (auto it = occurrences.crbegin(); it != occurrences.crend(); ++it) {
            if (it->basePosition < 0 || it->basePosition >= base.size() || base[it->basePosition] != QChar::ObjectReplacementCharacter) return false;
            base.replace(it->basePosition, 1, it->text);
        }
        semanticText_ = std::move(base); return semanticText_.size() == expected;
    }
    QString text(int first, int last) const {
        return current() && first >= 0 && last >= first && last <= semanticText_.size() ? semanticText_.mid(first, last - first) : QString();
    }
    QRectF rectangle(const Occurrence &row) const {
        if (!current()) return {};
        bool owned = false;
        for (const auto &entry : occurrences) if (entry.path == row.path && entry.widget == row.widget
            && entry.block == row.block && entry.cursor.position() == row.cursor.position() && entry.size == row.size
            && entry.owner == row.owner && entry.resource == row.resource) { owned = true; break; }
        if (!owned) return {};
        const QPointer<const Host> self(this);
        const auto geometry = LogicalFlow::position(document_, row.cursor.position());
        if (!self || !current() || geometry.status == LogicalFlow::Status::Refused) return {};
        // QTextCursor::insertImage(format, FloatLeft/FloatRight) creates a
        // real image frame. Qt deliberately gives that atom zero inline advance;
        // its document-space border box belongs to the current image frame.
        if (!row.widget) return {};
        const auto placement = row.widget->model().placement;
        if (placement == QStringLiteral("float_left") || placement == QStringLiteral("float_right")) {
            // Cursor formats deliberately omit ObjectIndex; only the stored
            // one-atom fragment can identify this native floating frame.
            QTextFragment atom;
            const auto block = document_->findBlock(row.cursor.position());
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (fragment.isValid() && fragment.contains(row.cursor.position())) { atom = fragment; break; }
            }
            const auto stored = atom.charFormat();
            const auto image = stored.toImageFormat();
            if (!atom.isValid() || atom.position() != row.cursor.position() || atom.length() != 1
                || atom.text() != QString(QChar::ObjectReplacementCharacter) || !stored.isImageFormat() || image.objectIndex() < 0
                || image.name() != row.resource || image.stringProperty(PathProperty) != row.path
                || image.property(GenerationProperty).toULongLong() != generation_
                || QSizeF(image.width(), image.height()) != row.size) return {};
            const QPointer<QTextFrame> frame(qobject_cast<QTextFrame *>(document_->objectForFormat(image)));
            const auto side = placement == QStringLiteral("float_left") ? QTextFrameFormat::FloatLeft : QTextFrameFormat::FloatRight;
            const auto ownsFrame = [&] {
                return self && current() && row.widget && frame && row.owner && frame->document() == document_
                    && document_->object(frame->objectIndex()) == frame && frame->objectIndex() == image.objectIndex()
                    && frame->parentFrame() == row.owner && frame->firstPosition() == row.cursor.position() + 1
                    && frame->lastPosition() == row.cursor.position() && frame->frameFormat().position() == side
                    && row.owner->frameFormat().property(FlowConstruction::containerSourceProperty).toByteArray() == row.ownerBytes;
            };
            if (!ownsFrame()) return {};
            const auto rect = layout_->frameBoundingRect(frame);
            if (!ownsFrame() || !LogicalFlow::finiteRect(QVariant::fromValue(rect))) return {};
            constexpr qreal unit = qreal(1) / 64;
            if (rect.isEmpty() || qAbs(rect.width() - row.size.width()) > unit || qAbs(rect.height() - row.size.height()) > unit) return {};
            return rect;
        }
        const auto raw = geometry.values.value("inlineCharacterRect");
        if (!raw.isValid() && geometry.status == LogicalFlow::Status::Handled
            && LogicalFlow::finiteRect(geometry.values.value("characterRect"))
            && geometry.values.value("lineBaseline").metaType().id() == QMetaType::Double) {
            const qreal x = geometry.values.value("characterRect").toRectF().left();
            const qreal baseline = geometry.values.value("lineBaseline").toDouble();
            return QRectF(QPointF(x, baseline - row.size.height()), row.size);
        }
        if (!LogicalFlow::finiteRect(raw)) return {};
        const auto rect = raw.toRectF();
        constexpr qreal unit = qreal(1) / 64;
        if (rect.isEmpty() || qAbs(rect.width() - row.size.width()) > unit || qAbs(rect.height() - row.size.height()) > unit) return {};
        return rect;
    }
    QRectF rectangleAt(int position) const { for (const auto &row : occurrences) if (row.cursor.position() == position) return rectangle(row); return {}; }
    bool sync(const QPointF &rootOffset, const std::function<QPainterPath(int, const QPainterPath &)> &clip) {
        if (!current()) { retire(); return false; }
        const QPointer<Host> self(this); const auto generation = generation_;
        const auto same = [&] { return self && current() && generation_ == generation; };
        for (const auto &row : QList<Occurrence>(occurrences)) {
            if (!row.widget) { retire(); return false; }
            const auto border = rectangle(row); if (!same()) return false;
            if (border.isEmpty()) { retire(); return false; }
            const qreal overhang = row.widget->outlineOverhang();
            const auto canvas = border.adjusted(-overhang, -overhang, overhang, overhang);
            QPainterPath paint; paint.addRect(canvas);
            paint = clip(row.cursor.position(), paint).translated(-rootOffset);
            if (!same() || !row.widget) return false;
            QPainterPath viewport; viewport.addRect(viewport_->rect()); paint = paint.intersected(viewport);
            const auto geometry = canvas.translated(-rootOffset).toAlignedRect();
            row.widget->setGeometry(geometry); if (!same() || !row.widget) return false;
            row.widget->setBorderOrigin(border.topLeft() - rootOffset - geometry.topLeft());
            const QRegion mask(paint.translated(-geometry.topLeft()).toFillPolygon().toPolygon());
            row.widget->setMask(mask.isEmpty() ? QRegion(-2, -2, 1, 1) : mask);
            if (!same() || !row.widget) return false;
            row.widget->show(); if (!same() || !row.widget) return false;
            row.widget->raise(); if (!same()) return false;
        }
        return true;
    }
protected:
    bool eventFilter(QObject *watched, QEvent *event) override {
        if ((event->type() == QEvent::FocusIn || event->type() == QEvent::KeyPress || event->type() == QEvent::MouseButtonPress) && !current()) {
            retire(); return true;
        }
        if (event->type() == QEvent::FocusIn && current()) {
            const QPointer<Host> self(this); const auto generation = generation_;
            const auto rows = occurrences;
            for (const auto &row : rows) if (row.widget == watched) {
                const QPointer<Button> widget(row.widget); const auto show = reveal;
                if (show) show(row.cursor.position());
                return !self || !widget || generation_ != generation || !current();
            }
        }
        return QObject::eventFilter(watched, event);
    }
private:
    bool restoreHeldActivation(const QString &path, const QPointer<Button> &widget, quint64 generation) {
        if (!widget || !formatting_ || heldRevision_ < 0 || generation_ != generation || restoringHeldActivation_) return false;
        const QPointer<Host> self(this); const int heldRevision = heldRevision_;
        const auto rows = occurrences;
        for (const auto &row : rows) if (row.path == path && row.widget == widget) {
            if (row.pendingToggle && !ownsToggle(row.toggle)) return false;
            const bool checked = row.pendingToggle ? row.toggle->expanded : row.expanded;
            const QString label = checked ? widget->model().collapseLabel : widget->model().expandLabel;
            const auto same = [&] {
                if (!self || !widget || self->generation_ != generation || !self->formatting_
                    || self->heldRevision_ != heldRevision) return false;
                for (const auto &entry : self->occurrences) if (entry.path == path && entry.widget == widget
                    && entry.block == row.block && entry.expanded == row.expanded
                    && entry.pendingToggle == row.pendingToggle && entry.toggle == row.toggle) return true;
                return false;
            };
            restoringHeldActivation_ = true;
            const auto finish = qScopeGuard([self, generation] {
                if (self && self->generation_ == generation) self->restoringHeldActivation_ = false;
            });
            QSignalBlocker blocked(widget.data());
            // Qt property/accessibility callbacks may delete the widget. Never
            // restore its signal flag through a dead QObject on scope exit.
            const auto dismiss = qScopeGuard([&blocked, widget] { if (!widget) blocked.dismiss(); });
            widget->setChecked(checked); if (!same()) return false;
            widget->setText(label); if (!same()) return false;
            widget->setAccessibleName(label); if (!same()) return false;
            return widget->isChecked() == checked && widget->text() == label && widget->accessibleName() == label;
        }
        return false;
    }
    bool ownsToggle(const Toggle &ticket) const {
        if (!ticket || ticket->host != this || ticket->generation != generation_ || !ticket->widget) return false;
        for (const auto &row : occurrences) if (row.pendingToggle && row.toggle == ticket
            && row.widget == ticket->widget && row.path == ticket->path && row.block == ticket->source) return true;
        return false;
    }
    void queueMetrics(const QString &path, const QPointer<Button> &widget) {
        if (!current()) return;
        for (auto &row : occurrences) if (row.path == path && row.widget == widget) {
            if (row.pendingToggle || row.metricsQueued) return;
            row.metricsQueued = true;
            const auto generation = generation_; const QPointer<Host> self(this);
            QTimer::singleShot(0, this, [self, path, widget, generation] {
                if (!self || !widget || !self->current() || self->generation_ != generation) return;
                for (auto &entry : self->occurrences) if (entry.path == path && entry.widget == widget) {
                    entry.metricsQueued = false; if (entry.pendingToggle) return;
                    const auto size = widget->borderBoxSize(); if (size == entry.size) return;
                    const auto mutate = [self, path, widget, generation, size] {
                        require(self && widget && self->generation_ == generation);
                        for (auto &owned : self->occurrences) if (owned.path == path && owned.widget == widget) {
                            QTextCursor cursor = owned.cursor; cursor.setPosition(cursor.position() + 1, QTextCursor::KeepAnchor);
                            auto format = cursor.charFormat().toImageFormat();
                            require(format.name() == owned.resource); format.setWidth(size.width()); format.setHeight(size.height());
                            owned.size = size; cursor.setCharFormat(format); return;
                        }
                        require(false);
                    };
                    const auto edit = self->editFormats;
                    if (!edit || !edit(mutate)) { if (self) self->retire(); return; }
                    if (self && self->requestSync) self->requestSync();
                    return;
                }
            });
            return;
        }
    }
    QPointer<QTextDocument> document_;
    QPointer<QAbstractTextDocumentLayout> layout_;
    QPointer<QWidget> viewport_;
    int revision_ = -1, count_ = -1, heldRevision_ = -1;
    quint64 generation_ = 0;
    bool formatting_ = false, restoringHeldActivation_ = false, interactive_ = false;
    QString semanticText_;
};
}
