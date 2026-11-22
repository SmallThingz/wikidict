#pragma once

#include "DictApi.hpp"
#include "LogicalFlow.hpp"
#include "MediaPanel.hpp"
#include "SemanticHtml.hpp"
#include "FlowConstruction.hpp"

#include <QApplication>
#include <QAbstractTextDocumentLayout>
#include <QJsonDocument>
#include <QJsonArray>
#include <QLayout>
#include <QPainterPath>
#include <QPointer>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextObjectInterface>
#include <QTextLayout>
#include <QWidget>
#include <QEvent>
#include <QFocusEvent>
#include <QRegion>
#include <QScopeGuard>
#include <functional>
#include <utility>

// The document owns the inline allocation; the viewport owns real native
// controls. Resource/player state remains in MediaPanel, never in this handler.
class InlineAudioControls final : public QObject, public QTextObjectInterface {
    Q_OBJECT
    Q_INTERFACES(QTextObjectInterface)
public:
    static constexpr int ObjectType = QTextFormat::UserObject + 0x71;
    static constexpr int SourceProperty = QTextFormat::UserProperty + 0x5870;
    static constexpr int IdentityProperty = QTextFormat::UserProperty + 0x5871;
    static constexpr auto Scheme = "wikidict-audio-control";
    struct Occurrence {
        QTextCursor cursor;
        QJsonObject span;
        QPointer<QWidget> widget;
        QSizeF size;
        int identity = -1;
        int sourceOrdinal = -1;
        int basePosition = -1;
        QString text;
        bool bound = false;
    };
    QList<Occurrence> occurrences;
    std::function<void()> requestSync;
    std::function<void(int)> reveal;
    std::function<void(bool)> enterKeyboardFocus;

