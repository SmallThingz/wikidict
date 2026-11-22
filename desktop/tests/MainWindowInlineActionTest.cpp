#include "MainWindowInlineActionTest.hpp"
#include "CompiledInlineAction.hpp"
#include "CompiledRuby.hpp"
#include "LogicalFlow.hpp"

#include <QAbstractTextDocumentLayout>
#include <QAccessible>
#include <QAction>
#include <QApplication>
#include <QBrush>
#include <QClipboard>
#include <QColor>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFont>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QPair>
#include <QScopeGuard>
#include <QScrollBar>
#include <QSet>
#include <QTextBrowser>
#include <QTextCharFormat>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextOption>
#include <QVariant>
#include <QWidget>
#include <QtMath>
#include <QtTest>
#include <stdexcept>

namespace MainWindowInlineActionTest {

void inlineActionGroupsKeepRichOccurrencesKeyboardAndCopy(
    QWidget &window, QTextBrowser *const &readingBrowser, const int &readingPointSize,
    QObject &receiver, QList<QUrl> &opened, const ComposeReadingBlocks &composeReadingBlocks)
{
    const auto leaf = [](QString text, qreal scale = 1) {
        return QJsonObject{{"kind", "text"}, {"text", text}, {"target", ""}, {"trail", ""},
            {"font_scale", scale}, {"font_scale_basis", "normal_body"}, {"direction", ""}};
    };
    const auto group = [&](QJsonArray children, QString target = QStringLiteral("https://example.invalid/one"), qreal scale = 1) {
        auto value = leaf({}, scale); value.insert("kind", "external_link"); value.insert("target", target);
        value.insert("inline_action_group", QJsonObject{{"spans", children}}); return value;
    };
    auto ku = leaf("d"); ku.insert("trail", "a");
    auto italic = leaf("Italic ", 1.2); italic.insert("italic", true);
    auto superscript = leaf("language", .9); superscript.insert("superscript", true);
    superscript.insert("inline_style", QJsonObject{{"font_normalized", true}});
    // Synthetic style controls, not an inferred current Mai computed tuple.
    const auto rich = group(QJsonArray{leaf(QString::fromUtf8("\u2192\u00a0"), 1.2), italic, superscript},
        QStringLiteral("https://example.invalid/rich"), 1.2);
    const QString bidi = QString::fromUtf8("Latin \u05d0\u05d1\u05d2 mixed words ").repeated(18);
    auto bidiGroup = group(QJsonArray{leaf(bidi)}, QStringLiteral("https://example.invalid/bidi"));
    bidiGroup.insert("foreground", "#224466"); bidiGroup.insert("background", "#fff0aa"); bidiGroup.insert("underline", true);
    const QJsonArray spans{group(QJsonArray{ku}), group(QJsonArray{leaf("d"), leaf("a")}), leaf(" "), rich,
        leaf(" "), bidiGroup,
        group(QJsonArray{leaf("")}, QStringLiteral("https://example.invalid/empty-one"), 2),
        group(QJsonArray{leaf("")}, QStringLiteral("https://example.invalid/empty-two"), 1.5)};
    const QJsonArray blocks{QJsonObject{{"kind", "paragraph"}, {"spans", spans}}};
    const auto source = QJsonDocument(blocks).toJson(QJsonDocument::Compact);
    QVERIFY(composeReadingBlocks(blocks));
    auto *browser = readingBrowser; auto *document = browser->document();
    const QString raw = document->toRawText();
    QVERIFY(raw.contains("dada ")); QVERIFY(raw.contains(bidi));
    QVERIFY(!raw.contains(QChar(0xe000))); QVERIFY(!raw.contains(QChar::ObjectReplacementCharacter));
    QCOMPARE(QJsonDocument(blocks).toJson(QJsonDocument::Compact), source);
    const auto formatAt = [&](int position) {
        QTextCursor cursor(document); cursor.setPosition(position);
        cursor.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor); return cursor.charFormat();
    };
    const int first = raw.indexOf("dada "); QVERIFY(first >= 0);
    const auto firstOwner = formatAt(first).property(QCompiledInline::ActionOwnerProperty);
    const auto secondOwner = formatAt(first + 2).property(QCompiledInline::ActionOwnerProperty);
    QVERIFY(firstOwner != secondOwner);
    QCOMPARE(formatAt(first + 1).property(QCompiledInline::ActionOwnerProperty), firstOwner);
    QCOMPARE(formatAt(first + 3).property(QCompiledInline::ActionOwnerProperty), secondOwner);
    QCOMPARE(formatAt(first).anchorHref(), formatAt(first + 2).anchorHref());
    const int italicFirst = raw.indexOf("Italic "), superFirst = raw.indexOf("language");
    QVERIFY(italicFirst >= 0 && superFirst > italicFirst);
    QVERIFY(formatAt(italicFirst).fontItalic()); QVERIFY(!formatAt(superFirst).fontItalic());
    QVERIFY(qAbs(formatAt(italicFirst).font().pointSizeF() - readingPointSize * 1.2) < .001);
    QCOMPARE(formatAt(superFirst).verticalAlignment(), QTextCharFormat::AlignNormal);
    QVERIFY(QCompiledInline::policy(formatAt(superFirst)).value("shift").toDouble() > 0);
    QVERIFY(qAbs(formatAt(superFirst).font().pointSizeF() - readingPointSize * .9) < .001);
    QTextCharFormat declaring;
    QVERIFY(QCompiledInline::actionMetric(formatAt(superFirst), &declaring));
    QVERIFY(qAbs(declaring.font().pointSizeF() - readingPointSize * 1.2) < .001);
    QCOMPARE(declaring.verticalAlignment(), QTextCharFormat::AlignNormal);
    QDesktopServices::setUrlHandler("https", &receiver, "capture");
    const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler("https"); });
    auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible && accessible->textInterface());
    const auto links = [&] {
        QList<QAccessibleInterface *> result;
        for (int i = 0; i < accessible->childCount(); ++i) {
            auto *child = accessible->child(i);
            if (child && child->role() == QAccessible::Link && child->hyperlinkInterface()
                && child->hyperlinkInterface()->anchorTarget().startsWith("https://example.invalid/")) result.append(child);
        }
        return result;
    };
    auto owners = links(); QCOMPARE(owners.size(), 6);
    QCOMPARE(owners[0]->hyperlinkInterface()->endIndex() - owners[0]->hyperlinkInterface()->startIndex(), 2);
    QCOMPARE(owners[1]->hyperlinkInterface()->startIndex(), owners[0]->hyperlinkInterface()->endIndex());
    owners[0]->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
    QTRY_VERIFY(owners[0]->state().focused);
    QTest::keyClick(browser, Qt::Key_Tab); QTRY_VERIFY(owners[1]->state().focused);
    QVERIFY(!owners[0]->state().focused);
    QTest::keyClick(browser, Qt::Key_Backtab); QTRY_VERIFY(owners[0]->state().focused);
    owners[2]->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
    const QString richRaw = QString::fromUtf8("\u2192\u00a0Italic language");
    const QTextCursor richSelection = browser->textCursor();
    QCOMPARE(richSelection.selectedText(), richRaw);
    QCOMPARE(document->toRawText().mid(richSelection.selectionStart(),
        richSelection.selectionEnd() - richSelection.selectionStart()), richRaw);
    QCOMPARE(accessible->textInterface()->text(owners[2]->hyperlinkInterface()->startIndex(),
        owners[2]->hyperlinkInterface()->endIndex()), richRaw);
    const QTextDocumentFragment richFragment(richSelection);
    QCOMPARE(richFragment.toRawText(), richRaw);
    // Stock Qt plain-text copying normalizes NBSP; raw source and AX do not.
    const QString richPlain = richFragment.toPlainText();
    QCOMPARE(richPlain, QString::fromUtf8("\u2192 Italic language"));
    QTest::keyClick(browser, Qt::Key_C, Qt::ControlModifier);
    QCOMPARE(QApplication::clipboard()->text(), richPlain);
    QCOMPARE(document->toRawText(), raw);
    QCOMPARE(QJsonDocument(blocks).toJson(QJsonDocument::Compact), source);
    owners[2]->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
    QTRY_COMPARE(opened, QList<QUrl>{QUrl("https://example.invalid/rich")});
    owners[3]->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
    QTest::keyClick(browser, Qt::Key_C, Qt::ControlModifier); QCOMPARE(QApplication::clipboard()->text(), bidi);
    const int zero = owners[4]->hyperlinkInterface()->startIndex();
    QCOMPARE(owners[4]->hyperlinkInterface()->endIndex(), zero);
    QCOMPARE(owners[5]->hyperlinkInterface()->startIndex(), zero);
    QCOMPARE(owners[5]->hyperlinkInterface()->endIndex(), zero);
    owners[4]->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
    QTRY_VERIFY(owners[4]->state().focused); QVERIFY(!browser->textCursor().hasSelection());
    QTRY_VERIFY(owners[4]->rect().height() > 0); QCOMPARE(owners[4]->rect().width(), 0);
    QTest::keyClick(browser, Qt::Key_Tab); QTRY_VERIFY(owners[5]->state().focused);
    QVERIFY(!owners[4]->state().focused);
    owners[5]->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
    QTRY_COMPARE(opened.last(), QUrl("https://example.invalid/empty-two"));
    for (int width : {480, 900}) {
        const int selectedFirst = browser->textCursor().selectionStart();
        const int selectedLast = browser->textCursor().selectionEnd();
        window.resize(width, 650); QCoreApplication::processEvents(); document->documentLayout()->documentSize();
        QCOMPARE(browser->textCursor().selectionStart(), selectedFirst);
        QCOMPARE(browser->textCursor().selectionEnd(), selectedLast);
        // Authored paint is checked without the native selection highlight.
        // The focus/copy checks below deliberately restore the full selection.
        QTextCursor unselected = browser->textCursor(); unselected.clearSelection();
        browser->setTextCursor(unselected); QCoreApplication::processEvents();
        QVERIFY(!browser->textCursor().hasSelection());
        QCOMPARE(document->toRawText(), raw); QCOMPARE(links().size(), 6);
        owners = links();
        const int begin = owners[3]->hyperlinkInterface()->startIndex(), end = owners[3]->hyperlinkInterface()->endIndex();
        QCOMPARE(accessible->textInterface()->text(begin, end), bidi);
        QSet<int> lineTops;
        for (int i = begin; i < end; ++i) {
            const auto rect = accessible->textInterface()->characterRect(i);
            if (!rect.isEmpty()) lineTops.insert(rect.top());
        }
        QVERIFY(lineTops.size() > 1);
        const QImage pixels = browser->viewport()->grab().toImage();
        const qreal dpr = pixels.devicePixelRatio();
        QSet<int> paintedLines; int latinHits = 0, hebrewHits = 0;
        for (int i = 0; i < bidi.size(); ++i) {
            if (bidi[i] != QChar('L') && bidi[i] != QChar(0x05d0)) continue;
            const QRect global = accessible->textInterface()->characterRect(begin + i);
            if (global.isEmpty()) continue;
            const QPoint local = browser->viewport()->mapFromGlobal(global.center());
            if (!browser->viewport()->rect().contains(local)) continue;
            QCOMPARE(browser->anchorAt(local), QStringLiteral("https://example.invalid/bidi"));
            bidi[i] == QChar('L') ? ++latinHits : ++hebrewHits;
            QRect scan(browser->viewport()->mapFromGlobal(global.topLeft()), global.size());
            scan &= browser->viewport()->rect(); bool background = false;
            const QRect physical(qFloor(scan.x() * dpr), qFloor(scan.y() * dpr), qCeil(scan.width() * dpr), qCeil(scan.height() * dpr));
            for (int y = physical.top(); y <= physical.bottom() && !background; ++y)
                for (int x = physical.left(); x <= physical.right(); ++x)
                    if (pixels.rect().contains(x, y) && pixels.pixelColor(x, y) == QColor("#fff0aa")) { background = true; break; }
            if (!background) {
                const auto selection = browser->textCursor();
                qInfo() << "INLINE_ACTION_BACKGROUND_FAILURE" << "width" << width
                        << "index" << i << "codepoint" << bidi[i].unicode()
                        << "selection" << selection.selectionStart() << selection.selectionEnd()
                        << "global" << global << "local" << local << "scan" << scan
                        << "physical" << physical << "dpr" << dpr
                        << "viewport" << browser->viewport()->rect()
                        << "scroll" << browser->horizontalScrollBar()->value() << browser->verticalScrollBar()->value();
                const QString directory = qEnvironmentVariable("WIKIDICT_CONTAINER_FRAME_DIR");
                QVERIFY(!directory.isEmpty()); QVERIFY(QDir().mkpath(directory));
                const QString path = QDir(directory).filePath(QStringLiteral("inline-action-background-%1.png").arg(width));
                QVERIFY(pixels.save(path)); qInfo() << "INLINE_ACTION_BACKGROUND_FRAME" << path;
            }
            QVERIFY(background); paintedLines.insert(global.top());
        }
        QVERIFY(latinHits > 0 && hebrewHits > 0); QVERIFY(paintedLines.size() > 1);
        owners[3]->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
        QTRY_VERIFY(owners[3]->state().focused);
        QCOMPARE(browser->textCursor().selectedText(), bidi);
        QTest::keyClick(browser, Qt::Key_C, Qt::ControlModifier); QCOMPARE(QApplication::clipboard()->text(), bidi);
    }
    // Mutation invalidates the native/AX occurrence registry; old identities
    // must never silently acquire the next document's same-position text.
    auto *oldLink = owners[0];
    document->setPlainText(QStringLiteral("replacement"));
    QVERIFY(!oldLink->isValid());
}

