#pragma once

#include <QList>
#include <QUrl>
#include <functional>

class QAction;
class QJsonArray;
class QObject;
class QTextBrowser;
class QWidget;

// Test-only boundary: MainWindowTest keeps private access, QObject/MOC and
// lifecycle ownership. Live references retain the original field semantics.
namespace MainWindowInlineActionTest {
using ComposeReadingBlocks = std::function<bool(const QJsonArray &)>;

void inlineActionGroupsKeepRichOccurrencesKeyboardAndCopy(
    QWidget &window, QTextBrowser *const &readingBrowser, const int &readingPointSize,
    QObject &receiver, QList<QUrl> &opened, const ComposeReadingBlocks &composeReadingBlocks);
void inlineActionGroupsRejectMalformedOwnersAndChildren();
void inlineActionGroupsOwnRubyAndGenuineReadingPadding(
    QWidget &window, QTextBrowser *const &readingBrowser, const int &readingPointSize,
    QAction *const &readingPaneAction, const bool &readingFloatLayoutScheduled,
    QObject &receiver, QList<QUrl> &opened, const ComposeReadingBlocks &composeReadingBlocks);
} // namespace MainWindowInlineActionTest