    InlineAudioControls(QTextDocument *document, MediaPanel *media, QWidget *viewport)
        : QObject(document->documentLayout()), document_(document), layout_(document->documentLayout()),
          media_(media), viewport_(viewport) {
        if (layout_->handlerForObject(ObjectType)) throw DictApiError("duplicate audio object handler");
        layout_->registerHandler(ObjectType, this);
        connect(document, &QTextDocument::contentsChanged, this, [this] {
            const QPointer<InlineAudioControls> self(this);
            if (!formatting_ && revision_ >= 0 && !current()) retire();
            if (self && requestSync) requestSync();
        });
    }
    ~InlineAudioControls() override { retire(); }
    static bool present(const QJsonObject &span) { return SemanticHtml::present(span.value("audio_control")); }
    static bool nestedAudio(const QJsonValue &value) {
        QList<QJsonValue> pending{value};
        while (!pending.isEmpty()) {
            const auto next = pending.takeLast();
            if (next.isArray()) {
                for (const auto &child : next.toArray()) pending.append(child);
            } else if (next.isObject()) {
                const auto object = next.toObject();
                if (present(object)) return true;
                for (auto it = object.begin(); it != object.end(); ++it) pending.append(it.value());
            }
        }
        return false;
    }
    static QString marker(const QJsonObject &span, qreal normalPoints, int sourceOrdinal) {
        if (!present(span) || !span.value("audio_control").isObject()
            || span.value("kind") != QJsonValue("link") || !span.value("text").isString())
            throw DictApiError("invalid audio occurrence");
        for (const char *key : {"image", "ruby", "inline_box_group", "inline_action_group", "inline_padding_group", "link_paint"})
            if (SemanticHtml::present(span.value(QLatin1String(key)))) throw DictApiError("unsupported audio inline owner");
        const auto bytes = QJsonDocument(QJsonArray{span, normalPoints, sourceOrdinal}).toJson(QJsonDocument::Compact);
        return QStringLiteral("<a href=\"%1:%2\">%3</a>").arg(QLatin1String(Scheme),
            QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)),
            QString(QChar::ObjectReplacementCharacter));
    }
    bool current() const {
        return document_ && layout_ && viewport_ && media_ && document_->documentLayout() == layout_
            && document_->revision() == revision_ && document_->characterCount() == count_;
    }
    bool empty() const { return occurrences.isEmpty(); }
    bool ownsFocusWidget(const QWidget *widget) const {
        if (!widget || !current()) return false;
        for (const auto &row : occurrences)
            if (row.bound && row.widget && media_->audioOccurrenceCurrent(row.widget)
                && (widget == row.widget || row.widget->isAncestorOf(widget))) return true;
        return false;
    }
    QList<QPair<int, QPointer<QWidget>>> focusTargets() const {
        QList<QPair<int, QPointer<QWidget>>> result;
        if (!current()) return result;
        for (const auto &row : occurrences) {
            if (!row.bound || !row.widget || !media_->audioOccurrenceCurrent(row.widget)) continue;
            auto *first = row.widget->focusProxy();
            if (!first || !row.widget->isAncestorOf(first)) continue;
            auto *child = first;
            do {
                if (!row.widget->isAncestorOf(child)) break;
                if ((child->focusPolicy() & Qt::TabFocus) && child->isEnabled() && child->isVisible())
                    result.append({row.cursor.position(), child});
                child = child->nextInFocusChain();
            } while (child != first);
        }
        return result;
    }
    void setMedia(MediaPanel *media) {
        if (!occurrences.isEmpty() || !media) throw DictApiError("audio controller replacement requires retired views");
        media_ = media;
    }
    void retire() {
        const QPointer<InlineAudioControls> self(this);
        const auto old = std::exchange(occurrences, {});
        semanticText_.clear();
        revision_ = -1; count_ = -1;
        formatting_ = false;
        ++generation_;
        for (const auto &row : old) if (row.widget) {
            if (media_) media_->retireAudioOccurrence(row.widget);
            if (!self) return;
            if (row.widget && viewport_ && viewport_->parentWidget() && (row.widget->hasFocus()
                || row.widget->isAncestorOf(QApplication::focusWidget()))) viewport_->parentWidget()->setFocus(Qt::OtherFocusReason);
            if (!self) return;
            if (row.widget) row.widget->setEnabled(false);
            if (!self) return;
            if (row.widget) row.widget->hide();
            if (!self) return;
            if (row.widget) row.widget->deleteLater();
        }
    }
    void expand(const QJsonArray &catalog) {
        if (!document_ || !layout_ || !media_ || !viewport_ || document_->isLayoutEnabled())
            throw DictApiError("audio outside owned composition");
        const QPointer<InlineAudioControls> self(this);
        const auto expected = generation_;
        const auto same = [&] { return self && document_ && layout_ && media_ && viewport_
            && document_->documentLayout() == layout_ && !document_->isLayoutEnabled() && generation_ == expected; };
        struct Marker { int position; QTextCharFormat format; QJsonArray data; };
        QList<Marker> markers;
        QSet<int> sourceOrdinals;
        for (auto block = document_->begin(); block.isValid(); block = block.next())
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (!fragment.isValid() || !fragment.charFormat().isAnchor()) continue;
                const QUrl url(fragment.charFormat().anchorHref());
                if (url.scheme() != QLatin1String(Scheme)) continue;
                const auto encoded = url.path().toLatin1();
                const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
                QJsonParseError error;
                const auto parsed = QJsonDocument::fromJson(bytes, &error);
                if (error.error != QJsonParseError::NoError || !parsed.isArray() || parsed.array().size() != 3
                    || !parsed.array()[0].isObject() || !parsed.array()[1].isDouble()
                    || !parsed.array()[2].isDouble() || parsed.array()[2].toDouble() < 0
                    || parsed.array()[2].toDouble() != parsed.array()[2].toInt()
                    || parsed.toJson(QJsonDocument::Compact) != bytes || fragment.length() != 1
                    || fragment.text() != QString(QChar::ObjectReplacementCharacter))
                    throw DictApiError("invalid audio import marker");
                if (sourceOrdinals.contains(parsed.array()[2].toInt())) throw DictApiError("duplicate audio source occurrence");
                sourceOrdinals.insert(parsed.array()[2].toInt());
                markers.append({fragment.position(), fragment.charFormat(), parsed.array()});
            }
        for (const auto &marker : markers) {
            QTextCursor owner(document_); owner.setPosition(marker.position);
            for (auto *frame = owner.currentFrame(); frame && frame != document_->rootFrame(); frame = frame->parentFrame()) {
                const auto format = frame->frameFormat();
                if (qobject_cast<QTextTable *>(frame) || format.position() != QTextFrameFormat::InFlow
                    || format.stringProperty(FlowConstruction::containerPolicyProperty) != "wikidict.plain-container/1")
                    throw DictApiError("audio control needs an ordinary in-flow source owner");
                // Reject the reserved absolute-owner marker without importing its producer.
                constexpr int unsupportedAbsoluteOwnerProperty = QTextFormat::UserProperty + 0x5861;
                for (int property : {FlowConstruction::containerColumnsProperty, FlowConstruction::containerPositioningProperty,
                     FlowConstruction::containerFixedFloatProperty, unsupportedAbsoluteOwnerProperty,
                     FlowConstruction::containerFlexProperty, FlowConstruction::containerFlexItemProperty})
                    if (format.hasProperty(property)) throw DictApiError("unsupported audio paint owner");
            }
            Occurrence row;
            row.span = marker.data[0].toObject(); row.text = row.span.value("text").toString() + row.span.value("trail").toString();
            const QString file = row.span.value("target").toString().mid(5);
            int matching = 0;
            for (const auto &raw : catalog) if (raw.toObject().value("file") == QJsonValue(file)) {
                if (raw.toObject().value("kind") != QJsonValue("audio")) throw DictApiError("audio source has foreign media kind");
                ++matching;
            }
            if (matching != 1) throw DictApiError("audio source has no unique catalog resource");
            row.identity = occurrences.size();
            row.sourceOrdinal = marker.data[2].toInt();
            row.widget = media_->createAudioOccurrence(row.span, viewport_);
            bool retained = false;
            const auto discard = qScopeGuard([&] { if (!retained && row.widget) row.widget->deleteLater(); });
            if (!same() || !row.widget) throw DictApiError("audio control construction refused");
            row.widget->hide(); if (!same() || !row.widget) throw DictApiError("stale audio control");
            const QPointer<QWidget> proxy(row.widget->focusProxy());
            if (!proxy || !row.widget->isAncestorOf(proxy)) throw DictApiError("audio control has no owned focus proxy");
            // Qt orders a compound widget only when the aggregate itself has a
            // focus policy. Preserve the native Play policy and native child order.
            row.widget->setFocusPolicy(proxy->focusPolicy());
            if (!same() || !row.widget || !proxy) throw DictApiError("stale audio focus policy");
            // The source label's font is not playback-chrome typography. Keep
            // the native widget font; the inline object still has its real host strut.
            if (!row.widget->layout()) throw DictApiError("audio control has no native layout");
            row.widget->layout()->setSizeConstraint(QLayout::SetNoConstraint);
            row.widget->setMinimumSize(0, 0);
            if (!same() || !row.widget) throw DictApiError("stale audio allocation");
            if (!SemanticHtml::present(row.span.value("direction"))) {
                auto direction = marker.format.layoutDirection();
                if (direction == Qt::LayoutDirectionAuto) direction = document_->findBlock(marker.position).blockFormat().layoutDirection();
                if (direction == Qt::LayoutDirectionAuto) direction = document_->defaultTextOption().textDirection();
                if (direction == Qt::LayoutDirectionAuto) direction = viewport_->layoutDirection();
                row.widget->setLayoutDirection(direction);
                if (!same() || !row.widget) throw DictApiError("stale audio direction");
            }
            row.widget->ensurePolished(); if (!same() || !row.widget) throw DictApiError("stale audio metrics");
            row.widget->setProperty("wikidict.audio.position", marker.position);
            if (!same() || !row.widget) throw DictApiError("stale audio occurrence");
            row.widget->setProperty("wikidict.audio.sourceOrdinal", row.sourceOrdinal);
            if (!same() || !row.widget) throw DictApiError("stale audio source identity");
            row.size = row.widget->sizeHint();
            const auto policy = row.span.value("audio_control").toObject();
            const qreal scale = layout_->paintDevice() ? layout_->paintDevice()->logicalDpiY() / qreal(96) : qreal(1);
            const qreal em = marker.data[1].toDouble() * 96 / 72;
            const auto axis = [&](const QJsonValue &raw, bool width, qreal native) {
                if (!SemanticHtml::present(raw)) return native;
                if (!raw.isObject()) throw DictApiError("invalid audio dimension");
                const auto value = raw.toObject(); const QString unit = value.value("unit").toString();
                const qreal number = value.value("value").toDouble(-1);
                if (value.size() != 2 || !value.value("value").isDouble() || !qIsFinite(number) || number <= 0
                    || (unit != "px" && unit != "em"))
                    throw DictApiError(width ? "audio percentage width needs native containing allocation" : "invalid audio height");
                return number * (unit == "em" ? em : qreal(1)) * scale;
            };
            row.size.setWidth(axis(policy.value("width"), true, row.size.width()));
            row.size.setHeight(axis(policy.value("height"), false, row.size.height()));
            if (!qIsFinite(em) || em <= 0 || !qIsFinite(row.size.width()) || !qIsFinite(row.size.height())
                || row.size.width() <= 0 || row.size.height() <= 0
                || row.size.width() > QWIDGETSIZE_MAX || row.size.height() > QWIDGETSIZE_MAX) {
                row.widget->deleteLater(); throw DictApiError("invalid native audio metrics");
            }
            row.widget->setProperty("wikidict.audio.allocatedSize", row.size);
            for (auto *child : row.widget->findChildren<QWidget *>()) child->installEventFilter(this);
            row.widget->installEventFilter(this);
            QTextCharFormat format = marker.format;
            for (int property : {QTextFormat::ImageName, QTextFormat::ImageWidth, QTextFormat::ImageHeight,
                                 QTextFormat::ObjectIndex, QTextFormat::AnchorHref, QTextFormat::AnchorName}) format.clearProperty(property);
            format.setAnchor(false); format.setObjectType(ObjectType); format.setVerticalAlignment(QTextCharFormat::AlignNormal);
            format.setProperty(SourceProperty, QJsonDocument(row.span).toJson(QJsonDocument::Compact));
            format.setProperty(IdentityProperty, row.identity);
            QTextCursor cursor(document_); cursor.setPosition(marker.position);
            cursor.setPosition(marker.position + 1, QTextCursor::KeepAnchor); cursor.setCharFormat(format);
            if (!same() || !row.widget) throw DictApiError("stale audio source replacement");
            row.cursor = QTextCursor(document_); row.cursor.setPosition(marker.position); row.cursor.setKeepPositionOnInsert(true);
            occurrences.append(row);
            retained = true;
        }
    }
    bool seal(const std::function<int(int)> &baseOffset) {
        if (!document_ || !layout_ || document_->documentLayout() != layout_) return false;
        const QPointer<InlineAudioControls> self(this);
        const auto expected = generation_;
        const int revision = document_->revision(), count = document_->characterCount();
        const auto same = [&] { return self && document_ && layout_ && generation_ == expected
            && document_->documentLayout() == layout_ && document_->revision() == revision && document_->characterCount() == count; };
        int previous = -1;
        const auto rows = occurrences;
        for (auto row : rows) {
            const int position = row.cursor.position();
            QTextCursor cursor(document_); cursor.setPosition(position); cursor.setPosition(position + 1, QTextCursor::KeepAnchor);
            const auto format = cursor.charFormat();
            if (!row.widget || cursor.selectedText() != QString(QChar::ObjectReplacementCharacter)
                || format.objectType() != ObjectType || format.property(IdentityProperty).metaType().id() != QMetaType::Int
                || format.intProperty(IdentityProperty) != row.identity
                || format.property(SourceProperty).toByteArray() != QJsonDocument(row.span).toJson(QJsonDocument::Compact)) return false;
            row.basePosition = baseOffset(position);
            if (row.basePosition <= previous || baseOffset(position + 1) != row.basePosition + 1) return false;
            previous = row.basePosition;
            if (!same()) return false;
            occurrences[row.identity].basePosition = row.basePosition;
            row.widget->setProperty("wikidict.audio.position", position);
            if (!same()) return false;
        }
        revision_ = document_->revision(); count_ = document_->characterCount(); return true;
    }
    bool refreshRevision() {
        if (!document_ || !layout_ || document_->documentLayout() != layout_ || document_->characterCount() != count_) return false;
        return seal([&](int position) {
            for (const auto &row : occurrences) {
                if (row.cursor.position() == position) return row.basePosition;
                if (row.cursor.position() + 1 == position) return row.basePosition + 1;
            }
            return -1;
        });
    }
    bool holdFormats() {
        if (!current() || formatting_) return false;
        formatting_ = true;
        const QPointer<InlineAudioControls> self(this);
        const auto rows = occurrences;
        for (const auto &row : rows) if (row.widget) {
            row.widget->setEnabled(false);
            if (!self) return false;
            if (!current()) { retire(); return false; }
        }
        return true;
    }
    void releaseFormats(bool accepted) {
        if (!formatting_) return;
        formatting_ = false;
        if (!accepted || !current()) { retire(); return; }
        const QPointer<InlineAudioControls> self(this);
        const auto rows = occurrences;
        for (const auto &row : rows) {
            if (!row.widget || (row.bound && !media_->audioOccurrenceCurrent(row.widget))) { retire(); return; }
            row.widget->setEnabled(true);
            if (!self) return;
            if (!current()) { retire(); return; }
        }
    }
    bool bind() {
        if (!current()) return false;
        const QPointer<InlineAudioControls> self(this);
        const auto expected = generation_;
        const auto rows = occurrences;
        for (const auto &row : rows) {
            const bool bound = row.widget && media_->bindAudioOccurrence(row.widget, row.span);
            if (!self) return false;
            if (!bound || !current() || generation_ != expected) { retire(); return false; }
            occurrences[row.identity].bound = true;
        }
        if (requestSync) requestSync();
        return true;
    }
    QSizeF intrinsicSize(QTextDocument *document, int position, const QTextFormat &format) override {
        const int id = format.intProperty(IdentityProperty);
        if (document != document_ || format.property(IdentityProperty).metaType().id() != QMetaType::Int
            || id < 0 || id >= occurrences.size()) return {};
        const auto &row = occurrences[id];
        if (!row.widget || row.cursor.position() != position
            || format.property(SourceProperty).toByteArray() != QJsonDocument(row.span).toJson(QJsonDocument::Compact)) return {};
        return row.size;
    }
    void drawObject(QPainter *, const QRectF &, QTextDocument *, int, const QTextFormat &) override {
        if (requestSync) requestSync();
    }
    QRectF rectangle(const Occurrence &row) const {
        if (!current()) return {};
        const QPointer<const InlineAudioControls> self(this);
        const int position = row.cursor.position();
        const auto queried = LogicalFlow::position(document_, position);
        if (!self || !current() || queried.status == LogicalFlow::Status::Refused) return {};
        qreal x = 0, baseline = 0;
        if (queried.status == LogicalFlow::Status::Handled) {
            if (!LogicalFlow::finiteRect(queried.values.value("characterRect"))
                || queried.values.value("lineBaseline").metaType().id() != QMetaType::Double) return {};
            x = queried.values.value("characterRect").toRectF().left(); baseline = queried.values.value("lineBaseline").toDouble();
        } else {
            if (row.identity < 0 || row.identity >= occurrences.size()) return {};
            const auto &owned = occurrences.at(row.identity);
            if (!row.widget || owned.widget != row.widget || owned.cursor.position() != position
                || row.cursor.document() != document_ || owned.span != row.span || owned.size != row.size) return {};
            QTextCursor cursor(document_); cursor.setPosition(position);
            cursor.setPosition(position + 1, QTextCursor::KeepAnchor);
            const auto format = cursor.charFormat();
            if (cursor.selectedText() != QString(QChar::ObjectReplacementCharacter)
                || format.objectType() != ObjectType || format.verticalAlignment() != QTextCharFormat::AlignNormal
                || format.property(IdentityProperty).metaType().id() != QMetaType::Int
                || format.intProperty(IdentityProperty) != row.identity
                || format.property(SourceProperty).toByteArray() != QJsonDocument(row.span).toJson(QJsonDocument::Compact)
                || !LogicalFlow::finiteRect(queried.values.value("inlineCharacterRect"))) return {};
            const auto rect = queried.values.value("inlineCharacterRect").toRectF();
            // Native object advances are quantized to 26.6 layout units. Cursor
            // edges describe insertion positions and cannot place an RTL object.
            constexpr qreal layoutUnit = qreal(1) / 64;
            if (rect.isEmpty() || qAbs(rect.width() - row.size.width()) > layoutUnit
                || qAbs(rect.height() - row.size.height()) > layoutUnit) return {};
            return self && current() ? rect : QRectF();
        }
        return self && current() ? QRectF(QPointF(x, baseline - row.size.height()), row.size) : QRectF();
    }
    QRectF rectangleAt(int position) const {
        for (const auto &row : occurrences) if (row.cursor.position() == position) return rectangle(row);
        return {};
    }
    void sync(const QPointF &rootOffset, const std::function<QPainterPath(int, const QPainterPath &)> &clip) {
        if (!current()) { retire(); return; }
        const QPointer<InlineAudioControls> self(this);
        const auto expected = generation_;
        const auto same = [&] { return self && current() && generation_ == expected; };
        const auto rows = occurrences;
        for (const auto &row : rows) {
            if (!row.bound) continue;
            if (!row.widget || !media_->audioOccurrenceCurrent(row.widget)) { retire(); return; }
            const auto rect = rectangle(row); if (!same() || !row.widget) return;
            QPainterPath path; path.addRect(rect); path = clip(row.cursor.position(), path).translated(-rootOffset);
            if (!same() || !row.widget) return;
            QPainterPath viewportPath; viewportPath.addRect(viewport_->rect()); path = path.intersected(viewportPath);
            const QRect geometry = rect.translated(-rootOffset).toAlignedRect();
            row.widget->setGeometry(geometry); if (!same() || !row.widget) return;
            const QRegion mask(path.translated(-geometry.topLeft()).toFillPolygon().toPolygon());
            row.widget->setMask(mask.isEmpty() ? QRegion(-2, -2, 1, 1) : mask);
            if (!same() || !row.widget) return;
            // Keep enabled offscreen controls in the keyboard chain. An empty
            // native mask clips paint/input; FocusIn reveals this exact occurrence.
            row.widget->setVisible(true); if (!same() || !row.widget) return;
            row.widget->raise();
            if (!same()) return;
        }
    }
    int toSource(int base) const {
        int extra = 0;
        for (const auto &row : occurrences) if (row.basePosition < base) extra += row.text.size() - 1;
        return base + extra;
    }
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
    QString sourceText(QString base) const {
        for (auto it = occurrences.crbegin(); it != occurrences.crend(); ++it) {
            if (it->basePosition < 0 || it->basePosition >= base.size()
                || base[it->basePosition] != QChar::ObjectReplacementCharacter) return {};
            base.replace(it->basePosition, 1, it->text);
        }
        return base;
    }
    bool cacheText(QString base) {
        if (!current()) return false;
        if (empty()) { semanticText_.clear(); return true; }
        const int expected = toSource(base.size());
        semanticText_ = sourceText(std::move(base));
        return semanticText_.size() == expected;
    }
    QString text(int first, int last) const {
        return current() && first >= 0 && last >= first && last <= semanticText_.size()
            ? semanticText_.mid(first, last - first) : QString();
    }