void inlineActionGroupsRejectMalformedOwnersAndChildren()
{
    const auto leaf = [](QString text) {
        return QJsonObject{{"kind", "text"}, {"text", text}, {"target", ""}, {"trail", ""}};
    };
    auto owner = leaf({}); owner.insert("kind", "link"); owner.insert("target", "d");
    owner.insert("inline_action_group", QJsonObject{{"spans", QJsonArray{leaf("d")}}});
    const auto validate = [](const QJsonObject &value) {
        qsizetype remaining = 65536;
        const auto group = CompiledInlineAction::group(value);
        CompiledInlineAction::validateBody(group.value("spans").toArray(), value, 1, 0, remaining);
    };
    validate(owner);
    CompiledRuby::Context inherited{QFont(QStringLiteral("DejaVu Sans"), 12), 12, nullptr,
        QTextOption(), QBrush(Qt::magenta)};
    const auto resolved = CompiledRuby::resolveOwner(QJsonObject{{"font", CompiledRuby::spanFont(owner)}, {"direction", ""}}, inherited);
    const auto inheritedAction = CompiledInlineAction::actionFormat(owner, qint64(1) << 32, resolved, inherited);
    QTextCharFormat inheritedMetric; QVERIFY(QCompiledInline::actionMetric(inheritedAction, &inheritedMetric));
    QCOMPARE(inheritedMetric.foreground().color(), QColor(Qt::magenta));
    for (const auto &key : {"unknown", "image", "ruby", "inline_padding_group"}) {
        auto bad = owner; bad.insert(key, QJsonObject{});
        QVERIFY_EXCEPTION_THROWN(validate(bad), std::runtime_error);
    }
    for (const auto &key : {"text", "trail"}) {
        auto bad = owner; bad.insert(key, "extra");
        QVERIFY_EXCEPTION_THROWN(validate(bad), std::runtime_error);
    }
    for (const auto &replacement : {QJsonValue(QJsonArray{}), QJsonValue("children"), QJsonValue(QJsonValue::Null)}) {
        auto bad = owner; bad.insert("inline_action_group", QJsonObject{{"spans", replacement}});
        QVERIFY_EXCEPTION_THROWN(validate(bad), std::runtime_error);
    }
    const QList<QPair<QString, QJsonValue>> corrupt{
        {"target", 123}, {"underline", "yes"}, {"strike", 1}, {"tooltip", QJsonObject{}},
        {"direction", "rtl"}, {"text", QJsonValue(QJsonValue::Null)}, {"trail", false},
        {"unknown", true}, {"kind", "break"}, {"image", QJsonObject{}},
        {"link_paint", QJsonObject{}}, {"text", "line\nbreak"}};
    for (const auto &change : corrupt) {
        auto bad = owner; auto child = leaf("d"); child.insert(change.first, change.second);
        bad.insert("inline_action_group", QJsonObject{{"spans", QJsonArray{child}}});
        QVERIFY_EXCEPTION_THROWN(validate(bad), std::runtime_error);
    }
    auto competing = leaf("d"); competing.insert("kind", "link"); competing.insert("target", "d");
    auto bad = owner; bad.insert("inline_action_group", QJsonObject{{"spans", QJsonArray{competing}}});
    QVERIFY_EXCEPTION_THROWN(validate(bad), std::runtime_error);
    auto direction = owner; direction.insert("direction", "ltr");
    QVERIFY_EXCEPTION_THROWN(validate(direction), std::runtime_error);
    qsizetype exhausted = 0;
    QVERIFY_EXCEPTION_THROWN(CompiledInlineAction::validateBody(QJsonArray{leaf("d")}, owner, 1, 0, exhausted), std::runtime_error);
    qsizetype budget = 100;
    QVERIFY_EXCEPTION_THROWN(CompiledInlineAction::validateBody(QJsonArray{leaf("d")}, owner, 17, 0, budget), std::runtime_error);
    auto empty = owner; empty.insert("inline_action_group", QJsonObject{{"spans", QJsonArray{leaf("")}}});
    validate(empty);
}

