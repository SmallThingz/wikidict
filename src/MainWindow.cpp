#include "MainWindow.hpp"
#include "LibraryDialog.hpp"
#include "MediaPanel.hpp"

#include <QApplication>
#include <QAccessible>
#include <QAccessibleWidget>
#include <QAbstractTextDocumentLayout>
#include <QTextCursor>
#include <QTextLayout>
#include <QAction>
#include <QCheckBox>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QFormLayout>
#include <QFontDatabase>
#include <QFutureWatcher>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QMouseEvent>
#include <QMenu>
#include <QPalette>
#include <QPushButton>
#include <QProgressBar>
#include <QRandomGenerator>
#include <QScrollArea>
#include <QScrollBar>
#include <QSettings>
#include <QSet>
#include <QShortcut>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QStackedWidget>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QSplitter>
#include <QTabWidget>
#include <QTextBrowser>
#include <QTextBlock>
#include <QTextBoundaryFinder>
#include <QTextDocument>
#include <QTextEdit>
#include <QTextFragment>
#include <QTextOption>
#include <QTimer>
#include <QtMath>
#include <QUrl>
#include <QVBoxLayout>
#include <QWidget>
#include <QtConcurrent/QtConcurrentRun>
#include <algorithm>
#include <array>
namespace {
class HeadingBrowser final : public QTextBrowser {
public:
    explicit HeadingBrowser(QWidget *parent) : QTextBrowser(parent) {
        setFrameShape(QFrame::NoFrame);
        setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        setTextInteractionFlags(Qt::TextSelectableByMouse);
        setFocusPolicy(Qt::ClickFocus);
        setOpenLinks(false);
        setOpenExternalLinks(false);
        document()->setDocumentMargin(0);
        setWordWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
        setStyleSheet(QStringLiteral("background: transparent; border: 0; padding: 0;"));
        connect(document(), &QTextDocument::contentsChanged, this, [this] {
            setAccessibleName(toPlainText());
            fitHeight();
        });
        connect(document()->documentLayout(), &QAbstractTextDocumentLayout::documentSizeChanged,
                this, [this] { fitHeight(); });
    }
protected:
    void resizeEvent(QResizeEvent *event) override {
        QTextBrowser::resizeEvent(event);
        fitHeight();
    }
private:
    bool fitting_ = false;
    void fitHeight() {
        if (fitting_) return;
        fitting_ = true;
        document()->setTextWidth(qMax(1, viewport()->width()));
        setFixedHeight(qMax(1, qCeil(document()->size().height())));
        fitting_ = false;
    }
};

class ReadingBrowser final : public QTextBrowser {
public:
    using QTextBrowser::QTextBrowser;
    bool keyboardActivation = false;
    quint64 interaction = 0;
    void restoreAnchor(const QUrl &url) {
        int count = 0;
        bool present = false;
        for (auto block = document()->begin(); block.isValid(); block = block.next()) {
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const auto fragment = it.fragment();
                if (!fragment.isValid() || fragment.charFormat().anchorHref().isEmpty()) continue;
                ++count;
                present |= QUrl(fragment.charFormat().anchorHref()) == url;
            }
        }
        if (!present) return;
        QTextCursor beginning(document());
        beginning.movePosition(QTextCursor::Start);
        setTextCursor(beginning);
        for (int i = 0; i <= count; ++i) {
            if (!QTextBrowser::focusNextPrevChild(true)) break;
            QTextCursor selected = textCursor();
            if (!selected.hasSelection()) continue;
            selected.setPosition(selected.selectionStart());
            selected.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            if (QUrl(selected.charFormat().anchorHref()) == url) break;
        }
    }
protected:
    void keyPressEvent(QKeyEvent *event) override {
        ++interaction;
        keyboardActivation = event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter;
        QTextBrowser::keyPressEvent(event);
        keyboardActivation = false;
    }
    void mousePressEvent(QMouseEvent *event) override {
        ++interaction;
        QTextBrowser::mousePressEvent(event);
    }
};

#if QT_VERSION >= QT_VERSION_CHECK(6, 12, 0)
using ReadingAccessibleBase = QAccessibleWidgetV2;
#else
using ReadingAccessibleBase = QAccessibleWidget;
#endif

// Restrict the workaround to our reader. Other Qt text widgets retain their own adapters.
class AccessibleReadingBrowser final : public ReadingAccessibleBase,
                                       public QAccessibleTextInterface,
                                       public QAccessibleEditableTextInterface {
public:
    explicit AccessibleReadingBrowser(ReadingBrowser *browser)
        : ReadingAccessibleBase(browser, QAccessible::StaticText), browser_(browser) {}

    void *interface_cast(QAccessible::InterfaceType type) override {
        if (type == QAccessible::TextInterface) return static_cast<QAccessibleTextInterface *>(this);
        if (type == QAccessible::EditableTextInterface) return static_cast<QAccessibleEditableTextInterface *>(this);
        return ReadingAccessibleBase::interface_cast(type);
    }
    QAccessible::State state() const override {
        auto result = ReadingAccessibleBase::state();
        result.multiLine = true; result.selectableText = true;
        result.readOnly = browser_->isReadOnly(); result.editable = !result.readOnly;
        return result;
    }
    QString text(QAccessible::Text type) const override {
        if (type == QAccessible::Value) return browser_->toPlainText();
        return ReadingAccessibleBase::text(type);
    }
    int characterCount() const override { return qMax(0, browser_->document()->characterCount() - 1); }
    QString text(int start, int end) const override {
        if (end == -1) end = characterCount();
        if (!validRange(start, end)) return {};
        QTextCursor cursor(browser_->document()); cursor.setPosition(start);
        cursor.setPosition(end, QTextCursor::KeepAnchor);
        return cursor.selectedText().replace(QChar(QChar::ParagraphSeparator), QChar('\n'));
    }
    QString textAtOffset(int offset, QAccessible::TextBoundaryType boundary, int *start, int *end) const override {
        if (boundary == QAccessible::LineBoundary) return visualLine(offset, 0, start, end);
        if (boundary == QAccessible::ParagraphBoundary) return paragraphText(offset, 0, start, end);
        return QAccessibleTextInterface::textAtOffset(offset == -2 ? cursorPosition() : offset, boundary, start, end);
    }
    QString textBeforeOffset(int offset, QAccessible::TextBoundaryType boundary, int *start, int *end) const override {
        if (boundary == QAccessible::LineBoundary) return visualLine(offset, -1, start, end);
        if (boundary == QAccessible::ParagraphBoundary) return paragraphText(offset, -1, start, end);
        return QAccessibleTextInterface::textBeforeOffset(offset == -2 ? cursorPosition() : offset, boundary, start, end);
    }
    QString textAfterOffset(int offset, QAccessible::TextBoundaryType boundary, int *start, int *end) const override {
        if (boundary == QAccessible::LineBoundary) return visualLine(offset, 1, start, end);
        if (boundary == QAccessible::ParagraphBoundary) return paragraphText(offset, 1, start, end);
        return QAccessibleTextInterface::textAfterOffset(offset == -2 ? cursorPosition() : offset, boundary, start, end);
    }
    int cursorPosition() const override { return browser_->textCursor().position(); }
    void setCursorPosition(int offset) override {
        if (!validRange(offset, offset)) return;
        QTextCursor cursor(browser_->document()); cursor.setPosition(offset); browser_->setTextCursor(cursor);
    }
    int selectionCount() const override { return browser_->textCursor().hasSelection() ? 1 : 0; }
    void selection(int index, int *start, int *end) const override {
        *start = *end = -1;
        if (index != 0 || !selectionCount()) return;
        const auto cursor = browser_->textCursor(); *start = cursor.selectionStart(); *end = cursor.selectionEnd();
    }
    void setSelection(int index, int start, int end) override {
        if (index != 0 || !validRange(start, end)) return;
        QTextCursor cursor(browser_->document()); cursor.setPosition(start);
        cursor.setPosition(end, QTextCursor::KeepAnchor); browser_->setTextCursor(cursor);
    }
    void addSelection(int start, int end) override { setSelection(0, start, end); }
    void removeSelection(int index) override {
        if (index != 0) return;
        auto cursor = browser_->textCursor(); cursor.clearSelection(); browser_->setTextCursor(cursor);
    }
    QRect characterRect(int offset) const override {
        if (offset < 0 || offset >= characterCount()) return {};
        const QTextBlock block = browser_->document()->findBlock(offset);
        const QString blockText = block.text();
        int start = offset - block.position();
        if (start < blockText.size()) {
            QTextBoundaryFinder finder(QTextBoundaryFinder::Grapheme, blockText);
            finder.setPosition(start);
            if (!finder.isAtBoundary()) start = finder.toPreviousBoundary();
        }
        const QRectF blockRect = browser_->document()->documentLayout()->blockBoundingRect(block);
        const auto line = block.layout()->lineForTextPosition(start);
        if (!line.isValid()) return {};
        const qreal leading = line.cursorToX(start, QTextLine::Leading);
        const qreal trailing = line.cursorToX(start, QTextLine::Trailing);
        // Both edges belong to this character on this visual line. Adjacent cursor
        // positions may instead jump to another line or the far side of a bidi run.
        QRectF result(blockRect.left() + qMin(leading, trailing), blockRect.top() + line.y(),
                      qMax(qreal(1), qAbs(trailing - leading)), line.height());
        result.translate(browser_->viewport()->mapToGlobal(QPoint())
                         - QPoint(browser_->horizontalScrollBar()->value(), browser_->verticalScrollBar()->value()));
        return result.toAlignedRect();
    }
    int offsetAtPoint(const QPoint &screenPoint) const override {
        const QPoint local = browser_->viewport()->mapFromGlobal(screenPoint);
        const QPoint document = local + QPoint(browser_->horizontalScrollBar()->value(), browser_->verticalScrollBar()->value());
        return browser_->document()->documentLayout()->hitTest(document, Qt::ExactHit);
    }
    void scrollToSubstring(int start, int end) override {
        if (!validRange(start, end)) return;
        QTextCursor first(browser_->document()); first.setPosition(start);
        QTextCursor last(browser_->document()); last.setPosition(end);
        const QRect wanted = browser_->cursorRect(first).united(browser_->cursorRect(last));
        const QRect viewport = browser_->viewport()->rect();
        const int dy = wanted.height() > viewport.height() || wanted.top() < 0 ? wanted.top()
            : qMax(0, wanted.bottom() - viewport.bottom());
        const int dx = wanted.width() > viewport.width() || wanted.left() < 0 ? wanted.left()
            : qMax(0, wanted.right() - viewport.right());
        browser_->verticalScrollBar()->setValue(browser_->verticalScrollBar()->value() + dy);
        browser_->horizontalScrollBar()->setValue(browser_->horizontalScrollBar()->value() + dx);
    }
    QString attributes(int offset, int *start, int *end) const override {
        *start = *end = -1;
        if (offset == -2) offset = cursorPosition();
        const int count = characterCount();
        if (offset == -1 || offset == count) offset = count - 1;
        if (offset < 0 || offset >= count) return {};
        QTextCursor cursor(browser_->document()); cursor.setPosition(offset);
        const auto block = cursor.block(); auto format = block.charFormat();
        *start = block.position(); *end = qMin(count, block.position() + block.length());
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (fragment.contains(offset)) {
                format = fragment.charFormat();
                *start = qMax(fragment.position(), block.position());
                *end = qMin(fragment.position() + fragment.length(), block.position() + block.length());
                break;
            }
            // A paragraph separator uses the block format and excludes prior styled runs.
            *start = fragment.position() + fragment.length();
        }
        const QFont font = format.font().resolve(browser_->document()->defaultFont());
        QString family = font.family();
        family.replace(QStringLiteral("\\"), QStringLiteral("\\\\"));
        family.replace(QStringLiteral(":"), QStringLiteral("\\:"));
        family.replace(QStringLiteral(";"), QStringLiteral("\\;"));
        QString result = QStringLiteral("font-family:%1;font-size:%2pt;font-weight:%3;font-style:%4;")
            .arg(family).arg(font.pointSizeF()).arg(int(font.weight()))
            .arg(font.italic() ? QStringLiteral("italic") : QStringLiteral("normal"));
        if (font.underline()) result += QStringLiteral("text-underline-type:single;");
        if (font.strikeOut()) result += QStringLiteral("text-line-through-type:single;");
        if (format.verticalAlignment() == QTextCharFormat::AlignSuperScript) result += QStringLiteral("text-position:super;");
        else if (format.verticalAlignment() == QTextCharFormat::AlignSubScript) result += QStringLiteral("text-position:sub;");
        result += QStringLiteral("direction:%1;").arg(block.textDirection() == Qt::RightToLeft ? QStringLiteral("rtl") : QStringLiteral("ltr"));
        const QColor foreground = format.foreground().style() == Qt::NoBrush ? browser_->palette().color(QPalette::Text) : format.foreground().color();
        const QColor background = format.background().style() == Qt::NoBrush ? browser_->palette().color(QPalette::Base) : format.background().color();
        result += QStringLiteral("color:rgb(%1,%2,%3);background-color:rgb(%4,%5,%6);")
            .arg(foreground.red()).arg(foreground.green()).arg(foreground.blue())
            .arg(background.red()).arg(background.green()).arg(background.blue());
        return result;
    }
    void deleteText(int start, int end) override { replaceText(start, end, {}); }
    void insertText(int offset, const QString &value) override { replaceText(offset, offset, value); }
    void replaceText(int start, int end, const QString &value) override {
        if (browser_->isReadOnly() || !validRange(start, end)) return;
        QTextCursor cursor(browser_->document()); cursor.setPosition(start);
        cursor.setPosition(end, QTextCursor::KeepAnchor); cursor.insertText(value);
    }
private:
    QString paragraphText(int offset, int step, int *start, int *end) const {
        *start = *end = -1;
        if (offset == -2) offset = cursorPosition();
        if (offset == -1) offset = characterCount();
        if (offset < 0 || offset > characterCount()) return {};
        auto block = browser_->document()->findBlock(offset);
        if (step < 0) block = block.previous();
        else if (step > 0) block = block.next();
        if (!block.isValid()) return {};
        *start = block.position(); *end = qMin(characterCount(), *start + block.length() - 1);
        return text(*start, *end);
    }
    QString visualLine(int offset, int step, int *start, int *end) const {
        *start = *end = -1;
        if (offset == -2) offset = cursorPosition();
        if (offset == -1) offset = characterCount();
        if (offset < 0 || offset > characterCount()) return {};
        auto block = browser_->document()->findBlock(offset);
        if (!block.isValid()) return {};
        browser_->document()->documentLayout()->blockBoundingRect(block);
        auto *layout = block.layout();
        auto line = layout->lineForTextPosition(offset - block.position());
        if (!line.isValid()) return {};
        int index = line.lineNumber() + step;
        if (index < 0 || index >= layout->lineCount()) {
            block = index < 0 ? block.previous() : block.next();
            if (!block.isValid()) return {};
            browser_->document()->documentLayout()->blockBoundingRect(block);
            layout = block.layout(); index = step < 0 ? layout->lineCount() - 1 : 0;
        }
        if (index < 0 || index >= layout->lineCount()) return {};
        line = layout->lineAt(index);
        *start = block.position() + line.textStart();
        *end = qMin(characterCount(), *start + line.textLength());
        return text(*start, *end);
    }
    bool validRange(int start, int end) const { return 0 <= start && start <= end && end <= characterCount(); }
    ReadingBrowser *browser_;
};

QTextBrowser *createReadingBrowser(QWidget *parent) {
    static const bool registered = [] {
        QAccessible::installFactory([](const QString &, QObject *object) -> QAccessibleInterface * {
            if (auto *browser = dynamic_cast<ReadingBrowser *>(object)) return new AccessibleReadingBrowser(browser);
            return nullptr;
        });
        return true;
    }();
    Q_UNUSED(registered);
    return new ReadingBrowser(parent);
}

bool compiledBookSourcesTarget(const QString &target) {
    const QString prefix = QStringLiteral("Special:BookSources/");
    if (!target.startsWith(prefix)) return false;
    const QString isbn = target.mid(prefix.size());
    if (isbn.size() != 10 && isbn.size() != 13) return false;
    if (isbn.size() == 13 && !isbn.startsWith(QStringLiteral("978")) && !isbn.startsWith(QStringLiteral("979"))) return false;
    const auto digit = [](QChar c) { return c >= QChar('0') && c <= QChar('9'); };
    for (qsizetype i = 0; i < isbn.size() - 1; ++i) if (!digit(isbn[i])) return false;
    return digit(isbn.back()) || isbn.back() == QChar('X');
}



QStringList poemClassTokens(const QJsonObject &span);