protected:
    bool eventFilter(QObject *watched, QEvent *event) override {
        if (!current() && revision_ >= 0 && (event->type() == QEvent::FocusIn
            || event->type() == QEvent::MouseButtonPress || event->type() == QEvent::KeyPress)) {
            retire(); return true;
        }
        if (event->type() == QEvent::LayoutRequest && current()) {
            const QPointer<InlineAudioControls> self(this);
            const auto rows = occurrences;
            for (const auto &row : rows) if (row.widget && watched == row.widget) {
                const auto native = row.widget->sizeHint();
                if (!self || !current() || !row.widget) return false;
                auto size = row.size; const auto policy = row.span.value("audio_control").toObject();
                if (!SemanticHtml::present(policy.value("width"))) size.setWidth(native.width());
                if (!SemanticHtml::present(policy.value("height"))) size.setHeight(native.height());
                if (size != row.size && size.width() > 0 && size.height() > 0
                    && size.width() <= QWIDGETSIZE_MAX && size.height() <= QWIDGETSIZE_MAX) {
                    occurrences[row.identity].size = size;
                    document_->markContentsDirty(row.cursor.position(), 1);
                    if (!self) return false;
                    if (requestSync) requestSync();
                }
                break;
            }
        }
        if (event->type() == QEvent::FocusIn && current())
            for (const auto &row : occurrences) if (row.widget && (watched == row.widget
                || row.widget->isAncestorOf(qobject_cast<QWidget *>(watched)))) {
                if (row.bound && media_->audioOccurrenceCurrent(row.widget)) {
                    const QPointer<InlineAudioControls> self(this);
                    const QPointer<QWidget> focused(qobject_cast<QWidget *>(watched));
                    const auto generation = generation_;
                    const auto revealCurrent = reveal;
                    if (revealCurrent) revealCurrent(row.cursor.position());
                    if (!focused) return true;
                    if (!self || generation_ != generation || !current() || !ownsFocusWidget(focused)) return false;
                    const auto reason = static_cast<QFocusEvent *>(event)->reason();
                    const auto enterCurrent = enterKeyboardFocus;
                    if (enterCurrent && (reason == Qt::TabFocusReason || reason == Qt::BacktabFocusReason))
                        enterCurrent(reason == Qt::TabFocusReason);
                    if (!focused) return true;
                    if (!self || generation_ != generation || !current() || !ownsFocusWidget(focused)) return false;
                }
                break;
            }
        return QObject::eventFilter(watched, event);
    }
private:
    QPointer<QTextDocument> document_;
    QPointer<QAbstractTextDocumentLayout> layout_;
    QPointer<MediaPanel> media_;
    QPointer<QWidget> viewport_;
    int revision_ = -1, count_ = -1;
    quint64 generation_ = 0;
    bool formatting_ = false;
    QString semanticText_;
};
