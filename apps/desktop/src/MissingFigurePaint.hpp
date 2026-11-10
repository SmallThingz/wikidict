#pragma once

#include <QAbstractTextDocumentLayout>
#include <QColor>
#include <QJsonObject>
#include <QPalette>
#include <QSet>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextFragment>
#include <QTextFrame>
#include <QTextEdit>
#include <QUrl>
#include <QVector>

// App-local presentation properties. They carry only already-compiled policy;
// no stylesheet, browser history, or external state is consulted here.
namespace MissingFigurePaint {
inline constexpr int policyProperty = QTextFormat::UserProperty + 0x57b4;
inline constexpr int ownerProperty = policyProperty + 1;
inline constexpr int underlineProperty = policyProperty + 2;
inline constexpr int zeroFontProperty = policyProperty + 3;
inline constexpr int overlayProperty = policyProperty + 4;
inline const QString policy = QStringLiteral("vector_new_link_v1");
enum class Interaction { Rest, Hover, Active };
struct State {
    int hovered = -1;
    int pressed = -1;
    int focused = -1;
    bool focusVisible = false;
    QString context;
    QSet<QString> visitedTargets;
};
inline QString targetKey(const State &state, const QString &href) {
    const QUrl url(href);
    const QString encoded = url.toString(QUrl::FullyEncoded);
    return url.scheme() == QStringLiteral("dict") ? state.context + QChar(0) + encoded : encoded;
}
inline QColor foreground(bool dark, bool visited, Interaction interaction) {
    const int index = (visited ? 3 : 0) + (interaction == Interaction::Active ? 2 : interaction == Interaction::Hover ? 1 : 0);
    static const char *const light[] = {"#bf3c2c", "#9f3526", "#612419", "#9f5555", "#854848", "#512e2e"};
    static const char *const night[] = {"#fd7865", "#fea898", "#ffc8bd", "#c99391", "#dcb5b3", "#e8cecd"};
    return QColor(QString::fromLatin1(dark ? night[index] : light[index]));
}
inline bool owns(const QTextCharFormat &format) {
    return format.stringProperty(policyProperty) == policy && format.isAnchor()
        && format.hasProperty(ownerProperty) && format.intProperty(ownerProperty) >= 0;
}
inline int ownerAt(QTextDocument *document, int position) {
    if (!document || position < 0 || position >= document->characterCount() - 1) return -1;
    QTextCursor cursor(document); cursor.setPosition(position);
    cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
    return owns(cursor.charFormat()) ? cursor.charFormat().intProperty(ownerProperty) : -1;
}
// Interactive color/decoration is a standard text selection overlay. It never
// edits document formats, revisions, source positions or logical owner maps.
inline QList<QTextEdit::ExtraSelection> selections(QTextDocument *document, const QPalette &palette, const State &state) {
    QList<QTextEdit::ExtraSelection> result;
    const bool dark = palette.color(QPalette::Base).lightness() < 128;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment(); if (!fragment.isValid()) continue;
            auto format = fragment.charFormat(); if (!owns(format)) continue;
            const int owner = format.intProperty(ownerProperty);
            const auto interaction = owner == state.pressed ? Interaction::Active
                : owner == state.hovered ? Interaction::Hover : Interaction::Rest;
            const bool zero = format.boolProperty(zeroFontProperty);
            const QColor ink = zero ? QColor(Qt::transparent)
                : foreground(dark, state.visitedTargets.contains(targetKey(state, format.anchorHref())), interaction);
            QTextCharFormat overlay;
            overlay.setProperty(overlayProperty, true);
            overlay.setForeground(ink);
            const bool underline = !zero && (format.boolProperty(underlineProperty) || interaction != Interaction::Rest);
            overlay.setUnderlineStyle(underline ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
            QTextCursor cursor(document); cursor.setPosition(fragment.position());
            cursor.setPosition(fragment.position() + fragment.length(), QTextCursor::KeepAnchor);
            result.append({cursor, overlay});
        }
    }
    return result;
}
inline QRectF focusBox(QTextDocument *document, int owner) {
    if (!document || owner < 0) return {};
    QRectF found;
    const auto visit = [&](auto &&self, QTextFrame *parent) -> void {
        for (auto *frame : parent->childFrames()) {
            const auto format = frame->frameFormat();
            if (format.stringProperty(policyProperty) == policy && format.intProperty(ownerProperty) == owner)
                found = document->documentLayout()->frameBoundingRect(frame);
            self(self, frame);
        }
    };
    visit(visit, document->rootFrame());
    return found;
}
}