QJsonArray sectionHeadingSpans(const QJsonObject &section) {
    const QString title = section.value(QStringLiteral("title")).toString();
    const QJsonArray blocks = section.value(QStringLiteral("blocks")).toArray();
    if (title.isEmpty() || blocks.isEmpty()) return {};
    const QJsonObject first = blocks.first().toObject();
    if (first.value(QStringLiteral("kind")).toString() != QStringLiteral("heading") ||
        first.value(QStringLiteral("level")).toInt() != section.value(QStringLiteral("level")).toInt()) return {};
    const QJsonArray spans = first.value(QStringLiteral("spans")).toArray();
    QString label;
    bool rich = false;
    for (const QJsonValue &value : spans) {
        const QJsonObject span = value.toObject();
        const QString kind = span.value(QStringLiteral("kind")).toString();
        const QString text = span.value(QStringLiteral("text")).toString();
        const QString trail = span.value(QStringLiteral("trail")).toString();
        if (kind == QStringLiteral("line_break")) {
            // The producer has no break trail; noncanonical imported blocks stay in the body.
            if (!trail.isEmpty()) return {};
            label += QChar('\n');
        } else label += text + trail;
        if ((kind == QStringLiteral("link") || kind == QStringLiteral("external_link")) &&
            !span.value(QStringLiteral("target")).toString().isEmpty() && (!text.isEmpty() || !trail.isEmpty()))
            rich = true;
        bool styled = false;
        for (const QString &flag : {QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code"),
             QStringLiteral("small"), QStringLiteral("superscript"), QStringLiteral("subscript"),
             QStringLiteral("strike"), QStringLiteral("underline")})
            styled = styled || span.value(flag).toBool();
        const QJsonValue foreground = span.value(QStringLiteral("foreground"));
        const QString role = span.value(QStringLiteral("role")).toString(QStringLiteral("normal"));
        styled = styled || (!foreground.isUndefined() && !foreground.isNull()) ||
            !span.value(QStringLiteral("classes")).toString().isEmpty() ||
            !span.value(QStringLiteral("language")).toString().isEmpty() ||
            !span.value(QStringLiteral("direction")).toString().isEmpty() || role != QStringLiteral("normal");
        if (kind == QStringLiteral("text") && !text.isEmpty() &&
            span.value(QStringLiteral("target")).toString().isEmpty() && styled)
            rich = true;
        if (!span.value(QStringLiteral("explanation")).toString().isEmpty() && (!text.isEmpty() || !trail.isEmpty()))
            rich = true;
    }
    const auto edgeSpace = [](QChar c) {
        return c == QChar(' ') || c == QChar('\t') || c == QChar('\r') || c == QChar('\n') || c == QChar(0x00a0);
    };
    qsizetype start = 0, end = label.size();
    while (start < end && edgeSpace(label[start])) ++start;
    while (end > start && edgeSpace(label[end - 1])) --end;
    const bool indented = first.value(QStringLiteral("depth")).toInt() > 0;
    return (rich || indented) && label.mid(start, end - start) == title ? spans : QJsonArray{};
}

struct HeadingDestination {
    QString title;
    QString anchor;
    QString anchorFallback;
    int section;
    int block = -1;
};

QVector<HeadingDestination> headingDestinations(const QJsonObject &entry) {
    QVector<HeadingDestination> result;
    const QJsonArray sections = entry.value(QStringLiteral("sections")).toArray();
    for (qsizetype i = 0; i < sections.size(); ++i) {
        const QJsonObject section = sections[i].toObject();
        const QString title = section.value(QStringLiteral("title")).toString();
        if (!title.isEmpty()) result.append({title, section.value(QStringLiteral("anchor")).toString(), section.value(QStringLiteral("anchor_fallback")).toString(), int(i)});
        const bool companion = !sectionHeadingSpans(section).isEmpty();
        const QJsonArray blocks = section.value(QStringLiteral("blocks")).toArray();
        for (qsizetype j = 0; j < blocks.size(); ++j) {
            if (j == 0 && companion) continue;
            const QJsonObject block = blocks[j].toObject();
            if (block.value(QStringLiteral("kind")).toString() != QStringLiteral("heading")) continue;
            QString label;
            for (const QJsonValue &value : block.value(QStringLiteral("spans")).toArray()) {
                const QJsonObject span = value.toObject();
                label += span.value(QStringLiteral("kind")).toString() == QStringLiteral("line_break") ? QStringLiteral("\n")
                    : span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString();
            }
            if (!label.isEmpty()) result.append({label, block.value(QStringLiteral("anchor")).toString(), block.value(QStringLiteral("anchor_fallback")).toString(), int(i), int(j)});
        }
    }
    return result;
}

// Layout whitespace has no words, actions or formatting metadata. In a
// section-heading edge it duplicates the enclosing block boundary; in an
// ordinary depth-zero paragraph it must not manufacture another empty block.
// Explicit code/Poem/NBSP/bidi/media metadata never takes this display path.
bool ordinaryLayoutWhitespaceSpan(const QJsonObject &span, bool allowBreak) {
    const QString kind = span.value(QStringLiteral("kind")).toString();
    if (kind != QStringLiteral("text") && !(allowBreak && kind == QStringLiteral("line_break"))) return false;
    for (const QString &key : {QStringLiteral("target"), QStringLiteral("trail"), QStringLiteral("language"),
         QStringLiteral("classes"), QStringLiteral("direction"), QStringLiteral("explanation")})
        if (!span.value(key).toString().isEmpty()) return false;
    const QString role = span.value(QStringLiteral("role")).toString();
    if (!role.isEmpty() && role != QStringLiteral("normal")) return false;
    if (!span.value(QStringLiteral("foreground")).toString().isEmpty()) return false;
    for (const QString &key : {QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code"),
         QStringLiteral("small"), QStringLiteral("superscript"), QStringLiteral("subscript"),
         QStringLiteral("strike"), QStringLiteral("underline")})
        if (span.value(key).toBool()) return false;
    for (const QChar c : span.value(QStringLiteral("text")).toString())
        if (c != QChar(' ') && c != QChar('\t') && c != QChar('\r') && c != QChar('\n')) return false;
    return true;
}
QJsonArray compactSectionHeadingDisplaySpans(const QJsonArray &spans) {
    qsizetype start = 0, end = spans.size();
    while (start < end && ordinaryLayoutWhitespaceSpan(spans[start].toObject(), true)) ++start;
    while (end > start && ordinaryLayoutWhitespaceSpan(spans[end - 1].toObject(), true)) --end;
    QJsonArray display;
    for (qsizetype i = start; i < end; ++i) display.append(spans[i]);
    return display;
}

QStringList poemClassTokens(const QJsonObject &span) {
    const QString value = span.value(QStringLiteral("classes")).toString();
    const auto space = [](QChar c) { return c == QChar(' ') || (c.unicode() >= 9 && c.unicode() <= 13); };
    QStringList tokens;
    for (qsizetype start = 0; start < value.size();) {
        while (start < value.size() && space(value[start])) ++start;
        qsizetype end = start;
        while (end < value.size() && !space(value[end])) ++end;
        if (end > start) tokens.append(value.mid(start, end - start));
        start = end;
    }
    return tokens;
}

bool hasPoemSpans(const QJsonArray &spans) {
    return std::any_of(spans.begin(), spans.end(), [](const QJsonValue &value) {
        return poemClassTokens(value.toObject()).contains(QStringLiteral("wikidict-poem"));
    });
}

// -1 means invalid metadata; dimensions fall back independently for the whole line.
int poemIndent(const QStringList &classes) {
    if (!classes.contains(QStringLiteral("wikidict-poem"))) return 0;
    const QString reserved = QStringLiteral("wikidict-poem-indent");
    const QString prefix = reserved + QChar('-');
    int indent = 0;
    bool seen = false;
    for (const QString &token : classes) {
        if (!token.startsWith(reserved)) continue;
        if (seen || !token.startsWith(prefix)) return -1;
        seen = true;
        bool ok = false;
        const QString number = token.mid(prefix.size());
        const int value = number.toInt(&ok);
        if (!ok || value < 1 || value > 32 || QString::number(value) != number) return -1;
        indent = value;
    }
    return indent;
}

int poemDirection(const QStringList &classes) {
    if (!classes.contains(QStringLiteral("wikidict-poem"))) return 0;
    int direction = 0;
    for (const QString &token : classes) {
        if (!token.startsWith(QStringLiteral("wikidict-poem-dir"))) continue;
        if (direction != 0) return -1;
        if (token == QStringLiteral("wikidict-poem-dir-ltr")) direction = 1;
        else if (token == QStringLiteral("wikidict-poem-dir-rtl")) direction = 2;
        else return -1;
    }
    return direction;
}


QString kindLabel(const QString &kind) {
    if (kind == QStringLiteral("language")) return QStringLiteral("Dictionary");
    QString label = kind;
    label.replace('_', ' ');
    if (!label.isEmpty()) label[0] = label[0].toUpper();
    return label;
}

struct LoadedDataset {
    std::unique_ptr<DictApi> api;
    QStringList languages;
    QVector<QString> titles;
    QVector<QJsonObject> practice;
    QString originRoot;
    QString originEdition;
    QString error;
    QString missingWord;
    bool emptyLibrary = false;
};

bool titleLess(const QString &left, const QString &right) {
    return QString::compare(left, right, Qt::CaseInsensitive) < 0;
}

QString readerFamily() {
    static const QString family = [] {
        const int id = QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/reader.ttf"));
        const auto families = QFontDatabase::applicationFontFamilies(id);
        return families.isEmpty() ? QStringLiteral("serif") : families.first();
    }();
    return family;
}

QString egyptianFamily() {
    static const QString family = [] {
        const int id = QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/NewGardinerOmni2d4.ttf"));
        const auto families = QFontDatabase::applicationFontFamilies(id);
        return families.isEmpty() ? readerFamily() : families.first();
    }();
    return family;
}
}

MainWindow::MainWindow(const QString &root, const QString &initialWord)
    : QMainWindow() {
    setupUi();
    restoreGeometry(QSettings().value(QStringLiteral("reader/windowGeometry")).toByteArray());
    if (auto *splitter = findChild<QSplitter *>(QStringLiteral("readerSplit")))
        splitter->restoreState(QSettings().value(QStringLiteral("reader/splitter")).toByteArray());
    readingPointSize_ = std::clamp(QSettings().value(QStringLiteral("reader/pointSize"), 12).toInt(), 9, 24);
    applyTheme();
    const QString folder = root.isEmpty() ? QSettings().value(QStringLiteral("reader/root")).toString() : root;
    const QString word = !initialWord.isEmpty() ? initialWord : (root.isEmpty() ? QSettings().value(QStringLiteral("reader/lastWord")).toString() : QString());
    if (root.isEmpty() && !word.isEmpty())
        loadDataset(folder, QSettings().value(QStringLiteral("reader/language"), QStringLiteral("English")).toString(),
            QSettings().value(QStringLiteral("reader/lastKind"), QStringLiteral("language")).toString(), true, word);
    else openRoot(folder, word);
}

MainWindow::~MainWindow() {
    if (cancelLoad_) cancelLoad_->store(true);
    QSettings().setValue(QStringLiteral("reader/windowGeometry"), saveGeometry());
    if (auto *splitter = findChild<QSplitter *>(QStringLiteral("readerSplit")))
        QSettings().setValue(QStringLiteral("reader/splitter"), splitter->saveState());
}

void MainWindow::setLoading(bool loading) {
    loading_ = loading;
    const bool ready = !loading && bool(api_);
    kind_->setEnabled(ready);
    language_->setEnabled(ready && api_->kind() == QStringLiteral("language"));
    search_->setEnabled(ready);
    results_->setEnabled(ready);
    random_->setEnabled(ready);
    listen_->setEnabled(ready && !currentEntry_.isEmpty());
    if (loading) media_->stopPlayback();
    moreResults_->setEnabled(ready && moreAvailable_);
    cancelOpening_->setVisible(loading);
    openingProgress_->setVisible(loading);
    updateNavigation();
}

void MainWindow::openRoot(const QString &root, const QString &word) {
    loadDataset(root, QSettings().value(QStringLiteral("reader/language"), QStringLiteral("English")).toString(), QStringLiteral("language"), true, word);
}