void inlineActionGroupsOwnRubyAndGenuineReadingPadding(
    QWidget &window, QTextBrowser *const &readingBrowser, const int &readingPointSize,
    QAction *const &readingPaneAction, const bool &readingFloatLayoutScheduled,
    QObject &receiver, QList<QUrl> &opened, const ComposeReadingBlocks &composeReadingBlocks)
{
    const auto leaf = [](QString text, double scale = 1) {
        return QJsonObject{{"kind", "text"}, {"text", text}, {"target", ""}, {"trail", ""},
            {"font_scale", scale}, {"font_scale_basis", "normal_body"}, {"direction", ""}};
    };
    const auto snapshot = [](double scale) {
        return QJsonObject{{"font", QJsonObject{{"font_scale", scale}, {"font_scale_basis", "normal_body"},
            {"font_normalized", false}, {"bold", false}, {"italic", false}, {"small", false},
            {"superscript", false}, {"subscript", false}, {"code", false}}}, {"direction", "ltr"},
            {"inline_style", QJsonValue()}, {"foreground", QJsonValue()}, {"background", QJsonValue()}};
    };
    const QString base = QString::fromUtf8("切"), reading = QStringLiteral("thiet");
    const QString target = QStringLiteral("https://example.invalid/ruby-owner");
    QDesktopServices::setUrlHandler("https", &receiver, "capture");
    const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler("https"); });
    for (bool padded : {false, true}) {
        auto text = leaf(reading, .65); text.insert("italic", true); text.insert("underline", true);
        text.insert("foreground", "#0000ff");
        auto annotation = text;
        if (padded) {
            annotation = leaf({}, .8);
            const QJsonObject edge{{"unit", "em"}, {"value", .25}};
            annotation.insert("inline_padding_group", QJsonObject{{"left", edge}, {"right", edge}, {"spans", QJsonArray{text}}});
        }
        auto ruby = leaf({});
        ruby.insert("ruby", QJsonObject{{"segments", QJsonArray{QJsonObject{{"gap_before", QJsonArray{}},
            {"bases", QJsonArray{QJsonObject{{"owner", snapshot(1)}, {"gap_before", QJsonArray{}}, {"spans", QJsonArray{leaf(base)}}}}},
            {"annotations", QJsonArray{QJsonObject{{"owner", snapshot(.65)}, {"base_start", 0}, {"base_count", 1}, {"level", 0},
                {"gap_before", QJsonArray{}}, {"spans", QJsonArray{annotation}}, {"fallback_before", QJsonArray{leaf("(")}},
                {"fallback_after", QJsonArray{leaf(")")}}, {"explicit_fallback", true}}}}}}}});
        auto action = leaf({}, 1.2); action.insert("kind", "external_link"); action.insert("target", target);
        action.insert("underline", true);
        action.insert("inline_action_group", QJsonObject{{"spans", QJsonArray{leaf("left "), ruby, leaf(" right")}}});
        const QJsonArray blocks{QJsonObject{{"kind", "paragraph"}, {"spans", QJsonArray{leaf("Before "), action, leaf(" after")}}}};
        const QByteArray source = QJsonDocument(blocks).toJson(QJsonDocument::Compact);
        QVERIFY(composeReadingBlocks(blocks)); readingPaneAction->trigger();
        auto *browser = readingBrowser; auto *document = browser->document();
        const QString selected = QStringLiteral("left ") + base + reading + QStringLiteral(" right");
        const QString raw = document->toRawText(); const int first = raw.indexOf(selected);
        QVERIFY(first >= 0); QCOMPARE(raw.count(selected), 1);
        QVERIFY(!raw.contains(QChar(0xe000))); QVERIFY(!raw.contains(QChar::ObjectReplacementCharacter));
        const int baseAt = first + 5, readingAt = baseAt + base.size();
        QTextCursor format(document); format.setPosition(readingAt);
        format.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
        QVERIFY(format.charFormat().fontItalic()); QVERIFY(format.charFormat().fontUnderline());
        QVERIFY(qAbs(format.charFormat().fontPointSize() - readingPointSize * .65) < .001);
        QTextCharFormat declaring; QVERIFY(QCompiledInline::actionMetric(format.charFormat(), &declaring));
        QVERIFY(qAbs(declaring.fontPointSize() - readingPointSize * 1.2) < .001);
        QCOMPARE(declaring.foreground(), document->find(QStringLiteral("Before")).charFormat().foreground());
        QCOMPARE(format.charFormat().foreground().color(), QColor(Qt::blue));
        for (int width : {900, 480, 900}) {
            window.resize(width, 650); readingPaneAction->trigger();
            QTRY_VERIFY(browser->isVisible() && !readingFloatLayoutScheduled);
            QTRY_COMPARE(document->pageSize(), QSizeF(browser->viewport()->width(), -1));
            document->documentLayout()->documentSize();
            QCOMPARE(document->documentLayout()->property("_wikidictParagraphBoxLayoutError").toInt(), 0);
            QCOMPARE(document->toRawText(), raw);
            auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible && accessible->textInterface());
            auto *content = accessible->textInterface(); QAccessibleInterface *link = nullptr;
            for (int i = 0; i < accessible->childCount(); ++i) {
                auto *candidate = accessible->child(i);
                if (candidate && candidate->hyperlinkInterface() && candidate->hyperlinkInterface()->anchorTarget() == target) {
                    QVERIFY(!link); link = candidate;
                }
            }
            QVERIFY(link && link->actionInterface());
            QCOMPARE(link->text(QAccessible::Name), selected);
            QCOMPARE(content->text(link->hyperlinkInterface()->startIndex(), link->hyperlinkInterface()->endIndex()), selected);
            link->actionInterface()->doAction(QAccessibleActionInterface::setFocusAction());
            QTRY_VERIFY(link->state().focused);
            QCOMPARE(browser->textCursor().selectionStart(), first);
            QCOMPARE(browser->textCursor().selectionEnd(), first + selected.size());
            QTest::keyClick(browser, Qt::Key_C, Qt::ControlModifier);
            QCOMPARE(QApplication::clipboard()->text(), selected);
            for (const int position : {baseAt, readingAt}) {
                const auto geometry = LogicalFlow::position(document, position);
                QCOMPARE(geometry.status, LogicalFlow::Status::Handled);
                const auto character = geometry.values.value("characterRect").toRectF(); QVERIFY(!character.isEmpty());
                const QPoint local = character.center().toPoint() - QPoint(browser->horizontalScrollBar()->value(), browser->verticalScrollBar()->value());
                QVERIFY(browser->viewport()->rect().contains(local)); QCOMPARE(browser->anchorAt(local), target);
            }
            const auto geometry = LogicalFlow::position(document, readingAt);
            const auto actionBox = geometry.values.value("actionRect").toRectF();
            if (padded) {
                const auto character = geometry.values.value("characterRect").toRectF();
                QVERIFY(!actionBox.isEmpty()); QVERIFY(actionBox.left() < character.left());
                const QPointF padding((actionBox.left() + character.left()) / 2, character.center().y());
                const QPoint local = padding.toPoint() - QPoint(browser->horizontalScrollBar()->value(), browser->verticalScrollBar()->value());
                QCOMPARE(browser->anchorAt(local), target);
            } else QVERIFY(actionBox.isEmpty());
            const int calls = opened.size();
            link->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
            QTRY_COMPARE(opened.size(), calls + 1); QCOMPARE(opened.last(), QUrl(target));
            QCOMPARE(QJsonDocument(blocks).toJson(QJsonDocument::Compact), source);
        }
    }
}

} // namespace MainWindowInlineActionTest
