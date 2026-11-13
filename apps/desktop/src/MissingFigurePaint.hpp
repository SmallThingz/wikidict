#pragma once

#include <QAbstractTextDocumentLayout>
#include <QColor>
#include <QJsonObject>
#include <QJsonDocument>
#include <QJsonArray>
#include <cmath>
#include <stdexcept>
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
inline constexpr int fixedPolicyProperty = policyProperty + 5;
inline constexpr int outlineProperty = policyProperty + 6;
inline constexpr int atomicProperty = policyProperty + 7;
inline const QString fixedPolicy = QStringLiteral("wikidict.figure-link-state/1");
inline const QString ordinaryPolicy = QStringLiteral("wikidict.ordinary-link-state/1");
inline bool present(const QJsonValue &v) { return !v.isUndefined() && !v.isNull(); }
inline void require(bool condition) { if (!condition) throw std::runtime_error("invalid Figure link paint"); }
inline bool canonicalRgb(const QJsonValue &value) {
    if (!value.isString()) return false;
    const auto text = value.toString();
    if (text.size() != 7 || text[0] != QChar('#')) return false;
    for (const auto c : text.mid(1))
        if (!((c >= QChar('0') && c <= QChar('9')) || (c >= QChar('a') && c <= QChar('f')))) return false;
    return true;
}
inline qreal length(const QJsonValue &value, qreal em, bool signedValue = false) {
    require(value.isObject()); const auto object = value.toObject();
    require(object.size() == 2 && object.value("unit").isString() && object.value("value").isDouble());
    const auto unit = object.value("unit").toString(); const double number = object.value("value").toDouble();
    require((unit == "px" || unit == "em") && std::isfinite(number) && (signedValue || number >= 0));
    const qreal used = unit == "em" ? number * em : number;
    require(std::isfinite(used) && qAbs(used) < 1e6); return used;
}
inline QJsonObject validate(const QJsonValue &value, qreal em) {
    if (!present(value)) return {};
    require(value.isObject() && std::isfinite(em) && em > 0);
    const auto object = value.toObject();
    const QStringList states{"normal", "hover", "active", "visited", "visited_hover", "visited_active"};
    for (auto it = object.begin(); it != object.end(); ++it)
        require(states.contains(it.key()) || it.key() == "underline_on_focus" || it.key() == "focus_outline");
    for (const auto &name : states) {
        require(object.value(name).isObject()); const auto state = object.value(name).toObject();
        require(state.size() == 2 && canonicalRgb(state.value("foreground")) && state.value("underline").isBool());
    }
    require(object.value("underline_on_focus").isBool());
    if (present(object.value("focus_outline"))) {
        require(object.value("focus_outline").isObject()); const auto outline = object.value("focus_outline").toObject();
        require(outline.size() == 4); length(outline.value("width"), em); length(outline.value("radius"), em);
        length(outline.value("offset"), em, true);
        const auto color = outline.value("color").toObject();
        require(color.size() == 2 && color.value("kind") == "rgb" && canonicalRgb(color.value("value")));
    }
    return object;
}
inline QJsonObject validateOrdinary(const QJsonValue &value, qreal em) {
    require(value.isObject());
    const auto object = value.toObject(); auto base = object;
    for (const auto &key : {"hover_active", "visited_hover_active"}) {
        const auto value = base.take(QLatin1String(key));
        require(value.isObject()); const auto state = value.toObject();
        require(state.size() == 2 && canonicalRgb(state.value("foreground")) && state.value("underline").isBool());
    }
    validate(base, em);
    return object;
}
inline QVariantMap outline(const QJsonObject &paint, qreal em) {
    if (!present(paint.value("focus_outline"))) return {};
    const auto source = paint.value("focus_outline").toObject();
    return {{"width", length(source.value("width"), em)}, {"radius", length(source.value("radius"), em)},
        {"offset", length(source.value("offset"), em, true)},
        {"color", QColor(source.value("color").toObject().value("value").toString())}};
}
inline const QString policy = QStringLiteral("vector_new_link_v1");
enum class Interaction { Rest, Hover, Active };
struct State {
    qint64 hovered = -1;
    qint64 pressed = -1;
    qint64 focused = -1;
    bool focusVisible = false;
    QString context;
    QString fixedContext;
    QSet<QString> visitedTargets;
};
inline QString targetKey(const State &state, const QString &href) {
    const QUrl url(href);
    const QString encoded = url.toString(QUrl::FullyEncoded);
    return url.scheme() == QStringLiteral("dict") ? state.context + QChar(0) + encoded : encoded;
}
inline QString fixedTargetKey(const State &state, const QString &href) {
    const QUrl url(href);
    return QStringLiteral("figure-link-state/1:") + QString::fromUtf8(QJsonDocument(QJsonArray{
        state.fixedContext, url.scheme(), url.toString(QUrl::FullyEncoded)}).toJson(QJsonDocument::Compact));
}
inline QColor foreground(bool dark, bool visited, Interaction interaction) {
    const int index = (visited ? 3 : 0) + (interaction == Interaction::Active ? 2 : interaction == Interaction::Hover ? 1 : 0);
    static const char *const light[] = {"#bf3c2c", "#9f3526", "#612419", "#9f5555", "#854848", "#512e2e"};
    static const char *const night[] = {"#fd7865", "#fea898", "#ffc8bd", "#c99391", "#dcb5b3", "#e8cecd"};
    return QColor(QString::fromLatin1(dark ? night[index] : light[index]));
}
inline bool owns(const QTextCharFormat &format) {
    return (format.stringProperty(policyProperty) == policy || format.stringProperty(policyProperty) == fixedPolicy
            || format.stringProperty(policyProperty) == ordinaryPolicy)
        && format.isAnchor() && !format.anchorHref().isEmpty()
        && format.hasProperty(ownerProperty) && format.property(ownerProperty).toLongLong() >= 0;
}
inline qint64 ownerAt(QTextDocument *document, int position) {
    if (!document || position < 0 || position >= document->characterCount() - 1) return -1;
    QTextCursor cursor(document); cursor.setPosition(position);
    cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
    return owns(cursor.charFormat()) ? cursor.charFormat().property(ownerProperty).toLongLong() : -1;
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
            const qint64 owner = format.property(ownerProperty).toLongLong();
            const auto interaction = owner == state.pressed ? Interaction::Active
                : owner == state.hovered ? Interaction::Hover : Interaction::Rest;
            const bool zero = format.boolProperty(zeroFontProperty);
            const bool ordinary = format.stringProperty(policyProperty) == ordinaryPolicy;
            const bool fixed = ordinary || format.stringProperty(policyProperty) == fixedPolicy;
            const auto paint = QJsonObject::fromVariantMap(format.property(fixedPolicyProperty).toMap());
            const bool visited = state.visitedTargets.contains(fixed ? fixedTargetKey(state, format.anchorHref()) : targetKey(state, format.anchorHref()));
            const QString stateName = ordinary && owner == state.hovered && owner == state.pressed
                ? (visited ? QStringLiteral("visited_hover_active") : QStringLiteral("hover_active")) : visited
                ? (interaction == Interaction::Active ? QStringLiteral("visited_active") : interaction == Interaction::Hover ? QStringLiteral("visited_hover") : QStringLiteral("visited"))
                : (interaction == Interaction::Active ? QStringLiteral("active") : interaction == Interaction::Hover ? QStringLiteral("hover") : QStringLiteral("normal"));
            const auto selected = paint.value(stateName).toObject();
            const QColor ink = zero ? QColor(Qt::transparent) : fixed
                ? QColor(selected.value("foreground").toString()) : foreground(dark, visited, interaction);
            QTextCharFormat overlay;
            overlay.setProperty(overlayProperty, true);
            overlay.setForeground(ink);
            const bool underline = !zero && ((!ordinary && format.boolProperty(underlineProperty)) || (fixed
                ? selected.value("underline").toBool() || (owner == state.focused && paint.value("underline_on_focus").toBool())
                : interaction != Interaction::Rest));
            overlay.setUnderlineStyle(underline ? QTextCharFormat::SingleUnderline : QTextCharFormat::NoUnderline);
            QTextCursor cursor(document); cursor.setPosition(fragment.position());
            cursor.setPosition(fragment.position() + fragment.length(), QTextCursor::KeepAnchor);
            result.append({cursor, overlay});
        }
    }
    return result;
}
inline QRectF focusBox(QTextDocument *document, qint64 owner) {
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