void MainWindow::loadDataset(const QString &root, const QString &language, const QString &kind, bool resetVisits, const QString &word, int restoreVisit, const QString &expectedRoot, const QString &expectedEdition, const std::optional<QString> &fragment, bool requireExactWord) {
    if (cancelLoad_) cancelLoad_->store(true);
    const auto cancelled = std::make_shared<std::atomic_bool>(false);
    cancelLoad_ = cancelled;
    const unsigned serial = ++loadSerial_;
    saveVisit();
    searchTimer_->stop();
    setLoading(true);
    resultStatus_->setText(QStringLiteral("Opening dictionaries and preparing search..."));
    auto *watcher = new QFutureWatcher<std::shared_ptr<LoadedDataset>>(this);
    connect(watcher, &QFutureWatcher<std::shared_ptr<LoadedDataset>>::finished, this, [this, watcher, cancelled, serial, root, resetVisits, word, restoreVisit, fragment, requireExactWord] {
        const auto loaded = watcher->result();
        watcher->deleteLater();
        if (serial != loadSerial_ || cancelled->load()) return;
        auto publish = [this, loaded, cancelled, serial, root, resetVisits, word, restoreVisit, fragment, requireExactWord] {
            if (serial != loadSerial_ || cancelled->load()) return;
            if (!loaded->missingWord.isEmpty()) {
                // A fallback miss must not replace a readable current owner or entry.
                setLoading(false);
                if (api_) {
                    QSignalBlocker kindBlocker(kind_);
                    QSignalBlocker languageBlocker(language_);
                    kind_->setCurrentIndex(kind_->findData(api_->kind()));
                    language_->setCurrentText(api_->language());
                }
                search_->setText(loaded->missingWord);
                refreshSearch();
                resultStatus_->setText(QStringLiteral("No exact entry for “%1”. Try a suggestion or another collection.").arg(loaded->missingWord));
                search_->setFocus();
                return;
            }
            if (loaded->emptyLibrary || !loaded->error.isEmpty()) {
                if (!loaded->error.isEmpty())
                    qWarning().noquote() << "Dictionary opening failed:" << root << loaded->error;
                setLoading(false);
                if (api_) {
                    QSignalBlocker kindBlocker(kind_);
                    QSignalBlocker languageBlocker(language_);
                    kind_->setCurrentIndex(kind_->findData(api_->kind()));
                    language_->setCurrentText(api_->language());
                    resultStatus_->setText(QStringLiteral("Could not open the selected dictionary. Your current dictionary is still open."));
                } else {
                    // No reader owns the previous entry or its suggestions anymore.
                    json_->clear();
                    results_->clear();
                    sections_->clear();
                    sections_->setEnabled(false);
                    bookmark_->setEnabled(false);
                    title_->setHtml(QStringLiteral("Open your dictionaries"));
                    meta_->setText(QStringLiteral("Your words stay on this computer."));
                    reading_->setHtml(loaded->emptyLibrary
                        ? QStringLiteral("<p>No dictionaries are installed yet.</p><p>Open <b>Library</b> to import a dictionary, download one, or choose an existing folder.</p>")
                        : QStringLiteral("<p>Could not open this dictionary.</p><p>Open <b>Library</b> to import a dictionary, download one, or choose an existing folder.</p>"));
                    resultStatus_->setText(QStringLiteral("No dictionary open"));
                }
                return;
            }
            api_ = std::move(loaded->api);
            originRoot_ = loaded->originRoot;
            originEdition_ = loaded->originEdition;
            searchTitles_ = std::move(loaded->titles);
            sampleWords_.clear();
            for (const QJsonObject &entry : loaded->practice) {
                try { sampleWords_.append(savedWord(entry)); }
                catch (const std::exception &) { /* Unreadable sampled entries do not prevent dictionary browsing. */ }
            }
            {
                QSignalBlocker kindBlocker(kind_);
                QSignalBlocker languageBlocker(language_);
                kind_->setCurrentIndex(kind_->findData(api_->kind()));
                language_->clear();
                language_->addItems(loaded->languages);
                language_->setCurrentText(api_->language());
            }
            if (resetVisits) { visits_.clear(); visitIndex_ = -1; }
            currentEntry_ = {};
            currentJson_.clear();
            media_->setEntry({});
            bookmark_->setEnabled(false);
            sections_->clear();
            sections_->setEnabled(false);
            title_->setHtml(QStringLiteral("Find the word."));
            meta_->setText(QStringLiteral("%1 · %2").arg(api_->kind() == QStringLiteral("language") ? api_->language() : QStringLiteral("All languages"), kindLabel(api_->kind())));
            reading_->setHtml(QStringLiteral("<p>Type a word to search. Press Enter to open it, or use the arrow keys to choose a suggestion.</p><p>Ctrl+L focuses search. Alt+Left and Alt+Right revisit words.</p>"));
            json_->clear();
            QSettings().setValue(QStringLiteral("reader/root"), QDir(root).absolutePath());
            QSettings().setValue(QStringLiteral("reader/language"), api_->language());
            setLoading(false);
            refreshSearch();
            if (restoreVisit >= 0 && restoreVisit < visits_.size()) {
                try {
                    const Visit visit = visits_[restoreVisit];
                    renderResponse(api_->lookup(word), false);
                    if (!currentEntry_.isEmpty()) {
                        search_->setText(word);
                        refreshSearch();
                        restoreVisitReading(visit);
                        visitIndex_ = restoreVisit;
                        updateNavigation();
                    }
                } catch (const std::exception &error) { resultStatus_->setText(QString::fromUtf8(error.what())); }
            } else if (!word.isEmpty()) openWord(word, fragment);
            const bool restoredReader = restoreVisit >= 0 && restoreVisit < visits_.size()
                && visits_[restoreVisit].readerFocused && !currentEntry_.isEmpty();
            if ((restoredReader || fragment || requireExactWord) && !currentEntry_.isEmpty()) reading_->setFocus();
            else search_->setFocus();
            statusBar()->showMessage(QStringLiteral("Opened %1").arg(QDir::toNativeSeparators(root)), 4000);
        };
        // A modal Library worker can change files before its GUI notification.
        // Keep the actual result and intent unpublished until the dialog closes.
        if (libraryDialogActive_) deferredDatasetPublication_ = std::move(publish);
        else publish();
    });
    watcher->setFuture(QtConcurrent::run([root, language, kind, resetVisits, cancelled, expectedRoot, expectedEdition, word, requireExactWord] {
        auto loaded = std::make_shared<LoadedDataset>();
        try {
            if (root.isEmpty()) {
                loaded->emptyLibrary = true;
                return loaded;
            }
            LibraryStorage::recoverPendingMutation(root);
            const QDir directory(root);
            if (directory.exists() && directory.isReadable()
                && directory.entryList(QDir::AllEntries | QDir::Hidden | QDir::System | QDir::NoDotAndDotDot).isEmpty()) {
                loaded->emptyLibrary = true;
                return loaded;
            }
            loaded->originRoot = QFileInfo(root).canonicalFilePath();
            loaded->originEdition = LibraryStorage::editionIdentity(root);
            if (!expectedRoot.isEmpty() && (loaded->originRoot != expectedRoot || loaded->originEdition != expectedEdition))
                throw DictApiError("The saved dictionary has changed. Open its original folder.");
            // Removing the final dictionary retains its manifest and cache.
            // Only a valid empty manifest with no remaining blobs is empty.
            QFile manifest(directory.filePath(QStringLiteral("languages.tsv")));
            const QFileInfo languageFolder(directory.filePath(QStringLiteral("languages")));
            const QDir languageDirectory(languageFolder.filePath());
            const QStringList blobs{QStringLiteral("*.wikblb"), QStringLiteral("*.wikblb.xz")};
            const auto blobEntries = QDir::AllEntries | QDir::Hidden | QDir::System | QDir::NoDotAndDotDot;
            if (directory.isReadable() && !QFileInfo::exists(directory.filePath(QStringLiteral(".incomplete")))
                && manifest.open(QIODevice::ReadOnly) && manifest.read(9) == QByteArrayLiteral("heading\n")
                && manifest.error() == QFileDevice::NoError && manifest.atEnd()
                && directory.entryList(blobs, blobEntries).isEmpty()
                && ((!languageFolder.exists() && !languageFolder.isSymLink()) || (languageFolder.isDir() && !languageFolder.isSymLink()
                    && languageDirectory.isReadable() && languageDirectory.entryList(blobs, blobEntries).isEmpty()))) {
                loaded->emptyLibrary = true;
                return loaded;
            }
            loaded->api = std::make_unique<DictApi>(root);
            if (cancelled->load()) return loaded;
            if (QFileInfo::exists(QDir(root).filePath(QStringLiteral("languages.tsv")))) {
                for (const QJsonValue &value : QJsonDocument::fromJson(loaded->api->languages()).object().value(QStringLiteral("languages")).toArray())
                    loaded->languages.append(value.toString());
            }
            const QString selected = loaded->languages.isEmpty() ? QString() :
                (resetVisits && !loaded->languages.contains(language) ? loaded->languages.first() : language);
            QStringList candidates{kind};
            if (resetVisits) {
                candidates.append(QStringLiteral("language"));
                candidates.append({QStringLiteral("thesaurus"), QStringLiteral("citations"), QStringLiteral("reconstruction"), QStringLiteral("rhymes"), QStringLiteral("sign_gloss"), QStringLiteral("supplemental")});
                candidates.removeDuplicates();
            }
            bool selectedCollection = false;
            for (const QString &candidate : candidates) {
                if (cancelled->load()) return loaded;
                // The core admits a neutral redirect collection only when the
                // language manifest and language directory are both empty.
                try { loaded->api->select(selected, candidate); selectedCollection = true; break; }
                catch (const std::exception &) { /* Try the next available collection. */ }
            }
            if (!selectedCollection) throw DictApiError("No readable dictionary was found for this collection. Import a dictionary in Library.");
            if (requireExactWord) {
                QJsonParseError parseError{};
                const QJsonDocument response = QJsonDocument::fromJson(loaded->api->lookup(word), &parseError);
                if (parseError.error != QJsonParseError::NoError || !response.isObject() ||
                    !response.object().value(QStringLiteral("entries")).isArray())
                    throw DictApiError("invalid JSON returned by dictionary core");
                const QJsonArray entries = response.object().value(QStringLiteral("entries")).toArray();
                const bool exactOrdinary = entries.size() == 1 && std::all_of(entries.begin(), entries.end(), [&](const QJsonValue &value) {
                    const QJsonObject entry = value.toObject();
                    return entry.value(QStringLiteral("title")).toString() == word &&
                        entry.value(QStringLiteral("kind")).toString() == QStringLiteral("language") &&
                        entry.value(QStringLiteral("language")).toString() == QStringLiteral("Unclassified") &&
                        entry.value(QStringLiteral("redirect")).toObject().isEmpty();
                });
                if (!exactOrdinary) {
                    if (QFileInfo(root).canonicalFilePath() != loaded->originRoot || LibraryStorage::editionIdentity(root) != loaded->originEdition)
                        throw DictApiError("The dictionary changed while opening. Open it again.");
                    loaded->missingWord = word;
                    return loaded;
                }
            }
            for (qsizetype offset = 0; !cancelled->load();) {
                const QJsonObject page = QJsonDocument::fromJson(loaded->api->search(QString(), 1000, offset)).object();
                const QJsonArray matches = page.value(QStringLiteral("matches")).toArray();
                for (const QJsonValue &value : matches) loaded->titles.append(value.toObject().value(QStringLiteral("title")).toString());
                offset += matches.size();
                if (matches.isEmpty() || !page.value(QStringLiteral("has_more")).toBool()) break;
            }
            if (!cancelled->load()) std::sort(loaded->titles.begin(), loaded->titles.end(), titleLess);
            QSet<qsizetype> sampled;
            while (!cancelled->load() && sampled.size() < std::min(qsizetype(64), loaded->titles.size())) {
                const qsizetype index = QRandomGenerator::global()->bounded(loaded->titles.size());
                if (sampled.contains(index)) continue;
                sampled.insert(index);
                const auto entries = QJsonDocument::fromJson(loaded->api->lookup(loaded->titles[index])).object().value(QStringLiteral("entries")).toArray();
                if (!entries.isEmpty()) loaded->practice.append(entries.first().toObject());
            }
            if (QFileInfo(root).canonicalFilePath() != loaded->originRoot || LibraryStorage::editionIdentity(root) != loaded->originEdition)
                throw DictApiError("The dictionary changed while opening. Open it again.");
        } catch (const std::exception &error) { loaded->error = QString::fromUtf8(error.what()); }
        return loaded;
    }));
}

void MainWindow::chooseRoot() {
    const QString word = currentEntry_.value(QStringLiteral("title")).toString();
    LibraryDialog dialog(this, api_ ? api_->root() : QSettings().value(QStringLiteral("reader/root")).toString());
    libraryDialogActive_ = true;
    dialog.exec();
    libraryDialogActive_ = false;
    if (dialog.libraryChanged()) {
        if (cancelLoad_) cancelLoad_->store(true);
        ++loadSerial_;
        deferredDatasetPublication_ = {};
        // A different folder is only a candidate until opening succeeds. An
        // edited or explicitly reloaded original folder cannot keep its old reader.
        if (dialog.originalRootChanged()) {
            api_.reset();
            searchTitles_.clear();
            sampleWords_.clear();
            currentEntry_ = {};
            currentJson_.clear();
            media_->setEntry({});
            visits_.clear();
            visitIndex_ = -1;
        }
        openRoot(dialog.selectedRoot(), word);
    } else if (deferredDatasetPublication_) {
        auto publish = std::move(deferredDatasetPublication_);
        deferredDatasetPublication_ = {};
        publish();
    }
}

