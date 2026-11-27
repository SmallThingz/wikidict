#pragma once

#include "CompiledDisclosureModel.hpp"
#include <QAbstractButton>
#include <QFocusEvent>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QStyleOptionButton>
#include <QTextLayout>
#include <QtMath>
#include <QtGui/private/qcssutil_p.h>
#include <array>
#include <functional>
#include <optional>
#include <utility>

// Qt consumes JSON emitted by the validated public decoder. Duplicate JSON
// keys must be rejected before QJsonObject construction by that decoder.
namespace CompiledDisclosure {
// The host places the border box at its original Container owner and applies
// the declared inline/float placement. Outline overhang is independent of flow.
class Button final : public QAbstractButton {
public:
    Button(Model model, const QColor &inheritedForeground, Qt::LayoutDirection inheritedDirection, QWidget *parent = nullptr)
        : QAbstractButton(parent), model_(std::move(model)), inheritedForeground_(inheritedForeground) {
        require(inheritedForeground.isValid());
        setCheckable(true); setAutoRepeat(false); setFocusPolicy(Qt::StrongFocus); setMouseTracking(true);
        setLayoutDirection(model_.direction.value_or(inheritedDirection));
        setChecked(!model_.initiallyCollapsed);
        if (model_.button) {
            const auto &button = *model_.button;
            QFont declared(button.fontFamily);
            declared.setPointSizeF(button.fontSize * 72 / 96);
            declared.setWeight(QFont::Normal); declared.setItalic(false);
            require(QFontInfo(declared).family().compare(button.fontFamily, Qt::CaseInsensitive) == 0);
            require(QFontInfo(declared).weight() == QFont::Normal && !QFontInfo(declared).italic());
            setFont(declared);
            verifyLabel(model_.expandLabel); verifyLabel(model_.collapseLabel);
        }
        for (const auto &label : {model_.expandLabel, model_.collapseLabel}) for (int state = 0; state < 4; ++state) {
            const auto size = borderBoxSizeFor(label, state);
            require(size.width() + 2 * outlineOverhang() <= QWIDGETSIZE_MAX
                && size.height() + 2 * outlineOverhang() <= QWIDGETSIZE_MAX);
        }
        updateLabel();
        connect(this, &QAbstractButton::pressed, this, [this] { notifyMetrics(); update(); });
        connect(this, &QAbstractButton::released, this, [this] { notifyMetrics(); update(); });
        connect(this, &QAbstractButton::toggled, this, [this](bool expanded) {
            updateLabel();
            if (expandedChanged) expandedChanged(model_.contentIndex, expanded);
        });
    }
    std::function<void(quint32, bool)> expandedChanged;
    std::function<void()> metricsChanged;
    bool pointerHovered() const { return hovered_; }
    void setBorderOrigin(const QPointF &origin) { borderOrigin_ = origin; update(); }
    QPointF borderOrigin() const { return borderOrigin_.value_or(QPointF(outlineOverhang(), outlineOverhang())); }
    const Model &model() const { return model_; }
    bool focusVisible() const { return hasFocus() && focusVisible_; }
    std::optional<QColor> currentOutlineColor() const {
        return model_.button ? outlineColor(*model_.button, hasFocus(), focusVisible()) : std::nullopt;
    }
    QSizeF borderBoxSize() const { return borderBoxSizeFor(text(), stateIndex(hovered_, isDown())); }
    QSizeF borderBoxSizeFor(const QString &label, int stateIndexValue) const {
        require(stateIndexValue >= 0 && stateIndexValue < 4);
        QTextLayout layout(label, font(), const_cast<Button *>(this));
        const auto textSize = configureLayout(layout);
        if (!model_.button) {
            const auto option = nativeOption(label);
            const auto size = style()->sizeFromContents(QStyle::CT_PushButton, &option,
                QSize(qCeil(textSize.width()), qCeil(textSize.height())), this);
            require(size.width() > 0 && size.height() > 0 && size.width() <= QWIDGETSIZE_MAX && size.height() <= QWIDGETSIZE_MAX);
            return size;
        }
        const auto &button = *model_.button;
        const auto &state = button.states[stateIndexValue];
        const qreal scale = logicalDpiY() / qreal(96);
        const QSizeF size(textSize.width() + (button.padding[1] + button.padding[3] + state.border[1].width + state.border[3].width) * scale,
            textSize.height() + (button.padding[0] + button.padding[2] + state.border[0].width + state.border[2].width) * scale);
        require(std::isfinite(size.width()) && std::isfinite(size.height()) && size.width() <= QWIDGETSIZE_MAX && size.height() <= QWIDGETSIZE_MAX);
        return size;
    }
    qreal outlineOverhang() const {
        const auto outline = model_.button ? model_.button->focusVisible : std::nullopt;
        return outline ? qMax(qreal(0), outline->width + outline->offset) * logicalDpiY() / 96 : 0;
    }
    QSize sizeHint() const override {
        const auto size = borderBoxSize() + QSizeF(outlineOverhang() * 2, outlineOverhang() * 2);
        require(size.width() <= QWIDGETSIZE_MAX && size.height() <= QWIDGETSIZE_MAX);
        return QSize(qCeil(size.width()), qCeil(size.height()));
    }
protected:
    bool hitButton(const QPoint &point) const override {
        return QRectF(borderOrigin(), borderBoxSize()).contains(point);
    }
    void focusInEvent(QFocusEvent *event) override {
        focusVisible_ = event->reason() != Qt::MouseFocusReason;
        QAbstractButton::focusInEvent(event); update();
    }
    void focusOutEvent(QFocusEvent *event) override {
        pressedRun_ = false;
        focusVisible_ = false; enterDown_ = false; setDown(false);
        QAbstractButton::focusOutEvent(event); notifyMetrics(); update();
    }
    void mousePressEvent(QMouseEvent *event) override {
        focusVisible_ = false;
        hovered_ = hitButton(event->position().toPoint());
        pointer_ = event->globalPosition();
        if (event->button() == Qt::LeftButton) {
            pressedRun_ = false;
            const auto &run = currentRun();
            if (run && run->pointerOnRun) {
                QTextLayout layout(text(), font(), this);
                layoutLabel(layout, *run);
                pressedRun_ = runHit(layout, *run, mapFromGlobal(*pointer_));
            }
        }
        QAbstractButton::mousePressEvent(event); update();
    }
    void mouseReleaseEvent(QMouseEvent *event) override {
        pointer_ = event->globalPosition();
        if (event->button() == Qt::LeftButton) pressedRun_ = false;
        QAbstractButton::mouseReleaseEvent(event);
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        pointer_ = event->globalPosition();
        if (!(event->buttons() & Qt::LeftButton)) pressedRun_ = false;
        hovered_ = hitButton(event->position().toPoint());
        QAbstractButton::mouseMoveEvent(event); notifyMetrics(); update();
    }
    void keyPressEvent(QKeyEvent *event) override {
        if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
            if (!event->isAutoRepeat()) { enterDown_ = true; focusVisible_ = true; setDown(true); notifyMetrics(); update(); }
            event->accept(); return;
        }
        if (event->key() == Qt::Key_Space) focusVisible_ = true;
        QAbstractButton::keyPressEvent(event);
    }
    void keyReleaseEvent(QKeyEvent *event) override {
        if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
            const bool activate = enterDown_ && hasFocus() && isEnabled() && !event->isAutoRepeat();
            if (!event->isAutoRepeat()) { enterDown_ = false; setDown(false); notifyMetrics(); update(); }
            event->accept();
            if (activate) click();
            return;
        }
        QAbstractButton::keyReleaseEvent(event);
    }
    void enterEvent(QEnterEvent *event) override {
        pointer_ = event->globalPosition();
        hovered_ = hitButton(event->position().toPoint());
        QAbstractButton::enterEvent(event); notifyMetrics(); update();
    }
    void leaveEvent(QEvent *event) override { pointer_.reset(); hovered_ = false; QAbstractButton::leaveEvent(event); notifyMetrics(); update(); }
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        if (!model_.button) {
            auto option = nativeOption(text());
            option.rect = QRect(QPoint(), borderBoxSize().toSize());
            painter.translate(borderOrigin());
            style()->drawControl(QStyle::CE_PushButton, &option, &painter, this);
            return;
        }
        painter.setRenderHint(QPainter::Antialiasing);
        const auto &button = *model_.button;
        const int index = stateIndex(hovered_, isDown());
        const auto &state = button.states[index];
        const qreal scale = logicalDpiY() / qreal(96);
        const QRectF box(borderOrigin(), borderBoxSize());
        painter.fillRect(box, state.background);
        const QCss::Edge sides[] = {QCss::TopEdge, QCss::RightEdge, QCss::BottomEdge, QCss::LeftEdge};
        // Hidden edges are excluded below; keep their unused slot valid for QCss.
        const QCss::BorderStyle styles[] = {QCss::BorderStyle_None, QCss::BorderStyle_None, QCss::BorderStyle_Solid,
            QCss::BorderStyle_Dotted, QCss::BorderStyle_Inset, QCss::BorderStyle_Outset};
        for (int side = 0; side < 4; ++side) {
            const auto &border = state.border[side];
            if (border.kind == BorderKind::None || border.kind == BorderKind::Hidden || border.width == 0) continue;
            QRectF edge = box;
            if (side == 0) edge.setBottom(edge.top() + border.width * scale);
            else if (side == 1) edge.setLeft(edge.right() - border.width * scale);
            else if (side == 2) edge.setTop(edge.bottom() - border.width * scale);
            else edge.setRight(edge.left() + border.width * scale);
            const int start = side % 2 == 0 ? 3 : 0, end = side % 2 == 0 ? 1 : 2;
            qDrawEdge(&painter, edge.left(), edge.top(), edge.right(), edge.bottom(), state.border[start].width * scale,
                state.border[end].width * scale, sides[side], styles[static_cast<int>(border.kind)], QBrush(border.color));
        }
        QTextLayout layout(text(), font(), this);
        const auto &run = currentRun();
        QList<QTextLayout::FormatRange> selection;
        if (run) {
            layoutLabel(layout, *run);
            if (run->pointerOnRun) {
                const bool hover = pointer_ && runHit(layout, *run, mapFromGlobal(*pointer_));
                selection.append({run->utf16Start, run->utf16Length,
                    labelFormat(labelPaint(*run, hover, pressedRun_ && isDown(), hasFocus()))});
            }
        } else configureLayout(layout);
        painter.setPen(model_.foreground.value_or(inheritedForeground_));
        layout.draw(&painter, labelOrigin(), selection);
        if (focusVisible() && button.focusVisible) {
            const auto &outline = *button.focusVisible;
            const qreal expansion = (outline.offset + outline.width / 2) * scale;
            painter.setBrush(Qt::NoBrush); painter.setPen(QPen(outline.color, outline.width * scale));
            painter.drawRect(box.adjusted(-expansion, -expansion, expansion, expansion));
        }
    }