void MainWindow::setupUi() {
    setWindowTitle(QStringLiteral("Dict"));
    resize(1180, 780);
    setMinimumSize(480, 480);

    auto *splitter = new QSplitter(this);
    splitter->setObjectName(QStringLiteral("readerSplit"));
    auto *sideScroll = new QScrollArea(splitter);
    sideScroll->setObjectName(QStringLiteral("readerSidebarScroll"));
    sideScroll->setFrameShape(QFrame::NoFrame);
    sideScroll->setWidgetResizable(true);
    sideScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    auto *sidebar = new QWidget;
    auto *side = new QVBoxLayout(sidebar);
    side->setSizeConstraint(QLayout::SetMinimumSize);
    side->setContentsMargins(18, 18, 14, 18);
    side->setSpacing(10);
    auto *brand = new QLabel(QStringLiteral("dict."), sidebar);
    QFont brandFont = brand->font();
    brandFont.setPointSize(22);
    brandFont.setBold(true);
    brand->setFont(brandFont);
    side->addWidget(brand);
    auto *openButton = new QPushButton(QStringLiteral("Library"), sidebar);
    openButton->setObjectName(QStringLiteral("openDictionaries"));
    openButton->setToolTip(QStringLiteral("Import, download and manage dictionaries (Ctrl+O)"));
    side->addWidget(openButton);

    kind_ = new QComboBox(sidebar);
    kind_->setAccessibleName(QStringLiteral("Collection"));
    kind_->addItem(QStringLiteral("Dictionary"), QStringLiteral("language"));
    kind_->addItem(QStringLiteral("Thesaurus"), QStringLiteral("thesaurus"));
    kind_->addItem(QStringLiteral("Citations"), QStringLiteral("citations"));
    kind_->addItem(QStringLiteral("Reconstruction"), QStringLiteral("reconstruction"));
    kind_->addItem(QStringLiteral("Rhymes"), QStringLiteral("rhymes"));
    kind_->addItem(QStringLiteral("Sign gloss"), QStringLiteral("sign_gloss"));
    kind_->addItem(QStringLiteral("Supplemental"), QStringLiteral("supplemental"));
    side->addWidget(kind_);

    language_ = new QComboBox(sidebar);
    language_->setEditable(false);
    language_->setAccessibleName(QStringLiteral("Dictionary language"));
    side->addWidget(language_);

    search_ = new QLineEdit(sidebar);
    search_->setPlaceholderText(QStringLiteral("Find a word…"));
    search_->setClearButtonEnabled(true);
    search_->setObjectName(QStringLiteral("search"));
    search_->setAccessibleName(QStringLiteral("Find a word"));
    search_->installEventFilter(this);
    side->addWidget(search_);

    results_ = new QListWidget(sidebar);
    results_->setUniformItemSizes(true);
    results_->setObjectName(QStringLiteral("searchResults"));
    results_->setAccessibleName(QStringLiteral("Word suggestions"));
    results_->installEventFilter(this);
    side->addWidget(results_, 1);
    resultStatus_ = new QLabel(sidebar);
    resultStatus_->setWordWrap(true);
    resultStatus_->setTextFormat(Qt::PlainText);
    resultStatus_->setAccessibleDescription(QStringLiteral("Search status"));
    side->addWidget(resultStatus_);
    openingProgress_ = new QProgressBar(sidebar);
    openingProgress_->setRange(0, 0);
    openingProgress_->setTextVisible(false);
    openingProgress_->hide();
    side->addWidget(openingProgress_);
    cancelOpening_ = new QPushButton(QStringLiteral("Cancel opening"), sidebar);
    cancelOpening_->hide();
    side->addWidget(cancelOpening_);
    moreResults_ = new QPushButton(QStringLiteral("Load more"), sidebar);
    moreResults_->setEnabled(false);
    side->addWidget(moreResults_);
    auto *sideActions = new QGridLayout;
    random_ = new QPushButton(QStringLiteral("Random"), sidebar);
    auto *historyButton = new QPushButton(QStringLiteral("History"), sidebar);
    auto *savedButton = new QPushButton(QStringLiteral("Saved"), sidebar);
    auto *learnButton = new QPushButton(QStringLiteral("Learn"), sidebar);
    auto *settingsButton = new QPushButton(QStringLiteral("Settings"), sidebar);
    sideActions->addWidget(random_, 0, 0, 1, 2);
    sideActions->addWidget(historyButton, 1, 0);
    sideActions->addWidget(savedButton, 1, 1);
    sideActions->addWidget(learnButton, 2, 0);
    sideActions->addWidget(settingsButton, 2, 1);
    side->addLayout(sideActions);
    sideScroll->setWidget(sidebar);
    sideScroll->setMinimumWidth(sidebar->minimumSizeHint().width()
        + sideScroll->style()->pixelMetric(QStyle::PM_ScrollBarExtent));

    auto *content = new QWidget(splitter);
    readerContent_ = content;
    auto *right = new QVBoxLayout(content);
    right->setContentsMargins(28, 20, 28, 24);
    right->setSpacing(10);

    auto *navigation = new QGridLayout;
    navigationLayout_ = navigation;
    back_ = new QPushButton(QStringLiteral("Back"), content);
    forward_ = new QPushButton(QStringLiteral("Forward"), content);
    back_->setToolTip(QStringLiteral("Previous word (Alt+Left)"));
    forward_->setToolTip(QStringLiteral("Next word (Alt+Right)"));
    back_->setEnabled(false);
    forward_->setEnabled(false);
    navigation->addWidget(back_, 0, 0);
    navigation->addWidget(forward_, 0, 1);
    sections_ = new QComboBox(content);
    sections_->setAccessibleName(QStringLiteral("Jump to section"));
    sections_->setMinimumContentsLength(10);
    sections_->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    sections_->setEnabled(false);
    navigation->addWidget(sections_, 0, 2);
    navigation->setColumnStretch(2, 1);
    auto *smaller = new QPushButton(QStringLiteral("A-"), content);
    auto *larger = new QPushButton(QStringLiteral("A+"), content);
    smaller->setAccessibleName(QStringLiteral("Smaller reading text"));
    larger->setAccessibleName(QStringLiteral("Larger reading text"));
    smaller_ = smaller;
    navigation->addWidget(smaller, 0, 3);
    larger_ = larger;
    navigation->addWidget(larger, 0, 4);
    right->addLayout(navigation);

    auto *header = new QGridLayout;
    headerLayout_ = header;
    readerHeading_ = new QWidget(content);
    auto *heading = new QVBoxLayout(readerHeading_);
    heading->setContentsMargins(0, 0, 0, 0);
    title_ = new HeadingBrowser(content);
    title_->setHtml(QStringLiteral("Find the word."));
    QFont titleFont = title_->font();
    titleFont.setFamily(readerFamily());
    titleFont.setPointSize(30);
    titleFont.setBold(true);
    title_->setFont(titleFont);
    title_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    meta_ = new QLabel(QStringLiteral("Local Wiktionary"), content);
    meta_->setTextFormat(Qt::PlainText);
    meta_->setWordWrap(true);
    meta_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    heading->addWidget(title_);
    heading->addWidget(meta_);
    header->addWidget(readerHeading_, 0, 0);
    header->setColumnStretch(0, 1);
    listen_ = new QPushButton(QStringLiteral("Listen"), content);
    listen_->setToolTip(QStringLiteral("Pronounce this word with an installed offline voice"));
    listen_->setEnabled(false);
    header->addWidget(listen_, 0, 1);
    bookmark_ = new QPushButton(QStringLiteral("☆ Bookmark"), content);
    bookmark_->setEnabled(false);
    header->addWidget(bookmark_, 0, 2);
    right->addLayout(header);
    entryTabs_ = new QTabWidget(content);
    reading_ = createReadingBrowser(entryTabs_);
    // Preserve whole cell words; wide tables should scroll rather than split glyphs.
    reading_->setWordWrapMode(QTextOption::WordWrap);
    reading_->setOpenLinks(false);
    reading_->setOpenExternalLinks(false);
    reading_->setFrameShape(QFrame::NoFrame);
    reading_->setAccessibleName(QStringLiteral("Dictionary entry"));
    reading_->installEventFilter(this);
    reading_->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(reading_, &QTextBrowser::customContextMenuRequested, this, &MainWindow::showReaderContextMenu);
    json_ = new QTextEdit(entryTabs_);
    json_->setReadOnly(true);
    json_->setLineWrapMode(QTextEdit::NoWrap);
    entryTabs_->addTab(reading_, QStringLiteral("Reading"));
    media_ = new MediaPanel(entryTabs_);
    entryTabs_->addTab(media_, QStringLiteral("Media && speech"));
    entryTabs_->addTab(json_, QStringLiteral("Entry data"));
    right->addWidget(entryTabs_, 1);

    splitter->addWidget(sideScroll);
    splitter->addWidget(content);
    splitter->setStretchFactor(0, 0);
    splitter->setStretchFactor(1, 1);
    splitter->setSizes({280, 900});
    splitter->setChildrenCollapsible(false);
    setCentralWidget(splitter);
    content->installEventFilter(this);
    updateReaderLayout();

    searchTimer_ = new QTimer(this);
    searchTimer_->setSingleShot(true);
    searchTimer_->setInterval(120);
    connect(search_, &QLineEdit::textChanged, this, [this] {
        searchSelectionExplicit_ = false;
        results_->clear();
        moreResults_->setEnabled(false);
        resultStatus_->setText(QStringLiteral("Searching..."));
        searchTimer_->start();
    });
    connect(searchTimer_, &QTimer::timeout, this, &MainWindow::refreshSearch);
    connect(search_, &QLineEdit::returnPressed, this, &MainWindow::submitSearch);
    connect(results_, &QListWidget::currentRowChanged, this, [this](int row) {
        if (row >= 0) searchSelectionExplicit_ = true;
    });
    connect(results_, &QListWidget::itemClicked, this, [this](QListWidgetItem *item) {
        const QString word = item->data(Qt::UserRole).toString();
        if (currentEntry_.value(QStringLiteral("title")).toString() != word) openWord(word);
    });
    connect(kind_, &QComboBox::currentIndexChanged, this, [this] { selectDataset(); });
    connect(language_, &QComboBox::currentIndexChanged, this, [this] { selectDataset(); });
    connect(openButton, &QPushButton::clicked, this, &MainWindow::chooseRoot);
    connect(cancelOpening_, &QPushButton::clicked, this, [this] {
        if (cancelLoad_) cancelLoad_->store(true);
        ++loadSerial_;
        setLoading(false);
        if (api_) {
            QSignalBlocker kindBlocker(kind_);
            QSignalBlocker languageBlocker(language_);
            kind_->setCurrentIndex(kind_->findData(api_->kind()));
            language_->setCurrentText(api_->language());
        } else {
            // Library changes invalidated the old reader; cancellation cannot restore its view.
            json_->clear();
            results_->clear();
            sections_->clear();
            sections_->setEnabled(false);
            bookmark_->setEnabled(false);
            title_->setHtml(QStringLiteral("Open your dictionaries"));
            meta_->setText(QStringLiteral("Your words stay on this computer."));
            reading_->setHtml(QStringLiteral("<p>Opening cancelled.</p><p>Open <b>Library</b> to import a dictionary or choose another folder.</p>"));
        }
        resultStatus_->setText(QStringLiteral("Opening cancelled. Choose a folder to try again."));
    });
    connect(moreResults_, &QPushButton::clicked, this, &MainWindow::loadMoreResults);
    connect(random_, &QPushButton::clicked, this, &MainWindow::showRandomWord);
    connect(historyButton, &QPushButton::clicked, this, [this] { showLearningDialog(0); });
    connect(savedButton, &QPushButton::clicked, this, [this] { showLearningDialog(1); });
    connect(learnButton, &QPushButton::clicked, this, [this] { showLearningDialog(2); });
    connect(settingsButton, &QPushButton::clicked, this, [this] { showLearningDialog(3); });
    connect(bookmark_, &QPushButton::clicked, this, [this] {
        if (currentEntry_.isEmpty()) return;
        const bool saved = learning_.toggleBookmark(savedWord(currentEntry_));
        bookmark_->setText(saved ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
    });
    connect(listen_, &QPushButton::clicked, this, [this] {
        if (currentEntry_.isEmpty()) return;
        entryTabs_->setCurrentWidget(media_);
        media_->sayWord(currentEntry_.value(QStringLiteral("title")).toString(), currentEntry_.value(QStringLiteral("language_code")).toString());
    });
    connect(reading_, &QTextBrowser::anchorClicked, this, [this](const QUrl &url) {
        if (url.scheme() == QStringLiteral("dict")) {
            const QString target = url.path(QUrl::FullyDecoded);
            // Validate the entire compiled target before ordinary fragment handling.
            if (api_ && !url.hasQuery() && !url.hasFragment() && compiledBookSourcesTarget(target)) {
                const QString host = LibraryStorage::sourceHost(api_->root());
                if (!host.isEmpty()) {
                    const QUrl source(QStringLiteral("https://") + host + QStringLiteral("/wiki/") +
                        QString::fromLatin1(QUrl::toPercentEncoding(target)));
                    QDesktopServices::openUrl(source);
                    return;
                }
            }
            const QString word = target.section(QChar('#'), 0, 0);
            const std::optional<QString> section = target.contains(QChar('#')) ?
                std::optional<QString>(target.section(QChar('#'), 1)) : std::nullopt;
            if (!word.isEmpty()) {
                bool explicitOwner = false;
                if (api_ && !loading_ && api_->kind() == QStringLiteral("language") && section) {
                    QString owner = *section;
                    owner.replace(QChar('_'), QChar(' '));
                    // Only exact installed owner headings in this edition select another dictionary.
                    explicitOwner = language_->findText(owner, Qt::MatchExactly | Qt::MatchCaseSensitive) >= 0;
                    if (owner != api_->language() && explicitOwner) {
                        loadDataset(api_->root(), owner, api_->kind(), false, word, -1,
                            originRoot_, originEdition_, section);
                        return;
                    }
                }
                if (!openWord(word, section, !explicitOwner && !url.hasQuery() && !url.hasFragment())) return;
            } else if (section) jumpToFragment(*section);
        }
        else if (url.scheme() == QStringLiteral("section")) {
            const int index = url.path().toInt();
            if (collapsedSections_.contains(index)) collapsedSections_.remove(index);
            else collapsedSections_.insert(index);
            auto *browser = static_cast<ReadingBrowser *>(reading_);
            const bool keyboard = browser->keyboardActivation;
            refreshReading();
            if (keyboard) {
                const int revision = reading_->document()->revision();
                const int scroll = reading_->verticalScrollBar()->value();
                const quint64 interaction = browser->interaction;
                QTimer::singleShot(0, browser, [browser, url, revision, scroll, interaction] {
                    if (!browser->hasFocus() || browser->interaction != interaction ||
                        browser->document()->revision() != revision) return;
                    browser->restoreAnchor(url);
                    browser->verticalScrollBar()->setValue(scroll);
                });
            }
        }
        else if (url.scheme() == QStringLiteral("http") || url.scheme() == QStringLiteral("https")) QDesktopServices::openUrl(url);
    });
    connect(back_, &QPushButton::clicked, this, [this] { navigate(-1); });
    connect(forward_, &QPushButton::clicked, this, [this] { navigate(1); });
    connect(sections_, &QComboBox::activated, this, [this](int index) {
        const int section = sections_->itemData(index).toInt();
        if (section < 0) return;
        jumpToSection(section);
        const int block = sections_->itemData(index, Qt::UserRole + 1).toInt();
        if (block >= 0) reading_->scrollToAnchor(QStringLiteral("block-%1-%2").arg(section).arg(block));
    });
    auto resizeText = [this](int delta) {
        readingPointSize_ = std::clamp(readingPointSize_ + delta, 9, 24);
        QSettings().setValue(QStringLiteral("reader/pointSize"), readingPointSize_);
        refreshReading();
    };
    connect(smaller, &QPushButton::clicked, this, [resizeText] { resizeText(-1); });
    connect(larger, &QPushButton::clicked, this, [resizeText] { resizeText(1); });
    auto shortcut = [this](const QKeySequence &keys, auto action) {
        auto *key = new QShortcut(keys, this);
        connect(key, &QShortcut::activated, this, action);
    };
    shortcut(QKeySequence::Open, [this] { chooseRoot(); });
    shortcut(QKeySequence(QStringLiteral("Ctrl+L")), [this] { search_->setFocus(); search_->selectAll(); });
    shortcut(QKeySequence(QStringLiteral("Alt+Left")), [this] { navigate(-1); });
    shortcut(QKeySequence(QStringLiteral("Alt+Right")), [this] { navigate(1); });
    shortcut(QKeySequence(QStringLiteral("Ctrl+D")), [this] { if (bookmark_->isEnabled()) bookmark_->click(); });
    shortcut(QKeySequence(QStringLiteral("Ctrl+H")), [this] { showLearningDialog(0); });
    shortcut(QKeySequence(QStringLiteral("Ctrl+,")), [this] { showLearningDialog(3); });
    shortcut(QKeySequence::ZoomIn, [resizeText] { resizeText(1); });
    shortcut(QKeySequence::ZoomOut, [resizeText] { resizeText(-1); });
    connect(qApp->styleHints(), &QStyleHints::colorSchemeChanged, this, [this] {
        if (learning_.settings().theme == QStringLiteral("system")) applyTheme();
    });
}
void MainWindow::selectDataset() {
    if (!api_ || loading_) return;
    const QString kind = kind_->currentData().toString();
    const QString language = language_->currentText();
    loadDataset(api_->root(), language, kind, false);
}
void MainWindow::refreshSearch() {
    if (!api_ || loading_) return;
    searchTimer_->stop();
    resultsQuery_ = search_->text().trimmed();
    searchSelectionExplicit_ = false;
    results_->clear();
    const auto first = std::lower_bound(searchTitles_.cbegin(), searchTitles_.cend(), resultsQuery_, titleLess);
    const auto last = std::upper_bound(first, searchTitles_.cend(), resultsQuery_, [](const QString &query, const QString &title) {
        return QStringView(query).compare(QStringView(title).left(query.size()), Qt::CaseInsensitive) < 0;
    });
    searchFirst_ = first - searchTitles_.cbegin();
    searchLast_ = last - searchTitles_.cbegin();
    moreAvailable_ = true;
    loadMoreResults();
}

void MainWindow::loadMoreResults() {
    if (!api_ || loading_ || !moreAvailable_) return;
    if (resultsQuery_ != search_->text().trimmed()) { refreshSearch(); return; }
    {
        QSignalBlocker blocker(results_);
        const bool firstPage = results_->count() == 0;
        const qsizetype begin = searchFirst_ + results_->count();
        const qsizetype end = std::min(searchLast_, begin + 80);
        moreAvailable_ = end < searchLast_;
        for (qsizetype i = begin; i < end; ++i) {
            const QString &title = searchTitles_[i];
            auto *item = new QListWidgetItem(title, results_);
            item->setData(Qt::UserRole, title);
        }
        if (firstPage && results_->count() > 0) results_->setCurrentRow(0);
        moreResults_->setEnabled(moreAvailable_);
        resultStatus_->setText(results_->count() == 0
            ? (resultsQuery_.isEmpty() ? QStringLiteral("This collection is empty.") : QStringLiteral("No suggestions. Check the spelling or choose another collection."))
            : QStringLiteral("%1 of %2 suggestions").arg(results_->count()).arg(searchLast_ - searchFirst_));
    }
}

void MainWindow::submitSearch() {
    if (!api_ || loading_) return;
    if (searchTimer_->isActive() || resultsQuery_ != search_->text().trimmed()) refreshSearch();
    if (!searchSelectionExplicit_) {
        const auto equal = std::equal_range(searchTitles_.cbegin(), searchTitles_.cend(), resultsQuery_, titleLess);
        if (std::find(equal.first, equal.second, resultsQuery_) != equal.second) {
            openWord(resultsQuery_);
            return;
        }
    }
    if (auto *item = results_->currentItem()) openWord(item->data(Qt::UserRole).toString());
    else openWord(search_->text().trimmed());
}

void MainWindow::updateReaderLayout() {
    if (!readerContent_ || !navigationLayout_ || !headerLayout_) return;
    const bool compact = readerContent_->width() < 580;
    if (compact == compactReader_) return;
    compactReader_ = compact;
    QFont headingFont = title_->font();
    headingFont.setPointSize(compact ? 24 : 30);
    title_->setFont(headingFont);
    for (auto *widget : std::array<QWidget *, 5>{back_, forward_, sections_, smaller_, larger_})
        navigationLayout_->removeWidget(widget);
    for (auto *widget : std::array<QWidget *, 3>{readerHeading_, listen_, bookmark_})
        headerLayout_->removeWidget(widget);
    for (int column = 0; column < 5; ++column) navigationLayout_->setColumnStretch(column, 0);
    for (int column = 0; column < 3; ++column) headerLayout_->setColumnStretch(column, 0);
    if (compact) {
        navigationLayout_->addWidget(back_, 0, 0);
        navigationLayout_->addWidget(forward_, 0, 1);
        navigationLayout_->addWidget(sections_, 1, 0, 1, 2);
        navigationLayout_->addWidget(smaller_, 2, 0);
        navigationLayout_->addWidget(larger_, 2, 1);
        navigationLayout_->setColumnStretch(0, 1);
        navigationLayout_->setColumnStretch(1, 1);
        headerLayout_->addWidget(readerHeading_, 0, 0, 1, 2);
        headerLayout_->addWidget(listen_, 1, 0);
        headerLayout_->addWidget(bookmark_, 1, 1);
        headerLayout_->setColumnStretch(0, 1);
        headerLayout_->setColumnStretch(1, 1);
    } else {
        navigationLayout_->addWidget(back_, 0, 0);
        navigationLayout_->addWidget(forward_, 0, 1);
        navigationLayout_->addWidget(sections_, 0, 2);
        navigationLayout_->addWidget(smaller_, 0, 3);
        navigationLayout_->addWidget(larger_, 0, 4);
        navigationLayout_->setColumnStretch(2, 1);
        headerLayout_->addWidget(readerHeading_, 0, 0);
        headerLayout_->addWidget(listen_, 0, 1);
        headerLayout_->addWidget(bookmark_, 0, 2);
        headerLayout_->setColumnStretch(0, 1);
    }
    readerContent_->layout()->setContentsMargins(compact ? 12 : 28, 20, compact ? 12 : 28, 24);
}

bool MainWindow::eventFilter(QObject *watched, QEvent *event) {
    if (watched == readerContent_ && event->type() == QEvent::Resize)
        updateReaderLayout();
    if (event->type() == QEvent::KeyPress) {
        auto *key = static_cast<QKeyEvent *>(event);
        if (watched == reading_ && (key->key() == Qt::Key_Menu ||
            (key->key() == Qt::Key_F10 && key->modifiers() == Qt::ShiftModifier))) {
            showReaderContextMenu(reading_->cursorRect().center());
            return true;
        }
        if (watched == results_ && (key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter)) {
            if (auto *item = results_->currentItem()) openWord(item->data(Qt::UserRole).toString());
            return true;
        }
        if (watched == search_ && (key->key() == Qt::Key_Down || key->key() == Qt::Key_Up)) {
            if (searchTimer_->isActive()) refreshSearch();
            if (results_->count() > 0) {
                searchSelectionExplicit_ = true; // Arrow transfer also selects an unchanged row zero.
                results_->setFocus();
                results_->setCurrentRow(key->key() == Qt::Key_Down ? 0 : results_->count() - 1);
            }
            return true;
        }
        if (watched == results_ && results_->currentItem() &&
            (key->key() == Qt::Key_Up || key->key() == Qt::Key_Down ||
             key->key() == Qt::Key_Home || key->key() == Qt::Key_End ||
             key->key() == Qt::Key_PageUp || key->key() == Qt::Key_PageDown))
            searchSelectionExplicit_ = true;
        if (watched == results_ && (key->key() == Qt::Key_Escape || (key->key() == Qt::Key_Up && results_->currentRow() == 0))) {
            search_->setFocus();
            return true;
        }
    }
    return QMainWindow::eventFilter(watched, event);
}

bool MainWindow::openWord(const QString &word, const std::optional<QString> &fragment, bool allowUnclassifiedFallback) {
    if (!api_ || loading_ || word.trimmed().isEmpty()) return false;
    try {
        QString exact = word.trimmed();
        QByteArray response = api_->lookup(exact);
        QJsonParseError parseError{};
        QJsonDocument document = QJsonDocument::fromJson(response, &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject() ||
            !document.object().value(QStringLiteral("entries")).isArray())
            throw DictApiError("invalid JSON returned by dictionary core");
        if (document.object().value(QStringLiteral("entries")).toArray().isEmpty()) {
            const auto found = std::lower_bound(searchTitles_.cbegin(), searchTitles_.cend(), exact, titleLess);
            if (found != searchTitles_.cend() && found->compare(exact, Qt::CaseInsensitive) == 0) {
                exact = *found;
                response = api_->lookup(exact);
                document = QJsonDocument::fromJson(response, &parseError);
                if (parseError.error != QJsonParseError::NoError || !document.isObject() ||
                    !document.object().value(QStringLiteral("entries")).isArray())
                    throw DictApiError("invalid JSON returned by dictionary core");
            }
        }
        if (document.object().value(QStringLiteral("entries")).toArray().isEmpty()) {
            // Only compiled ordinary links opt in: searches, aliases and history do not.
            if (allowUnclassifiedFallback && api_->kind() == QStringLiteral("language") &&
                currentEntry_.value(QStringLiteral("kind")).toString() == QStringLiteral("language") &&
                currentEntry_.value(QStringLiteral("redirect")).toObject().isEmpty() &&
                !originRoot_.isEmpty() && !originEdition_.isEmpty() &&
                api_->language() != QStringLiteral("Unclassified") &&
                language_->findText(QStringLiteral("Unclassified"), Qt::MatchExactly | Qt::MatchCaseSensitive) >= 0) {
                loadDataset(api_->root(), QStringLiteral("Unclassified"), api_->kind(), false,
                    word.trimmed(), -1, originRoot_, originEdition_, fragment, true);
                return true;
            }
            search_->setText(word);
            refreshSearch();
            resultStatus_->setText(QStringLiteral("No exact entry for “%1”. Try a suggestion or another collection.").arg(word));
            return false;
        }
        search_->setText(exact);
        renderResponse(response, true, fragment);
        refreshSearch();
        return true;
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Open word"), error);
        return false;
    }
}
void MainWindow::renderResponse(const QByteArray &bytes, bool addVisit, const std::optional<QString> &fragment) {
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject())
        throw DictApiError("invalid JSON returned by dictionary core");
    const QJsonArray entries = document.object().value(QStringLiteral("entries")).toArray();
    if (entries.isEmpty() || !entries.first().isObject()) return;
    if (addVisit) saveVisit();
    currentJson_ = document.toJson(QJsonDocument::Indented);
    currentEntry_ = entries.first().toObject();

    const QString title = currentEntry_.value(QStringLiteral("title")).toString();
    const QJsonArray displayTitle = currentEntry_.value(QStringLiteral("display_title")).toArray();
    const QString language = currentEntry_.value(QStringLiteral("language")).toString();
    const QString kind = currentEntry_.value(QStringLiteral("kind")).toString();
    title_->setHtml(displayTitle.isEmpty() ? title.toHtmlEscaped() : spansHtml(displayTitle));
    meta_->setText(QStringLiteral("%1 · %2").arg(language.isEmpty() ? QStringLiteral("All languages") : language, kindLabel(kind)));
    const QJsonArray sections = currentEntry_.value(QStringLiteral("sections")).toArray();
    sections_->clear();
    sections_->addItem(QStringLiteral("Jump to section"), -1);
    bool ownerLanguageListed = false;
    for (const auto &heading : headingDestinations(currentEntry_)) {
        const QJsonObject section = sections[heading.section].toObject();
        const bool ownerLanguage = heading.block < 0 && kind == QStringLiteral("language") &&
            section.value(QStringLiteral("level")).toInt() == 2 && heading.title == language;
        if (ownerLanguage && ownerLanguageListed) continue;
        sections_->addItem(heading.title, heading.section);
        sections_->setItemData(sections_->count() - 1, heading.block, Qt::UserRole + 1);
        if (ownerLanguage) ownerLanguageListed = true;
    }
    sections_->setEnabled(sections_->count() > 1);
    resetFolding();
    reading_->verticalScrollBar()->setValue(0);
    json_->setPlainText(QString::fromUtf8(currentJson_));
    entryTabs_->setCurrentIndex(0);

    const SavedWord word = savedWord(currentEntry_);
    media_->setEntry(currentEntry_, LibraryStorage::sourceHost(api_->root()));
    listen_->setEnabled(true);
    QSettings().setValue(QStringLiteral("reader/lastWord"), title);
    QSettings().setValue(QStringLiteral("reader/lastKind"), api_->kind());
    learning_.record(word);
    bookmark_->setEnabled(true);
    bookmark_->setText(learning_.isBookmarked(word.key) ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
    const QJsonObject redirect = currentEntry_.value(QStringLiteral("redirect")).toObject();
    const QString sourceTitle = redirect.value(QStringLiteral("source_title")).toString();
    // Revisit the selected alias, preserving the same single redirect edge.
    const QString lookupTitle = sourceTitle.isEmpty() ? title : sourceTitle;
    if (addVisit) {
        visits_.resize(visitIndex_ + 1);
        if (visits_.isEmpty() || visits_.last().title != lookupTitle || visits_.last().language != api_->language() || visits_.last().kind != api_->kind())
            visits_.push_back({lookupTitle, api_->language(), api_->kind(), 0, {}});
        if (visits_.size() > 100) visits_.removeFirst();
        visitIndex_ = visits_.size() - 1;
        updateNavigation();
    }
    const QString destination = fragment ? *fragment :
        (redirect.value(QStringLiteral("followed")).toBool() ? redirect.value(QStringLiteral("fragment")).toString() : QString());
    jumpToFragment(destination);
}

QVector<QPair<QString, QString>> MainWindow::readingExplanations() const {
    QVector<QPair<QString, QString>> result;
    const auto collect = [&](const QTextDocument &document) {
        int previousEnd = -1;
        for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (!fragment.isValid()) continue;
                const QString explanation = fragment.charFormat().toolTip();
                if (explanation.isEmpty()) { previousEnd = -1; continue; }
                if (!result.isEmpty() && previousEnd == fragment.position() && result.last().second == explanation)
                    result.last().first += fragment.text();
                else result.append({fragment.text(), explanation});
                previousEnd = fragment.position() + fragment.length();
            }
        }
    };
    collect(*title_->document());
    collect(*reading_->document());
    return result;
}
void MainWindow::showReaderContextMenu(const QPoint &position) {
    std::unique_ptr<QMenu> menu(reading_->createStandardContextMenu());
    menu->setParent(reading_);
    menu->setObjectName(QStringLiteral("readerContextMenu"));
    QAction *explain = nullptr;
    if (!readingExplanations().isEmpty()) {
        menu->addSeparator();
        explain = menu->addAction(QStringLiteral("Abbreviations…"));
        explain->setObjectName(QStringLiteral("entryAbbreviations"));
    }
    QAction *chosen = menu->exec(reading_->viewport()->mapToGlobal(position));
    const bool showExplanations = explain && chosen == explain;
    menu.reset();
    if (showExplanations) showAbbreviations();
}
void MainWindow::showAbbreviations() {
    const auto explanations = readingExplanations();
    if (explanations.isEmpty()) return;
    auto dialog = std::make_unique<QDialog>(this);
    dialog->setObjectName(QStringLiteral("abbreviationsDialog"));
    dialog->setWindowTitle(QStringLiteral("Abbreviations"));
    auto *layout = new QVBoxLayout(dialog.get());
    auto *details = new QTextBrowser(dialog.get());
    details->setObjectName(QStringLiteral("abbreviationExplanations"));
    details->setAccessibleName(QStringLiteral("Abbreviation explanations"));
    details->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::TextSelectableByKeyboard);
    QStringList lines;
    for (const auto &item : explanations) lines.append(item.first + QStringLiteral(": ") + item.second);
    details->setPlainText(lines.join(QStringLiteral("\n\n")));
    layout->addWidget(details);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, dialog.get());
    connect(buttons, &QDialogButtonBox::rejected, dialog.get(), &QDialog::reject);
    layout->addWidget(buttons);
    dialog->resize(420, 300);
    dialog->exec();
    dialog.reset();
    activateWindow();
    reading_->setFocus(Qt::OtherFocusReason);
}