private:
    const std::optional<LabelRun> &currentRun() const {
        return isChecked() ? model_.collapseRun : model_.expandRun;
    }
    QPointF labelOrigin() const {
        const auto &button = *model_.button;
        const auto &state = button.states[stateIndex(hovered_, isDown())];
        const auto scale = logicalDpiY() / qreal(96);
        return borderOrigin() + QPointF((button.padding[3] + state.border[3].width) * scale,
            (button.padding[0] + state.border[0].width) * scale);
    }
    static QTextCharFormat labelFormat(const LabelPaint &paint) {
        QTextCharFormat format;
        format.setForeground(paint.foreground);
        format.setFontUnderline(paint.underline);
        return format;
    }
    void layoutLabel(QTextLayout &layout, const LabelRun &run) const {
        // Shape the range once. Pointer-only colors and underline can be overlaid at draw time.
        const auto paint = labelPaint(run, !run.pointerOnRun && hovered_, !run.pointerOnRun && isDown(), hasFocus());
        layout.setFormats({{run.utf16Start, run.utf16Length, labelFormat(paint)}});
        configureLayout(layout);
    }
    bool runHit(const QTextLayout &layout, const LabelRun &run, const QPointF &point) const {
        if (!QRectF(borderOrigin(), borderBoxSize()).contains(point)) return false;
        const auto local = point - labelOrigin();
        for (int i = 0; i < layout.lineCount(); ++i) {
            const auto line = layout.lineAt(i);
            const auto rect = line.naturalTextRect();
            if (local.y() < rect.top() || local.y() >= rect.bottom() ||
                local.x() < rect.left() || local.x() >= rect.right()) continue;
            const int pos = line.xToCursor(local.x(), QTextLine::CursorOnCharacter);
            if (pos >= run.utf16Start && pos < run.utf16Start + run.utf16Length) return true;
        }
        return false;
    }
    QStyleOptionButton nativeOption(QString label) const {
        QStyleOptionButton option;
        option.initFrom(this);
        // Localized labels are literal text in the native style API.
        option.text = label.replace(QChar('&'), QStringLiteral("&&"));
        option.state.setFlag(QStyle::State_MouseOver, hovered_);
        option.state.setFlag(QStyle::State_Sunken, isDown());
        option.state.setFlag(QStyle::State_Raised, !isDown());
        option.state.setFlag(QStyle::State_HasFocus, focusVisible());
        option.state.setFlag(QStyle::State_KeyboardFocusChange, focusVisible());
        return option;
    }
    void notifyMetrics() { updateGeometry(); if (metricsChanged) metricsChanged(); }
    void updateLabel() {
        pressedRun_ = false;
        setText(isChecked() ? model_.collapseLabel : model_.expandLabel);
        setAccessibleName(text()); notifyMetrics(); update();
    }
    QSizeF configureLayout(QTextLayout &layout) const {
        QTextOption option;
        option.setWrapMode(QTextOption::NoWrap); option.setTextDirection(layoutDirection());
        layout.setTextOption(option);
        layout.beginLayout();
        qreal width = 0, height = 0;
        // Consume every authored line, including Unicode line separators.
        // This is local control measurement; no public nowrap field is added.
        while (true) {
            auto line = layout.createLine();
            if (!line.isValid()) break;
            line.setLineWidth(QWIDGETSIZE_MAX);
            const qreal lineHeight = model_.button && model_.button->lineHeight
                ? *model_.button->lineHeight * logicalDpiY() / 96 : line.height();
            line.setPosition(QPointF(0, height + (lineHeight - line.height()) / 2));
            width = qMax(width, line.naturalTextWidth()); height += lineHeight;
        }
        layout.endLayout();
        require(layout.lineCount() > 0);
        return QSizeF(width, height);
    }
    void verifyLabel(const QString &text) const {
        QTextLayout layout(text, font(), const_cast<Button *>(this));
        configureLayout(layout);
        for (const auto &run : layout.glyphRuns()) {
            require(run.rawFont().familyName().compare(model_.button->fontFamily, Qt::CaseInsensitive) == 0);
            for (auto glyph : run.glyphIndexes()) require(glyph != 0);
        }
    }
    std::optional<QPointF> borderOrigin_, pointer_;
    bool pressedRun_ = false;
    Model model_;
    QColor inheritedForeground_;
    bool focusVisible_ = false, enterDown_ = false, hovered_ = false;
};
}