void MainWindow::refreshReading() {
    if (currentEntry_.isEmpty()) return;
    const int scroll = reading_->verticalScrollBar()->value();
    reading_->setHtml(entryHtml(currentEntry_));
    reading_->verticalScrollBar()->setValue(scroll);
}

void MainWindow::resetFolding() {
    collapsedSections_.clear();
    const QJsonArray sections = currentEntry_.value(QStringLiteral("sections")).toArray();
    for (qsizetype i = 0; i < sections.size(); ++i) {
        const QString title = sections[i].toObject().value(QStringLiteral("title")).toString();
        if ((learning_.settings().collapsePronunciation && title.startsWith(QStringLiteral("Pronunciation"), Qt::CaseInsensitive)) ||
            (learning_.settings().collapseEtymology && title.startsWith(QStringLiteral("Etymology"), Qt::CaseInsensitive))) collapsedSections_.insert(i);
    }
    refreshReading();
}

void MainWindow::jumpToFragment(const QString &fragment) {
    if (fragment.isEmpty()) return;
    const auto headings = headingDestinations(currentEntry_);
    const HeadingDestination *destination = nullptr;
    QString spaced = fragment;
    spaced.replace(QChar(' '), QChar('_'));
    for (const QString &identity : {fragment, spaced}) {
        for (const auto &heading : headings) {
            if ((!heading.anchor.isEmpty() && heading.anchor == identity) ||
                (!heading.anchorFallback.isEmpty() && heading.anchorFallback == identity)) {
                if (destination) return;
                destination = &heading;
            }
        }
        if (destination) break;
    }
    if (!destination && fragment.startsWith(QStringLiteral("reference-"))) {
        reading_->scrollToAnchor(fragment);
        return;
    }
    if (!destination) {
        // Older records retain unambiguous label jumps and the coalesced owner language.
        QString label = fragment;
        label.replace(QChar('_'), QChar(' '));
        bool ownerLanguageDestination = false;
        const QJsonArray sections = currentEntry_.value(QStringLiteral("sections")).toArray();
        for (const auto &heading : headings) {
            if (heading.title != label) continue;
            if (!heading.anchor.isEmpty() || !heading.anchorFallback.isEmpty()) return;
            const bool ownerLanguage = heading.block < 0 &&
                currentEntry_.value(QStringLiteral("kind")).toString() == QStringLiteral("language") &&
                heading.title == currentEntry_.value(QStringLiteral("language")).toString() &&
                sections[heading.section].toObject().value(QStringLiteral("level")).toInt() == 2;
            // Match the existing single owner-language menu destination for old records.
            // Ordinary duplicate labels remain ambiguous; compiled IDs were resolved above.
            if (destination) {
                if (!ownerLanguageDestination || !ownerLanguage) return;
                continue;
            }
            destination = &heading;
            ownerLanguageDestination = ownerLanguage;
        }
    }
    if (!destination) return;
    jumpToSection(destination->section);
    if (destination->block >= 0)
        reading_->scrollToAnchor(QStringLiteral("block-%1-%2").arg(destination->section).arg(destination->block));
}

void MainWindow::jumpToSection(int section) {
    if (section < 0) return;
    collapsedSections_.remove(section);
    refreshReading();
    reading_->scrollToAnchor(QStringLiteral("section-%1").arg(section));
    reading_->setFocus();
}

void MainWindow::saveVisit() {
    if (visitIndex_ < 0 || visitIndex_ >= visits_.size() || currentEntry_.isEmpty()) return;
    visits_[visitIndex_].scroll = reading_->verticalScrollBar()->value();
    visits_[visitIndex_].collapsed = collapsedSections_;
    const QTextCursor cursor = reading_->textCursor();
    visits_[visitIndex_].cursorPosition = cursor.position();
    visits_[visitIndex_].cursorAnchor = cursor.anchor();
    visits_[visitIndex_].readerFocused = reading_->hasFocus();
}

void MainWindow::restoreVisitReading(const Visit &visit) {
    collapsedSections_ = visit.collapsed;
    refreshReading();
    // Store offsets, never a cursor tied to the document replaced by setHtml.
    const int last = qMax(0, reading_->document()->characterCount() - 1);
    QTextCursor cursor(reading_->document());
    cursor.setPosition(qBound(0, visit.cursorAnchor, last));
    cursor.setPosition(qBound(0, visit.cursorPosition, last), QTextCursor::KeepAnchor);
    reading_->setTextCursor(cursor);
    if (visit.readerFocused) reading_->setFocus(Qt::OtherFocusReason);
    else search_->setFocus(Qt::OtherFocusReason);
    // Cursor/focus restoration can scroll; the saved reading position wins.
    reading_->verticalScrollBar()->setValue(visit.scroll);
}

void MainWindow::updateNavigation() {
    back_->setEnabled(!loading_ && (visitIndex_ > 0 || (currentEntry_.isEmpty() && visitIndex_ >= 0)));
    forward_->setEnabled(!loading_ && visitIndex_ >= 0 && visitIndex_ + 1 < visits_.size());
}

void MainWindow::navigate(int direction) {
    const int index = visitIndex_ + (currentEntry_.isEmpty() && direction < 0 ? 0 : direction);
    if (!api_ || loading_ || index < 0 || index >= visits_.size()) return;
    saveVisit();
    const Visit visit = visits_[index];
    if (visit.language != api_->language() || visit.kind != api_->kind()) {
        loadDataset(api_->root(), visit.language, visit.kind, false, visit.title, index);
        return;
    }
    const QString previousLanguage = api_->language();
    const QString previousKind = api_->kind();
    try {
        api_->select(visit.language, visit.kind);
        const QByteArray bytes = api_->lookup(visit.title);
        if (QJsonDocument::fromJson(bytes).object().value(QStringLiteral("entries")).toArray().isEmpty())
            throw DictApiError("This entry is no longer available in the open dictionary folder.");
        renderResponse(bytes, false);
        QSignalBlocker kindBlocker(kind_);
        QSignalBlocker languageBlocker(language_);
        kind_->setCurrentIndex(kind_->findData(visit.kind));
        language_->setCurrentText(visit.language);
        language_->setEnabled(visit.kind == QStringLiteral("language"));
        search_->setText(visit.title);
        refreshSearch();
        restoreVisitReading(visit);
        visitIndex_ = index;
        updateNavigation();
    } catch (const std::exception &error) {
        try { api_->select(previousLanguage, previousKind); } catch (const std::exception &) {}
        reportError(QStringLiteral("Revisit word"), error);
    }
}

void MainWindow::openSavedWord(const SavedWord &word) {
    if (!api_) {
        statusBar()->showMessage(QStringLiteral("Open your dictionary folder before opening saved words."), 5000);
        return;
    }
    const SavedWord requested = word;
    if (loading_) {
        statusBar()->showMessage(QStringLiteral("Wait for the dictionary to finish opening."), 5000);
        return;
    }
    try {
        const QString currentRoot = QFileInfo(api_->root()).canonicalFilePath();
        const QString currentEdition = LibraryStorage::editionIdentity(api_->root());
        if (currentRoot != originRoot_ || currentEdition != originEdition_) {
            statusBar()->showMessage(QStringLiteral("This dictionary has changed. Open it again."), 5000);
            return;
        }
        if (!requested.originRoot.isEmpty() &&
            (requested.originRoot != currentRoot || requested.originEdition != currentEdition)) {
            const QString required = requested.originEdition.isEmpty() ? QStringLiteral("the saved dictionary") : requested.originEdition;
            statusBar()->showMessage(QStringLiteral("Open %1 in %2.").arg(required, QDir::toNativeSeparators(requested.originRoot)), 8000);
            return;
        }
        if (requested.originRoot.isEmpty() || requested.originEdition.isEmpty()) {
            QMessageBox choice(QMessageBox::Question, QStringLiteral("Open saved word"),
                QStringLiteral("Open from this dictionary?"), QMessageBox::Open | QMessageBox::Cancel, this);
            choice.setInformativeText(QDir::toNativeSeparators(currentRoot));
            choice.setDefaultButton(QMessageBox::Cancel);
            if (choice.exec() != QMessageBox::Open) return;
        }
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Open saved word"), error);
        return;
    }
    const int kindIndex = kind_->findData(requested.kind);
    const int languageIndex = language_->findText(requested.language);
    if (kindIndex < 0 || (requested.kind == QStringLiteral("language") && languageIndex < 0)) {
        statusBar()->showMessage(QStringLiteral("This saved word needs %1. Open its dictionary folder.").arg(requested.language), 5000);
        return;
    }
    if (api_->kind() == requested.kind && (requested.kind != QStringLiteral("language") || api_->language() == requested.language)) openWord(requested.title);
    else loadDataset(api_->root(), requested.language, requested.kind, false, requested.title, -1, originRoot_, originEdition_);
}
QString MainWindow::spansHtml(const QJsonArray &spans, qreal leftMargin, const QString &prefix) const {
    const auto flatHtml = [&](const QJsonArray &parts) {
        QString out;
        for (const QJsonValue &value : parts) {
            const QJsonObject span = value.toObject();
            const QString kind = span.value(QStringLiteral("kind")).toString();
            if (kind == QStringLiteral("line_break")) { out += QStringLiteral("<br>"); continue; }
            const QString classes = span.value(QStringLiteral("classes")).toString();
            QString text = (span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString()).toHtmlEscaped();
            const QString explanation = span.value(QStringLiteral("explanation")).toString();
            if (!explanation.isEmpty())
                text = QStringLiteral("<span title=\"%1\">%2</span>")
                    .arg(explanation.toHtmlEscaped(), text);
            // Keep the script font on the characters themselves: Qt's full-page
            // body style can otherwise replace an outer span's font inside <b>.
            if (!span.value(QStringLiteral("code")).toBool() &&
                classes.simplified().split(QChar(' '), Qt::SkipEmptyParts).contains(QStringLiteral("Egyp")))
                text = QStringLiteral("<span style=\"font-family:'%1'\">%2</span>")
                    .arg(egyptianFamily().toHtmlEscaped(), text);
            const QJsonValue foregroundValue = span.value(QStringLiteral("foreground"));
            const QString foreground = foregroundValue.toString();
            bool canonicalForeground = foregroundValue.isString() && foreground.size() == 7 && foreground.startsWith(QChar('#'));
            for (const QChar digit : foreground.mid(1))
                canonicalForeground = canonicalForeground && ((digit >= QChar('0') && digit <= QChar('9'))
                    || (digit >= QChar('a') && digit <= QChar('f')));
            // Keep the authored color on the characters inside a possible link,
            // so the default anchor palette cannot replace its semantic color.
            if (canonicalForeground)
                text = QStringLiteral("<span style=\"color:%1\">%2</span>").arg(foreground, text);
            if (kind == QStringLiteral("template"))
                throw DictApiError("compiled dictionary contains an uncompiled template span");
            if (kind == QStringLiteral("link")) {
                const QByteArray encoded = QUrl::toPercentEncoding(span.value(QStringLiteral("target")).toString());
                text = QStringLiteral("<a href='dict:%1'>%2</a>").arg(QString::fromLatin1(encoded), text);
            } else if (kind == QStringLiteral("external_link")) {
                const QString target = span.value(QStringLiteral("target")).toString();
                QUrl url(target);
                if (target.startsWith(QStringLiteral("//")) && url.scheme().isEmpty())
                    url.setScheme(QStringLiteral("https"));
                if (url.isValid() && !url.host().isEmpty() &&
                    (url.scheme() == QStringLiteral("http") || url.scheme() == QStringLiteral("https")))
                    // QTextDocument decodes attribute entities only inside double quotes.
                    text = QStringLiteral("<a href=\"%1\">%2</a>").arg(url.toString(QUrl::FullyEncoded).toHtmlEscaped(), text);
            }
            if (span.value(QStringLiteral("code")).toBool()) text = QStringLiteral("<code>%1</code>").arg(text);
            if (span.value(QStringLiteral("small")).toBool()) text = QStringLiteral("<small>%1</small>").arg(text);
            if (span.value(QStringLiteral("bold")).toBool()) text = QStringLiteral("<b>%1</b>").arg(text);
            if (span.value(QStringLiteral("italic")).toBool()) text = QStringLiteral("<i>%1</i>").arg(text);
            if (span.value(QStringLiteral("underline")).toBool()) text = QStringLiteral("<u>%1</u>").arg(text);
            if (span.value(QStringLiteral("strike")).toBool()) text = QStringLiteral("<s>%1</s>").arg(text);
            if (span.value(QStringLiteral("superscript")).toBool()) text = QStringLiteral("<sup>%1</sup>").arg(text);
            if (span.value(QStringLiteral("subscript")).toBool()) text = QStringLiteral("<sub>%1</sub>").arg(text);
            const QString language = span.value(QStringLiteral("language")).toString();
            const QString direction = span.value(QStringLiteral("direction")).toString();
            // QTextDocument does not isolate inline HTML direction attributes.
            // Keep the complete styled link/text and its trail in one bidi isolate.
            ushort isolate = 0;
            if (direction == QStringLiteral("auto")) isolate = 0x2068; // FSI
            else if (direction == QStringLiteral("rtl")) isolate = 0x2067; // RLI
            else if (direction == QStringLiteral("ltr")) isolate = 0x2066; // LRI
            if (isolate) text = QString(QChar(isolate)) + text + QChar(0x2069); // PDI
            if (!classes.isEmpty() || !language.isEmpty() || !direction.isEmpty()) {
                QString attrs;
                if (!classes.isEmpty()) attrs += QStringLiteral(" class=\"%1\"").arg(classes.toHtmlEscaped());
                if (!language.isEmpty()) attrs += QStringLiteral(" lang=\"%1\"").arg(language.toHtmlEscaped());
                if (!direction.isEmpty()) attrs += QStringLiteral(" dir=\"%1\"").arg(direction.toHtmlEscaped());
                text = QStringLiteral("<span%1>%2</span>").arg(attrs, text);
            }
            out += text;
        }
        return out;
    };

    if (!hasPoemSpans(spans)) return prefix + flatHtml(spans);

    QString out;
    QString firstLinePrefix = prefix;
    QJsonArray line;
    bool haveMetadata = false;
    int indent = 0, direction = 0;
    bool endedWithBreak = false;
    QJsonObject lastBreak;
    const auto includeMetadata = [&](const QJsonObject &span) {
        const QStringList classes = poemClassTokens(span);
        const int nextIndent = poemIndent(classes), nextDirection = poemDirection(classes);
        if (!haveMetadata) {
            indent = nextIndent;
            direction = nextDirection;
            haveMetadata = true;
        } else {
            if (indent != nextIndent) indent = -1;
            if (direction != nextDirection) direction = -1;
        }
    };
    const auto appendLine = [&] {
        QString plain;
        for (const QJsonValue &value : line) {
            const QJsonObject span = value.toObject();
            plain += span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString();
        }
        // Enclosing layout direction is independent of child span isolates.
        const bool rtl = direction == 1 ? false : direction == 2 ? true : reading_->layoutDirection() == Qt::RightToLeft;
        const qreal margin = std::max(0, indent) * readingPointSize_ * reading_->logicalDpiY() / 72.0;
        const bool empty = plain.isEmpty() && firstLinePrefix.isEmpty();
        const QString body = firstLinePrefix + flatHtml(line);
        out += QStringLiteral("<p dir='%1' style='margin:0px;margin-left:%2px;margin-right:%3px%4'>%5</p>")
            .arg(rtl ? QStringLiteral("rtl") : QStringLiteral("ltr"))
            .arg(leftMargin + (rtl ? 0.0 : margin)).arg(rtl ? margin : 0.0)
            .arg(empty ? QStringLiteral(";-qt-paragraph-type:empty") : QString(),
                 empty ? QStringLiteral("<br>") : body);
        firstLinePrefix.clear();
        line = QJsonArray();
        haveMetadata = false;
        indent = direction = 0;
    };
    const auto appendPart = [&](QJsonObject &span, const QString &text, bool trail) {
        qsizetype start = 0;
        while (start < text.size()) {
            const qsizetype newline = text.indexOf(QChar('\n'), start);
            const qsizetype end = newline < 0 ? text.size() : newline;
            if (end > start) {
                QJsonObject part = span;
                part.insert(QStringLiteral("text"), trail ? QString() : text.mid(start, end - start));
                part.insert(QStringLiteral("trail"), trail ? text.mid(start, end - start) : QString());
                includeMetadata(span);
                line.append(part);
                endedWithBreak = false;
            }
            if (newline < 0) break;
            includeMetadata(span);
            appendLine();
            endedWithBreak = true;
            // Raw LF starts an unindented line unless a following span owns a
            // separately parsed line wrapper. Enclosing direction still applies.
            QStringList classes = poemClassTokens(span);
            classes.removeIf([](const QString &token) { return token.startsWith(QStringLiteral("wikidict-poem-indent")); });
            span.insert(QStringLiteral("classes"), classes.join(QChar(' ')));
            lastBreak = span;
            start = newline + 1;
        }
    };
    for (const QJsonValue &value : spans) {
        QJsonObject span = value.toObject();
        if (span.value(QStringLiteral("kind")).toString() == QStringLiteral("line_break")) {
            // An unmarked boundary ends the line without changing its poem metadata.
            if (poemClassTokens(span).contains(QStringLiteral("wikidict-poem"))) includeMetadata(span);
            appendLine();
            endedWithBreak = true;
            lastBreak = span;
        } else {
            const QString text = span.value(QStringLiteral("text")).toString();
            const QString trail = span.value(QStringLiteral("trail")).toString();
            if (text.isEmpty() && trail.isEmpty()) {
                includeMetadata(span);
                line.append(value);
                endedWithBreak = false;
            } else {
                appendPart(span, text, false);
                appendPart(span, trail, true);
            }
        }
    }
    if (!line.isEmpty() || haveMetadata) appendLine();
    else if (endedWithBreak) {
        // A retained terminal break starts an intentional empty line.
        includeMetadata(lastBreak);
        appendLine();
    }
    return out;

}
QString MainWindow::tableHtml(const QJsonObject &table, int depth) const {
    const int indent = depth > 0 ? 30 + std::clamp(depth - 1, 0, 20) * 16 : 0;
    QString out = QStringLiteral("<table cellspacing='0' cellpadding='5' style='border-collapse:collapse;margin:8px 0;margin-left:%1px'>").arg(indent);
    const QJsonArray caption = table.value(QStringLiteral("caption")).toArray();
    if (!caption.isEmpty()) out += QStringLiteral("<caption>%1</caption>").arg(spansHtml(caption));
    for (const QJsonValue &rowValue : table.value(QStringLiteral("rows")).toArray()) {
        out += QStringLiteral("<tr>");
        for (const QJsonValue &cellValue : rowValue.toObject().value(QStringLiteral("cells")).toArray()) {
            const QJsonObject cell = cellValue.toObject();
            const QString tag = cell.value(QStringLiteral("header")).toBool() ? QStringLiteral("th") : QStringLiteral("td");
            const int colspan = std::max(1, cell.value(QStringLiteral("colspan")).toInt(1));
            const int rowspan = std::max(1, cell.value(QStringLiteral("rowspan")).toInt(1));
            QString style = QStringLiteral("border:1px solid %1").arg(palette().color(QPalette::Mid).name());
            const QJsonValue backgroundValue = cell.value(QStringLiteral("background"));
            const QString background = backgroundValue.toString();
            bool canonicalBackground = backgroundValue.isString() && background.size() == 7 && background.startsWith(QChar('#'));
            for (const QChar digit : background.mid(1))
                canonicalBackground = canonicalBackground && ((digit >= QChar('0') && digit <= QChar('9'))
                    || (digit >= QChar('a') && digit <= QChar('f')));
            if (canonicalBackground) style += QStringLiteral(";background-color:") + background;
            out += QStringLiteral("<%1 colspan='%2' rowspan='%3' style='%4'>%5</%1>")
                .arg(tag).arg(colspan).arg(rowspan).arg(style, spansHtml(cell.value(QStringLiteral("spans")).toArray()));
        }
        out += QStringLiteral("</tr>");
    }
    out += QStringLiteral("</table>");
    return out;
}

QString MainWindow::blockHtml(const QJsonObject &block) const {
    const QString kind = block.value(QStringLiteral("kind")).toString();
    if (kind == QStringLiteral("blank")) return {};
    if (kind == QStringLiteral("rule")) return QStringLiteral("<hr>");
    const QJsonValue table = block.value(QStringLiteral("table"));
    const QJsonObject feature = block.value(QStringLiteral("feature")).toObject();
    const QString color = feature.value(QStringLiteral("data")).toString();
    bool canonicalColor = color.size() == 7 && color.startsWith(QChar('#'));
    for (const QChar digit : color.mid(1))
        canonicalColor = canonicalColor && ((digit >= QChar('0') && digit <= QChar('9'))
            || (digit >= QChar('a') && digit <= QChar('f')));
    const auto defaultField = [&](const QString &key, const QString &expected) {
        const QJsonValue value = feature.value(key);
        return value.isUndefined() || (value.isString() && value.toString() == expected);
    };
    if (kind == QStringLiteral("table") && table.isObject()
        && feature.value(QStringLiteral("kind")).toString() == QStringLiteral("color_swatch") && canonicalColor
        && defaultField(QStringLiteral("language"), QString())
        && defaultField(QStringLiteral("tail_kind"), QStringLiteral("none"))
        && defaultField(QStringLiteral("tail"), QString())) {
        const int depth = block.value(QStringLiteral("depth")).toInt();
        const int indent = depth > 0 ? 30 + std::clamp(depth - 1, 0, 20) * 16 : 0;
        // The empty sample is decorative; the adjacent readable text is its sole accessible label.
        return QStringLiteral("<table cellspacing='0' cellpadding='5' style='margin:8px 0;margin-left:%1px'>"
            "<tr><td width='40' bgcolor='%2'>&#160;</td><td>Color sample %2</td></tr></table>").arg(indent).arg(color);
    }
    if (table.isObject()) return tableHtml(table.toObject(), block.value(QStringLiteral("depth")).toInt());
    const QJsonArray spans = block.value(QStringLiteral("spans")).toArray();
    const bool poem = hasPoemSpans(spans);
    if (kind == QStringLiteral("paragraph") && block.value(QStringLiteral("depth")).toInt() == 0 &&
        block.value(QStringLiteral("list_path")).toString().isEmpty() &&
        block.value(QStringLiteral("number")).toString().isEmpty() &&
        block.value(QStringLiteral("level")).toInt() == 0 &&
        !poem && feature.isEmpty() && !spans.isEmpty()) {
        bool layoutOnly = true;
        for (const QJsonValue &span : spans)
            layoutOnly = layoutOnly && ordinaryLayoutWhitespaceSpan(span.toObject(), false);
        if (layoutOnly) return {};
    }
    const int indent = std::clamp(block.value(QStringLiteral("depth")).toInt(1) - 1, 0, 20) * 16;
    const int depth = block.value(QStringLiteral("depth")).toInt();
    const int outerIndent = kind == QStringLiteral("definition") || kind == QStringLiteral("term") ? indent
        : kind == QStringLiteral("list_item") ? 18 + indent
        : kind == QStringLiteral("list_detail") || kind == QStringLiteral("indent") ? 30 + indent
        : depth > 0 ? 30 + std::clamp(depth - 1, 0, 20) * 16 : 0;
    QString prefix;
    if (poem && (kind == QStringLiteral("definition") || kind == QStringLiteral("list_item"))) {
        const QString number = block.value(QStringLiteral("number")).toString();
        const QString marker = number.isEmpty() ? QStringLiteral("•")
            : number.toHtmlEscaped() + (kind == QStringLiteral("list_item") ? QStringLiteral(".") : QString());
        prefix = kind == QStringLiteral("definition") ? QStringLiteral("<b>%1</b> ").arg(marker) : marker + QChar(' ');
    } else if (poem && kind == QStringLiteral("example")) {
        prefix = QStringLiteral("<i>Example:</i> ");
    }
    const QString body = spansHtml(spans, poem ? outerIndent : 0, prefix);
    if (poem) {
        // Marked lines are paragraphs already. Prefixes belong to their first line.
        if (kind == QStringLiteral("quotation") || kind == QStringLiteral("example"))
            return QStringLiteral("<blockquote>%1</blockquote>").arg(body);
        const QString style = kind == QStringLiteral("term") ? QStringLiteral("font-weight:bold")
            : kind == QStringLiteral("heading") ? QStringLiteral("font-weight:bold;font-size:large")
            : kind == QStringLiteral("preformatted") ? QStringLiteral("font-family:monospace;white-space:pre") : QString();
        return QStringLiteral("<div style='%1'>%2</div>").arg(style, body);
    }
    if (kind == QStringLiteral("preformatted")) return QStringLiteral("<pre>%1</pre>").arg(body);
    if (kind == QStringLiteral("definition")) {
        const QString number = block.value(QStringLiteral("number")).toString();
        return QStringLiteral("<p style='margin:7px 0 7px %1px'><b>%2</b> %3</p>").arg(indent).arg(number.isEmpty() ? QStringLiteral("•") : number.toHtmlEscaped(), body);
    }
    if (kind == QStringLiteral("example")) return QStringLiteral("<blockquote><i>Example:</i> %1</blockquote>").arg(body);
    if (kind == QStringLiteral("quotation")) return QStringLiteral("<blockquote>%1</blockquote>").arg(body);
    if (kind == QStringLiteral("term")) return QStringLiteral("<p style='margin-left:%1px'><b>%2</b></p>").arg(indent).arg(body);
    if (kind == QStringLiteral("list_item")) {
        const QString number = block.value(QStringLiteral("number")).toString();
        const QString marker = number.isEmpty() ? QStringLiteral("•") : number.toHtmlEscaped() + QChar('.');
        return QStringLiteral("<p style='margin-left:%1px'>%2 %3</p>").arg(18 + indent).arg(marker, body);
    }
    if (kind == QStringLiteral("list_detail") || kind == QStringLiteral("indent"))
        return QStringLiteral("<p style='margin-left:%1px'>%2</p>").arg(30 + indent).arg(body);
    if (kind == QStringLiteral("heading")) {
        const int sourceLevel = block.value(QStringLiteral("level")).toInt();
        const int headingLevel = sourceLevel >= 1 && sourceLevel <= 6 ? sourceLevel : 3;
        // Preserve the existing h3-sized typography while retaining source semantics and depth.
        return QStringLiteral("<h%1 style=\"font-family:&quot;%3&quot;;font-size:large;margin-left:%2px\">%4</h%1>")
            .arg(headingLevel).arg(outerIndent).arg(readerFamily().toHtmlEscaped(), body);
    }
    if (depth > 0)
        return QStringLiteral("<p style='margin-left:%1px'>%2</p>")
            .arg(30 + std::clamp(depth - 1, 0, 20) * 16).arg(body);
    return QStringLiteral("<p>%1</p>").arg(body);
}

QString MainWindow::entryHtml(const QJsonObject &entry) const {
    QString out = QStringLiteral(
        "<style>body{font-family:'%4';font-size:%1pt;color:%2;}"
        ".wikidict-section-heading{font-family:sans-serif;font-size:x-large;margin-top:20px;}"
        "a{color:%3;text-decoration:none;}blockquote{margin:8px 18px;}"
        "code,pre{font-family:monospace;}</style><body>")
        .arg(readingPointSize_).arg(palette().color(QPalette::Text).name(), palette().color(QPalette::Link).name(), readerFamily());
    const QJsonObject redirect = entry.value(QStringLiteral("redirect")).toObject();
    if (redirect.value(QStringLiteral("followed")).toBool())
        out += QStringLiteral("<p><small>Redirected from %1</small></p>").arg(redirect.value(QStringLiteral("source_title")).toString().toHtmlEscaped());
    const QString ownerPrefix = QStringLiteral("wikidict-media-file-");
    QHash<QString, QString> mediaOwners;
    for (const QJsonValue &value : entry.value(QStringLiteral("media")).toArray()) {
        const QString file = value.toObject().value(QStringLiteral("file")).toString();
        if (!file.isEmpty())
            mediaOwners.insert(ownerPrefix + QString::fromLatin1(file.toUtf8().toHex()), file);
    }
    QHash<QString, QSet<QString>> embeddedCaptions;
    const auto collectEmbeddedMedia = [&](const QJsonArray &spans) {
        QString file, text;
        const auto finishCaption = [&] {
            if (!file.isEmpty() && !text.simplified().isEmpty()) embeddedCaptions[file].insert(text.simplified());
            file.clear();
            text.clear();
        };
        for (const QJsonValue &value : spans) {
            const QJsonObject span = value.toObject();
            const QStringList classes = span.value(QStringLiteral("classes")).toString().simplified().split(QChar(' '), Qt::SkipEmptyParts);
            const QString target = span.value(QStringLiteral("target")).toString();
            const QString kind = span.value(QStringLiteral("kind")).toString();
            QString captionFile;
            if (classes.contains(QStringLiteral("wikidict-media"))) {
                QStringList owners;
                for (const QString &token : classes)
                    if (token.startsWith(ownerPrefix)) owners.append(token);
                // Exact catalog tokens validate UTF-8, lowercase hex and membership without decoding input.
                // Present invalid or ambiguous ownership never falls back to a lexical File link.
                if (!owners.isEmpty()) {
                    if (owners.size() == 1) captionFile = mediaOwners.value(owners.first());
                } else if ((kind == QStringLiteral("link") || kind == QStringLiteral("line_break")) &&
                    (target.startsWith(QStringLiteral("File:"), Qt::CaseInsensitive) || target.startsWith(QStringLiteral("Image:"), Qt::CaseInsensitive))) {
                    captionFile = target.mid(target.indexOf(QChar(':')) + 1).replace(QChar('_'), QChar(' '));
                }
            }
            if (captionFile != file || captionFile.isEmpty()) finishCaption();
            if (!captionFile.isEmpty()) {
                file = captionFile;
                text += kind == QStringLiteral("line_break") ? QStringLiteral("\n")
                    : span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString();
            }
        }
        finishCaption();
    };
    const QJsonArray preamble = entry.value(QStringLiteral("preamble_spans")).toArray();
    collectEmbeddedMedia(preamble);
    if (!preamble.isEmpty()) {
        const QString tag = hasPoemSpans(preamble) ? QStringLiteral("div") : QStringLiteral("p");
        out += QStringLiteral("<%1>%2</%1>").arg(tag, spansHtml(preamble));
    }
    int index = -1;
    for (const QJsonValue &sectionValue : entry.value(QStringLiteral("sections")).toArray()) {
        ++index;
        const QJsonObject section = sectionValue.toObject();
        const QString title = section.value(QStringLiteral("title")).toString();
        const int level = section.value(QStringLiteral("level")).toInt();
        out += QStringLiteral("<a name='section-%1'></a>").arg(index);
        const bool ownerLanguage = entry.value(QStringLiteral("kind")).toString() == QStringLiteral("language") &&
            level == 2 && title == entry.value(QStringLiteral("language")).toString();
        const QJsonArray richHeading = sectionHeadingSpans(section);
        const bool renderRichHeading = !richHeading.isEmpty();
        if (renderRichHeading) {
            // The fold control and lexical links are siblings, never nested anchors.
            collectEmbeddedMedia(richHeading);
            const QJsonObject companion = section.value(QStringLiteral("blocks")).toArray().first().toObject();
            const int depth = companion.value(QStringLiteral("depth")).toInt();
            const int margin = depth > 0 ? 30 + std::clamp(depth - 1, 0, 20) * 16 : 0;
            const int headingLevel = level >= 1 && level <= 6 ? level : 2;
            // Section typography stays compact; the semantic heading level and indentation are authored.
            out += QStringLiteral("<h%1 class='wikidict-section-heading' style='font-family:sans-serif;font-size:%2pt;margin-top:20px;margin-left:%3px'><a href='section:%4'>%5</a> %6</h%1>")
                .arg(headingLevel).arg(readingPointSize_).arg(margin).arg(index)
                .arg(collapsedSections_.contains(index) ? QStringLiteral("▸") : QStringLiteral("▾"), spansHtml(compactSectionHeadingDisplaySpans(richHeading)));
        } else if (!ownerLanguage) {
            out += QStringLiteral("<h2 class='wikidict-section-heading'><a href='section:%1'>%2 %3</a></h2>").arg(index)
                .arg(collapsedSections_.contains(index) ? QStringLiteral("▸") : QStringLiteral("▾"), title.toHtmlEscaped());
        }
        if (collapsedSections_.contains(index)) continue;
        const QJsonArray blocks = section.value(QStringLiteral("blocks")).toArray();
        for (qsizetype blockIndex = 0; blockIndex < blocks.size(); ++blockIndex) {
            if (blockIndex == 0 && renderRichHeading) continue;
            const QJsonObject block = blocks[blockIndex].toObject();
            const QString kind = block.value(QStringLiteral("kind")).toString();
            if (kind != QStringLiteral("blank") && kind != QStringLiteral("rule")) {
                const QJsonValue table = block.value(QStringLiteral("table"));
                if (table.isObject()) {
                    const QJsonObject object = table.toObject();
                    collectEmbeddedMedia(object.value(QStringLiteral("caption")).toArray());
                    for (const QJsonValue &row : object.value(QStringLiteral("rows")).toArray())
                        for (const QJsonValue &cell : row.toObject().value(QStringLiteral("cells")).toArray())
                            collectEmbeddedMedia(cell.toObject().value(QStringLiteral("spans")).toArray());
                } else collectEmbeddedMedia(block.value(QStringLiteral("spans")).toArray());
            }
            if (kind == QStringLiteral("heading"))
                out += QStringLiteral("<a name='block-%1-%2'></a>").arg(index).arg(blockIndex);
            out += blockHtml(block);
        }
    }
    const QJsonArray references = entry.value(QStringLiteral("references")).toArray();
    if (!references.isEmpty()) {
        out += QStringLiteral("<h2>References</h2>");
        for (const QJsonValue &reference : references) {
            const QJsonObject ref = reference.toObject();
            collectEmbeddedMedia(ref.value(QStringLiteral("spans")).toArray());
            const QString group = ref.value(QStringLiteral("group")).toString();
            const int groupNumber = ref.value(QStringLiteral("group_number")).toInt();
            const QString label = group.isEmpty() ? QStringLiteral("[%1]").arg(groupNumber)
                : QStringLiteral("[%1 %2]").arg(group, QString::number(groupNumber));
            const QJsonArray spans = ref.value(QStringLiteral("spans")).toArray();
            const QString prefix = QStringLiteral("<a name='reference-%1'></a>%2 ")
                .arg(ref.value(QStringLiteral("number")).toInt()).arg(label.toHtmlEscaped());
            if (hasPoemSpans(spans))
                out += QStringLiteral("<div>%1</div>").arg(spansHtml(spans, 0, prefix));
            else
                out += QStringLiteral("<p>%1%2</p>").arg(prefix, spansHtml(spans));
        }
    }
    const QJsonArray media = entry.value(QStringLiteral("media")).toArray();
    if (!media.isEmpty()) {
        out += QStringLiteral("<h2>Media</h2><ul>");
        for (const QJsonValue &value : media) {
            const QJsonObject item = value.toObject();
            const QString file = item.value(QStringLiteral("file")).toString();
            const QString caption = item.value(QStringLiteral("caption")).toString();
            const QString url = QStringLiteral("https://commons.wikimedia.org/wiki/File:%1").arg(QString::fromLatin1(QUrl::toPercentEncoding(file)));
            out += QStringLiteral("<li>%1: <a href='%2'>%3</a>%4</li>")
                .arg(item.value(QStringLiteral("kind")).toString().toHtmlEscaped(), url.toHtmlEscaped(), file.toHtmlEscaped(),
                    caption.isEmpty() || embeddedCaptions.value(QString(file).replace(QChar('_'), QChar(' '))).contains(caption.simplified())
                        ? QString() : QStringLiteral(" · %1").arg(caption.toHtmlEscaped()));
        }
        out += QStringLiteral("</ul><p><small>Media links open online in your browser.</small></p>");
    }
    const QString host = api_ ? LibraryStorage::sourceHost(api_->root()) : QString();
    QString source = host.isEmpty() ? QStringLiteral("https://www.wiktionary.org/") : QStringLiteral("https://") + host + QChar('/');
    if (!host.isEmpty()) {
        const QString kind = entry.value(QStringLiteral("kind")).toString();
        QString pageTitle;
        if (kind == QStringLiteral("language") || kind == QStringLiteral("supplemental") || kind == QStringLiteral("alias"))
            pageTitle = entry.value(QStringLiteral("title")).toString();
        else if (redirect.value(QStringLiteral("followed")).toBool()) pageTitle = redirect.value(QStringLiteral("target_title")).toString();
        if (!pageTitle.isEmpty()) source += QStringLiteral("wiki/") + QString::fromLatin1(QUrl::toPercentEncoding(pageTitle));
    }
    out += QStringLiteral("<hr><p><small><a href='%1'>Wiktionary contributors</a> · <a href='https://creativecommons.org/licenses/by-sa/4.0/'>CC BY-SA 4.0</a></small></p>").arg(source.toHtmlEscaped());
    return out + QStringLiteral("</body>");
}

QString MainWindow::clueFor(const QJsonObject &entry) const {
    auto textFor = [](const QJsonArray &spans) {
        QString text;
        for (const QJsonValue &value : spans) {
            const QJsonObject span = value.toObject();
            if (span.value(QStringLiteral("kind")).toString() == QStringLiteral("template")) throw DictApiError("compiled dictionary contains an uncompiled template span");
            // Preview prose must not become an audio control or its filename.
            // Keep ordinary linked text, including meanings compiled as indents.
            const QStringList classes = span.value(QStringLiteral("classes")).toString().simplified().split(QChar(' '), Qt::SkipEmptyParts);
            if (classes.contains(QStringLiteral("wikidict-media")) || classes.contains(QStringLiteral("audiotable"))) continue;
            text += span.value(QStringLiteral("text")).toString();
            text += span.value(QStringLiteral("trail")).toString();
        }
        return text.simplified();
    };
    for (const QJsonValue &sectionValue : entry.value(QStringLiteral("sections")).toArray()) {
        for (const QJsonValue &blockValue : sectionValue.toObject().value(QStringLiteral("blocks")).toArray()) {
            const QJsonObject block = blockValue.toObject();
            if (block.value(QStringLiteral("kind")).toString() != QStringLiteral("definition")) continue;
            const QString text = textFor(block.value(QStringLiteral("spans")).toArray());
            if (!text.isEmpty()) return text.left(420);
        }
    }
    for (const QJsonValue &sectionValue : entry.value(QStringLiteral("sections")).toArray()) {
        for (const QJsonValue &blockValue : sectionValue.toObject().value(QStringLiteral("blocks")).toArray()) {
            const QString text = textFor(blockValue.toObject().value(QStringLiteral("spans")).toArray());
            if (!text.isEmpty()) return text.left(420);
        }
    }
    return QStringLiteral("Definition unavailable in this entry.");
}

SavedWord MainWindow::savedWord(const QJsonObject &entry) const {
    SavedWord word;
    word.title = entry.value(QStringLiteral("title")).toString();
    word.language = entry.value(QStringLiteral("language")).toString();
    word.kind = entry.value(QStringLiteral("kind")).toString();
    word.clue = clueFor(entry);
    word.originRoot = originRoot_;
    word.originEdition = originEdition_;
    word.key = QString::fromUtf8(QJsonDocument(QJsonArray{word.originRoot, word.originEdition, word.kind, word.language, word.title}).toJson(QJsonDocument::Compact));
    word.lastViewed = QDateTime::currentMSecsSinceEpoch();
    word.views = 1;
    return word;
}

QVector<SavedWord> MainWindow::learningPool() const {
    return learning_.pool(sampleWords_);
}

void MainWindow::showRandomWord() {
    if (!api_) return;
    try {
        const QString source = learning_.settings().randomPool;
        if (source == QStringLiteral("all")) {
            const QByteArray response = api_->random();
            const QJsonDocument document = QJsonDocument::fromJson(response);
            const QJsonArray entries = document.object().value(QStringLiteral("entries")).toArray();
            if (!entries.isEmpty()) {
                search_->setText(entries.first().toObject().value(QStringLiteral("title")).toString());
                renderResponse(response);
                refreshSearch();
            }
            return;
        }
        const QVector<SavedWord> words = source == QStringLiteral("bookmarks") ? learning_.bookmarks() : learning_.history();
        if (words.isEmpty()) { statusBar()->showMessage(QStringLiteral("No words in that random-word source yet."), 4000); return; }
        openSavedWord(words.at(QRandomGenerator::global()->bounded(words.size())));
    } catch (const std::exception &error) { reportError(QStringLiteral("Random word"), error); }
}
void MainWindow::showLearningDialog(int tab) {
    QDialog dialog(this);
    dialog.setWindowTitle(QStringLiteral("Saved words & learning"));
    dialog.resize(760, 620);
    auto *layout = new QVBoxLayout(&dialog);
    auto *tabs = new QTabWidget(&dialog);
    layout->addWidget(tabs, 1);

    auto makeWordList = [&](const QVector<SavedWord> &words, const QString &emptyText) {
        auto *list = new QListWidget(tabs);
        if (words.isEmpty()) {
            auto *item = new QListWidgetItem(emptyText, list);
            item->setFlags(Qt::NoItemFlags);
        } else {
            for (const SavedWord &word : words) {
                const QString origin = word.originEdition.isEmpty() ? QStringLiteral("Unknown edition") : word.originEdition;
                auto *item = new QListWidgetItem(QStringLiteral("%1 · %2 · %3\n%4").arg(word.title, word.language, origin, word.clue), list);
                item->setData(Qt::UserRole, word.key);
                item->setToolTip(word.originRoot.isEmpty() ? QStringLiteral("Original dictionary unknown") : QDir::toNativeSeparators(word.originRoot));
            }
        }
        return list;
    };

    auto *historyPage = new QWidget(tabs);
    auto *historyLayout = new QVBoxLayout(historyPage);
    auto *historyList = makeWordList(learning_.history(), QStringLiteral("No history yet."));
    auto *clearHistory = new QPushButton(QStringLiteral("Clear history"), historyPage);
    clearHistory->setEnabled(!learning_.history().isEmpty());
    auto *removeHistory = new QPushButton(QStringLiteral("Remove selected word"), historyPage);
    historyLayout->addWidget(historyList, 1);
    historyLayout->addWidget(removeHistory);
    historyLayout->addWidget(clearHistory);
    tabs->addTab(historyPage, QStringLiteral("History"));
    auto *bookmarkPage = new QWidget(tabs);
    auto *bookmarkLayout = new QVBoxLayout(bookmarkPage);
    auto *bookmarkList = makeWordList(learning_.bookmarks(), QStringLiteral("No bookmarks yet."));
    auto *removeBookmark = new QPushButton(QStringLiteral("Remove selected bookmark"), bookmarkPage);
    bookmarkLayout->addWidget(bookmarkList, 1);
    bookmarkLayout->addWidget(removeBookmark);
    tabs->addTab(bookmarkPage, QStringLiteral("Bookmarks"));

    const auto selectedWordItem = [](QListWidget *list) -> QListWidgetItem * {
        const auto selected = list->selectedItems();
        if (selected.size() != 1) return nullptr;
        auto *item = selected.first();
        return (item->flags() & Qt::ItemIsEnabled) &&
            !item->data(Qt::UserRole).toString().isEmpty() ? item : nullptr;
    };
    const auto restoreEmptyWordList = [](QListWidget *list, const QString &text) {
        if (list->count() != 0) return;
        auto *item = new QListWidgetItem(text, list);
        item->setFlags(Qt::NoItemFlags);
    };
    auto updateWordRemoval = [&] {
        removeHistory->setEnabled(selectedWordItem(historyList) != nullptr);
        removeBookmark->setEnabled(selectedWordItem(bookmarkList) != nullptr);
    };
    connect(historyList, &QListWidget::itemSelectionChanged, &dialog, updateWordRemoval);
    connect(bookmarkList, &QListWidget::itemSelectionChanged, &dialog, updateWordRemoval);
    updateWordRemoval();

    auto openFrom = [&](QListWidgetItem *item, const QVector<SavedWord> &words) {
        if (!item || !(item->flags() & Qt::ItemIsEnabled)) return;
        const QString key = item->data(Qt::UserRole).toString();
        const auto it = std::find_if(words.cbegin(), words.cend(), [&](const SavedWord &word) { return word.key == key; });
        if (it != words.cend()) { dialog.accept(); openSavedWord(*it); }
    };
    connect(historyList, &QListWidget::itemActivated, &dialog, [&](QListWidgetItem *item) { openFrom(item, learning_.history()); });
    connect(bookmarkList, &QListWidget::itemActivated, &dialog, [&](QListWidgetItem *item) { openFrom(item, learning_.bookmarks()); });
    connect(clearHistory, &QPushButton::clicked, &dialog, [&] {
        if (QMessageBox::question(&dialog, QStringLiteral("Clear history?"), QStringLiteral("Remove all viewed words from history? Saved words and learning scores will stay."), QMessageBox::Yes | QMessageBox::No, QMessageBox::No) != QMessageBox::Yes) return;
        learning_.clearHistory(); historyList->clear();
        clearHistory->setEnabled(false);
        auto *item = new QListWidgetItem(QStringLiteral("No history yet."), historyList); item->setFlags(Qt::NoItemFlags);
    });
    connect(removeHistory, &QPushButton::clicked, &dialog, [&] {
        auto *item = selectedWordItem(historyList);
        if (!item) return;
        learning_.removeHistory(item->data(Qt::UserRole).toString());
        delete item;
        restoreEmptyWordList(historyList, QStringLiteral("No history yet."));
        updateWordRemoval();
        clearHistory->setEnabled(!learning_.history().isEmpty());
    });
    connect(removeBookmark, &QPushButton::clicked, &dialog, [&] {
        auto *item = selectedWordItem(bookmarkList); if (!item) return;
        learning_.removeBookmark(item->data(Qt::UserRole).toString()); delete item;
        restoreEmptyWordList(bookmarkList, QStringLiteral("No bookmarks yet."));
        updateWordRemoval();
        if (currentEntry_.isEmpty()) return;
        bookmark_->setText(learning_.isBookmarked(savedWord(currentEntry_).key) ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
    });
    QVector<SavedWord> pool = learningPool();
    auto shuffled = [](QVector<SavedWord> values) {
        for (qsizetype i = values.size() - 1; i > 0; --i) {
            const qsizetype j = QRandomGenerator::global()->bounded(static_cast<int>(i + 1));
            values.swapItemsAt(i, j);
        }
        return values;
    };

    auto *learnPage = new QWidget(tabs);
    auto *learnLayout = new QVBoxLayout(learnPage);
    auto *gamePicker = new QComboBox(learnPage);
    auto *poolStatus = new QLabel(learnPage);
    poolStatus->setWordWrap(true);
    gamePicker->addItems({QStringLiteral("Definition quiz"), QStringLiteral("Flashcards"), QStringLiteral("Unscramble")});
    auto *games = new QStackedWidget(learnPage);
    learnLayout->addWidget(gamePicker);
    learnLayout->addWidget(poolStatus);
    learnLayout->addWidget(games, 1);
    tabs->addTab(learnPage, QStringLiteral("Learn"));

    auto *quizPage = new QWidget(games);
    auto *quizLayout = new QVBoxLayout(quizPage);
    auto *quizScore = new QLabel(QStringLiteral("0 / 0"), quizPage);
    auto *quizClue = new QLabel(quizPage);
    quizClue->setTextFormat(Qt::PlainText);
    quizClue->setWordWrap(true);
    quizClue->setTextInteractionFlags(Qt::TextSelectableByMouse);
    quizLayout->addWidget(quizScore);
    quizLayout->addWidget(quizClue, 1);
    QVector<QPushButton *> quizButtons;
    for (int i = 0; i < 4; ++i) { auto *button = new QPushButton(quizPage); quizButtons.push_back(button); quizLayout->addWidget(button); }
    auto *quizNext = new QPushButton(QStringLiteral("Next"), quizPage);
    quizLayout->addWidget(quizNext);
    games->addWidget(quizPage);
    SavedWord quizAnswer;
    int quizRight = 0;
    int quizTotal = 0;
    auto populateQuiz = [&] {
        if (quizTotal >= learning_.settings().quizLength) { quizRight = 0; quizTotal = 0; }
        quizScore->setText(QStringLiteral("%1 / %2 · %3 questions").arg(quizRight).arg(quizTotal).arg(learning_.settings().quizLength));
        QSet<QString> distinctTitles;
        for (const SavedWord &word : pool) distinctTitles.insert(word.title);
        if (distinctTitles.size() < 2) {
            quizAnswer = {};
            quizClue->setText(QStringLiteral("Open or bookmark at least two different words first."));
            for (auto *button : quizButtons) button->hide();
            quizNext->setEnabled(false);
            return;
        }
        quizAnswer = pool.at(QRandomGenerator::global()->bounded(pool.size()));
        quizClue->setText(quizAnswer.clue);
        QVector<SavedWord> candidates;
        candidates.push_back(quizAnswer);
        QSet<QString> candidateTitles{quizAnswer.title};
        for (const SavedWord &word : shuffled(pool)) {
            if (candidateTitles.contains(word.title)) continue;
            candidateTitles.insert(word.title);
            candidates.push_back(word);
            if (candidates.size() == 4) break;
        }
        candidates = shuffled(candidates);
        for (int i = 0; i < quizButtons.size(); ++i) {
            auto *button = quizButtons[i];
            if (i >= candidates.size()) { button->hide(); continue; }
            button->show(); button->setEnabled(true); button->setText(QString(candidates[i].title).replace(QChar('&'), QStringLiteral("&&"))); button->setProperty("wordKey", candidates[i].key);
        }
        quizNext->setEnabled(false);
    };
    for (auto *button : quizButtons) connect(button, &QPushButton::clicked, &dialog, [&, button] {
        if (!button->isEnabled()) return;
        const bool correct = button->property("wordKey").toString() == quizAnswer.key;
        learning_.answer(quizAnswer.key, correct);
        ++quizTotal; if (correct) ++quizRight;
        quizScore->setText(QStringLiteral("%1 / %2 · %3 questions").arg(quizRight).arg(quizTotal).arg(learning_.settings().quizLength));
        for (auto *candidate : quizButtons) {
            candidate->setEnabled(false);
            if (candidate->property("wordKey").toString() == quizAnswer.key) candidate->setText(candidate->text() + QStringLiteral(" ✓"));
        }
        if (!correct) button->setText(button->text() + QStringLiteral(" ✗"));
        quizNext->setText(quizTotal >= learning_.settings().quizLength ? QStringLiteral("New round") : QStringLiteral("Next"));
        quizNext->setEnabled(true);
    });
    connect(quizNext, &QPushButton::clicked, &dialog, populateQuiz);
    populateQuiz();
    auto *cardPage = new QWidget(games);
    auto *cardLayout = new QVBoxLayout(cardPage);
    auto *cardTitle = new QLabel(cardPage);
    cardTitle->setTextFormat(Qt::PlainText);
    cardTitle->setWordWrap(true);
    QFont cardFont = cardTitle->font(); cardFont.setPointSize(26); cardFont.setBold(true); cardTitle->setFont(cardFont);
    auto *cardClue = new QLabel(QStringLiteral("Recall the definition, then reveal it."), cardPage);
    cardClue->setTextFormat(Qt::PlainText);
    cardClue->setWordWrap(true);
    auto *revealCard = new QPushButton(QStringLiteral("Reveal"), cardPage);
    auto *readCard = new QPushButton(QStringLiteral("Read entry"), cardPage);
    auto *cardGrades = new QWidget(cardPage);
    auto *gradeLayout = new QHBoxLayout(cardGrades); gradeLayout->setContentsMargins(0, 0, 0, 0);
    auto *again = new QPushButton(QStringLiteral("Again"), cardGrades);
    auto *gotIt = new QPushButton(QStringLiteral("Got it"), cardGrades);
    gradeLayout->addWidget(again); gradeLayout->addWidget(gotIt);
    cardLayout->addWidget(cardTitle);
    cardLayout->addWidget(cardClue, 1);
    cardLayout->addWidget(revealCard);
    cardLayout->addWidget(cardGrades);
    cardLayout->addWidget(readCard);
    games->addWidget(cardPage);

    SavedWord card;
    auto nextCard = [&] {
        if (pool.isEmpty()) { card = {}; cardTitle->setText(QStringLiteral("No words yet")); cardClue->setText(QStringLiteral("Open or bookmark words first.")); revealCard->setEnabled(false); readCard->setEnabled(false); cardGrades->hide(); return; }
        card = pool.at(QRandomGenerator::global()->bounded(pool.size()));
        cardTitle->setText(card.title);
        cardClue->setText(QStringLiteral("Recall the definition, then reveal it."));
        revealCard->setEnabled(true); revealCard->show(); cardGrades->hide();
        readCard->setEnabled(true);
    };
    connect(revealCard, &QPushButton::clicked, &dialog, [&] { cardClue->setText(card.clue); revealCard->hide(); cardGrades->show(); });
    connect(again, &QPushButton::clicked, &dialog, [&] { learning_.answer(card.key, false); nextCard(); });
    connect(gotIt, &QPushButton::clicked, &dialog, [&] { learning_.answer(card.key, true); nextCard(); });
    connect(readCard, &QPushButton::clicked, &dialog, [&] { if (!card.key.isEmpty()) { dialog.accept(); openSavedWord(card); } });
    nextCard();
    auto *scramblePage = new QWidget(games);
    auto *scrambleLayout = new QVBoxLayout(scramblePage);
    auto *scrambled = new QLabel(scramblePage);
    scrambled->setTextFormat(Qt::PlainText);
    scrambled->setWordWrap(true);
    QFont scrambleFont = scrambled->font(); scrambleFont.setPointSize(24); scrambleFont.setBold(true); scrambled->setFont(scrambleFont);
    auto *scrambleClue = new QLabel(scramblePage); scrambleClue->setWordWrap(true);
    scrambleClue->setTextFormat(Qt::PlainText);
    auto *scrambleInput = new QLineEdit(scramblePage); scrambleInput->setPlaceholderText(QStringLiteral("Type the word"));
    scrambleInput->setAccessibleName(QStringLiteral("Unscramble answer"));
    auto *scrambleResult = new QLabel(scramblePage);
    scrambleResult->setTextFormat(Qt::PlainText);
    auto *scrambleCheck = new QPushButton(QStringLiteral("Check"), scramblePage);
    auto *scrambleNext = new QPushButton(QStringLiteral("Next"), scramblePage); scrambleNext->hide();
    scrambleLayout->addWidget(scrambled);
    scrambleLayout->addWidget(scrambleClue, 1);
    scrambleLayout->addWidget(scrambleInput);
    scrambleLayout->addWidget(scrambleResult);
    scrambleLayout->addWidget(scrambleCheck);
    scrambleLayout->addWidget(scrambleNext);
    games->addWidget(scramblePage);

    SavedWord scrambleWord;
    bool scrambleAnswered = false;
    auto nextScramble = [&] {
        QVector<SavedWord> words;
        for (const SavedWord &word : pool) if (word.title.size() > 2) words.push_back(word);
        if (words.isEmpty()) {
            scrambleWord = {};
            scrambleAnswered = false;
            scrambled->setText(QStringLiteral("No longer words yet"));
            scrambleClue->setText(QStringLiteral("Open or save a word with at least three letters."));
            scrambleInput->clear();
            scrambleInput->setEnabled(false);
            scrambleResult->clear();
            scrambleCheck->setEnabled(false);
            scrambleCheck->show();
            scrambleNext->hide();
            return;
        }
        scrambleWord = words.at(QRandomGenerator::global()->bounded(words.size()));
        QStringList characters;
        QTextBoundaryFinder boundaries(QTextBoundaryFinder::Grapheme, scrambleWord.title);
        int start = 0;
        for (int end = boundaries.toNextBoundary(); end >= 0; end = boundaries.toNextBoundary()) {
            characters.append(scrambleWord.title.mid(start, end - start));
            start = end;
        }
        for (qsizetype i = characters.size() - 1; i > 0; --i) characters.swapItemsAt(i, QRandomGenerator::global()->bounded(static_cast<int>(i + 1)));
        QString letters = characters.join(QString());
        if (letters == scrambleWord.title && characters.size() > 1) {
            std::rotate(characters.begin(), characters.begin() + 1, characters.end());
            letters = characters.join(QString());
        }
        scrambleAnswered = false;
        scrambleInput->setEnabled(true);
        scrambled->setText(letters); scrambleClue->setText(scrambleWord.clue); scrambleInput->clear(); scrambleResult->clear();
        scrambleCheck->show(); scrambleCheck->setEnabled(true); scrambleNext->hide();
    };
    auto checkScramble = [&] {
        if (scrambleWord.key.isEmpty() || scrambleAnswered) return;
        scrambleAnswered = true;
        const bool correct = scrambleInput->text().trimmed().compare(scrambleWord.title, Qt::CaseInsensitive) == 0;
        learning_.answer(scrambleWord.key, correct);
        scrambleResult->setText(correct ? QStringLiteral("Correct.") : QStringLiteral("Answer: %1").arg(scrambleWord.title));
        scrambleCheck->hide(); scrambleNext->show();
    };
    connect(scrambleCheck, &QPushButton::clicked, &dialog, checkScramble);
    connect(scrambleInput, &QLineEdit::returnPressed, &dialog, checkScramble);
    connect(scrambleNext, &QPushButton::clicked, &dialog, nextScramble);
    nextScramble();

    connect(gamePicker, &QComboBox::currentIndexChanged, games, &QStackedWidget::setCurrentIndex);

    auto *settingsPage = new QWidget(tabs);
    auto *form = new QFormLayout(settingsPage);
    auto *rememberHistory = new QCheckBox(settingsPage); rememberHistory->setChecked(learning_.settings().historyEnabled);
    auto *historyLimit = new QSpinBox(settingsPage); historyLimit->setRange(1, 500); historyLimit->setValue(learning_.settings().historyLimit);
    auto *quizLength = new QSpinBox(settingsPage); quizLength->setRange(3, 50); quizLength->setValue(learning_.settings().quizLength);
    auto *randomPool = new QComboBox(settingsPage);
    randomPool->addItem(QStringLiteral("All dictionary words"), QStringLiteral("all"));
    randomPool->addItem(QStringLiteral("History"), QStringLiteral("history"));
    randomPool->addItem(QStringLiteral("Bookmarks"), QStringLiteral("bookmarks"));
    randomPool->setCurrentIndex(std::max(0, randomPool->findData(learning_.settings().randomPool)));
    auto *theme = new QComboBox(settingsPage);
    theme->addItem(QStringLiteral("System"), QStringLiteral("system")); theme->addItem(QStringLiteral("Light"), QStringLiteral("light")); theme->addItem(QStringLiteral("Dark"), QStringLiteral("dark"));
    theme->setCurrentIndex(std::max(0, theme->findData(learning_.settings().theme)));
    auto *collapsePronunciation = new QCheckBox(settingsPage);
    collapsePronunciation->setChecked(learning_.settings().collapsePronunciation);
    auto *collapseEtymology = new QCheckBox(settingsPage);
    collapseEtymology->setChecked(learning_.settings().collapseEtymology);
    auto *resetStudy = new QPushButton(QStringLiteral("Reset learning scores"), settingsPage);
    auto *mediaSettings = new QPushButton(QStringLiteral("Media and speech preferences"), settingsPage);
    form->addRow(QStringLiteral("Remember viewed words"), rememberHistory);
    form->addRow(QStringLiteral("History limit"), historyLimit);
    form->addRow(QStringLiteral("Quiz length"), quizLength);
    form->addRow(QStringLiteral("Random word source"), randomPool);
    form->addRow(QStringLiteral("Theme"), theme);
    form->addRow(QStringLiteral("Fold pronunciation by default"), collapsePronunciation);
    form->addRow(QStringLiteral("Fold etymology by default"), collapseEtymology);
    form->addRow(mediaSettings);
    form->addRow(resetStudy);
    tabs->addTab(settingsPage, QStringLiteral("Settings"));

    connect(rememberHistory, &QCheckBox::toggled, &dialog, [this](bool value) { learning_.setHistoryEnabled(value); });
    connect(historyLimit, &QSpinBox::valueChanged, &dialog, [this](int value) { learning_.setHistoryLimit(value); });
    connect(quizLength, &QSpinBox::valueChanged, &dialog, [this](int value) { learning_.setQuizLength(value); });
    auto refreshPractice = [&] {
        pool = learningPool();
        poolStatus->setText((pool.size() == 1 ? QStringLiteral("%1 word ready · %2") : QStringLiteral("%1 words ready · %2")).arg(pool.size()).arg(randomPool->currentText()));
        quizRight = 0;
        quizTotal = 0;
        populateQuiz();
        nextCard();
        nextScramble();
    };
    connect(randomPool, &QComboBox::currentIndexChanged, &dialog, [&, randomPool](int) {
        learning_.setRandomPool(randomPool->currentData().toString());
        refreshPractice();
    });
    connect(tabs, &QTabWidget::currentChanged, &dialog, [&](int index) { if (index == 2) refreshPractice(); });
    connect(collapsePronunciation, &QCheckBox::toggled, &dialog, [this](bool value) { learning_.setCollapsePronunciation(value); resetFolding(); });
    connect(collapseEtymology, &QCheckBox::toggled, &dialog, [this](bool value) { learning_.setCollapseEtymology(value); resetFolding(); });
    connect(mediaSettings, &QPushButton::clicked, &dialog, [&] { dialog.accept(); entryTabs_->setCurrentWidget(media_); });
    connect(theme, &QComboBox::currentIndexChanged, &dialog, [&, theme](int) { learning_.setTheme(theme->currentData().toString()); applyTheme(); });
    connect(resetStudy, &QPushButton::clicked, &dialog, [&] {
        if (QMessageBox::question(&dialog, QStringLiteral("Reset learning scores?"), QStringLiteral("Remove all correct and incorrect answer counts?"), QMessageBox::Yes | QMessageBox::No, QMessageBox::No) == QMessageBox::Yes) learning_.clearStudy();
    });

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, &dialog);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    layout->addWidget(buttons);
    refreshPractice();
    tabs->setCurrentIndex(std::clamp(tab, 0, tabs->count() - 1));
    dialog.exec();
}

void MainWindow::applyTheme() {
    const QString theme = learning_.settings().theme;
    bool dark = theme == QStringLiteral("dark");
    if (theme == QStringLiteral("system")) dark = qApp->styleHints()->colorScheme() == Qt::ColorScheme::Dark;
    QPalette palette = qApp->style()->standardPalette();
    const QColor paper = dark ? QColor(QStringLiteral("#171C19")) : QColor(QStringLiteral("#F4F0E7"));
    const QColor ink = dark ? QColor(QStringLiteral("#E9E7DD")) : QColor(QStringLiteral("#18221E"));
    const QColor surface = dark ? QColor(QStringLiteral("#222B25")) : QColor(QStringLiteral("#FFFCF5"));
    const QColor accent = dark ? QColor(QStringLiteral("#E5B58C")) : QColor(QStringLiteral("#855332"));
    palette.setColor(QPalette::Window, paper);
    palette.setColor(QPalette::WindowText, ink);
    palette.setColor(QPalette::Base, surface);
    palette.setColor(QPalette::AlternateBase, paper);
    palette.setColor(QPalette::Text, ink);
    palette.setColor(QPalette::Button, paper);
    palette.setColor(QPalette::ButtonText, ink);
    palette.setColor(QPalette::Link, accent);
    palette.setColor(QPalette::Highlight, accent);
    palette.setColor(QPalette::HighlightedText, dark ? QColor(QStringLiteral("#18221E")) : Qt::white);
    palette.setColor(QPalette::ToolTipBase, surface);
    palette.setColor(QPalette::ToolTipText, ink);
    palette.setColor(QPalette::Mid, dark ? QColor(QStringLiteral("#566057")) : QColor(QStringLiteral("#ABA99F")));
    palette.setColor(QPalette::Disabled, QPalette::Text, dark ? QColor(QStringLiteral("#929A91")) : QColor(QStringLiteral("#6D756D")));
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, palette.color(QPalette::Disabled, QPalette::Text));
    qApp->setPalette(palette);
    setPalette(palette);
    refreshReading();
}

void MainWindow::reportError(const QString &title, const std::exception &error) {
    QMessageBox::warning(this, title, QString::fromUtf8(error.what()));
}
