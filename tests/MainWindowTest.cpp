#include "MainWindow.hpp"
#include "LibraryStore.hpp"
#include "LibraryDialog.hpp"

#include <QAbstractTextDocumentLayout>
#include <QAccessible>
#include <QApplication>
#include <QAction>
#include <QComboBox>
#include <QDialog>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QFontMetricsF>
#include <QGridLayout>
#include <QGlyphRun>
#include <QPainterPath>
#include <QImage>
#include <QItemSelectionModel>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QMenu>
#include <QStatusBar>
#include <QPalette>
#include <QPointer>
#include <QProgressBar>
#include <QPushButton>
#include <QScopeGuard>
#include <QSignalSpy>
#include <QScrollArea>
#include <QScrollBar>
#include <QSet>
#include <QSettings>
#include <QSemaphore>
#include <QThreadPool>
#include <QTreeWidget>
#include <QtConcurrent/QtConcurrentRun>
#include <QStackedWidget>
#include <QStringList>
#include <QTabBar>
#include <QTabWidget>
#include <QTemporaryDir>
#include <QTextBlock>
#include <QTextBrowser>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextFragment>
#include <QTextLayout>
#include <QTextTable>
#include <QTimer>
#include <QUrl>
#include <QtTest>
#include <algorithm>
#include <array>

class ExternalUrlReceiver final : public QObject {
    Q_OBJECT
public:
    QList<QUrl> opened;
public slots:
    void capture(const QUrl &url) { opened.append(url); }
};

class MainWindowTest final : public QObject {
    Q_OBJECT

private:
    QString fixture_;
    std::unique_ptr<QTemporaryDir> fixtureDirectory_;

    static QString title(const MainWindow &window) {
        return window.currentEntry_.value(QStringLiteral("title")).toString();
    }

    static bool clickAnchor(QTextBrowser *browser, const QString &href) {
        for (QTextBlock block = browser->document()->begin(); block.isValid(); block = block.next()) {
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (!fragment.isValid() || fragment.charFormat().anchorHref() != href) continue;
                QTextCursor cursor(browser->document());
                cursor.setPosition(fragment.position());
                browser->setTextCursor(cursor);
                browser->ensureCursorVisible();
                for (const int offset : {2, -2}) {
                    const QPoint point = browser->cursorRect(cursor).center() + QPoint(offset, 0);
                    if (browser->anchorAt(point) != href) continue;
                    QTest::mouseClick(browser->viewport(), Qt::LeftButton, Qt::NoModifier, point);
                    return true;
                }
            }
        }
        return false;
    }

    static bool hasAnchor(const QTextDocument *document, const QString &name) {
        for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
            if (block.charFormat().anchorNames().contains(name)) return true;
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QTextFragment fragment = it.fragment();
                if (fragment.isValid() && fragment.charFormat().anchorNames().contains(name)) return true;
            }
        }
        return false;
    }

    static bool textIsVisible(QTextBrowser *browser, const QString &text) {
        const QTextCursor cursor = browser->document()->find(text);
        if (cursor.isNull()) return false;
        const QRect rect = browser->cursorRect(cursor);
        return rect.bottom() >= 0 && rect.top() < browser->viewport()->height();
    }

    static bool hasLabel(QWidget *parent, const QString &text) {
        for (auto *label : parent->findChildren<QLabel *>()) if (label->text() == text) return true;
        return false;
    }

    static QPushButton *buttonWithText(QWidget *parent, const QString &text) {
        for (auto *button : parent->findChildren<QPushButton *>()) if (button->text() == text) return button;
        return nullptr;
    }

    static bool prepareCaseTitleFixture(const QString &fixtureRoot, const QString &directory, QStringList titles,
                                        const QByteArray &code = QByteArrayLiteral("en"),
                                        const QByteArray &heading = QByteArrayLiteral("English"), bool distinctBody = false) {
        QFile fixture(fixtureRoot + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        if (!fixture.open(QIODevice::ReadOnly)) return false;
        const QByteArray original = fixture.readAll();
        qsizetype at = 9;
        for (int i = 0; i < 3; ++i) {
            at = original.indexOf('\0', at) + 1;
            if (at <= 0) return false;
        }
        const qsizetype lengthStart = at;
        quint64 length = 0;
        for (int shift = 0; ; shift += 7) {
            if (at >= original.size() || shift >= 64) return false;
            const auto byte = static_cast<unsigned char>(original[at++]);
            length |= quint64(byte & 127) << shift;
            if (!(byte & 128)) break;
        }
        if (length > quint64(original.size() - at)) return false;
        QByteArray record = original.mid(lengthStart, at - lengthStart + qsizetype(length));
        if (distinctBody) {
            // Equal-length fixture text keeps the existing compiled record framing intact.
            if (record.count("A small animal.") != 1) return false;
            record.replace("A small animal.", "A river animal.");
        }
        std::sort(titles.begin(), titles.end(), [](const QString &left, const QString &right) {
            return left.toUtf8() < right.toUtf8();
        });
        QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) + code + '\0' + heading + '\0';
        for (const QString &word : titles) bytes += word.toUtf8() + '\0' + record;
        const QString source = directory + QStringLiteral("/source.wikblb");
        QFile file(source);
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size()) return false;
        file.close();
        std::atomic_bool cancelled = false;
        const QString root = directory + QStringLiteral("/library");
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        return true;
    }

private slots:
    void sectionHeadingLayoutWhitespaceDoesNotCreateEmptyReadingBlocks() {
        MainWindow window(QString{});
        const auto text = [](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        QJsonObject linked = text(QStringLiteral("Heading"));
        linked.insert(QStringLiteral("kind"), QStringLiteral("link"));
        linked.insert(QStringLiteral("target"), QStringLiteral("Lexical heading target"));
        const QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")}, {QStringLiteral("text"), QStringLiteral("\n")}};
        const auto paragraph = [](const QJsonArray &spans) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("depth"), 0}, {QStringLiteral("spans"), spans}}; };
        const auto fixture = [&](bool layoutWhitespace) {
            QJsonArray heading{linked};
            if (layoutWhitespace) heading.append(br);
            QJsonArray blocks{QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 2}, {QStringLiteral("spans"), heading}}};
            if (layoutWhitespace) blocks.append(paragraph(QJsonArray{text(QStringLiteral(" "))}));
            blocks.append(paragraph(QJsonArray{text(QStringLiteral("Actual lexical body"))}));
            return QJsonObject{{QStringLiteral("title"), QStringLiteral("Fixture")}, {QStringLiteral("kind"), QStringLiteral("language")},
                {QStringLiteral("language"), QStringLiteral("English")}, {QStringLiteral("sections"), QJsonArray{QJsonObject{
                    {QStringLiteral("level"), 2}, {QStringLiteral("title"), QStringLiteral("Heading")}, {QStringLiteral("blocks"), blocks}}}}};
        };
        const QJsonObject entry = fixture(true), original = entry;
        const QString html = window.entryHtml(entry), control = window.entryHtml(fixture(false));
        QCOMPARE(html, control); // Same lexical content must not gain two layout-only blocks.
        QTextDocument actualDocument, controlDocument;
        actualDocument.setHtml(html); controlDocument.setHtml(control);
        QCOMPARE(actualDocument.blockCount(), controlDocument.blockCount());
        QCOMPARE(actualDocument.toPlainText(), controlDocument.toPlainText());
        QCOMPARE(actualDocument.find(QStringLiteral("Heading")).charFormat().anchorHref(), QStringLiteral("dict:Lexical%20heading%20target"));
        QVERIFY(actualDocument.toPlainText().contains(QStringLiteral("Actual lexical body")));
        QCOMPARE(entry, original);

        QJsonObject second = linked; second.insert(QStringLiteral("text"), QStringLiteral("Second"));
        QJsonObject section{{QStringLiteral("level"), 2}, {QStringLiteral("title"), QStringLiteral("Heading\nSecond")},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")},
                {QStringLiteral("level"), 2}, {QStringLiteral("spans"), QJsonArray{linked, br, second, br}}}}}};
        QJsonObject multiline = fixture(false); multiline.insert(QStringLiteral("sections"), QJsonArray{section});
        const QString multilineHtml = window.entryHtml(multiline);
        QCOMPARE(multilineHtml.count(QStringLiteral("<br>")), 1); // Internal authored line break survives.
        QJsonObject pre{{QStringLiteral("kind"), QStringLiteral("preformatted")}, {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("  "))}}};
        QVERIFY(window.blockHtml(pre).contains(QStringLiteral("<pre>  </pre>")));
        QJsonObject codeSpace = text(QStringLiteral(" ")); codeSpace.insert(QStringLiteral("code"), true);
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{codeSpace})).isEmpty());
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{text(QString(QChar(0x00a0)))})).isEmpty());
        QJsonObject bidiSpace = text(QStringLiteral(" ")); bidiSpace.insert(QStringLiteral("direction"), QStringLiteral("rtl"));
        QVERIFY(!window.blockHtml(paragraph(QJsonArray{bidiSpace})).isEmpty());
        for (const QString &key : {QStringLiteral("list_path"), QStringLiteral("number"), QStringLiteral("level")}) {
            QJsonObject metadata = paragraph(QJsonArray{text(QStringLiteral(" "))});
            metadata.insert(key, key == QStringLiteral("level") ? QJsonValue(3) : QJsonValue(QStringLiteral("retained")));
            QVERIFY2(!window.blockHtml(metadata).isEmpty(), qPrintable(key));
        }
    }

    void initTestCase() {
        QString source = qEnvironmentVariable("DICT_TEST_ROOT");
        if (source.isEmpty()) source = QFINDTESTDATA("fixtures");
        source = QDir(source).absolutePath();
        QVERIFY2(QFileInfo::exists(source + QStringLiteral("/languages.tsv")), qPrintable(source));
        fixtureDirectory_ = std::make_unique<QTemporaryDir>(QStringLiteral(".tmp/ui-fixtures-XXXXXX"));
        QVERIFY(fixtureDirectory_->isValid());
        fixture_ = QDir(fixtureDirectory_->path()).absolutePath();
        QDirIterator files(source, QDir::Files, QDirIterator::Subdirectories);
        while (files.hasNext()) {
            const QString path = files.next();
            const QString destination = fixture_ + QChar('/') + QDir(source).relativeFilePath(path);
            QVERIFY(QDir().mkpath(QFileInfo(destination).path()));
            QVERIFY2(QFile::copy(path, destination), qPrintable(path));
        }
    }

    void init() {
        QSettings settings;
        settings.clear();
        settings.sync();
        QSettings learning(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
        learning.clear();
        learning.sync();
    }

    void emptyLibraryGuidanceDoesNotExposeInternalErrors() {
        QTemporaryDir empty(QDir::currentPath() + QStringLiteral("/.tmp/empty-library-XXXXXX"));
        QVERIFY(empty.isValid());
        MainWindow window(empty.path());
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QCOMPARE(window.title_->toPlainText(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), QStringLiteral("No dictionary open"));
        const QString guidance = window.reading_->toPlainText();
        QVERIFY(guidance.contains(QStringLiteral("No dictionaries are installed yet.")));
        QVERIFY(!guidance.contains(QStringLiteral("Could not open")));
        QVERIFY(!guidance.contains(QStringLiteral("select:")));
        QVERIFY(!guidance.contains(QStringLiteral("FileNotFound")));
        QVERIFY(!window.search_->isEnabled());
        QVERIFY(!window.results_->isEnabled());
        QVERIFY(!window.kind_->isEnabled());
        QVERIFY(!window.language_->isEnabled());
        auto *library = window.findChild<QPushButton *>(QStringLiteral("openDictionaries"));
        QVERIFY(library && library->isEnabled());
        // Empty-library guidance must not conceal damaged or unrecognized roots.
        for (const QString &problem : {QStringLiteral("missing"), QStringLiteral("unrecognized"),
                QStringLiteral("manifest"), QStringLiteral("missing-language"), QStringLiteral("unfinished"),
                QStringLiteral("raw"), QStringLiteral("compressed"), QStringLiteral("orphan"),
                QStringLiteral("edition"), QStringLiteral("dangling-languages")}) {
            QTemporaryDir rejected(QDir::currentPath() + QStringLiteral("/.tmp/rejected-initial-root-XXXXXX"));
            QVERIFY(rejected.isValid());
            QString path = rejected.path();
            const auto write = [&](const QString &name, const QByteArray &bytes) {
                QFile file(path + QChar('/') + name);
                return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
            };
            if (problem == QStringLiteral("missing")) path += QStringLiteral("/missing");
            else if (problem == QStringLiteral("unrecognized")) {
                QVERIFY(write(QStringLiteral("notes.txt"), QByteArrayLiteral("unrecognized folder")));
            } else {
                QVERIFY(write(QStringLiteral("languages.tsv"), problem == QStringLiteral("manifest")
                    ? QByteArrayLiteral("invalid manifest\n") : problem == QStringLiteral("missing-language")
                    ? QByteArrayLiteral("heading\nEnglish\n") : QByteArrayLiteral("heading\n")));
                if (problem == QStringLiteral("unfinished")) QVERIFY(write(QStringLiteral(".incomplete"), {}));
                if (problem == QStringLiteral("raw")) QVERIFY(write(QStringLiteral("supplemental.wikblb"), QByteArrayLiteral("broken")));
                if (problem == QStringLiteral("compressed")) QVERIFY(write(QStringLiteral("supplemental.wikblb.xz"), QByteArrayLiteral("broken")));
                if (problem == QStringLiteral("orphan")) {
                    QVERIFY(QDir(path).mkpath(QStringLiteral("languages")));
                    QVERIFY(write(QStringLiteral("languages/orphan.wikblb"), QByteArrayLiteral("broken")));
                }
                if (problem == QStringLiteral("dangling-languages")) {
                    const QString target = path + QStringLiteral("/removed-languages");
                    QVERIFY(QDir().mkdir(target));
                    QVERIFY(QFile::link(target, path + QStringLiteral("/languages")));
                    QVERIFY(QDir().rmdir(target));
                    QVERIFY(QFileInfo(path + QStringLiteral("/languages")).isSymLink());
                    QVERIFY(!QFileInfo::exists(path + QStringLiteral("/languages")));
                }
                if (problem == QStringLiteral("edition")) QVERIFY(write(QStringLiteral(".desktop-edition"), QByteArrayLiteral("invalid edition")));
            }
            MainWindow failed(path);
            failed.show();
            QTRY_VERIFY_WITH_TIMEOUT(!failed.loading_, 30000);
            QVERIFY(!failed.api_);
            QVERIFY(failed.reading_->toPlainText().contains(QStringLiteral("Could not open this dictionary.")));
            QVERIFY(!failed.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
        }
        // Synthetic empty-library state, captured before ordinary recovery.
        window.resize(780, 480);
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-empty.png")));
        window.openRoot(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(window.results_->isEnabled());
    }

    void narrowReaderKeepsNavigationAndHeadingVisible() {
        MainWindow window{QString()};
        window.title_->setHtml(QStringLiteral("acupuncture"));
        window.resize(480, 540);
        window.show();
        QTRY_VERIFY(window.compactReader_);
        QCOMPARE(window.width(), 480);
        const QRect bounds = window.readerContent_->rect();
        for (auto *widget : std::array<QWidget *, 7>{window.back_, window.forward_, window.sections_, window.smaller_, window.larger_, window.listen_, window.bookmark_}) {
            QVERIFY(widget->isVisible());
            QVERIFY(bounds.contains(QRect(widget->mapTo(window.readerContent_, QPoint()), widget->size())));
            QVERIFY(widget->width() >= widget->minimumSizeHint().width());
        }
        QVERIFY(window.title_->width() >= window.title_->fontMetrics().horizontalAdvance(QStringLiteral("acupuncture")));
        QVERIFY(window.readerHeading_->geometry().bottom() < window.listen_->geometry().top());
        QVERIFY(window.sections_->geometry().top() > window.back_->geometry().bottom());
        auto *back = window.back_;
        auto *sections = window.sections_;
        window.resize(1180, 780);
        QTRY_VERIFY(!window.compactReader_);
        QCOMPARE(window.back_, back);
        QCOMPARE(window.sections_, sections);
        QTRY_VERIFY(window.back_->geometry().top() <= window.sections_->geometry().bottom());
        QTRY_VERIFY(window.sections_->geometry().top() <= window.back_->geometry().bottom());
    }

    void richLongTitleWrapsWithoutAddingKeyboardStop() {
        MainWindow window{QString()};
        const QString title = QStringLiteral("StyledHeadingWitnessStyledHeadingWitnessStyledHeadingWitness");
        window.title_->setHtml(QStringLiteral("<b><i title='title explanation'>%1</i></b>").arg(title));
        window.resize(900, 700);
        window.show();
        QTRY_COMPARE(window.title_->accessibleName(), title);
        QVERIFY(!(window.title_->focusPolicy() & Qt::TabFocus));
        QCOMPARE(window.title_->focusPolicy(), Qt::ClickFocus);
        QVERIFY(window.title_->textInteractionFlags().testFlag(Qt::TextSelectableByMouse));
        QVERIFY(!window.title_->openLinks());
        QVERIFY(!window.title_->openExternalLinks());
        for (const int width : {900, 640}) {
            window.resize(width, 700);
            QTRY_VERIFY(window.title_->document()->size().height() <= window.title_->viewport()->height() + 1);
            QVERIFY(window.title_->document()->idealWidth() <= window.title_->viewport()->width() + 1);
            const QTextCursor text = window.title_->document()->find(title);
            QVERIFY(!text.isNull());
            QVERIFY(text.charFormat().fontItalic());
            QVERIFY(text.charFormat().fontWeight() >= QFont::Bold);
            QCOMPARE(text.charFormat().toolTip(), QStringLiteral("title explanation"));
            window.title_->setTextCursor(text);
            QCOMPARE(window.title_->textCursor().selectedText(), title);
        }
    }

    void keyboardFoldRetainsItsActivationAnchor() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(false);
        window.resize(900, 700);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const auto selectedAnchor = [&] {
            QTextCursor selected = window.reading_->textCursor();
            if (!selected.hasSelection()) return QUrl();
            selected.setPosition(selected.selectionStart());
            selected.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            return QUrl(selected.charFormat().anchorHref());
        };
        window.search_->setFocus();
        QTRY_VERIFY(window.search_->hasFocus());
        window.reading_->setFocus(Qt::TabFocusReason);
        QTRY_VERIFY(window.reading_->hasFocus());
        int anchorFragments = 0;
        bool sectionAnchorPresent = false;
        for (auto block = window.reading_->document()->begin(); block.isValid(); block = block.next()) {
            for (auto it = block.begin(); !it.atEnd(); ++it) {
                const QString href = it.fragment().charFormat().anchorHref();
                if (href.isEmpty()) continue;
                ++anchorFragments;
                sectionAnchorPresent |= QUrl(href).scheme() == QStringLiteral("section");
            }
        }
        QVERIFY(sectionAnchorPresent);
        QVERIFY(window.collapsedSections_.isEmpty());
        QStringList traversed;
        for (int i = 0; i <= anchorFragments && selectedAnchor().scheme() != QStringLiteral("section"); ++i) {
            QTest::keyClick(window.reading_, Qt::Key_Tab);
            traversed.append(selectedAnchor().toString());
        }
        QVERIFY2(selectedAnchor().scheme() == QStringLiteral("section"), qPrintable(traversed.join(QStringLiteral(", "))));
        const QUrl anchor = selectedAnchor();
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_VERIFY(!window.collapsedSections_.isEmpty());
        const auto collapsed = window.collapsedSections_;
        QTRY_COMPARE(selectedAnchor(), anchor);
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_VERIFY(window.collapsedSections_.isEmpty());
        QTRY_COMPARE(selectedAnchor(), anchor);
        QTest::keyClick(window.reading_, Qt::Key_Return);
        QTRY_COMPARE(window.collapsedSections_, collapsed);
    }

    void narrowTablesKeepWordsAndScrollHorizontally() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString coptic = QString::fromUtf8("ϥⲱϭⲉ");
        QJsonArray rows;
        for (const QString &word : {QStringLiteral("present"), coptic}) {
            QJsonArray cells;
            for (int column = 0; column < 12; ++column)
                cells.append(QJsonObject{{QStringLiteral("spans"), QJsonArray{
                    QJsonObject{{QStringLiteral("text"), word}}}}});
            rows.append(QJsonObject{{QStringLiteral("cells"), cells}});
        }
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), rows}}, 0));
        QTextDocument *document = window.reading_->document();
        document->documentLayout()->documentSize();
        QTextTable *table = nullptr;
        for (QTextFrame *frame : document->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->columns(), 12);
        QCOMPARE(table->rows(), 2);
        for (int row = 0; row < 2; ++row) {
            for (int column = 0; column < 12; ++column) {
                const QTextBlock block = table->cellAt(row, column).firstCursorPosition().block();
                QCOMPARE(block.text(), row == 0 ? QStringLiteral("present") : coptic);
                QCOMPARE(block.layout()->lineCount(), 1);
            }
        }
        QTRY_VERIFY(window.reading_->horizontalScrollBar()->maximum() >
                    window.reading_->viewport()->width() / 4);
        // Ordinary prose still wraps at spaces instead of becoming one unbounded line.
        window.reading_->setHtml(QStringLiteral("<p>") + QStringLiteral("ordinary prose ").repeated(80) + QStringLiteral("</p>"));
        document->documentLayout()->documentSize();
        QVERIFY(document->begin().layout()->lineCount() > 1);
        QTRY_COMPARE(window.reading_->horizontalScrollBar()->maximum(), 0);
    }

    void recoveryAndFolderPersistence() {
        {
            MainWindow window{QString()};
            window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QVERIFY(!window.api_);
            QVERIFY(!window.search_->isEnabled());
            auto *openButton = window.findChild<QPushButton *>(QStringLiteral("openDictionaries"));
            QVERIFY(openButton && openButton->isEnabled());

            window.openRoot(fixture_ + QStringLiteral("/missing-folder"));
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QVERIFY(!window.api_);
            QVERIFY(openButton->isEnabled());

            window.openRoot(fixture_);
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QVERIFY(window.search_->isEnabled());
            QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), fixture_);
            window.openWord(QStringLiteral("cat"));
            QTRY_COMPARE(title(window), QStringLiteral("cat"));

            window.openRoot(fixture_ + QStringLiteral("/missing-folder"));
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QVERIFY(window.api_);
            QCOMPARE(window.api_->root(), fixture_);
            QCOMPARE(title(window), QStringLiteral("cat"));
            QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), fixture_);
        }
        MainWindow reopened{QString()};
        reopened.show();
        QTRY_VERIFY_WITH_TIMEOUT(!reopened.loading_ && reopened.api_, 30000);
        QCOMPARE(reopened.api_->root(), fixture_);
        QVERIFY(reopened.search_->isEnabled());
        QTRY_COMPARE(title(reopened), QStringLiteral("cat"));
    }

    void protocolRelativeExternalLinksOpenWithHttps() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QString target = QStringLiteral("//en.wiktionary.org/w/index.php?title=%D9%82%D8%A7%D9%84%D8%A8:%D8%AD_%D8%B1_%D8%B1&action=edit");
        const QString resolved = QStringLiteral("https:") + target;
        const auto span = [](const QString &kind, const QString &url) {
            return QJsonArray{QJsonObject{{QStringLiteral("kind"), kind},
                {QStringLiteral("target"), url}, {QStringLiteral("text"), QStringLiteral("ت")}}};
        };
        window.reading_->setHtml(window.spansHtml(span(QStringLiteral("external_link"), target)));
        QCOMPARE(window.reading_->toPlainText(), QStringLiteral("ت"));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("ت")).charFormat().anchorHref(), resolved);
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QVERIFY(clickAnchor(window.reading_, resolved));
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(resolved)});

        for (const QString &url : {QStringLiteral("http://example.org/path?q=1&v=2"),
                                  QStringLiteral("https://example.org/path#fragment"),
                                  QStringLiteral("https://example.org/?q='\"<b>word</b>&next=1"),
                                  QStringLiteral("https://example.org/?q=&quot;&next=1"),
                                  QStringLiteral("https://例え.テスト/辞書?q=字&n=1")}) {
            QTextDocument document;
            document.setHtml(window.spansHtml(span(QStringLiteral("external_link"), url)));
            QCOMPARE(document.toPlainText(), QStringLiteral("ت"));
            QCOMPARE(QUrl(document.find(QStringLiteral("ت")).charFormat().anchorHref()), QUrl(url));
        }
        for (const QString &url : {QStringLiteral("//"), QStringLiteral("///path"),
                                  QStringLiteral("//[invalid/path"), QStringLiteral("https:///path"),
                                  QStringLiteral("javascript:alert(1)"), QStringLiteral("file:///local")}) {
            QTextDocument document;
            document.setHtml(window.spansHtml(span(QStringLiteral("external_link"), url)));
            QCOMPARE(document.toPlainText(), QStringLiteral("ت"));
            QVERIFY(document.find(QStringLiteral("ت")).charFormat().anchorHref().isEmpty());
        }
        QTextDocument literal;
        literal.setHtml(window.spansHtml(span(QStringLiteral("text"), target)));
        QVERIFY(literal.find(QStringLiteral("ت")).charFormat().anchorHref().isEmpty());
    }

    void typedDirectionsIsolateLinkedTextAndTrail_data() {
        QTest::addColumn<QString>("direction");
        QTest::addColumn<QString>("parentDirection");
        QTest::addColumn<QString>("label");
        QTest::addColumn<QString>("trail");
        QTest::addColumn<QString>("tokenA");
        QTest::addColumn<QString>("tokenB");
        QTest::addColumn<ushort>("isolate");
        QTest::addColumn<bool>("aBeforeB");
        QTest::newRow("auto-arabic-in-ltr") << QStringLiteral("auto") << QStringLiteral("ltr") << QString::fromUtf8("العربية") << QStringLiteral(" XYZ") << QString::fromUtf8("العربية") << QStringLiteral("XYZ") << ushort(0x2068) << false;
        QTest::newRow("auto-hebrew-in-ltr") << QStringLiteral("auto") << QStringLiteral("ltr") << QString::fromUtf8("אבג") << QStringLiteral(" abc") << QString::fromUtf8("אבג") << QStringLiteral("abc") << ushort(0x2068) << false;
        QTest::newRow("rtl-arabic-in-ltr") << QStringLiteral("rtl") << QStringLiteral("ltr") << QString::fromUtf8("العربية") << QStringLiteral(" XYZ") << QString::fromUtf8("العربية") << QStringLiteral("XYZ") << ushort(0x2067) << false;
        QTest::newRow("ltr-english-in-rtl") << QStringLiteral("ltr") << QStringLiteral("rtl") << QStringLiteral("English") << QString::fromUtf8(" אבג") << QStringLiteral("English") << QString::fromUtf8("אבג") << ushort(0x2066) << true;
        QTest::newRow("auto-english-in-rtl") << QStringLiteral("auto") << QStringLiteral("rtl") << QStringLiteral("English") << QStringLiteral(" XYZ") << QStringLiteral("English") << QStringLiteral("XYZ") << ushort(0x2068) << true;
        QTest::newRow("auto-neutral-in-ltr") << QStringLiteral("auto") << QStringLiteral("ltr") << QStringLiteral("123") << QStringLiteral(" 456") << QStringLiteral("123") << QStringLiteral("456") << ushort(0x2068) << true;
        QTest::newRow("unknown-preserves-inheritance") << QStringLiteral("unknown") << QStringLiteral("ltr") << QString::fromUtf8("العربية") << QStringLiteral(" XYZ") << QString::fromUtf8("العربية") << QStringLiteral("XYZ") << ushort(0) << true;
        QTest::newRow("empty-preserves-inheritance") << QStringLiteral("") << QStringLiteral("ltr") << QString::fromUtf8("العربية") << QStringLiteral(" XYZ") << QString::fromUtf8("العربية") << QStringLiteral("XYZ") << ushort(0) << true;
    }

    void typedDirectionsIsolateLinkedTextAndTrail() {
        QFETCH(QString, direction);
        QFETCH(QString, parentDirection);
        QFETCH(QString, label);
        QFETCH(QString, trail);
        QFETCH(QString, tokenA);
        QFETCH(QString, tokenB);
        QFETCH(ushort, isolate);
        QFETCH(bool, aBeforeB);
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QString href = QStringLiteral("https://example.org/direction?q=1&v=2");
        const QJsonArray spans{QJsonObject{{QStringLiteral("kind"), QStringLiteral("external_link")},
            {QStringLiteral("target"), QStringLiteral("//example.org/direction?q=1&v=2")},
            {QStringLiteral("text"), label}, {QStringLiteral("trail"), trail},
            {QStringLiteral("direction"), direction}, {QStringLiteral("bold"), true},
            {QStringLiteral("italic"), true}, {QStringLiteral("strike"), true}}};
        const QString beforeToken = parentDirection == QStringLiteral("rtl") ? QString::fromUtf8("ראש") : QStringLiteral("LEFT");
        const QString afterToken = parentDirection == QStringLiteral("rtl") ? QString::fromUtf8("סוף") : QStringLiteral("RIGHT");
        const auto paragraph = [&](const QString &content) {
            return QStringLiteral("<p dir=\"%1\">%2| %3 |%4</p>").arg(parentDirection, beforeToken, content, afterToken);
        };
        window.reading_->setHtml(paragraph(window.spansHtml(spans)));
        QTextDocument *actual = window.reading_->document();
        actual->setTextWidth(1000);
        actual->documentLayout()->documentSize();

        // Independent Unicode-isolate reference; compare shaped glyph origins,
        // not ambiguous cursor positions at a bidi-run boundary.
        QString expectedLink = QStringLiteral("<b><i><s><a href=\"%1\">%2</a></s></i></b>")
            .arg(href.toHtmlEscaped(), (label + trail).toHtmlEscaped());
        if (isolate) expectedLink = QString(QChar(isolate)) + expectedLink + QChar(0x2069);
        QTextDocument reference;
        reference.setDefaultFont(actual->defaultFont());
        reference.setDefaultStyleSheet(actual->defaultStyleSheet());
        reference.setDefaultTextOption(actual->defaultTextOption());
        reference.setDocumentMargin(actual->documentMargin());
        reference.setHtml(paragraph(expectedLink));
        reference.setTextWidth(actual->textWidth());
        reference.documentLayout()->documentSize();
        const auto origins = [](const QTextDocument *document, const QString &token) {
            QList<qreal> xs;
            const QTextBlock block = document->begin();
            const int at = block.text().indexOf(token);
            if (at < 0 || !block.layout() || block.layout()->lineCount() != 1) return xs;
            for (const QGlyphRun &run : block.layout()->glyphRuns(at, token.size()))
                for (const QPointF &point : run.positions()) xs.append(point.x());
            std::sort(xs.begin(), xs.end());
            return xs;
        };
        const QList<qreal> a = origins(actual, tokenA), b = origins(actual, tokenB);
        QVERIFY(!a.isEmpty() && !b.isEmpty());
        QVERIFY2(aBeforeB ? a.last() < b.first() : b.last() < a.first(),
                 "The typed span did not preserve the intended mixed-text group order.");
        const QList<qreal> before = origins(actual, beforeToken), after = origins(actual, afterToken);
        QVERIFY(!before.isEmpty() && !after.isEmpty());
        QVERIFY(parentDirection == QStringLiteral("ltr") ? before.last() < after.first() : after.last() < before.first());
        for (const QString &token : {beforeToken, tokenA, tokenB, afterToken}) {
            const QList<qreal> got = origins(actual, token), expected = origins(&reference, token);
            QCOMPARE(got.size(), expected.size());
            QVERIFY(!got.isEmpty());
            for (qsizetype i = 0; i < got.size(); ++i)
                QVERIFY2(qAbs(got[i] - expected[i]) < 0.05, qPrintable(QStringLiteral("Glyph layout differs for %1 at %2").arg(token).arg(i)));
        }
        QCOMPARE(actual->toRawText(), reference.toRawText());
        const QTextCursor linked = actual->find(label + trail);
        QVERIFY(!linked.isNull());
        for (int pos = linked.selectionStart(); pos < linked.selectionEnd(); ++pos) {
            QTextCursor character(actual);
            character.setPosition(pos);
            character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
            const QTextCharFormat format = character.charFormat();
            QCOMPARE(format.anchorHref(), href);
            QVERIFY(format.fontWeight() >= QFont::Bold);
            QVERIFY(format.fontItalic());
            QVERIFY(format.fontStrikeOut());
        }
        QVERIFY(actual->find(beforeToken).charFormat().anchorHref().isEmpty());
        QVERIFY(actual->find(afterToken).charFormat().anchorHref().isEmpty());
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QTextCursor insideTrail(actual);
        insideTrail.setPosition(linked.selectionEnd() - 2);
        window.reading_->setTextCursor(insideTrail);
        window.reading_->ensureCursorVisible();
        bool clicked = false;
        for (const int offset : {2, -2}) {
            const QPoint point = window.reading_->cursorRect(insideTrail).center() + QPoint(offset, 0);
            if (window.reading_->anchorAt(point) != href) continue;
            QTest::mouseClick(window.reading_->viewport(), Qt::LeftButton, Qt::NoModifier, point);
            clicked = true;
            break;
        }
        QVERIFY2(clicked, "The linked trail was not clickable.");
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(href)});
    }

    void egyptianSpansShapeGroupsAndKeepNavigation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QString joined = QString::fromUtf8("𓂜𓐰𓏏𓐱𓏭𓅪𓆑");
        const QString unjoined = QString::fromUtf8("𓂜𓏏𓏭𓅪𓆑");
        const QJsonArray spans{
            QJsonObject{{QStringLiteral("text"), QStringLiteral("before ")}},
            QJsonObject{{QStringLiteral("text"), joined},
                        {QStringLiteral("classes"), QStringLiteral("example Egyp")},
                        {QStringLiteral("language"), QStringLiteral("egy")},
                        {QStringLiteral("direction"), QStringLiteral("ltr")}},
            QJsonObject{{QStringLiteral("text"), QStringLiteral("next")},
                        {QStringLiteral("kind"), QStringLiteral("link")},
                        {QStringLiteral("target"), QStringLiteral("jwtj-n.f")}},
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" after")}}
        };
        window.collapsedSections_.clear(); // Render the diagnostic Noun independent of fixture fold defaults.
        for (const bool actualHeadword : {false, true}) {
            QJsonArray renderedSpans = spans;
            if (actualHeadword) {
                QJsonObject headword = renderedSpans.at(1).toObject();
                headword.insert(QStringLiteral("classes"), QStringLiteral("headword-line None headword Egyp"));
                headword.insert(QStringLiteral("bold"), true);
                headword.insert(QStringLiteral("role"), QStringLiteral("headword"));
                renderedSpans.replace(1, headword);
            }
            const QJsonObject section{{QStringLiteral("title"), QStringLiteral("Noun")},
                {QStringLiteral("level"), 3},
                {QStringLiteral("blocks"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("paragraph")},
                    {QStringLiteral("spans"), renderedSpans}}}}};
            const QString html = actualHeadword
                ? window.entryHtml(QJsonObject{{QStringLiteral("sections"), QJsonArray{section}}})
                : window.spansHtml(renderedSpans);
            window.reading_->setHtml(html);
            QTextDocument *document = window.reading_->document();
            document->setTextWidth(1000);
            document->documentLayout()->documentSize();
            const QTextCursor signs = document->find(joined);
            QVERIFY(!signs.isNull());
            QCOMPARE(signs.selectedText(), joined);
            const QFont font = signs.charFormat().font();
            QVERIFY(font.families().contains(QStringLiteral("NewGardinerOmni")));
            QVERIFY(!document->find(QStringLiteral("before")).charFormat().font().families()
                         .contains(QStringLiteral("NewGardinerOmni")));
            QCOMPARE(document->find(QStringLiteral("next")).charFormat().anchorHref(),
                     QStringLiteral("dict:jwtj-n.f"));

            // The authored jwtj.f sequence stacks D35 over the horizontal t/y pair.
            // Verify Qt's actual font shaping, not just retained Unicode controls.
            const QFontMetricsF metrics(font);
            QVERIFY(metrics.horizontalAdvance(joined) + 1 < metrics.horizontalAdvance(unjoined));
            const QTextBlock block = signs.block();
            QList<QRectF> ink;
            for (const QGlyphRun &run : block.layout()->glyphRuns(
                     signs.selectionStart() - block.position(), joined.size())) {
                QCOMPARE(run.rawFont().familyName(), QStringLiteral("NewGardinerOmni"));
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                QCOMPARE(indexes.size(), positions.size());
                for (qsizetype i = 0; i < indexes.size(); ++i) {
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect().translated(positions[i]);
                    if (bounds.isEmpty()) continue;
                    QVERIFY(indexes[i] != 0);
                    ink.append(bounds);
                }
            }
            QCOMPARE(ink.size(), qsizetype(5));
            QVERIFY(ink[0].bottom() < ink[1].top());
            QVERIFY(ink[0].bottom() < ink[2].top());
            QVERIFY(ink[1].right() < ink[2].left());
            QVERIFY(ink[3].left() > ink[2].right());
            QVERIFY(ink[4].left() > ink[3].right());
        }

        // Exact captured AR names, encoded only after authoritative MdC mapping.
        // This tests reader shaping; it does not decode MdC or certify all enclosures.
        const QString tut = QString::fromUtf8("𓇋𓏠𓐰𓈖𓏏𓅱𓐴𓏏𓋹");
        const QString akhenaten = QString::fromUtf8("𓍹𓐼𓇋𓏏𓐰𓈖𓐰𓇳𓅜𓐍𓐰𓈖𓐽𓍺");
        const QString before = QString::fromUtf8("قبل ");
        const QString after = QString::fromUtf8(" بعد ");
        const QString caption = QString::fromUtf8("الرابط");
        const auto inkFor = [](const QString &text, const QFont &font) {
            QTextLayout layout(text, font);
            layout.beginLayout();
            QTextLine line = layout.createLine();
            if (line.isValid()) line.setLineWidth(1000);
            layout.endLayout();
            QList<QRectF> ink;
            for (const QGlyphRun &run : layout.glyphRuns()) {
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                for (qsizetype i = 0; i < indexes.size() && i < positions.size(); ++i) {
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect();
                    if (!bounds.isEmpty()) ink.append(bounds.translated(positions[i]));
                }
            }
            return ink;
        };
        window.resize(780, 480);
        window.show();
        QCoreApplication::processEvents();
        for (const QString &encoded : {tut, akhenaten}) {
            const QJsonArray captured{
                QJsonObject{{QStringLiteral("text"), before}, {QStringLiteral("language"), QStringLiteral("ar")},
                            {QStringLiteral("direction"), QStringLiteral("rtl")}},
                QJsonObject{{QStringLiteral("text"), encoded}, {QStringLiteral("classes"), QStringLiteral("Egyp")},
                            {QStringLiteral("language"), QStringLiteral("egy")}, {QStringLiteral("direction"), QStringLiteral("ltr")}},
                QJsonObject{{QStringLiteral("text"), after}, {QStringLiteral("language"), QStringLiteral("ar")},
                            {QStringLiteral("direction"), QStringLiteral("rtl")}},
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), caption},
                            {QStringLiteral("target"), QStringLiteral("egy-following")}, {QStringLiteral("direction"), QStringLiteral("rtl")}}
            };
            window.reading_->setHtml(window.spansHtml(captured));
            QTextDocument *document = window.reading_->document();
            document->setTextWidth(window.reading_->viewport()->width());
            const QSizeF size = document->documentLayout()->documentSize();
            QCoreApplication::processEvents();
            // Same existing Qt screenshot path, resolved inside the owned test cwd.
            // Retain actual pixels before the new shaping assertions can fail.
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            const QString screenshot = encoded == tut
                ? QStringLiteral(".tmp/ui-screenshots/desktop-egyptian-tut.png")
                : QStringLiteral(".tmp/ui-screenshots/desktop-egyptian-akhenaten.png");
            QVERIFY(window.grab().save(screenshot));
            QVERIFY(qIsFinite(size.width()) && qIsFinite(size.height()));
            QVERIFY(size.width() > 0 && size.height() > 0);
            const QTextCursor signs = document->find(encoded);
            QVERIFY(!signs.isNull());
            QCOMPARE(signs.selectedText(), encoded);
            const QFont font = signs.charFormat().font();
            QVERIFY(font.families().contains(QStringLiteral("NewGardinerOmni")));
            QVERIFY(!document->find(before.trimmed()).isNull());
            QVERIFY(!document->find(after.trimmed()).isNull());
            QVERIFY(!document->find(after.trimmed()).charFormat().font().families()
                         .contains(QStringLiteral("NewGardinerOmni")));
            QCOMPARE(document->find(caption).charFormat().anchorHref(), QStringLiteral("dict:egy-following"));
            const QTextBlock block = signs.block();
            qsizetype painted = 0;
            for (const QGlyphRun &run : block.layout()->glyphRuns(signs.selectionStart() - block.position(), encoded.size())) {
                QCOMPARE(run.rawFont().familyName(), QStringLiteral("NewGardinerOmni"));
                const auto indexes = run.glyphIndexes();
                const auto positions = run.positions();
                QCOMPARE(indexes.size(), positions.size());
                for (qsizetype i = 0; i < indexes.size(); ++i) {
                    QVERIFY(indexes[i] != 0);
                    const QRectF bounds = run.rawFont().pathForGlyph(indexes[i]).boundingRect().translated(positions[i]);
                    QVERIFY(qIsFinite(bounds.left()) && qIsFinite(bounds.top()) &&
                            qIsFinite(bounds.width()) && qIsFinite(bounds.height()));
                    if (!bounds.isEmpty()) ++painted;
                }
            }
            QVERIFY(painted > 0);
            if (encoded == tut) {
                QString withoutInsertion = encoded;
                withoutInsertion.remove(QString::fromUtf8("𓐴"));
                // Ignore invisible control glyphs: require an actual ink-layout change.
                QVERIFY(inkFor(encoded, font) != inkFor(withoutInsertion, font));
            }
        }
    }

    void abbreviationExplanationsPreserveCopyLinksAndKeyboardAccess() {
        // Required ordinary native test-bundle output; no hand-built interoperability fallback.
        QString interopRoot = qEnvironmentVariable("DICT_ABBREVIATION_INTEROP_ROOT");
        if (interopRoot.isEmpty()) interopRoot = QDir(fixture_).filePath(QStringLiteral("abbreviation-interop"));
        const QString source = QDir(interopRoot).filePath(QStringLiteral(
            "languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        QVERIFY2(QFileInfo::exists(source), qPrintable(source));
        QTemporaryDir imported(QStringLiteral(".tmp/ui-native-abbreviations-XXXXXX"));
        QVERIFY(imported.isValid());
        const QString root = imported.path() + QStringLiteral("/library");
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled,
            [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        {
            DictApi actual(root);
            actual.select(QStringLiteral("English"), QStringLiteral("language"));
            const std::array<QPair<QString, QString>, 2> samples{{
                {QStringLiteral("Acupuncture abbreviation sample"), QStringLiteral("annotated.export.json")},
                {QStringLiteral("Legacy format abbreviation control"), QStringLiteral("legacy.export.json")}
            }};
            for (const auto &sample : samples) {
                QFile exported(QDir(interopRoot).filePath(sample.second));
                QVERIFY2(exported.open(QIODevice::ReadOnly), qPrintable(exported.fileName()));
                QJsonParseError exportError;
                const QJsonDocument expected = QJsonDocument::fromJson(exported.readAll(), &exportError);
                QCOMPARE(exportError.error, QJsonParseError::NoError);
                QVERIFY(expected.isObject());
                const QJsonArray expectedEntries = expected.object().value(QStringLiteral("entries")).toArray();
                QCOMPARE(expectedEntries.size(), 1);
                QVERIFY(expectedEntries.first().isObject());
                QJsonParseError lookupError;
                const QJsonDocument observed = QJsonDocument::fromJson(actual.lookup(sample.first), &lookupError);
                QCOMPARE(lookupError.error, QJsonParseError::NoError);
                QVERIFY(observed.isObject());
                const QJsonArray actualEntries = observed.object().value(QStringLiteral("entries")).toArray();
                QCOMPARE(actualEntries.size(), 1);
                // Compare the entire typed Entry, not operation-specific export/lookup envelopes.
                QCOMPARE(actualEntries.first(), expectedEntries.first());
                QCOMPARE(actualEntries.first().toObject().value(QStringLiteral("title")).toString(), sample.first);
            }
        }
        MainWindow window(root, QStringLiteral("Acupuncture abbreviation sample"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.resize(780, 480);
        window.show();
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Acupuncture abbreviation sample"), 30000);
        QTRY_VERIFY_WITH_TIMEOUT(!window.reading_->toPlainText().isEmpty(), 30000);
        const QVector<QPair<QString, QString>> nativeExplanations{
            {QStringLiteral("der."), QStringLiteral("derived terms")},
            {QStringLiteral("?"), QStringLiteral("uncertain")},
            {QStringLiteral("lbor."), QStringLiteral("learned borrowing")},
            {QStringLiteral("f"), QStringLiteral("feminine gender")},
            {QStringLiteral("c"), QStringLiteral("common gender")},
            {QStringLiteral("m"), QStringLiteral("masculine gender")},
            {QStringLiteral("n"), QStringLiteral("neuter gender")}
        };
        QCOMPARE(window.readingExplanations(), nativeExplanations);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("der. ? lbor. f c m n")));
        const QTextCursor derived = window.reading_->document()->find(QStringLiteral("der."));
        const QTextCursor learned = window.reading_->document()->find(QStringLiteral("lbor."));
        QVERIFY(!derived.isNull() && !learned.isNull());
        QCOMPARE(QUrl::fromPercentEncoding(derived.charFormat().anchorHref().mid(5).toUtf8()),
                 QStringLiteral("Appendix:Glossary#derived terms"));
        QCOMPARE(QUrl::fromPercentEncoding(learned.charFormat().anchorHref().mid(5).toUtf8()),
                 QStringLiteral("Appendix:Glossary#learned borrowing"));
        QVERIFY(derived.charFormat().anchorHref().startsWith(QStringLiteral("dict:")));
        QVERIFY(learned.charFormat().anchorHref().startsWith(QStringLiteral("dict:")));
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-native-abbreviations-reader.png")));
        QVERIFY(window.openWord(QStringLiteral("Legacy format abbreviation control")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Legacy format abbreviation control"), 30000);
        QTRY_VERIFY_WITH_TIMEOUT(window.reading_->toPlainText().contains(QStringLiteral("Plain control.")), 30000);
        QVERIFY(window.readingExplanations().isEmpty());
        const QTextCursor control = window.reading_->document()->find(QStringLiteral("control"));
        QVERIFY(!control.isNull());
        QCOMPARE(control.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        const QString feminine = QStringLiteral("feminine gender");
        const QString styled = QString::fromUtf8("expanded <plain> \"quoted\" العربية");
        const QJsonArray spans{
            QJsonObject{{"kind", "link"}, {"text", "f"}, {"target", "cat"}, {"explanation", feminine}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "ab"}, {"bold", true}, {"explanation", styled}},
            QJsonObject{{"text", "br"}, {"italic", true}, {"explanation", styled}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "f"}, {"explanation", "masculine meaning in another context"}},
            QJsonObject{{"text", " "}},
            QJsonObject{{"text", "?"}, {"explanation", "uncertain"}}
        };
        window.reading_->setHtml(window.spansHtml(spans));
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-abbreviations-reader.png")));
        QCOMPARE(window.reading_->toPlainText(), QStringLiteral("f abbr f ?"));
        QTextDocument *document = window.reading_->document();
        const QTextCursor first = document->find(QStringLiteral("f"));
        QCOMPARE(first.charFormat().toolTip(), feminine); // Actual Qt HTML import, no fallback parser.
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        const auto explanations = window.readingExplanations();
        QCOMPARE(explanations.size(), 4);
        QCOMPARE(explanations.at(0), qMakePair(QStringLiteral("f"), feminine));
        QCOMPARE(explanations.at(1), qMakePair(QStringLiteral("abbr"), styled));
        QCOMPARE(explanations.at(2).first, QStringLiteral("f"));
        QVERIFY(explanations.at(2).second != feminine);
        QCOMPARE(explanations.at(3), qMakePair(QStringLiteral("?"), QStringLiteral("uncertain")));
        window.reading_->selectAll();
        QCOMPARE(window.reading_->textCursor().selection().toPlainText(), QStringLiteral("f abbr f ?"));
        window.activateWindow();
        window.reading_->setFocus();
        auto focusContext = [&] {
            auto describe = [](QWidget *widget) {
                return widget ? QString::fromLatin1(widget->metaObject()->className()) + QStringLiteral("/") + widget->objectName() : QStringLiteral("none");
            };
            return QStringLiteral("active=%1 focus=%2 modal=%3 popup=%4 windowActive=%5 readerVisible=%6 readerEnabled=%7")
                .arg(describe(QApplication::activeWindow()), describe(QApplication::focusWidget()),
                     describe(QApplication::activeModalWidget()), describe(QApplication::activePopupWidget()))
                .arg(window.isActiveWindow()).arg(window.reading_->isVisible()).arg(window.reading_->isEnabled());
        };
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        bool inspected = false;
        bool timedOut = false;
        QTimer fallback;
        fallback.setSingleShot(true);
        connect(&fallback, &QTimer::timeout, &window, [&] {
            timedOut = true;
            for (QDialog *dialog : window.findChildren<QDialog *>()) dialog->reject();
            for (QMenu *menu : window.findChildren<QMenu *>()) menu->close();
        });
        fallback.start(2000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu"));
            QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations"));
            QVERIFY(action);
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog"));
                QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations"));
                QVERIFY(details);
                QCoreApplication::processEvents();
                QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-abbreviations-dialog.png")));
                QCOMPARE(details->accessibleName(), QStringLiteral("Abbreviation explanations"));
                QVERIFY(details->toPlainText().contains(styled));
                QVERIFY(details->toPlainText().contains(QStringLiteral("f: feminine gender")));
                QVERIFY(details->toPlainText().contains(QStringLiteral("?: uncertain")));
                inspected = true;
                dialog->reject();
            });
            menu->setActiveAction(action);
            QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        fallback.stop();
        QVERIFY(!timedOut);
        QVERIFY(inspected);
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        QCOMPARE(window.reading_->toPlainText(), QStringLiteral("f abbr f ?"));
        QCOMPARE(document->find(QStringLiteral("f")).charFormat().anchorHref(), QStringLiteral("dict:cat"));
        window.reading_->setHtml(window.spansHtml(QJsonArray{QJsonObject{{"text", "ordinary"}}}));
        QVERIFY(window.readingExplanations().isEmpty());
        // Explained-only heading companions are rich even without a navigation target.
        const QJsonObject heading{{"kind", "heading"}, {"level", 3},
            {"spans", QJsonArray{QJsonObject{{"text", "Noun"}, {"explanation", "noun meaning"}}}}};
        const QJsonObject section{{"title", "Noun"}, {"level", 3}, {"blocks", QJsonArray{heading}}};
        window.collapsedSections_.clear();
        window.reading_->setHtml(window.entryHtml(QJsonObject{{"sections", QJsonArray{section}}}));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Noun")), 1);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Noun")).charFormat().toolTip(), QStringLiteral("noun meaning"));
        QCOMPARE(window.readingExplanations().size(), 1);
        // A title-only annotation must use the same ordinary reader keyboard route.
        QJsonObject titleResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("Legacy format abbreviation control"))).object();
        QJsonObject titleEntry = titleResponse.value(QStringLiteral("entries")).toArray().first().toObject();
        titleEntry.insert(QStringLiteral("display_title"), QJsonArray{
            QJsonObject{{"text", "f"}, {"explanation", "title feminine gender"}}});
        titleResponse.insert(QStringLiteral("entries"), QJsonArray{titleEntry});
        window.renderResponse(QJsonDocument(titleResponse).toJson(), false);
        QVERIFY(window.title_->isVisible());
        QTextDocument displayedTitle;
        displayedTitle.setHtml(window.title_->toHtml());
        QCOMPARE(displayedTitle.toPlainText(), QStringLiteral("f"));
        const QVector<QPair<QString, QString>> titleOnly{{QStringLiteral("f"), QStringLiteral("title feminine gender")}};
        QCOMPARE(window.readingExplanations(), titleOnly);
        inspected = false;
        timedOut = false;
        window.reading_->setFocus();
        fallback.start(2000);
        QTimer::singleShot(0, &window, [&] {
            auto *menu = window.findChild<QMenu *>(QStringLiteral("readerContextMenu"));
            QVERIFY(menu);
            auto *action = menu->findChild<QAction *>(QStringLiteral("entryAbbreviations"));
            QVERIFY(action);
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = window.findChild<QDialog *>(QStringLiteral("abbreviationsDialog"));
                QVERIFY(dialog);
                auto *details = dialog->findChild<QTextBrowser *>(QStringLiteral("abbreviationExplanations"));
                QVERIFY(details);
                QVERIFY(details->toPlainText().contains(QStringLiteral("f: title feminine gender")));
                inspected = true;
                dialog->reject();
            });
            menu->setActiveAction(action);
            QTest::keyClick(menu, Qt::Key_Return);
        });
        QTest::keyClick(window.reading_, Qt::Key_F10, Qt::ShiftModifier);
        fallback.stop();
        QVERIFY(!timedOut);
        QVERIFY(inspected);
        QTRY_VERIFY2(window.reading_->hasFocus(), qPrintable(focusContext()));
        QVERIFY(window.openWord(QStringLiteral("Legacy format abbreviation control")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("Legacy format abbreviation control"), 30000);
        QVERIFY(window.readingExplanations().isEmpty());
    }

    void cancellationKeepsLastWorkingDictionary() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QString reading = window.reading_->toPlainText();
        window.openRoot(fixture_ + QStringLiteral("/cancelled-folder"));
        QVERIFY(window.loading_);
        QVERIFY(window.cancelOpening_->isVisible());
        const auto watchers = window.findChildren<QFutureWatcherBase *>();
        QVERIFY(!watchers.isEmpty());
        const QPointer<QFutureWatcherBase> pending = watchers.last();
        window.cancelOpening_->click();
        QVERIFY(!window.loading_);
        QVERIFY(window.search_->isEnabled());
        QTRY_VERIFY_WITH_TIMEOUT(!pending || pending->isFinished(), 30000);
        QCoreApplication::processEvents();
        QCOMPARE(window.api_->root(), fixture_);
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.reading_->toPlainText(), reading);
        QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), fixture_);
        QCOMPARE(QSettings().value(QStringLiteral("reader/lastWord")).toString(), QStringLiteral("cat"));
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("cancelled")));
    }


    void libraryModalDefersQueuedLoadUntilAfterActualRemoval() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-modal-remove-XXXXXX"));
        QVERIFY(directory.isValid());
        QTemporaryDir rejected(QStringLiteral(".tmp/ui-removed-then-switch-XXXXXX"));
        QVERIFY(rejected.isValid());
        const QString rejectedRoot = QDir(rejected.path()).absolutePath();
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        for (const QString &file : {
                QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
        }
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restoreSources = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        MainWindow window(root, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QByteArray originalJson = window.currentJson_;
        const QString originalReading = window.reading_->toPlainText();
        QStringList originalHistory;
        for (const auto &entry : window.learning_.history()) originalHistory.append(entry.key);
        window.loadDataset(root, QStringLiteral("English"), QStringLiteral("language"), true, QStringLiteral("Cats"));
        const auto watchers = window.findChildren<QFutureWatcherBase *>();
        QVERIFY(!watchers.isEmpty());
        QPointer<QFutureWatcherBase> pending = watchers.last();
        pending->blockSignals(true);
        QTRY_VERIFY_WITH_TIMEOUT(pending->isFinished(), 30000);
        // Consume the real original notification while blocked, then deliver it once
        // only after a real removal inside Library's nested event loop.
        QCoreApplication::sendPostedEvents(pending.data());
        bool removed = false, deliveredInsideModal = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *installed = dialog->findChild<QTreeWidget *>(QStringLiteral("installedDictionaries"));
            auto *remove = dialog->findChild<QPushButton *>(QStringLiteral("removeDictionary"));
            auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
            QVERIFY(installed && remove && status);
            QTreeWidgetItem *english = nullptr;
            for (int i = 0; i < installed->topLevelItemCount(); ++i)
                if (installed->topLevelItem(i)->text(0) == QStringLiteral("English")) english = installed->topLevelItem(i);
            QVERIFY(english);
            installed->setCurrentItem(english);
            bool confirmationClicked = false;
            QObject confirmationContext;
            QTimer::singleShot(0, &confirmationContext, [&] {
                auto *confirmation = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
                QVERIFY(confirmation);
                auto *yes = confirmation->button(QMessageBox::Yes);
                QVERIFY(yes);
                QTest::mouseClick(yes, Qt::LeftButton);
                confirmationClicked = true;
            });
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(confirmationClicked);
            QTRY_VERIFY2_WITH_TIMEOUT(status->text().startsWith(QStringLiteral("Removed ")), qPrintable(status->text()), 30000);
            QVERIFY(!QFileInfo::exists(root + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")));
            QVERIFY(QFileInfo::exists(root + QStringLiteral("/aliases.wikblb")));
            removed = true;
            // Editing the original root still invalidates it after selecting a different folder.
            auto *choose = dialog->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
            QVERIFY(choose);
            bool selected = false;
            QTimer deadline;
            deadline.setSingleShot(true);
            QObject::connect(&deadline, &QTimer::timeout, dialog, [dialog] {
                for (auto *picker : dialog->findChildren<QFileDialog *>())
                    if (picker->isVisible()) picker->reject();
            });
            deadline.start(2000);
            QTimer::singleShot(0, dialog, [&] {
                auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                QVERIFY(picker);
                picker->setDirectory(rejectedRoot); picker->selectFile(rejectedRoot);
                selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
            });
            QTest::mouseClick(choose, Qt::LeftButton);
            deadline.stop();
            QVERIFY(selected);
            QVERIFY(pending);
            pending->blockSignals(false);
            QVERIFY(QMetaObject::invokeMethod(pending.data(), "finished", Qt::DirectConnection));
            deliveredInsideModal = true;
            QCOMPARE(window.currentJson_, originalJson);
            QCOMPARE(window.reading_->toPlainText(), originalReading);
            QStringList history;
            for (const auto &entry : window.learning_.history()) history.append(entry.key);
            QCOMPARE(history, originalHistory);
        });
        window.chooseRoot();
        QVERIFY(removed && deliveredInsideModal);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(!window.api_);
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.visits_.isEmpty());
        QCOMPARE(window.visitIndex_, -1);
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.currentEntry_.isEmpty() || !window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("followed")).toBool());
    }

    void removingLastDictionaryClearsVisibleEntryAndSearchState_data() {
        QTest::addColumn<bool>("cancelReload");
        QTest::newRow("reload-managed-empty") << false;
        QTest::newRow("reload-cancelled-empty") << true;
    }

    void removingLastDictionaryClearsVisibleEntryAndSearchState() {
        QFETCH(bool, cancelReload);
        QTemporaryDir directory(QStringLiteral(".tmp/ui-last-dictionary-remove-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QStringLiteral(
                "/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
        }
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(root, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(!window.json_->toPlainText().isEmpty());
        QVERIFY(window.results_->count() > 0);
        QVERIFY(window.sections_->count() > 1);
        QVERIFY(window.sections_->isEnabled());
        QVERIFY(window.bookmark_->isEnabled());
        const QString query = window.search_->text();
        QStringList history;
        for (const auto &entry : window.learning_.history()) history.append(entry.key);
        window.entryTabs_->setCurrentWidget(window.json_);

        bool removed = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *installed = dialog->findChild<QTreeWidget *>(QStringLiteral("installedDictionaries"));
            auto *remove = dialog->findChild<QPushButton *>(QStringLiteral("removeDictionary"));
            auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
            QVERIFY(installed && remove && status);
            QCOMPARE(installed->topLevelItemCount(), 1);
            QCOMPARE(installed->topLevelItem(0)->text(0), QStringLiteral("English"));
            installed->setCurrentItem(installed->topLevelItem(0));
            bool confirmationClicked = false;
            QObject confirmationContext;
            QTimer::singleShot(0, &confirmationContext, [&] {
                auto *confirmation = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
                QVERIFY(confirmation);
                auto *yes = confirmation->button(QMessageBox::Yes);
                QVERIFY(yes);
                QTest::mouseClick(yes, Qt::LeftButton);
                confirmationClicked = true;
            });
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(confirmationClicked);
            QTRY_VERIFY2_WITH_TIMEOUT(status->text().startsWith(QStringLiteral("Removed ")), qPrintable(status->text()), 30000);
            QVERIFY(!QFileInfo::exists(root + QStringLiteral(
                "/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb")));
            removed = true;
        });
        window.chooseRoot();
        QVERIFY(removed);
        if (cancelReload) {
            // chooseRoot starts the real replacement load before returning; no event-loop delay.
            QVERIFY(window.loading_);
            QVERIFY(!window.api_);
            QVERIFY(window.cancelOpening_->isVisible());
            window.cancelOpening_->click();
        }
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && !window.api_, 30000);
        QTRY_VERIFY_WITH_TIMEOUT(window.findChildren<QFutureWatcherBase *>().isEmpty(), 30000);
        QCoreApplication::processEvents();
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.currentJson_.isEmpty());
        QVERIFY(window.json_->toPlainText().isEmpty());
        QCOMPARE(window.search_->text(), query);
        QCOMPARE(window.results_->count(), 0);
        QCOMPARE(window.sections_->count(), 0);
        QVERIFY(!window.sections_->isEnabled());
        QVERIFY(!window.bookmark_->isEnabled());
        QVERIFY(!window.search_->isEnabled());
        QVERIFY(!window.results_->isEnabled());
        QVERIFY(!window.random_->isEnabled());
        QVERIFY(!window.listen_->isEnabled());
        QVERIFY(!window.moreResults_->isEnabled());
        QVERIFY(!window.back_->isEnabled());
        QVERIFY(!window.forward_->isEnabled());
        QCOMPARE(window.title_->toPlainText(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), cancelReload
            ? QStringLiteral("Opening cancelled. Choose a folder to try again.")
            : QStringLiteral("No dictionary open"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Open Library")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        if (!cancelReload) {
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Could not open")));
            QVERIFY(QFileInfo::exists(root + QStringLiteral("/.desktop-library.json")));
            QFile manifest(root + QStringLiteral("/languages.tsv"));
            QVERIFY(manifest.open(QIODevice::ReadOnly));
            QCOMPARE(manifest.readAll(), QByteArrayLiteral("heading\n"));
            MainWindow reopened(root);
            reopened.show();
            QTRY_VERIFY_WITH_TIMEOUT(!reopened.loading_, 30000);
            QVERIFY(!reopened.api_);
            QVERIFY(reopened.reading_->toPlainText().contains(QStringLiteral("No dictionaries are installed yet.")));
            QVERIFY(!reopened.reading_->toPlainText().contains(QStringLiteral("Could not open")));
        }
        QStringList remainingHistory;
        for (const auto &entry : window.learning_.history()) remainingHistory.append(entry.key);
        QCOMPARE(remainingHistory, history);
    }

    void choosingSameFolderReloadsExternallyReplacedDictionary() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-same-folder-reload-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString base = QDir(directory.path()).absolutePath();
        QVERIFY(prepareCaseTitleFixture(fixture_, base, {QStringLiteral("cat")}));
        const QString root = base + QStringLiteral("/library");
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restore = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        MainWindow window(root, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(!window.searchTitles_.contains(QStringLiteral("newterm")));
        const unsigned serial = window.loadSerial_;
        // The same ordinary installer transaction replaces bytes outside this window.
        QVERIFY(prepareCaseTitleFixture(fixture_, base, {QStringLiteral("cat"), QStringLiteral("newterm")}));
        bool selected = false;
        QTimer::singleShot(0, &window, [&] {
            auto *library = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(library && library->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { library->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!library->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            auto *choose = library->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
            QVERIFY(choose);
            // A failed assertion in the callback must not strand the nested chooser.
            QTimer chooserDeadline;
            chooserDeadline.setSingleShot(true);
            QObject::connect(&chooserDeadline, &QTimer::timeout, library, [library] {
                for (auto *picker : library->findChildren<QFileDialog *>())
                    if (picker->isVisible()) picker->reject();
            });
            chooserDeadline.start(2000);
            auto stopDeadline = qScopeGuard([&] { chooserDeadline.stop(); });
            QTimer::singleShot(0, library, [&] {
                auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                QVERIFY(picker);
                picker->setDirectory(root);
                picker->selectFile(root);
                selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
            });
            QTest::mouseClick(choose, Qt::LeftButton);
            QVERIFY(selected);
        });
        window.chooseRoot();
        QVERIFY(selected);
        QVERIFY(window.loadSerial_ > serial);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.searchTitles_.contains(QStringLiteral("newterm")));
        window.search_->setText(QStringLiteral("newterm"));
        window.refreshSearch();
        QCOMPARE(window.results_->count(), 1);
        window.search_->setFocus();
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("newterm"));
        QVERIFY(!window.currentEntry_.isEmpty());
        QVERIFY(!window.reading_->toPlainText().isEmpty());
    }

    void failedLibraryFolderSelectionPreservesReaderAndNavigation() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        const bool nativeDisabled = QApplication::testAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
        auto restore = qScopeGuard([&] {
            QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
            QApplication::setAttribute(Qt::AA_DontUseNativeDialogs, nativeDisabled);
        });
        for (const bool malformed : {false, true}) {
            QTemporaryDir candidate(QStringLiteral(".tmp/ui-rejected-root-XXXXXX"));
            QVERIFY(candidate.isValid());
            const QString rejectedRoot = QDir(candidate.path()).absolutePath();
            if (malformed) {
                QFile manifest(rejectedRoot + QStringLiteral("/languages.tsv"));
                QVERIFY(manifest.open(QIODevice::WriteOnly));
                QCOMPARE(manifest.write("invalid manifest\n"), qint64(17));
            }
            MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QVERIFY(window.openWord(QStringLiteral("dog")));
            QTRY_COMPARE(title(window), QStringLiteral("dog"));
            const QByteArray json = window.currentJson_;
            const QString reading = window.reading_->toPlainText();
            window.saveVisit();
            const auto visits = window.visits_;
            const auto collapsed = window.collapsedSections_;
            const int scroll = window.reading_->verticalScrollBar()->value();
            const int visitIndex = window.visitIndex_;
            const QString rootSetting = QSettings().value(QStringLiteral("reader/root")).toString();
            bool selected = false;
            QTimer::singleShot(0, &window, [&] {
                auto *library = qobject_cast<QDialog *>(QApplication::activeModalWidget());
                QVERIFY(library && library->objectName() == QStringLiteral("libraryDialog"));
                auto close = qScopeGuard([&] { library->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!library->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                auto *choose = library->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
                QVERIFY(choose);
                QTimer deadline;
                deadline.setSingleShot(true);
                QObject::connect(&deadline, &QTimer::timeout, library, [library] {
                    for (auto *picker : library->findChildren<QFileDialog *>())
                        if (picker->isVisible()) picker->reject();
                });
                deadline.start(2000);
                QTimer::singleShot(0, library, [&] {
                    auto *picker = qobject_cast<QFileDialog *>(QApplication::activeModalWidget());
                    QVERIFY(picker);
                    picker->setDirectory(rejectedRoot); picker->selectFile(rejectedRoot);
                    selected = QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
                });
                QTest::mouseClick(choose, Qt::LeftButton);
                deadline.stop();
                QVERIFY(selected);
            });
            window.chooseRoot();
            QVERIFY(selected);
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QVERIFY(window.api_ && window.search_->isEnabled());
            QCOMPARE(window.api_->root(), fixture_);
            QCOMPARE(window.currentJson_, json);
            QCOMPARE(window.reading_->toPlainText(), reading);
            QCOMPARE(window.visitIndex_, visitIndex);
            QCOMPARE(window.visits_.size(), visits.size());
            for (qsizetype i = 0; i < visits.size(); ++i) {
                QCOMPARE(window.visits_[i].title, visits[i].title);
                QCOMPARE(window.visits_[i].language, visits[i].language);
                QCOMPARE(window.visits_[i].kind, visits[i].kind);
                QCOMPARE(window.visits_[i].scroll, visits[i].scroll);
                QCOMPARE(window.visits_[i].collapsed, visits[i].collapsed);
            }
            QCOMPARE(window.collapsedSections_, collapsed);
            QCOMPARE(window.reading_->verticalScrollBar()->value(), scroll);
            QCOMPARE(QSettings().value(QStringLiteral("reader/root")).toString(), rootSetting);
            QVERIFY(window.resultStatus_->text() == QStringLiteral("Could not open the selected dictionary. Your current dictionary is still open."));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-rejected-root-%1.png").arg(malformed ? QStringLiteral("invalid") : QStringLiteral("empty"))));
            window.navigate(-1);
            QTRY_COMPARE(title(window), QStringLiteral("cat"));
        }
    }

    void libraryWorkerDistinguishesUnrestoredMutationFromRestoredErrors() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        // The worker fixture injects the typed result after real filesystem recovery attempts.
        // The same message on ordinary failures must not mark a root as changed.
        for (const int mode : {0, 1, 2}) { // validation, restored error, unrestored error
            QTemporaryDir directory(QStringLiteral(".tmp/ui-recovery-status-XXXXXX"));
            QTemporaryDir recovery(QStringLiteral(".tmp/ui-recovery-files-XXXXXX"));
            QVERIFY(directory.isValid() && recovery.isValid());
            const QString root = QDir(directory.path()).absolutePath();
            const QString backup = QDir(recovery.path()).absoluteFilePath(QStringLiteral("dictionary.wikblb"));
            std::atomic_bool cancelled = false;
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"), {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(root, *prepared);
            const QString dictionary = prepared->dictionary.path;
            QFile original(dictionary);
            QVERIFY(original.open(QIODevice::ReadOnly));
            const QByteArray originalBytes = original.readAll();
            QVERIFY(!originalBytes.isEmpty());
            original.close();
            MainWindow window(root, QStringLiteral("cat")); window.show();
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
            QVERIFY(window.openWord(QStringLiteral("dog")));
            QTRY_COMPARE(title(window), QStringLiteral("dog"));
            const QByteArray json = window.currentJson_;
            const QString reading = window.reading_->toPlainText();
            const int visitIndex = window.visitIndex_;
            const qsizetype visitCount = window.visits_.size();
            bool completed = false;
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = static_cast<LibraryDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
                auto closeOnSetupFailure = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                dialog->setBusy(true, QStringLiteral("Testing recovery status"));
                dialog->runWorker([dictionary, backup, mode] {
                    const char *message = "The dictionary could not be restored.";
                    if (mode != 0) {
                        if (!QFile::rename(dictionary, backup)) throw std::runtime_error("Recovery fixture could not move the dictionary");
                        if (mode == 1) {
                            if (!QFile::rename(backup, dictionary)) throw std::runtime_error("Recovery fixture could not restore the dictionary");
                        } else {
                            if (!QDir().mkpath(dictionary)) throw std::runtime_error("Recovery fixture could not block the original path");
                            if (QFile::rename(backup, dictionary)) throw std::runtime_error("Recovery fixture unexpectedly restored the dictionary");
                            throw LibraryStorage::UnrestoredMutation(message);
                        }
                    }
                    throw std::runtime_error(message);
                }, [&, dialog](const QString &error) {
                    auto close = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                    dialog->finishOperation(error, true);
                    QCOMPARE(error, QStringLiteral("The dictionary could not be restored."));
                    QCOMPARE(dialog->libraryChanged(), mode == 2);
                    QCOMPARE(dialog->originalRootChanged(), mode == 2);
                    auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
                    auto *choose = dialog->findChild<QPushButton *>(QStringLiteral("chooseDictionaryFolder"));
                    auto *importButton = dialog->findChild<QPushButton *>(QStringLiteral("importDictionary"));
                    auto *cancel = dialog->findChild<QPushButton *>(QStringLiteral("cancelLibraryOperation"));
                    auto *progress = dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"));
                    QVERIFY(status && choose && importButton && cancel && progress);
                    QCOMPARE(status->text(), QStringLiteral("Could not finish: The dictionary could not be restored."));
                    QVERIFY(choose->isEnabled() && importButton->isEnabled());
                    QVERIFY(!cancel->isVisible() && !progress->isVisible());
                    dialog->activateWindow();
                    choose->setFocus();
                    QTRY_VERIFY(choose->hasFocus());
                    for (int steps = 0; steps < 16 && !importButton->hasFocus(); ++steps)
                        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
                    QTRY_VERIFY(importButton->hasFocus());
                    const QString suffix = mode == 0 ? QStringLiteral("validation")
                        : mode == 1 ? QStringLiteral("restored") : QStringLiteral("unrestored");
                    QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-worker-recovery-%1.png").arg(suffix)));
                    QTest::keyClick(importButton, Qt::Key_Escape);
                    QTRY_VERIFY(!dialog->isVisible());
                    completed = true;
                });
                closeOnSetupFailure.dismiss();
            });
            window.chooseRoot();
            QVERIFY(completed);
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            if (mode == 2) {
                QVERIFY(QFileInfo(dictionary).isDir() && QFileInfo(backup).isFile());
                QFile retained(backup);
                QVERIFY(retained.open(QIODevice::ReadOnly));
                QCOMPARE(retained.readAll(), originalBytes);
                QVERIFY(!window.api_ && window.currentEntry_.isEmpty() && window.currentJson_.isEmpty());
                QVERIFY(window.visits_.isEmpty());
                QCOMPARE(window.visitIndex_, -1);
                QVERIFY(!window.back_->isEnabled());
                QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Could not open this dictionary.")));
            } else {
                QVERIFY(QFileInfo(dictionary).isFile() && !QFileInfo::exists(backup));
                QFile restored(dictionary);
                QVERIFY(restored.open(QIODevice::ReadOnly));
                QCOMPARE(restored.readAll(), originalBytes);
                QVERIFY(window.api_ && window.search_->isEnabled());
                QCOMPARE(window.currentJson_, json);
                QCOMPARE(window.reading_->toPlainText(), reading);
                QCOMPARE(window.visitIndex_, visitIndex);
                QCOMPARE(window.visits_.size(), visitCount);
                window.navigate(-1);
                QTRY_COMPARE(title(window), QStringLiteral("cat"));
            }
        }
    }

    void unchangedLibraryClosePreservesDisplayedEntry() {
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QByteArray json = window.currentJson_;
        const QString reading = window.reading_->toPlainText();
        const unsigned serial = window.loadSerial_;
        QTimer::singleShot(0, &window, [] {
            if (auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget())) dialog->done(QDialog::Rejected);
        });
        window.chooseRoot();
        QCOMPARE(window.currentJson_, json);
        QCOMPARE(window.reading_->toPlainText(), reading);
        QCOMPARE(window.loadSerial_, serial);
        QVERIFY(!window.loading_ && window.api_ && window.search_->isEnabled());
    }

    void unchangedLibraryClosePreservesPendingInitialWord_data() {
        QTest::addColumn<bool>("queued");
        QTest::newRow("completed-result-held") << true;
        QTest::newRow("unfinished-worker") << false;
    }
    void unchangedLibraryClosePreservesPendingInitialWord() {
        QFETCH(bool, queued);
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        QThreadPool *pool = QThreadPool::globalInstance();
        const int originalMaximum = pool->maxThreadCount();
        QSemaphore entered, release;
        QFuture<void> blocker;
        if (!queued) {
            pool->setMaxThreadCount(1);
            blocker = QtConcurrent::run([&] { entered.release(); release.acquire(); });
        }
        auto unblock = qScopeGuard([&] {
            if (!queued) { release.release(); blocker.waitForFinished(); pool->setMaxThreadCount(originalMaximum); }
        });
        if (!queued) QVERIFY(entered.tryAcquire(1, 30000));
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QPointer<QFutureWatcherBase> pending;
        if (queued) {
            const auto watchers = window.findChildren<QFutureWatcherBase *>();
            QVERIFY(!watchers.isEmpty()); pending = watchers.last();
            pending->blockSignals(true);
            QTRY_VERIFY_WITH_TIMEOUT(pending->isFinished(), 30000);
            QCoreApplication::sendPostedEvents(pending.data());
        }
        bool inside = false;
        QTimer::singleShot(0, &window, [&] {
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
            auto close = qScopeGuard([&] { dialog->done(QDialog::Rejected); });
            QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
            if (queued) {
                QVERIFY(pending); pending->blockSignals(false);
                QVERIFY(QMetaObject::invokeMethod(pending.data(), "finished", Qt::DirectConnection));
            }
            inside = true;
            QVERIFY(window.loading_ && !window.api_ && window.currentEntry_.isEmpty());
        });
        window.chooseRoot();
        QVERIFY(inside);
        if (!queued) {
            QVERIFY(window.loading_ && !window.api_);
            // Existing held worker makes this loading state deterministic.
            window.resize(780, 480);
            QCoreApplication::processEvents();
            auto *sidebar = window.findChild<QScrollArea *>(QStringLiteral("readerSidebarScroll"));
            QVERIFY(sidebar);
            QVERIFY(window.results_->height() >= window.results_->minimumSizeHint().height());
            QPushButton *settings = nullptr;
            for (QPushButton *button : sidebar->findChildren<QPushButton *>()) {
                QVERIFY(button->height() >= button->minimumSizeHint().height());
                QVERIFY(button->width() >= button->minimumSizeHint().width());
                if (button->text() == QStringLiteral("Settings")) settings = button;
            }
            QVERIFY(settings);
            QCOMPARE(sidebar->horizontalScrollBar()->maximum(), 0);
            sidebar->verticalScrollBar()->setValue(0);
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-held-loading.png")));
            window.activateWindow();
            window.cancelOpening_->setFocus();
            QTRY_VERIFY(window.cancelOpening_->hasFocus());
            for (int steps = 0; steps < 24 && !settings->hasFocus(); ++steps)
                QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
            QTRY_VERIFY(settings->hasFocus());
            QTRY_VERIFY(sidebar->viewport()->rect().contains(QRect(settings->mapTo(sidebar->viewport(), QPoint()), settings->size())));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-held-loading-keyboard.png")));
            release.release(); blocker.waitForFinished();
        }
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.originRoot_, QFileInfo(fixture_).canonicalFilePath());
        QCOMPARE(window.originEdition_, LibraryStorage::editionIdentity(fixture_));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(!window.cancelOpening_->isVisible());
    }

    void namespaceOnlyFolderOpensWithoutLanguageManifest() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-namespace-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        QVERIFY(QFile::copy(fixture_ + QStringLiteral("/thesaurus.wikblb"), root + QStringLiteral("/thesaurus.wikblb")));
        QVERIFY(!QFileInfo::exists(root + QStringLiteral("/languages.tsv")));
        MainWindow window(root);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY2(window.api_ != nullptr, qPrintable(window.resultStatus_->text()));
        QCOMPARE(window.api_->kind(), QStringLiteral("thesaurus"));
        QVERIFY(window.search_->isEnabled());
        QTest::keyClicks(window.search_, "cat");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("thesaurus"));
    }


    void supplementalOnlyFolderPreservesUnicodeNamespaces() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-supplemental-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        QVERIFY(QFile::copy(fixture_ + QStringLiteral("/supplemental.wikblb"), root + QStringLiteral("/supplemental.wikblb")));
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(window.api_->kind(), QStringLiteral("supplemental"));
        window.search_->setText(QStringLiteral("ANNEXE:É"));
        QTRY_COMPARE(window.results_->count(), 1);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("Annexe:école"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Annexe:école")));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("supplemental"));
        window.search_->setText(QStringLiteral("APPENDIX:É"));
        QTRY_COMPARE(window.results_->count(), 1);
        QTRY_COMPARE(window.results_->item(0)->data(Qt::UserRole).toString(), QStringLiteral("Appendix:école"));
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("Appendix:école"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Appendix:école")));
    }

    void importedAliasesFollowOneEdgeAndRenderMissingTargets() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-aliases-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        const auto progress = [](const QString &, qint64, qint64) {};
        for (const QString &file : {
                QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("supplemental.wikblb"), QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *prepared);
        }
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.search_->setText(QStringLiteral("CATS"));
        QTRY_COMPARE(window.results_->count(), 1);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("source_title")).toString(), QStringLiteral("Cats"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Redirected from Cats")));
        window.openWord(QStringLiteral("Loop A"));
        QTRY_COMPARE(title(window), QStringLiteral("Loop B"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("alias"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Redirected from Loop A")));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("cat")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        window.openWord(QStringLiteral("Missing"));
        QTRY_COMPARE(title(window), QStringLiteral("Missing"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("not installed")));
        const int supplemental = window.kind_->findData(QStringLiteral("supplemental"));
        QVERIFY(supplemental >= 0); window.kind_->setCurrentIndex(supplemental);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->kind() == QStringLiteral("supplemental"), 30000);
        window.openWord(QStringLiteral("Annexe:École"));
        QTRY_COMPARE(title(window), QStringLiteral("Annexe:école"));
    }

    void searchAliasFragmentUnfoldsDestinationAndExplicitLinkWins() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-alias-fragment-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        const auto progress = [](const QString &, qint64, qint64) {};
        for (const QString &file : {
                QStringLiteral("fragment-cases/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *prepared);
        }
        MainWindow window(root); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.learning_.setCollapseEtymology(true);
        window.search_->setText(QStringLiteral("History of cat"));
        QTRY_COMPARE(window.results_->count(), 1);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const int etymologyChoice = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(etymologyChoice >= 0);
        const int etymologySection = window.sections_->itemData(etymologyChoice).toInt();
        QCOMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("fragment")).toString(), QStringLiteral("Etymology"));
        QVERIFY(!window.collapsedSections_.contains(etymologySection));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Historical source.")));
        QVERIFY(window.reading_->verticalScrollBar()->value() > 0);

        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Alias noun destination")},
            {QStringLiteral("target"), QStringLiteral("History of cat#Noun")}}});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:History%20of%20cat%23Noun")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.collapsedSections_.contains(etymologySection));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("A small animal.")));

        QVERIFY(window.openWord(QStringLiteral("History of cat"), QStringLiteral("No such section")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // An explicit missing fragment never falls back to the alias fragment.
        QVERIFY(window.openWord(QStringLiteral("History of cat"), QStringLiteral("")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // Explicit empty fragments also suppress alias fallback.
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QVERIFY(window.collapsedSections_.contains(etymologySection)); // Fragment-free aliases retain normal folding.
        QVERIFY(window.openWord(QStringLiteral("Loop A")));
        QCOMPARE(title(window), QStringLiteral("Loop B"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("alias")); // Still one edge.
    }

    void repeatedOwnerLanguageSectionsKeepOneMenuChoiceAndOriginalAnchors() {
        MainWindow window(fixture_); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("title"), QStringLiteral("YYA"));
        entry.insert(QStringLiteral("kind"), QStringLiteral("language"));
        entry.insert(QStringLiteral("language"), QStringLiteral("Finnish"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{});
        const QJsonArray overview{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("See also: ")}},
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("yya")}, {QStringLiteral("target"), QStringLiteral("yya")}}
            }}
        }};
        const auto section = [](int level, const QString &title, const QJsonArray &blocks = QJsonArray{}) {
            return QJsonObject{{QStringLiteral("level"), level}, {QStringLiteral("title"), title}, {QStringLiteral("blocks"), blocks}};
        };
        // Current YYA has an owner-language overview, an empty owner heading, and these lexical sections.
        entry.insert(QStringLiteral("sections"), QJsonArray{
            section(2, QStringLiteral("Finnish"), overview), section(2, QStringLiteral("Finnish")),
            section(3, QStringLiteral("Etymology")), section(3, QStringLiteral("Proper noun")), section(4, QStringLiteral("Declension")),
            section(3, QStringLiteral("Etymology")), // Ordinary duplicate headings retain both original indices.
            section(2, QStringLiteral("English")), section(2, QStringLiteral("English")) // Non-owner L2 duplicates also remain.
        });
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QStringList choices; QList<int> indices;
        for (int i = 1; i < window.sections_->count(); ++i) {
            choices.append(window.sections_->itemText(i)); indices.append(window.sections_->itemData(i).toInt());
        }
        QCOMPARE(choices, QStringList({QStringLiteral("Finnish"), QStringLiteral("Etymology"), QStringLiteral("Proper noun"),
            QStringLiteral("Declension"), QStringLiteral("Etymology"), QStringLiteral("English"), QStringLiteral("English")}));
        QCOMPARE(indices, QList<int>({0, 2, 3, 4, 5, 6, 7}));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("English")), 2);
        QVERIFY(window.reading_->document()->find(QStringLiteral("Finnish")).isNull());
        const QTextCursor firstEnglish = window.reading_->document()->find(QStringLiteral("English"));
        const QTextCursor secondEnglish = window.reading_->document()->find(QStringLiteral("English"), firstEnglish);
        QVERIFY(!firstEnglish.isNull() && !secondEnglish.isNull());
        QCOMPARE(firstEnglish.charFormat().anchorHref(), QStringLiteral("section:6"));
        QCOMPARE(secondEnglish.charFormat().anchorHref(), QStringLiteral("section:7"));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:6")));
        QVERIFY(window.collapsedSections_.contains(6));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("See also: yya")), 1);
        QVERIFY(window.reading_->toHtml().contains(QStringLiteral("dict:yya")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-0")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-1")));
        window.collapsedSections_.insert(0); window.refreshReading();
        window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(!window.collapsedSections_.contains(0));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("See also: yya")));
        for (int index : {2, 5, 6, 7}) window.collapsedSections_.insert(index);
        window.refreshReading();
        window.jumpToFragment(QStringLiteral("Etymology"));
        QVERIFY(window.collapsedSections_.contains(2) && window.collapsedSections_.contains(5));
        window.jumpToFragment(QStringLiteral("English"));
        QVERIFY(window.collapsedSections_.contains(6) && window.collapsedSections_.contains(7));

        // A same-label nested heading is not an equivalent owner-language destination.
        QJsonObject nestedOwnerEntry = entry;
        QJsonArray nestedOwnerSections = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject nestedOwnerSection = nestedOwnerSections[0].toObject();
        QJsonArray nestedOwnerBlocks = overview;
        nestedOwnerBlocks.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")},
            {QStringLiteral("level"), 3}, {QStringLiteral("spans"), QJsonArray{
                QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Finnish")}}}}});
        nestedOwnerSection.insert(QStringLiteral("blocks"), nestedOwnerBlocks);
        nestedOwnerSections[0] = nestedOwnerSection;
        nestedOwnerEntry.insert(QStringLiteral("sections"), nestedOwnerSections);
        response.insert(QStringLiteral("entries"), QJsonArray{nestedOwnerEntry});
        window.renderResponse(QJsonDocument(response).toJson());
        window.collapsedSections_.insert(0); window.collapsedSections_.insert(1);
        window.refreshReading(); window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(window.collapsedSections_.contains(0) && window.collapsedSections_.contains(1));

        // A compiled owner heading is authoritative even when the menu coalesces owner labels.
        QJsonArray explicitSections = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject actualOwnerHeading = explicitSections[1].toObject();
        actualOwnerHeading.insert(QStringLiteral("anchor"), QStringLiteral("Finnish"));
        explicitSections[1] = actualOwnerHeading;
        entry.insert(QStringLiteral("sections"), explicitSections);
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        window.collapsedSections_.insert(0); window.collapsedSections_.insert(1);
        window.refreshReading(); window.jumpToFragment(QStringLiteral("Finnish"));
        QVERIFY(window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(1));
    }

    void aliasOnlyFolderUsesNeutralCollection() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-neutral-aliases-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root, fixture_ + QStringLiteral("/alias-cases/aliases.wikblb"), {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(window.api_->kind(), QStringLiteral("language"));
        window.openWord(QStringLiteral("Cats"));
        QTRY_COMPARE(title(window), QStringLiteral("Cats"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("cat")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
    }

    void aliasesOverlayAnEmptyFeatureCollection() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-empty-feature-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        QVERIFY(QFile::copy(fixture_ + QStringLiteral("/alias-cases/aliases.wikblb"), root + QStringLiteral("/aliases.wikblb")));
        QFile manifest(root + QStringLiteral("/languages.tsv")); QVERIFY(manifest.open(QIODevice::WriteOnly));
        manifest.write("heading\n"); manifest.close();
        QFile empty(root + QStringLiteral("/supplemental.wikblb")); QVERIFY(empty.open(QIODevice::WriteOnly));
        empty.write(QByteArrayLiteral("WIKBLB08") + char(7)); empty.close();
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.kind_->setCurrentIndex(window.kind_->findData(QStringLiteral("supplemental")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->kind() == QStringLiteral("supplemental"), 30000);
        window.openWord(QStringLiteral("Annexe:École"));
        QTRY_COMPARE(title(window), QStringLiteral("Annexe:École"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Annexe:école")));
    }

    void invalidCompiledImportPreservesReaderAndHistory() {
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QTemporaryDir directory(QStringLiteral(".tmp/ui-invalid-compiled-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.filePath(QStringLiteral("library"))).absolutePath();
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root,
            fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
            {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        QFile original(prepared->dictionary.path); QVERIFY(original.open(QIODevice::ReadOnly));
        const QByteArray originalBytes = original.readAll(); original.close();
        QFile manifest(root + QStringLiteral("/languages.tsv")); QVERIFY(manifest.open(QIODevice::ReadOnly));
        const QByteArray manifestBytes = manifest.readAll(); manifest.close();
        QFile fixture(fixture_ + QStringLiteral("/alias-cases/aliases.wikblb"));
        QVERIFY(fixture.open(QIODevice::ReadOnly));
        QByteArray aliasBytes = fixture.readAll();
        const qsizetype presentation = aliasBytes.indexOf("DPR2");
        QVERIFY(presentation >= 0 && presentation + 8 <= aliasBytes.size());
        for (qsizetype i = 4; i < 8; ++i) aliasBytes[presentation + i] = char(255);
        // A valid first record, then a framed but incomplete second presentation.
        QByteArray ordinary = QByteArrayLiteral("WIKBLB08") + char(1) + QByteArray("en\0English\0apple\0", 17);
        ordinary.append(char(32)); ordinary.append("DPR2", 4); ordinary.append(QByteArray(28, '\0'));
        ordinary.append("banana", 6); ordinary.append('\0'); ordinary.append(char(4)); ordinary.append("DPR2", 4);
        const QVariant sources = QSettings().value(QStringLiteral("library/catalogSources"));
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
        MainWindow window(root, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QVERIFY(window.openWord(QStringLiteral("dog")));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        window.saveVisit();
        const QByteArray json = window.currentJson_;
        const QString reading = window.reading_->toPlainText();
        const auto visits = window.visits_;
        const int visitIndex = window.visitIndex_;
        for (const bool alias : {false, true}) {
            const QString source = directory.filePath(alias ? QStringLiteral("bad-alias.wikblb") : QStringLiteral("bad-later-record.wikblb"));
            QFile candidate(source); QVERIFY(candidate.open(QIODevice::WriteOnly));
            const QByteArray bytes = alias ? aliasBytes : ordinary;
            QCOMPARE(candidate.write(bytes), bytes.size()); candidate.close();
            bool completed = false;
            QTimer::singleShot(0, &window, [&] {
                auto *dialog = static_cast<LibraryDialog *>(QApplication::activeModalWidget());
                QVERIFY(dialog && dialog->objectName() == QStringLiteral("libraryDialog"));
                auto close = qScopeGuard([dialog] { dialog->done(QDialog::Rejected); });
                QTRY_VERIFY_WITH_TIMEOUT(!dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"))->isVisible(), 30000);
                auto *status = dialog->findChild<QLabel *>(QStringLiteral("libraryStatus"));
                auto *progress = dialog->findChild<QProgressBar *>(QStringLiteral("libraryProgress"));
                auto *importButton = dialog->findChild<QPushButton *>(QStringLiteral("importDictionary"));
                QVERIFY(status && progress && importButton);
                dialog->startImport(source); // Real import worker and native semantic decoder, no injected refusal.
                const QString invalidMessage = QStringLiteral("Could not import this dictionary. The file contains invalid entry data.");
                QTRY_VERIFY2_WITH_TIMEOUT(status->text() == invalidMessage && !progress->isVisible(), qPrintable(status->text()), 30000);
                QVERIFY(status->property("validationDiagnostic").toString().contains(QStringLiteral("InvalidPresentation")));
                QVERIFY(!status->text().contains(QStringLiteral("InvalidPresentation")));
                auto *guidance = dialog->findChild<QLabel *>(QStringLiteral("availableDictionariesSummary"));
                auto *addSource = dialog->findChild<QPushButton *>(QStringLiteral("addCatalogueSource"));
                auto *refresh = dialog->findChild<QPushButton *>(QStringLiteral("refreshCatalogues"));
                QVERIFY(guidance && addSource && refresh);
                QCOMPARE(guidance->text(), QStringLiteral("Add a source to browse available dictionaries."));
                QVERIFY(addSource->isEnabled() && !refresh->isEnabled());
                QVERIFY(importButton->isEnabled());
                QVERIFY(!dialog->libraryChanged() && !dialog->originalRootChanged());
                QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-semantic-import-%1-plain-error.png").arg(alias ? QStringLiteral("alias") : QStringLiteral("later-record"))));
                completed = true;
            });
            window.chooseRoot();
            QVERIFY(completed);
            QVERIFY(!window.loading_ && window.api_ && window.search_->isEnabled());
            QCOMPARE(window.api_->root(), root);
            QCOMPARE(window.currentJson_, json);
            QCOMPARE(window.reading_->toPlainText(), reading);
            QCOMPARE(window.visitIndex_, visitIndex);
            QCOMPARE(window.visits_.size(), visits.size());
            for (qsizetype i = 0; i < visits.size(); ++i) {
                QCOMPARE(window.visits_[i].title, visits[i].title);
                QCOMPARE(window.visits_[i].language, visits[i].language);
                QCOMPARE(window.visits_[i].kind, visits[i].kind);
                QCOMPARE(window.visits_[i].scroll, visits[i].scroll);
                QCOMPARE(window.visits_[i].collapsed, visits[i].collapsed);
            }
            QVERIFY(original.open(QIODevice::ReadOnly)); QCOMPARE(original.readAll(), originalBytes); original.close();
            QVERIFY(manifest.open(QIODevice::ReadOnly)); QCOMPARE(manifest.readAll(), manifestBytes); manifest.close();
            QCOMPARE(LibraryStorage::installed(root).size(), qsizetype(1));
            QVERIFY(!QFileInfo::exists(root + QStringLiteral("/aliases.wikblb")));
        }
        window.navigate(-1);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
    }

    void initialBomSurvivesLanguageAndTitleJsonBoundaries() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-bom-identities-XXXXXX"));
        QVERIFY(directory.isValid());
        QFile fixture(fixture_ + QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"));
        QVERIFY(fixture.open(QIODevice::ReadOnly));
        const QByteArray original = fixture.readAll();
        qsizetype at = 9;
        for (int i = 0; i < 3; ++i) { at = original.indexOf('\0', at) + 1; QVERIFY(at > 0); }
        const qsizetype lengthStart = at;
        quint64 length = 0;
        for (int shift = 0; ; shift += 7) {
            QVERIFY(at < original.size() && shift < 64);
            const auto byte = static_cast<unsigned char>(original[at++]);
            length |= quint64(byte & 127) << shift;
            if (!(byte & 128)) break;
        }
        QVERIFY(length <= quint64(original.size() - at));
        const QByteArray bom = QByteArray::fromHex("efbbbf");
        const QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) + QByteArrayLiteral("en\0") + bom +
            QByteArrayLiteral("English\0") + bom + QByteArrayLiteral("cat\0") + original.mid(lengthStart, at - lengthStart + qsizetype(length));
        const QString source = directory.filePath(QStringLiteral("source.wikblb"));
        QFile file(source); QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write(bytes), bytes.size()); file.close();
        const QString root = directory.filePath(QStringLiteral("library"));
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(window.language_->currentText(), QChar(0xfeff) + QStringLiteral("English"));
        const QString exact = QChar(0xfeff) + QStringLiteral("cat");
        window.search_->setText(exact);
        QTRY_COMPARE(window.results_->count(), 1);
        QTRY_COMPARE(window.results_->item(0)->data(Qt::UserRole).toString(), exact);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), exact);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTest::mouseClick(window.bookmark_, Qt::LeftButton);
        LearningStore reopened;
        QCOMPARE(reopened.bookmarks().size(), 1);
        QCOMPARE(reopened.bookmarks().first().title, exact);
        QCOMPARE(reopened.bookmarks().first().language, QChar(0xfeff) + QStringLiteral("English"));
        QVERIFY(!reopened.history().isEmpty());
        QCOMPARE(reopened.history().first().title, exact);
        QCOMPARE(reopened.history().first().language, QChar(0xfeff) + QStringLiteral("English"));
    }

    void attributionUsesKnownEditionAndFullTitlesOnly() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-source-edition-XXXXXX"));
        QVERIFY(directory.isValid());
        MainWindow window(fixture_); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject entry{{QStringLiteral("kind"), QStringLiteral("language")}, {QStringLiteral("title"), QStringLiteral("école")}};
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("href='https://www.wiktionary.org/'")));
        const QString root = QDir(directory.path()).absolutePath();
        QFile marker(root + QStringLiteral("/.desktop-edition")); QVERIFY(marker.open(QIODevice::WriteOnly));
        marker.write("arwiktionary-20261001\n"); marker.close();
        window.api_ = std::make_unique<DictApi>(root);
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("https://ar.wiktionary.org/wiki/%C3%A9cole")));
        entry.insert(QStringLiteral("kind"), QStringLiteral("rhymes"));
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("href='https://ar.wiktionary.org/'")));
        entry.insert(QStringLiteral("redirect"), QJsonObject{{QStringLiteral("followed"), true}, {QStringLiteral("target_title"), QStringLiteral("قافية:école")}});
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("https://ar.wiktionary.org/wiki/%D9%82%D8%A7%D9%81%D9%8A%D8%A9%3A%C3%A9cole")));
    }

    void startupKeepsUiResponsiveAndOpensRequestedWord() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        QVERIFY(window.loading_);
        QVERIFY(!window.search_->isEnabled());
        window.show();
        bool processedEvent = false;
        QTimer::singleShot(0, &window, [&] { processedEvent = true; });
        QTRY_VERIFY(processedEvent);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.search_->isEnabled());
    }

    void searchPagesHaveNoMissingOrDuplicateWords() {
        MainWindow window(fixture_);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.search_->setFocus();
        QTest::keyClicks(window.search_, "page");
        QTRY_COMPARE(window.results_->count(), 80);
        QCOMPARE(window.results_->item(0)->data(Qt::UserRole).toString(), QStringLiteral("page001"));
        QCOMPARE(window.results_->item(79)->data(Qt::UserRole).toString(), QStringLiteral("page080"));
        QVERIFY(window.moreResults_->isEnabled());
        QTest::mouseClick(window.moreResults_, Qt::LeftButton);
        QTRY_COMPARE(window.results_->count(), 160);
        QTest::mouseClick(window.moreResults_, Qt::LeftButton);
        QTRY_COMPARE(window.results_->count(), 180);
        QVERIFY(!window.moreResults_->isEnabled());
        QSet<QString> words;
        for (int i = 0; i < window.results_->count(); ++i) words.insert(window.results_->item(i)->data(Qt::UserRole).toString());
        QCOMPARE(words.size(), 180);
        QVERIFY(words.contains(QStringLiteral("page180")));
        QTest::keyClick(window.search_, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClicks(window.search_, "PAGE");
        QTRY_COMPARE(window.results_->count(), 80);
        QCOMPARE(window.results_->item(0)->data(Qt::UserRole).toString(), QStringLiteral("page001"));
    }

    void explicitLanguageFragmentSelectsInstalledOwnerAndPreservesNavigation() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-language-fragments-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString word = QString::fromUtf8("κρώζω");
        const QString modernOnly = QStringLiteral("modern-only");
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {word, modernOnly},
            QByteArrayLiteral("el"), QByteArrayLiteral("Greek")));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(), {word},
            QByteArrayLiteral("grc"), QByteArrayLiteral("Ancient Greek"), true));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition"));
        QVERIFY(edition.open(QIODevice::WriteOnly));
        const QByteArray editionBytes = QByteArrayLiteral("enwiktionary-20261001\n");
        QCOMPARE(edition.write(editionBytes), qint64(editionBytes.size()));
        edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, word); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        const QString originalRoot = window.originRoot_;
        const QString originalEdition = window.originEdition_;
        const QString greekKey = window.savedWord(window.currentEntry_).key;
        const auto follow = [&](const QString &target) {
            QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(word)).object();
            QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
            QJsonArray preamble = entry.value(QStringLiteral("preamble_spans")).toArray();
            preamble.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("Follow owner or section")}, {QStringLiteral("target"), target}});
            entry.insert(QStringLiteral("preamble_spans"), preamble);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), false);
            return clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target)));
        };
        QTRY_VERIFY(window.search_->hasFocus()); // Ordinary dataset opening keeps search ready.
        window.reading_->setFocus();
        QTRY_VERIFY(window.reading_->hasFocus());
        QVERIFY(follow(word + QStringLiteral("#Ancient_Greek")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.currentEntry_.value(QStringLiteral("language")).toString(), QStringLiteral("Ancient Greek"));
        QTRY_VERIFY(window.reading_->hasFocus()); // The link destination retains reader focus.
        QCOMPARE(window.language_->currentText(), QStringLiteral("Ancient Greek"));
        QCOMPARE(window.originRoot_, originalRoot);
        QCOMPARE(window.originEdition_, originalEdition);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.savedWord(window.currentEntry_).key != greekKey);
        QVERIFY(window.back_->isEnabled());
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QCOMPARE(window.savedWord(window.currentEntry_).key, greekKey);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));

        const unsigned serial = window.loadSerial_;
        QVERIFY(follow(word + QStringLiteral("#Etymology")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Ancient Greek"));
        const int row = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(row >= 0);
        QVERIFY(!window.collapsedSections_.contains(window.sections_->itemData(row).toInt()));
        QTRY_VERIFY(window.reading_->hasFocus()); // Same-owner section links follow the same contract.
        QVERIFY(follow(word + QStringLiteral("#Missing_owner")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Ancient Greek"));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), word);
        const int historyCount = window.learning_.history().size();
        QVERIFY(follow(modernOnly + QStringLiteral("#Ancient_Greek")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Ancient Greek"), 30000);
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(window.search_->text(), modernOnly);
        QTRY_VERIFY(window.search_->hasFocus()); // Missing destinations keep search recovery available.
        QCOMPARE(window.learning_.history().size(), historyCount);
    }

    void ordinaryLinksFallBackOnlyToExactSameEditionUnclassified() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-unclassified-links-XXXXXX"));
        QVERIFY(directory.isValid());
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("source"), QStringLiteral("Shared")}, QByteArrayLiteral("el"), QByteArrayLiteral("Greek")));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("fallback"), QStringLiteral("Shared")}, QByteArrayLiteral("und"), QByteArrayLiteral("Unclassified"), true));
        QVERIFY(prepareCaseTitleFixture(fixture_, directory.path(),
            {QStringLiteral("foreign-only")}, QByteArrayLiteral("fr"), QByteArrayLiteral("French"), true));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition"));
        QVERIFY(edition.open(QIODevice::WriteOnly));
        const QByteArray editionBytes = QByteArrayLiteral("enwiktionary-20261001\n");
        QCOMPARE(edition.write(editionBytes), qint64(editionBytes.size()));
        edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, QStringLiteral("source")); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        const QString originRoot = window.originRoot_, originEdition = window.originEdition_;
        const QString sourceKey = window.savedWord(window.currentEntry_).key;
        const auto follow = [&](const QString &target) {
            QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(title(window))).object();
            QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
            QJsonArray spans = entry.value(QStringLiteral("preamble_spans")).toArray();
            spans.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("Follow installed target")}, {QStringLiteral("target"), target}});
            entry.insert(QStringLiteral("preamble_spans"), spans);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), false);
            return clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target)));
        };
        // The current owner's case retry wins over an equally named fallback record.
        const unsigned initialSerial = window.loadSerial_;
        QVERIFY(follow(QStringLiteral("shared")));
        QCOMPARE(window.loadSerial_, initialSerial);
        QCOMPARE(title(window), QStringLiteral("Shared"));
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.openWord(QStringLiteral("source")));
        QVERIFY(follow(QStringLiteral("fallback#Etymology")));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QCOMPARE(title(window), QStringLiteral("fallback"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A river animal.")));
        QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);
        QCOMPARE(window.language_->currentText(), QStringLiteral("Unclassified"));
        QTRY_VERIFY(window.reading_->hasFocus());
        const int section = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(section >= 0);
        QVERIFY(!window.collapsedSections_.contains(window.sections_->itemData(section).toInt()));
        QVERIFY(window.savedWord(window.currentEntry_).key != sourceKey);
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QCOMPARE(title(window), QStringLiteral("source"));
        QCOMPARE(window.savedWord(window.currentEntry_).key, sourceKey);
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QCOMPARE(title(window), QStringLiteral("fallback"));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QCOMPARE(title(window), QStringLiteral("source"));

        // A default search, explicit current-owner fragment, and another installed
        // language must not borrow an Unclassified or arbitrary-language target.
        unsigned serial = window.loadSerial_;
        QVERIFY(!window.openWord(QStringLiteral("fallback")));
        QCOMPARE(window.loadSerial_, serial);
        QVERIFY(follow(QStringLiteral("fallback#Greek")));
        QCOMPARE(window.loadSerial_, serial);
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        for (const QString &target : {QStringLiteral("FALLBACK"), QStringLiteral("foreign-only"), QStringLiteral("absent")}) {
            const int visitIndex = window.visitIndex_, visitCount = window.visits_.size();
            const int historyCount = window.learning_.history().size();
            QVERIFY(follow(target));
            const QJsonObject entry = window.currentEntry_;
            QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
            QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
            QCOMPARE(window.currentEntry_, entry);
            QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);
            QCOMPARE(window.visitIndex_, visitIndex); QCOMPARE(window.visits_.size(), visitCount);
            QCOMPARE(window.learning_.history().size(), historyCount);
            QCOMPARE(QSettings().value(QStringLiteral("reader/language")).toString(), QStringLiteral("Greek"));
            QVERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        }

        // Cancellation before publication cannot install a stale fallback owner.
        const QString body = window.reading_->toPlainText();
        QVERIFY(QMetaObject::invokeMethod(window.reading_, "anchorClicked", Qt::DirectConnection,
            Q_ARG(QUrl, QUrl(QStringLiteral("dict:fallback")))));
        QVERIFY(window.loading_);
        const auto watchers = window.findChildren<QFutureWatcherBase *>();
        QVERIFY(!watchers.isEmpty()); const QPointer<QFutureWatcherBase> pending = watchers.last();
        window.cancelOpening_->click();
        QVERIFY(!window.loading_);
        QTRY_VERIFY_WITH_TIMEOUT(!pending || pending->isFinished(), 30000);
        QCoreApplication::processEvents();
        QCOMPARE(window.api_->language(), QStringLiteral("Greek"));
        QCOMPARE(title(window), QStringLiteral("source"));
        QCOMPARE(window.reading_->toPlainText(), body);
        QCOMPARE(window.originRoot_, originRoot); QCOMPARE(window.originEdition_, originEdition);

        // Empty/legacy edition identity and alias-origin presentation stay excluded.
        const auto assertNoFallback = [&] {
            const unsigned before = window.loadSerial_;
            QMetaObject::invokeMethod(window.reading_, "anchorClicked", Qt::DirectConnection,
                Q_ARG(QUrl, QUrl(QStringLiteral("dict:fallback"))));
            return !window.loading_ && window.loadSerial_ == before && window.api_->language() == QStringLiteral("Greek");
        };
        window.currentEntry_.insert(QStringLiteral("redirect"), QJsonObject{{QStringLiteral("followed"), true}});
        QVERIFY(assertNoFallback());
        window.currentEntry_.remove(QStringLiteral("redirect"));
        window.currentEntry_.insert(QStringLiteral("kind"), QStringLiteral("alias"));
        QVERIFY(assertNoFallback());
        window.currentEntry_.insert(QStringLiteral("kind"), QStringLiteral("language"));
        window.originEdition_.clear();
        QVERIFY(assertNoFallback());
    }

    void keyboardBackRestoresReaderLinkContext() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-keyboard-history-XXXXXX"));
        QVERIFY(directory.isValid());
        // A persistent native DPR2 fixture: three distinct ordinary links in the
        // preamble survive the real lookup performed when Back rebuilds HTML.
        const auto u32 = [](QByteArray &out, quint32 value) {
            for (int shift = 0; shift < 32; shift += 8) out.append(char(value >> shift));
        };
        const auto string = [&](QByteArray &out, const QByteArray &value) {
            u32(out, quint32(value.size())); out += value;
        };
        QByteArray presentation = QByteArrayLiteral("DPR2");
        u32(presentation, 0); // display title
        u32(presentation, 0); // sections
        u32(presentation, 3); // preamble spans
        for (const QByteArray &target : {QByteArray("same"), QByteArray("fallback"), QByteArray("neighbor")}) {
            presentation += QByteArray::fromHex("010000"); // link, normal, no flags
            string(presentation, target); string(presentation, target);
            for (int field = 0; field < 4; ++field) string(presentation, {});
        }
        for (int count = 0; count < 4; ++count) u32(presentation, 0); // layout, refs, media
        const auto install = [&](const QByteArray &code, const QByteArray &owner, const QStringList &titles) {
            QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) + code + '\0' + owner + '\0';
            for (const QString &word : titles) {
                bytes += word.toUtf8() + '\0';
                quint64 length = quint64(presentation.size());
                do { const auto byte = static_cast<unsigned char>(length & 127); length >>= 7;
                    bytes += char(byte | (length ? 128 : 0)); } while (length);
                bytes += presentation;
            }
            QFile source(directory.path() + QStringLiteral("/history-") + QString::fromUtf8(code) + QStringLiteral(".wikblb"));
            if (!source.open(QIODevice::WriteOnly) || source.write(bytes) != bytes.size()) return false;
            source.close(); std::atomic_bool cancelled = false;
            auto prepared = LibraryStorage::prepareImport(directory.path() + QStringLiteral("/library"), source.fileName(), {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(directory.path() + QStringLiteral("/library"), *prepared);
            return true;
        };
        QVERIFY(install("el", "Greek", {QStringLiteral("same"), QStringLiteral("source")}));
        QVERIFY(install("und", "Unclassified", {QStringLiteral("fallback"), QStringLiteral("neighbor")}));
        const QString root = directory.path() + QStringLiteral("/library");
        QFile edition(root + QStringLiteral("/.desktop-edition")); QVERIFY(edition.open(QIODevice::WriteOnly));
        QCOMPARE(edition.write("enwiktionary-20261001\n"), qint64(22)); edition.close();
        QSettings().setValue(QStringLiteral("reader/language"), QStringLiteral("Greek"));
        MainWindow window(root, QStringLiteral("source")); window.show(); window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        const auto key = [&](Qt::Key value, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            QWidget *focused = QApplication::focusWidget();
            if (!focused || !window.isAncestorOf(focused)) return false;
            QTest::keyClick(focused, value, modifiers); return true;
        };
        const auto href = [&] { return window.reading_->textCursor().charFormat().anchorHref(); };
        window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
        // Select the second anchor by actual Tab traversal, not cursor injection.
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:fallback"));
        const int position = window.reading_->textCursor().position();
        const int anchor = window.reading_->textCursor().anchor();
        const int scroll = window.reading_->verticalScrollBar()->value();
        QVERIFY(key(Qt::Key_Return));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("fallback"));
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.reading_->hasFocus());
        QCOMPARE(window.reading_->textCursor().position(), position);
        QCOMPARE(window.reading_->textCursor().anchor(), anchor);
        QCOMPARE(window.reading_->verticalScrollBar()->value(), scroll);
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:neighbor"));
        QVERIFY(key(Qt::Key_Return));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Unclassified"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("neighbor"));
        // Same-owner history uses the same public cursor reconstruction path.
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->language() == QStringLiteral("Greek"), 30000);
        QTRY_COMPARE(title(window), QStringLiteral("source"));
        QVERIFY(key(Qt::Key_Backtab, Qt::ShiftModifier));
        QVERIFY(key(Qt::Key_Backtab, Qt::ShiftModifier)); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Return)); QTRY_COMPARE(title(window), QStringLiteral("same"));
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier)); QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.reading_->hasFocus()); QTRY_COMPARE(href(), QStringLiteral("dict:same"));
        QVERIFY(key(Qt::Key_Tab)); QTRY_COMPARE(href(), QStringLiteral("dict:fallback"));
        // Revisiting a search-origin visit must not steal focus into the reader.
        window.search_->setText(QStringLiteral("same")); window.search_->setFocus();
        QTRY_VERIFY(window.search_->hasFocus());
        QVERIFY(key(Qt::Key_Return)); QTRY_COMPARE(title(window), QStringLiteral("same"));
        for (int step = 0; step < 64 && !window.reading_->hasFocus(); ++step)
            QVERIFY(key(Qt::Key_Tab));
        QTRY_VERIFY(window.reading_->hasFocus());
        QVERIFY(key(Qt::Key_Left, Qt::AltModifier)); QTRY_COMPARE(title(window), QStringLiteral("source"));
        QTRY_VERIFY(window.search_->hasFocus());
    }

    void exactSearchPreservesExplicitSelection_data() {
        QTest::addColumn<QString>("action");
        QTest::addColumn<bool>("typeSecond");
        QTest::addColumn<int>("expectedRow");
        QTest::newRow("typed-exact") << QStringLiteral("typed") << true << 1;
        QTest::newRow("arrow-down-unchanged-row-zero") << QStringLiteral("down") << true << 0;
        QTest::newRow("arrow-up-transfer-last-row") << QStringLiteral("up") << false << 1;
        QTest::newRow("list-down") << QStringLiteral("list-down") << false << 1;
        QTest::newRow("list-up") << QStringLiteral("list-up") << true << 0;
        QTest::newRow("home") << QStringLiteral("home") << true << 0;
        QTest::newRow("end") << QStringLiteral("end") << false << 1;
        QTest::newRow("page-up") << QStringLiteral("page-up") << true << 0;
        QTest::newRow("page-down") << QStringLiteral("page-down") << false << 1;
        QTest::newRow("mouse-alternate") << QStringLiteral("mouse") << false << 1;
        QTest::newRow("list-enter-alternate") << QStringLiteral("list-enter") << false << 1;
    }

    void exactSearchPreservesExplicitSelection() {
        QFETCH(QString, action);
        QFETCH(bool, typeSecond);
        QFETCH(int, expectedRow);
        QTemporaryDir directory(QStringLiteral(".tmp/ui-exact-selection-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        QVERIFY(prepareCaseTitleFixture(fixture_, path, {QStringLiteral("Apple"), QStringLiteral("apple")}));
        MainWindow window(path + QStringLiteral("/library"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        window.search_->setText(QStringLiteral("app"));
        QTRY_COMPARE(window.resultsQuery_, QStringLiteral("app"));
        QTRY_COMPARE(window.results_->count(), 2);
        const QString first = window.results_->item(0)->data(Qt::UserRole).toString();
        const QString second = window.results_->item(1)->data(Qt::UserRole).toString();
        QVERIFY(first != second);
        const QString typed = typeSecond ? second : first;
        const QString expected = expectedRow == 0 ? first : second;
        window.search_->setText(typed);
        QTRY_COMPARE(window.resultsQuery_, typed);
        QTRY_COMPARE(window.results_->count(), 2);
        window.search_->setFocus();
        if (action == QStringLiteral("mouse")) {
            window.results_->scrollToItem(window.results_->item(1));
            QTest::mouseClick(window.results_->viewport(), Qt::LeftButton, Qt::NoModifier,
                window.results_->visualItemRect(window.results_->item(1)).center());
        } else {
            if (action != QStringLiteral("typed")) {
                QTest::keyClick(window.search_, action == QStringLiteral("up") ? Qt::Key_Up : Qt::Key_Down);
                if (action == QStringLiteral("list-down") || action == QStringLiteral("list-enter"))
                    QTest::keyClick(window.results_, Qt::Key_Down);
                if (action == QStringLiteral("list-up") || action == QStringLiteral("home") || action == QStringLiteral("page-up"))
                    QTest::keyClick(window.results_, Qt::Key_End);
                if (action == QStringLiteral("list-up")) QTest::keyClick(window.results_, Qt::Key_Up);
                if (action == QStringLiteral("home")) QTest::keyClick(window.results_, Qt::Key_Home);
                if (action == QStringLiteral("end")) QTest::keyClick(window.results_, Qt::Key_End);
                if (action == QStringLiteral("page-up")) QTest::keyClick(window.results_, Qt::Key_PageUp);
                if (action == QStringLiteral("page-down")) QTest::keyClick(window.results_, Qt::Key_PageDown);
                QCOMPARE(window.results_->currentRow(), expectedRow);
                if (action != QStringLiteral("list-enter"))
                    QTest::keyClick(window.results_, Qt::Key_Escape);
            }
            QTest::keyClick(action == QStringLiteral("list-enter") ? static_cast<QWidget *>(window.results_) :
                static_cast<QWidget *>(window.search_), Qt::Key_Return);
        }
        QTRY_COMPARE(title(window), expected);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));

        // A new query resets an earlier explicit choice without changing the row ordering.
        const QString next = expected == first ? second : first;
        window.search_->setText(next);
        QTRY_COMPARE(window.resultsQuery_, next);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), next);
    }

    void exactSearchFindsTitleBeyondFirstSuggestionPage() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-exact-page-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        QStringList variants;
        for (unsigned bits = 0; bits < 96; ++bits) {
            QString word = QStringLiteral("caseword");
            for (int i = 0; i < word.size(); ++i)
                if (bits & (1u << i)) word[i] = word[i].toUpper();
            variants.append(word);
        }
        QVERIFY(prepareCaseTitleFixture(fixture_, path, variants));
        MainWindow window(path + QStringLiteral("/library"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QCOMPARE(window.searchTitles_.size(), 96);
        const QString exact = window.searchTitles_.last();
        window.search_->setText(exact);
        QTRY_COMPARE(window.resultsQuery_, exact);
        QTRY_COMPARE(window.results_->count(), 80);
        QVERIFY(window.moreResults_->isEnabled());
        for (int i = 0; i < window.results_->count(); ++i)
            QVERIFY(window.results_->item(i)->data(Qt::UserRole).toString() != exact);
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), exact);
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
    }

    void enterUsesFreshSuggestionsDuringDebounce() {
        MainWindow window(fixture_);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTest::keyClicks(window.search_, "page");
        QTRY_COMPARE(window.results_->count(), 80);
        window.results_->setCurrentRow(12);
        window.search_->setFocus();
        window.searchTimer_->setInterval(1000);
        QTest::keyClick(window.search_, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClicks(window.search_, "dog");
        QVERIFY(window.searchTimer_->isActive());
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.search_->text(), QStringLiteral("dog"));

        QTest::keyClick(window.search_, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClicks(window.search_, "<b>missing</b>");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_VERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.results_->count(), 0);
        const QString literal = QStringLiteral("No exact entry for “<b>missing</b>”. Try a suggestion or another collection.");
        QCOMPARE(window.resultStatus_->text(), literal);
        // Capture the ordinary missing-word state before the isolated label-render oracle.
        window.resize(780, 480);
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-no-exact-match.png")));
        // The narrow sidebar may scroll, but the complete wrapped feedback must remain reachable.
        window.resize(580, 480);
        QCoreApplication::processEvents();
        auto *sidebar = window.findChild<QScrollArea *>(QStringLiteral("readerSidebarScroll"));
        QVERIFY(sidebar);
        QVERIFY(window.resultStatus_->wordWrap());
        QVERIFY(window.resultStatus_->heightForWidth(window.resultStatus_->width()) > 0);
        QVERIFY(window.resultStatus_->height() >= window.resultStatus_->heightForWidth(window.resultStatus_->width()));
        sidebar->ensureWidgetVisible(window.resultStatus_);
        QCoreApplication::processEvents();
        QVERIFY(sidebar->viewport()->rect().contains(QRect(window.resultStatus_->mapTo(sidebar->viewport(), QPoint()), window.resultStatus_->size())));
        QCOMPARE(sidebar->horizontalScrollBar()->maximum(), 0);
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-no-exact-match-narrow.png")));
        window.resultStatus_->setFixedSize(440, 120);
        QLabel plain(window.resultStatus_->parentWidget());
        QLabel rich(window.resultStatus_->parentWidget());
        for (QLabel *reference : {&plain, &rich}) {
            reference->setFont(window.resultStatus_->font());
            reference->setPalette(window.resultStatus_->palette());
            reference->setFixedSize(window.resultStatus_->size());
            reference->setWordWrap(window.resultStatus_->wordWrap());
            reference->setAlignment(window.resultStatus_->alignment());
            reference->setMargin(window.resultStatus_->margin());
            reference->setIndent(window.resultStatus_->indent());
            reference->setText(literal);
        }
        plain.setTextFormat(Qt::PlainText);
        rich.setTextFormat(Qt::RichText);
        const auto rendered = [](QLabel &label) {
            QImage image(label.size(), QImage::Format_ARGB32_Premultiplied);
            image.fill(Qt::transparent);
            label.render(&image);
            return image;
        };
        const QImage plainImage = rendered(plain);
        const QImage richImage = rendered(rich);
        QVERIFY(plainImage != richImage);
        QCOMPARE(rendered(*window.resultStatus_), plainImage);

        auto *accessible = QAccessible::queryAccessibleInterface(window.resultStatus_);
        QVERIFY(accessible);
        QCOMPARE(accessible->text(QAccessible::Name), literal);
        QCOMPARE(accessible->text(QAccessible::Description), QStringLiteral("Search status"));
        QTest::keyClick(window.search_, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClicks(window.search_, "cat");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.resultStatus_->text() != literal);
        QCOMPARE(accessible->text(QAccessible::Name), window.resultStatus_->text());
    }

    void keyboardTraversalUsesActualFocusAndKeepsBackReachable() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        window.activateWindow();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.search_->setText(QStringLiteral("dog"));
        QTRY_COMPARE(window.resultsQuery_, QStringLiteral("dog"));
        QTRY_VERIFY(window.results_->count() > 0);
        auto dogResultRow = [&window] {
            for (int row = 0; row < window.results_->count(); ++row)
                if (window.results_->item(row)->data(Qt::UserRole).toString() == QStringLiteral("dog"))
                    return row;
            return -1;
        };
        QTRY_VERIFY(dogResultRow() >= 0);
        const int dogRow = dogResultRow();

        // Send Qt test events only to the actual focus owner. This does not prove
        // physical keyboard delivery or a visible focus indicator.
        auto focusedKey = [&window](Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            QWidget *owner = QApplication::focusWidget();
            if (!owner || !window.isAncestorOf(owner) || !owner->isEnabled())
                return false;
            QTest::keyClick(owner, key, modifiers);
            QCoreApplication::processEvents();
            return true;
        };
        window.search_->setFocus(Qt::TabFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QVERIFY(focusedKey(Qt::Key_Tab));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QVERIFY(focusedKey(Qt::Key_Backtab, Qt::ShiftModifier));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));

        QVERIFY(focusedKey(Qt::Key_Down));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QCOMPARE(window.results_->currentRow(), 0);
        QVERIFY(focusedKey(Qt::Key_Escape));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        QVERIFY(focusedKey(Qt::Key_Down));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QCOMPARE(window.results_->currentRow(), 0);
        for (int row = 0; row < dogRow; ++row) {
            QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
            QVERIFY(focusedKey(Qt::Key_Down));
            QCOMPARE(window.results_->currentRow(), row + 1);
        }
        QCOMPARE(window.results_->currentItem()->data(Qt::UserRole).toString(), QStringLiteral("dog"));
        QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QVERIFY(focusedKey(Qt::Key_Return));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.results_));
        QTRY_VERIFY(window.back_->isEnabled());

        // Do not assume a platform-specific number of intermediate tab stops.
        window.search_->setFocus(Qt::TabFocusReason);
        QTRY_COMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.search_));
        for (int step = 0; step < 64 && QApplication::focusWidget() != window.back_; ++step)
            QVERIFY(focusedKey(Qt::Key_Tab));
        QCOMPARE(QApplication::focusWidget(), static_cast<QWidget *>(window.back_));
        QVERIFY(window.back_->isEnabled());
        QVERIFY(focusedKey(Qt::Key_Space));
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTRY_VERIFY(window.forward_->isEnabled());
        QTRY_VERIFY(QApplication::focusWidget() &&
            window.isAncestorOf(QApplication::focusWidget()) &&
            QApplication::focusWidget()->isEnabled());
    }

    void backAndForwardPreserveSelectedAliasIdentity() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-alias-back-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString root = QDir(directory.path()).absolutePath();
        std::atomic_bool cancelled = false;
        const auto progress = [](const QString &, qint64, qint64) {};
        for (const QString &file : {
                QStringLiteral("languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"),
                QStringLiteral("alias-cases/aliases.wikblb")}) {
            auto prepared = LibraryStorage::prepareImport(root, fixture_ + QChar('/') + file, {}, -1, cancelled, progress);
            LibraryStorage::commitImport(root, *prepared);
        }
        MainWindow window(root); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QVERIFY(window.openWord(QStringLiteral("Loop A")));
        QCOMPARE(title(window), QStringLiteral("Loop B"));
        QVERIFY(window.openWord(QStringLiteral("dog")));
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("Loop B"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("kind")).toString(), QStringLiteral("alias"));
        QCOMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("source_title")).toString(), QStringLiteral("Loop A"));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));

        QVERIFY(window.openWord(QStringLiteral("cat")));
        const auto ordinaryVisits = window.visits_.size();
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.visits_.size(), ordinaryVisits + 1);
        QVERIFY(window.openWord(QStringLiteral("Cats")));
        QCOMPARE(window.visits_.size(), ordinaryVisits + 1);
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.currentEntry_.value(QStringLiteral("redirect")).toObject().isEmpty());
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_COMPARE(window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("source_title")).toString(), QStringLiteral("Cats"));
        QCOMPARE(title(window), QStringLiteral("cat"));
    }

    void backAndForwardRestoreScrollAndFolds() {
        QSettings().setValue(QStringLiteral("reader/pointSize"), 24);
        LearningStore defaults;
        defaults.setCollapseEtymology(false);
        defaults.setCollapsePronunciation(false);
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const int sectionRow = window.sections_->findText(QStringLiteral("Etymology"));
        QVERIFY(sectionRow >= 0);
        const int section = window.sections_->itemData(sectionRow).toInt();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:%1").arg(section)));
        QVERIFY(window.collapsedSections_.contains(section));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QTRY_VERIFY(window.reading_->verticalScrollBar()->maximum() > 20);
        window.reading_->verticalScrollBar()->setValue(window.reading_->verticalScrollBar()->maximum() / 2);
        const int catScroll = window.reading_->verticalScrollBar()->value();

        window.openWord(QStringLiteral("dog"));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->verticalScrollBar()->value(), 0);
        window.reading_->verticalScrollBar()->setValue(window.reading_->verticalScrollBar()->maximum());
        const int dogScroll = window.reading_->verticalScrollBar()->value();
        QVERIFY(window.back_->isEnabled());
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && title(window) == QStringLiteral("cat"), 30000);
        QVERIFY(window.collapsedSections_.contains(section));
        QCOMPARE(window.reading_->verticalScrollBar()->value(), catScroll);
        QVERIFY(window.forward_->isEnabled());
        QTest::mouseClick(window.forward_, Qt::LeftButton);
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && title(window) == QStringLiteral("dog"), 30000);
        QVERIFY(window.collapsedSections_.isEmpty());
        QCOMPARE(window.reading_->verticalScrollBar()->value(), dogScroll);
    }

    void reselectingCollectionKeepsLastWordReachable() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.openWord(QStringLiteral("dog"));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        window.selectDataset();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        QVERIFY(window.currentEntry_.isEmpty());
        QVERIFY(window.back_->isEnabled());
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        QVERIFY(window.back_->isEnabled());
        QTest::mouseClick(window.back_, Qt::LeftButton);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
    }

    void compiledHeadingAnchorsSelectSectionAndStandaloneDestinations() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto text = [](const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto section = [&](const QString &anchor, const QString &body) { return QJsonObject{
            {QStringLiteral("level"), 3}, {QStringLiteral("title"), QStringLiteral("Noun")}, {QStringLiteral("anchor"), anchor},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{text(body)}}}}}}; };
        QJsonObject standalone{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
            {QStringLiteral("anchor"), QStringLiteral("Noun_4")}, {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Noun"))}}};
        QJsonObject owner = section(QStringLiteral("Noun_3"), QStringLiteral("THIRD SECTION BODY"));
        QJsonArray blocks = owner.value(QStringLiteral("blocks")).toArray();
        blocks.append(standalone);
        blocks.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("STANDALONE HEADING BODY"))}}});
        owner.insert(QStringLiteral("blocks"), blocks);
        QJsonObject second = section(QStringLiteral("Noun_2"), QStringLiteral("SECOND SECTION BODY"));
        QJsonArray secondBlocks = second.value(QStringLiteral("blocks")).toArray();
        secondBlocks.prepend(QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 3},
            {QStringLiteral("anchor"), QStringLiteral("Noun_2")}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Noun")},
                {QStringLiteral("target"), QStringLiteral("cat")}}}}});
        second.insert(QStringLiteral("blocks"), secondBlocks);
        entry.insert(QStringLiteral("sections"), QJsonArray{section(QStringLiteral("Noun"), QStringLiteral("FIRST SECTION BODY")), second, owner});
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Second noun")}, {QStringLiteral("target"), QStringLiteral("#Noun_2")}}});
        const auto publish = [&](const std::optional<QString> &fragment = std::nullopt) {
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson(), true, fragment);
        };
        publish();
        QCOMPARE(window.sections_->count(), 5); // Rich first companion shares its section row; standalone heading adds one.
        window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23Noun_2")));
        QVERIFY(window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(window.collapsedSections_.contains(2));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("SECOND SECTION BODY")));

        // openWord publishes an explicit cross-entry fragment through this boundary.
        publish(QStringLiteral("Noun_4"));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-1")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));
        QCOMPARE(title(window), QStringLiteral("cat"));
        QCOMPARE(window.sections_->itemData(4).toInt(), 2);
        QCOMPARE(window.sections_->itemData(4, Qt::UserRole + 1).toInt(), 1);
        window.collapsedSections_.insert(2); window.refreshReading();
        QVERIFY(QMetaObject::invokeMethod(window.sections_, "activated", Qt::DirectConnection, Q_ARG(int, 4)));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-1")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));

        entry.insert(QStringLiteral("redirect"), QJsonObject{{QStringLiteral("source_title"), QStringLiteral("Alias cat")},
            {QStringLiteral("target_title"), QStringLiteral("cat")}, {QStringLiteral("fragment"), QStringLiteral("Noun_2")},
            {QStringLiteral("followed"), true}});
        publish(); // The same compiled destination is inherited from an alias.
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("SECOND SECTION BODY")));
        publish(QStringLiteral("Noun_4")); // An explicit fragment overrides the alias destination.
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("STANDALONE HEADING BODY")));

        entry.remove(QStringLiteral("redirect"));
        QJsonArray anchored = entry.value(QStringLiteral("sections")).toArray();
        QJsonObject spaced = anchored[0].toObject(); spaced.insert(QStringLiteral("anchor"), QStringLiteral("Usage_notes"));
        QJsonObject reference = anchored[1].toObject(); reference.insert(QStringLiteral("anchor"), QStringLiteral("reference-1"));
        anchored[0] = spaced; anchored[1] = reference; entry.insert(QStringLiteral("sections"), anchored);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Usage notes"));
        QVERIFY(!window.collapsedSections_.contains(0));
        window.jumpToFragment(QStringLiteral("reference-1"));
        QVERIFY(!window.collapsedSections_.contains(1)); // Authored identity precedes synthetic reference fallback.
        QJsonArray legacy = entry.value(QStringLiteral("sections")).toArray();
        for (qsizetype i = 0; i < legacy.size(); ++i) {
            QJsonObject value = legacy[i].toObject(); value.remove(QStringLiteral("anchor"));
            value.insert(QStringLiteral("blocks"), QJsonArray{}); legacy[i] = value;
        }
        entry.insert(QStringLiteral("sections"), legacy);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Noun"));
        QCOMPARE(window.collapsedSections_, QSet<int>({0, 1, 2})); // Ambiguous legacy labels do not invent an identity.
        QJsonObject unique = legacy[0].toObject(); unique.insert(QStringLiteral("title"), QStringLiteral("Usage notes"));
        legacy[0] = unique; entry.insert(QStringLiteral("sections"), legacy);
        publish(); window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
        window.jumpToFragment(QStringLiteral("Usage_notes"));
        QVERIFY(!window.collapsedSections_.contains(0));

        // Primary and fallback IDs share the producer's page-order collision namespace.
        const QString umlaut(QChar(0x00e4));
        QJsonObject unicode = section(umlaut, QStringLiteral("UNICODE HEADING BODY"));
        unicode.insert(QStringLiteral("title"), umlaut);
        unicode.insert(QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4"));
        QJsonObject literal = section(QStringLiteral(".C3.A4_2"), QStringLiteral("LITERAL DOT HEADING BODY"));
        literal.insert(QStringLiteral("title"), QStringLiteral(".C3.A4"));
        QJsonObject repeated{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
            {QStringLiteral("anchor"), umlaut + QStringLiteral("_2")},
            {QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4_3")},
            {QStringLiteral("spans"), QJsonArray{text(umlaut)}}};
        QJsonObject blockOwner = section(QStringLiteral("Owner"), QStringLiteral("OWNER BODY"));
        blockOwner.insert(QStringLiteral("title"), QStringLiteral("Owner"));
        blockOwner.insert(QStringLiteral("blocks"), QJsonArray{repeated, QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("REPEATED UNICODE BLOCK BODY"))}}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{unicode, literal, blockOwner});
        publish();
        const auto expectOwner = [&](const QString &fragment, int expected) {
            window.collapsedSections_ = {0, 1, 2}; window.refreshReading();
            window.jumpToFragment(fragment);
            QSet<int> folded{0, 1, 2}; folded.remove(expected);
            QCOMPARE(window.collapsedSections_, folded);
        };
        expectOwner(umlaut, 0);
        expectOwner(QStringLiteral(".C3.A4"), 0); // Exact retained fallback, never reader unescaping.
        expectOwner(QStringLiteral(".C3.A4_2"), 1); // Literal dot spelling owns the collision suffix.
        expectOwner(umlaut + QStringLiteral("_2"), 2);
        expectOwner(QStringLiteral(".C3.A4_3"), 2); // Standalone Block.anchor_fallback.
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-2-0")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("REPEATED UNICODE BLOCK BODY")));
    }

    void sectionAndReferenceLinksReachVisibleTargets() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        QJsonArray sections = entry.value(QStringLiteral("sections")).toArray();
        sections.append(QJsonObject{
            {QStringLiteral("level"), 3}, {QStringLiteral("title"), QStringLiteral("Usage notes")},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("text"), QStringLiteral("USAGE FRAGMENT TARGET")}}}}
            }}}
        });
        entry.insert(QStringLiteral("sections"), sections);
        QJsonArray preamble = entry.value(QStringLiteral("preamble_spans")).toArray();
        preamble.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Jump to usage")}, {QStringLiteral("target"), QStringLiteral("#Usage_notes")}});
        preamble.append(QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Jump to reference")}, {QStringLiteral("target"), QStringLiteral("#reference-1")}});
        entry.insert(QStringLiteral("preamble_spans"), preamble);
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23Usage_notes")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("USAGE FRAGMENT TARGET")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("reference-1")));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23reference-1")));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Reference content.")));
    }

    void bookmarksSurviveLargeLibrariesAndSubsequentSaves() {
        QJsonArray rows;
        QVector<SavedWord> expected;
        for (int index = 0; index < 1025; ++index) {
            SavedWord word;
            word.key = QStringLiteral("saved-%1").arg(index);
            word.title = QString::fromUtf8("слово");
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QString::fromUtf8("معنى %1").arg(index);
            word.originRoot = QStringLiteral("/saved-fixture/%1").arg(index % 2);
            word.originEdition = index % 2 ? QStringLiteral("frwiktionary-20261001") : QStringLiteral("enwiktionary-20261001");
            word.savedAt = index + 10;
            word.lastViewed = index + 20;
            word.views = index + 1;
            expected.append(word);
            rows.append(QJsonObject{
                {QStringLiteral("key"), word.key}, {QStringLiteral("title"), word.title},
                {QStringLiteral("language"), word.language}, {QStringLiteral("kind"), word.kind},
                {QStringLiteral("clue"), word.clue}, {QStringLiteral("origin_root"), word.originRoot},
                {QStringLiteral("origin_edition"), word.originEdition},
                {QStringLiteral("saved_at"), double(word.savedAt)},
                {QStringLiteral("last_viewed"), double(word.lastViewed)}, {QStringLiteral("views"), word.views}});
        }
        QSettings storage(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
        storage.setValue(QStringLiteral("learning/state"), QJsonDocument(QJsonObject{
            {QStringLiteral("bookmarks"), rows},
            {QStringLiteral("history"), QJsonArray{rows.at(0), rows.at(1), rows.at(2), rows.at(3)}},
            {QStringLiteral("settings"), QJsonObject{{QStringLiteral("history_limit"), 3}}}
        }).toJson(QJsonDocument::Compact));
        storage.sync();
        QCOMPARE(storage.status(), QSettings::NoError);
        const auto compareWords = [](const QVector<SavedWord> &actual, const QVector<SavedWord> &wanted) {
            QCOMPARE(actual.size(), wanted.size());
            for (qsizetype index = 0; index < wanted.size(); ++index) {
                const SavedWord &a = actual.at(index), &b = wanted.at(index);
                QCOMPARE(a.key, b.key); QCOMPARE(a.title, b.title); QCOMPARE(a.language, b.language);
                QCOMPARE(a.kind, b.kind); QCOMPARE(a.clue, b.clue);
                QCOMPARE(a.originRoot, b.originRoot); QCOMPARE(a.originEdition, b.originEdition);
                QCOMPARE(a.savedAt, b.savedAt); QCOMPARE(a.lastViewed, b.lastViewed); QCOMPARE(a.views, b.views);
            }
        };
        LearningStore store;
        QCOMPARE(store.bookmarks().size(), 1025);
        compareWords(store.bookmarks(), expected);
        QCOMPARE(store.history().size(), 3);
        SavedWord added = expected.first();
        added.key = QStringLiteral("saved-new");
        added.title = QStringLiteral("new word");
        QVERIFY(store.toggleBookmark(added));
        QCOMPARE(store.bookmarks().size(), 1026);
        expected.prepend(store.bookmarks().first()); // Keep the actual assigned savedAt timestamp.
        compareWords(store.bookmarks(), expected);
        store.record(added);
        store.setTheme(QStringLiteral("dark"));
        storage.sync();
        QCOMPARE(storage.status(), QSettings::NoError);
        LearningStore reopened;
        compareWords(reopened.bookmarks(), expected);
        QCOMPARE(reopened.history().size(), 3);
        QCOMPARE(reopened.history().first().key, added.key);
        QCOMPARE(reopened.settings().theme, QStringLiteral("dark"));
        QVERIFY(reopened.toggleBookmark(added) == false);
        expected.removeFirst();
        LearningStore afterRemoval;
        compareWords(afterRemoval.bookmarks(), expected);
    }

    void savedOriginsSeparateIdenticalEntriesAndRejectReplacedEditions() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-saved-origin-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString rootA = directory.filePath(QStringLiteral("a"));
        const QString rootB = directory.filePath(QStringLiteral("b"));
        const auto marker = [](const QString &root, const QByteArray &edition) {
            QFile file(QDir(root).filePath(QStringLiteral(".desktop-edition")));
            return file.open(QIODevice::WriteOnly) && file.write(edition + '\n') == edition.size() + 1;
        };
        for (const QString &root : {rootA, rootB}) {
            QVERIFY(QDir().mkpath(root + QStringLiteral("/languages")));
            const QString relative = QStringLiteral("/languages/ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb");
            QVERIFY(QFile::copy(fixture_ + relative, root + relative));
            QFile manifest(root + QStringLiteral("/languages.tsv"));
            QVERIFY(manifest.open(QIODevice::WriteOnly));
            QCOMPARE(manifest.write("heading\nEnglish\n"), qint64(16));
        }
        QVERIFY(marker(rootA, "enwiktionary-20261001"));
        // Equal edition markers still require the exact canonical folder.
        QVERIFY(marker(rootB, "enwiktionary-20261001"));
        MainWindow window(rootA, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const SavedWord a = window.savedWord(window.currentEntry_);
        QCOMPARE(a.originRoot, QFileInfo(rootA).canonicalFilePath());
        QCOMPARE(a.originEdition, QStringLiteral("enwiktionary-20261001"));
        QVERIFY(window.learning_.toggleBookmark(a));
        const qint64 savedAt = window.learning_.bookmarks().first().savedAt;

        window.openRoot(rootB, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->root() == rootB, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const SavedWord b = window.savedWord(window.currentEntry_);
        QVERIFY(a.key != b.key);
        QVERIFY(window.learning_.toggleBookmark(b));
        QCOMPARE(window.learning_.bookmarks().size(), 2);
        const int viewsB = window.learning_.history().first().views;
        const int historySize = window.learning_.history().size();
        window.openSavedWord(a);
        QVERIFY(!window.loading_);
        QCOMPARE(window.api_->root(), rootB);
        QCOMPARE(window.learning_.history().first().views, viewsB);
        QCOMPARE(window.learning_.history().size(), historySize);
        QVERIFY(window.statusBar()->currentMessage().contains(QStringLiteral("enwiktionary-20261001")));

        window.openRoot(rootA, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_->root() == rootA, 30000);
        const int viewsA = window.learning_.history().first().views;
        QVERIFY(marker(rootA, "enwiktionary-20261101"));
        window.openSavedWord(a);
        QCOMPARE(window.learning_.history().first().views, viewsA);
        QVERIFY(window.statusBar()->currentMessage().contains(QStringLiteral("changed")));
        QVERIFY(marker(rootA, "enwiktionary-20261001"));
        window.openSavedWord(a);
        QCOMPARE(window.learning_.history().first().views, viewsA + 1);

        LearningStore reopened;
        QCOMPARE(reopened.bookmarks().size(), 2);
        const auto found = std::find_if(reopened.bookmarks().cbegin(), reopened.bookmarks().cend(), [&](const SavedWord &word) { return word.key == a.key; });
        QVERIFY(found != reopened.bookmarks().cend());
        QCOMPARE(found->originRoot, a.originRoot);
        QCOMPARE(found->originEdition, a.originEdition);
        QCOMPARE(found->savedAt, savedAt);
    }

    void legacySavedOriginRequiresChoiceWithoutRebindingRecords() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        SavedWord legacy = window.savedWord(window.currentEntry_);
        QVERIFY(!legacy.originRoot.isEmpty());
        QVERIFY(legacy.originEdition.isEmpty());
        const int unlabelledViews = window.learning_.history().first().views;
        bool unlabelledPrompted = false;
        QTimer::singleShot(0, &window, [&] {
            auto *choice = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!choice) return;
            unlabelledPrompted = true;
            choice->done(QMessageBox::Cancel);
        });
        window.openSavedWord(legacy);
        QVERIFY(unlabelledPrompted);
        QCOMPARE(window.learning_.history().first().views, unlabelledViews);
        legacy.key = QStringLiteral("language\nEnglish\ncat");
        legacy.originRoot.clear();
        legacy.originEdition.clear();
        legacy.clue = QStringLiteral("Legacy clue");
        QVERIFY(window.learning_.toggleBookmark(legacy));
        const SavedWord original = window.learning_.bookmarks().first();
        window.learning_.answer(legacy.key, true);
        const StudyStat study = window.learning_.study().value(legacy.key);
        const int historySize = window.learning_.history().size();
        const int views = window.learning_.history().first().views;
        bool prompted = false;
        QTimer::singleShot(0, &window, [&] {
            auto *choice = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!choice) return;
            prompted = choice->text() == QStringLiteral("Open from this dictionary?");
            choice->done(QMessageBox::Cancel);
        });
        window.openSavedWord(legacy);
        QVERIFY(prompted);
        QCOMPARE(window.learning_.history().size(), historySize);
        QCOMPARE(window.learning_.history().first().views, views);
        prompted = false;
        QTimer::singleShot(0, &window, [&] {
            auto *choice = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!choice) return;
            prompted = true;
            choice->done(QMessageBox::Open);
        });
        window.openSavedWord(legacy);
        QVERIFY(prompted);
        QCOMPARE(window.learning_.history().first().views, views + 1);
        const SavedWord retained = window.learning_.bookmarks().first();
        QCOMPARE(retained.key, original.key);
        QCOMPARE(retained.clue, original.clue);
        QCOMPARE(retained.savedAt, original.savedAt);
        QCOMPARE(retained.lastViewed, original.lastViewed);
        QCOMPARE(retained.views, original.views);
        QVERIFY(retained.originRoot.isEmpty());
        QVERIFY(retained.originEdition.isEmpty());
        QCOMPARE(window.learning_.study().value(legacy.key).right, study.right);
        QCOMPARE(window.learning_.study().value(legacy.key).last, study.last);
        LearningStore reloaded;
        QCOMPARE(reloaded.bookmarks().first().key, legacy.key);
        QVERIFY(reloaded.bookmarks().first().originRoot.isEmpty());
        QVERIFY(reloaded.bookmarks().first().originEdition.isEmpty());
    }

    void orderedListItemsKeepNumbersWithoutBecomingDefinitions() {
        MainWindow window{QString()};
        const auto block = [](const QString &kind, const QString &text, const QString &number, const QString &path, int depth) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("number"), number},
                {QStringLiteral("list_path"), path}, {QStringLiteral("depth"), depth},
                {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}};
        };
        // Labels are opaque: wiki lists may retain hierarchical numbering.
        QJsonArray items{
            block(QStringLiteral("list_item"), QStringLiteral("Parent ordered"), QStringLiteral("3"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Nested unordered"), {}, QStringLiteral("#*"), 2),
            block(QStringLiteral("list_item"), QStringLiteral("Nested ordered"), QStringLiteral("3.1"), QStringLiteral("#*#"), 3),
            block(QStringLiteral("list_detail"), QStringLiteral("Parent continuation"), {}, QStringLiteral("#:"), 2),
            block(QStringLiteral("list_item"), QStringLiteral("Explicit value"), QStringLiteral("8"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Following value"), QStringLiteral("9"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Alphabetic label"), QStringLiteral("AA"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Roman label"), QStringLiteral("iii"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Roman value"), QStringLiteral("xxvi"), QStringLiteral("#"), 1),
            block(QStringLiteral("list_item"), QStringLiteral("Escaped label"), QStringLiteral("<i>"), QStringLiteral("#"), 1),
            block(QStringLiteral("paragraph"), QStringLiteral("{{example}} [[literal]]"), {}, {}, 0)};
        QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Ordered fixture")}, {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("List")}, {QStringLiteral("blocks"), items}}}}};
        QCOMPARE(window.clueFor(entry), QStringLiteral("Parent ordered"));
        QJsonArray sections = entry.value(QStringLiteral("sections")).toArray();
        sections.append(QJsonObject{{QStringLiteral("title"), QStringLiteral("Meaning")}, {QStringLiteral("blocks"), QJsonArray{
            block(QStringLiteral("definition"), QStringLiteral("Actual dictionary meaning"), QStringLiteral("1"), QStringLiteral("#"), 1)}}});
        entry.insert(QStringLiteral("sections"), sections);
        const QJsonObject original = entry;
        QCOMPARE(window.clueFor(entry), QStringLiteral("Actual dictionary meaning"));
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        const QString text = document.toPlainText();
        for (const QString &expected : {QStringLiteral("3. Parent ordered"), QStringLiteral("• Nested unordered"),
                QStringLiteral("3.1. Nested ordered"), QStringLiteral("8. Explicit value"), QStringLiteral("9. Following value"),
                QStringLiteral("AA. Alphabetic label"), QStringLiteral("iii. Roman label"), QStringLiteral("xxvi. Roman value"),
                QStringLiteral("<i>. Escaped label"), QStringLiteral("Parent continuation"), QStringLiteral("{{example}} [[literal]]")})
            QVERIFY2(text.contains(expected), qPrintable(text));
        const QTextCursor parent = document.find(QStringLiteral("Parent ordered"));
        const QTextCursor child = document.find(QStringLiteral("Nested ordered"));
        QVERIFY(!parent.isNull() && !child.isNull());
        QVERIFY(child.blockFormat().leftMargin() > parent.blockFormat().leftMargin());
        QCOMPARE(entry, original);
    }

    void headingsKeepCompiledDepthLevelAndCompanionActions() {
        MainWindow window{QString()};
        const auto heading = [](const QString &dialect, int depth, int level = 4) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), level},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), QString(depth, QChar(':'))},
                {QStringLiteral("spans"), QJsonArray{
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Se beiga ")}, {QStringLiteral("italic"), true}},
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("la conchugazión ") + dialect},
                        {QStringLiteral("target"), QStringLiteral("templlar/conj.") + (dialect == QStringLiteral("benasquesa") ? QStringLiteral("BEN") : QStringLiteral("RIB"))},
                        {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true}},
                    QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral(" d'este berbo.")}, {QStringLiteral("italic"), true}}}}};
        };
        // Use entryHtml so the section h2 stylesheet is present: ordinary h2 must not inherit its sans-serif family.
        QJsonArray levelBlocks;
        for (int level = 1; level <= 6; ++level)
            levelBlocks.append(heading(QStringLiteral("level%1").arg(level), 0, level));
        const QJsonObject levelsEntry{{QStringLiteral("kind"), QStringLiteral("language")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Typography controls")},
                {QStringLiteral("level"), 2}, {QStringLiteral("blocks"), levelBlocks}}}}};
        QTextDocument levelsDocument;
        QString levelsHtml = window.entryHtml(levelsEntry);
        const qsizetype bodyEnd = levelsHtml.lastIndexOf(QStringLiteral("</body>"));
        QVERIFY(bodyEnd >= 0);
        levelsHtml.insert(bodyEnd, QStringLiteral("<h3>Legacy h3 typography control</h3>"));
        levelsDocument.setHtml(levelsHtml);
        levelsDocument.setTextWidth(560);
        levelsDocument.documentLayout()->documentSize();
        const QTextCursor oldH3Style = levelsDocument.find(QStringLiteral("Legacy h3 typography control"));
        QVERIFY(!oldH3Style.isNull());
        const auto glyphSizes = [](const QTextCursor &cursor) {
            QJsonArray sizes;
            const QTextBlock block = cursor.block();
            for (const QGlyphRun &run : block.layout()->glyphRuns(cursor.selectionStart() - block.position(), cursor.selectedText().size()))
                sizes.append(run.rawFont().pixelSize());
            return sizes;
        };
        const auto glyphFamilies = [](const QTextCursor &cursor) {
            QJsonArray families;
            const QTextBlock block = cursor.block();
            for (const QGlyphRun &run : block.layout()->glyphRuns(cursor.selectionStart() - block.position(), cursor.selectedText().size())) {
                const QString family = run.rawFont().familyName();
                if (!families.contains(family)) families.append(family);
            }
            return families;
        };
        const QJsonArray legacyFamilies = glyphFamilies(oldH3Style);
        QVERIFY(!legacyFamilies.isEmpty());
        const QJsonArray legacyPixels = glyphSizes(oldH3Style);
        QVERIFY(!legacyPixels.isEmpty());
        QJsonArray computedFonts;
        for (int level = 1; level <= 6; ++level) {
            const QTextCursor cursor = levelsDocument.find(QStringLiteral("level%1").arg(level));
            QVERIFY(!cursor.isNull());
            computedFonts.append(QJsonObject{{QStringLiteral("level"), level},
                {QStringLiteral("size_adjustment"), cursor.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("requested_point_size"), cursor.charFormat().fontPointSize()},
                {QStringLiteral("glyph_pixel_sizes"), glyphSizes(cursor)},
                {QStringLiteral("resolved_glyph_families"), glyphFamilies(cursor)}});
        }
        qInfo().noquote() << "HEADING_FONT_METRICS" << QJsonDocument(QJsonObject{
            {QStringLiteral("legacy_h3_adjustment"), oldH3Style.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
            {QStringLiteral("legacy_h3_glyph_pixels"), legacyPixels},
            {QStringLiteral("legacy_h3_resolved_glyph_families"), legacyFamilies}, {QStringLiteral("computed_headings"), computedFonts}}).toJson(QJsonDocument::Compact);
        for (int level = 1; level <= 6; ++level) {
            const QTextCursor cursor = levelsDocument.find(QStringLiteral("level%1").arg(level));
            QVERIFY(!cursor.isNull());
            QCOMPARE(cursor.blockFormat().headingLevel(), level);
            QCOMPARE(cursor.charFormat().fontFamilies(), oldH3Style.charFormat().fontFamilies());
            QCOMPARE(glyphFamilies(cursor), legacyFamilies);
            QCOMPARE(cursor.charFormat().property(QTextFormat::FontSizeAdjustment), oldH3Style.charFormat().property(QTextFormat::FontSizeAdjustment));
            QVERIFY(cursor.charFormat().fontWeight() >= QFont::Bold);
            const QJsonArray pixels = glyphSizes(cursor);
            QVERIFY(!pixels.isEmpty());
            for (const QJsonValue &size : pixels) QVERIFY(qAbs(size.toDouble() - legacyPixels.first().toDouble()) < 0.05);
        }
        for (int level = 1; level <= 6; ++level) {
            const QString dialect = QStringLiteral("section-level%1").arg(level);
            const QString sectionTitle = QStringLiteral("Se beiga la conchugazión ") + dialect + QStringLiteral(" d'este berbo.");
            const QJsonObject sectionEntry{{QStringLiteral("kind"), QStringLiteral("language")},
                {QStringLiteral("sections"), QJsonArray{
                    QJsonObject{{QStringLiteral("title"), QStringLiteral("Compact section control")}, {QStringLiteral("level"), 2}, {QStringLiteral("blocks"), QJsonArray{}}},
                    QJsonObject{{QStringLiteral("title"), sectionTitle}, {QStringLiteral("level"), level},
                        {QStringLiteral("blocks"), QJsonArray{heading(dialect, 1, level)}}}}}};
            QTextDocument compactDocument;
            compactDocument.setHtml(window.entryHtml(sectionEntry));
            compactDocument.setTextWidth(560);
            compactDocument.documentLayout()->documentSize();
            const QTextCursor control = compactDocument.find(QStringLiteral("Compact section control"));
            const QTextCursor rich = compactDocument.find(dialect);
            QVERIFY(!control.isNull() && !rich.isNull());
            qInfo().noquote() << "COMPACT_HEADING_FONT_METRICS" << QJsonDocument(QJsonObject{
                {QStringLiteral("level"), level},
                {QStringLiteral("size_adjustment"), rich.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("control_h2_size_adjustment"), control.charFormat().intProperty(QTextFormat::FontSizeAdjustment)},
                {QStringLiteral("requested_point_size"), rich.charFormat().fontPointSize()},
                {QStringLiteral("control_h2_requested_point_size"), control.charFormat().fontPointSize()},
                {QStringLiteral("resolved_glyph_families"), glyphFamilies(rich)},
                {QStringLiteral("control_h2_resolved_glyph_families"), glyphFamilies(control)},
                {QStringLiteral("glyph_pixel_sizes"), glyphSizes(rich)},
                {QStringLiteral("control_h2_glyph_pixel_sizes"), glyphSizes(control)}}).toJson(QJsonDocument::Compact);
            QCOMPARE(rich.charFormat().property(QTextFormat::FontSizeAdjustment), control.charFormat().property(QTextFormat::FontSizeAdjustment));
            QCOMPARE(rich.blockFormat().headingLevel(), level);
            QCOMPARE(rich.blockFormat().leftMargin(), 30.0);
            QCOMPARE(rich.charFormat().fontFamilies(), control.charFormat().fontFamilies());
            QCOMPARE(rich.charFormat().fontPointSize(), control.charFormat().fontPointSize());
            QCOMPARE(glyphFamilies(rich), glyphFamilies(control));
            QCOMPARE(glyphSizes(rich), glyphSizes(control));
        }
        const QJsonObject ben = heading(QStringLiteral("benasquesa"), 1);
        const QJsonObject rib = heading(QStringLiteral("ribagorzana"), 2);
        QTextDocument direct;
        direct.setHtml(window.blockHtml(ben) + window.blockHtml(rib)
            + window.blockHtml(heading(QStringLiteral("fallback"), 0, 99)) + QStringLiteral("<h3>Old heading control</h3>"));
        const QTextCursor first = direct.find(QStringLiteral("la conchugazión benasquesa"));
        const QTextCursor second = direct.find(QStringLiteral("la conchugazión ribagorzana"));
        QVERIFY(!first.isNull() && !second.isNull());
        QCOMPARE(first.blockFormat().headingLevel(), 4);
        QCOMPARE(first.blockFormat().leftMargin(), 30.0);
        QCOMPARE(second.blockFormat().leftMargin(), 46.0);
        QCOMPARE(direct.find(QStringLiteral("fallback")).blockFormat().headingLevel(), 3);
        QCOMPARE(first.charFormat().property(QTextFormat::FontSizeAdjustment), direct.find(QStringLiteral("Old heading control")).charFormat().property(QTextFormat::FontSizeAdjustment));
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(first.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
        QVERIFY(first.charFormat().fontItalic());
        QVERIFY(first.charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(!direct.toPlainText().contains(QStringLiteral(":Se beiga")));
        const QString title = QStringLiteral("Se beiga la conchugazión benasquesa d'este berbo.");
        const QJsonObject plain{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4}, {QStringLiteral("depth"), 1},
            {QStringLiteral("list_path"), QStringLiteral(":")}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("Plain indented heading")}}}}};
        const QJsonObject entry{{QStringLiteral("kind"), QStringLiteral("language")}, {QStringLiteral("title"), QStringLiteral("templlar")},
            {QStringLiteral("sections"), QJsonArray{
                QJsonObject{{QStringLiteral("title"), title}, {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{ben}}},
                QJsonObject{{QStringLiteral("title"), QStringLiteral("Plain indented heading")}, {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{plain}}}}}};
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(title), 1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Plain indented heading")), 1);
        const QTextCursor companion = document.find(QStringLiteral("la conchugazión benasquesa"));
        QCOMPARE(companion.blockFormat().headingLevel(), 4);
        QCOMPARE(companion.blockFormat().leftMargin(), 30.0);
        QCOMPARE(companion.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(companion.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
        QVERIFY(hasAnchor(&document, QStringLiteral("section-0")));
        QVERIFY(window.entryHtml(entry).contains(QStringLiteral("href='section:0'")));
        window.collapsedSections_.insert(0);
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(title), 1);
        QCOMPARE(document.find(QStringLiteral("la conchugazión benasquesa")).charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
        QCOMPARE(QUrl(document.find(QStringLiteral("la conchugazión benasquesa")).charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
    }

    void headingFixtureRendersNarrowLtrAndRtlWithoutClipping() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        const auto section = [](const QString &label, const QString &target, const QString &direction, int depth, bool companion) {
            QJsonObject span{{QStringLiteral("kind"), target.isEmpty() ? QStringLiteral("text") : QStringLiteral("link")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), target}, {QStringLiteral("direction"), direction},
                {QStringLiteral("bold"), !target.isEmpty()}, {QStringLiteral("italic"), true}};
            QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 4},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), QString(depth, QChar(':'))},
                {QStringLiteral("spans"), QJsonArray{span}}};
            return QJsonObject{{QStringLiteral("title"), companion ? label : QStringLiteral("Ordinary heading control")},
                {QStringLiteral("level"), 4}, {QStringLiteral("blocks"), QJsonArray{heading}}};
        };
        window.resize(580, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QJsonObject sourceResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        for (const QString &direction : {QStringLiteral("ltr"), QStringLiteral("rtl")}) {
            const QString linked = direction == QStringLiteral("ltr")
                ? QStringLiteral("Se beiga la conchugazión benasquesa d'este berbo.")
                : QString::fromUtf8("عنوان عربي طويل لاختبار التفاف النص واتجاه القراءة");
            const QJsonObject entry{{QStringLiteral("kind"), QStringLiteral("language")}, {QStringLiteral("title"), QStringLiteral("Heading renderer fixture")},
                {QStringLiteral("sections"), QJsonArray{
                    section(linked, QStringLiteral("templlar/conj.BEN"), direction, 1, true),
                    section(QStringLiteral("Plain indented companion"), {}, direction, 1, true),
                    section(QStringLiteral("Ordinary source heading retains depth"), {}, direction, 1, false)}}};
            QJsonObject response = sourceResponse;
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson());
            QCoreApplication::processEvents();
            const QString frame = QStringLiteral(".tmp/ui-screenshots/heading-companion-%1-580.png").arg(direction);
            QVERIFY(window.grab().save(frame));
            QCOMPARE(window.size(), QSize(580, 480));
            QVERIFY(window.reading_->viewport()->width() > 100);
            QVERIFY(window.reading_->viewport()->height() > 100);
            QCOMPARE(window.reading_->horizontalScrollBar()->maximum(), 0);
            const QTextCursor link = window.reading_->document()->find(linked);
            QVERIFY2(!link.isNull(), qPrintable(window.reading_->toPlainText()));
            QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:templlar%2Fconj.BEN"));
            QCOMPARE(QUrl(link.charFormat().anchorHref()).path(QUrl::FullyDecoded), QStringLiteral("templlar/conj.BEN"));
            QCOMPARE(link.blockFormat().leftMargin(), 30.0);
            QCOMPARE(link.blockFormat().headingLevel(), 4);
            QCOMPARE(window.reading_->toPlainText().count(linked), 1);
            QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Plain indented companion")), 1);
            const QTextCursor ordinary = window.reading_->document()->find(QStringLiteral("Ordinary source heading retains depth"));
            QVERIFY(!ordinary.isNull());
            QCOMPARE(ordinary.blockFormat().headingLevel(), 4);
            QCOMPARE(ordinary.blockFormat().leftMargin(), 30.0);
            window.reading_->setTextCursor(ordinary); window.reading_->ensureCursorVisible();
            QCoreApplication::processEvents();
            const QString lowerFrame = QStringLiteral(".tmp/ui-screenshots/heading-ordinary-%1-580.png").arg(direction);
            QVERIFY(window.grab().save(lowerFrame));
        }
    }

    void nestedTermsKeepTheirCompiledDepth() {
        MainWindow window{QString()};
        const auto term = [](const QString &text, int depth, const QString &path) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("term")}, {QStringLiteral("depth"), depth},
                {QStringLiteral("list_path"), path}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}};
        };
        QTextDocument document;
        document.setHtml(window.blockHtml(term(QStringLiteral("Outer term"), 1, QStringLiteral(";")))
            + window.blockHtml(term(QStringLiteral("Nested term"), 2, QStringLiteral("*;"))));
        const QTextCursor outer = document.find(QStringLiteral("Outer term"));
        const QTextCursor inner = document.find(QStringLiteral("Nested term"));
        QVERIFY(!outer.isNull() && !inner.isNull());
        QCOMPARE(outer.blockFormat().leftMargin(), 0.0);
        QCOMPARE(inner.blockFormat().leftMargin(), 16.0);
        QVERIFY(outer.charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(inner.charFormat().fontWeight() >= QFont::Bold);
    }


    void poemLinesPreserveBlankLinesStylesAndLinks() {
        MainWindow window{QString()};
        const auto text = [](const QString &value, const QString &classes = QString()) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), value}, {QStringLiteral("classes"), classes}};
        };
        const QString marked = QStringLiteral("wikidict-poem");
        const QString indented = marked + QStringLiteral(" wikidict-poem-indent-2");
        const auto br = [](const QString &classes) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("classes"), classes}};
        };
        QJsonObject bold = text(QStringLiteral("Styled "), indented);
        bold.insert(QStringLiteral("bold"), true);
        QJsonObject link = text(QStringLiteral("cat"), indented);
        link.insert(QStringLiteral("kind"), QStringLiteral("link"));
        link.insert(QStringLiteral("target"), QStringLiteral("cat#Noun"));
        const QString padding = QString(2, QChar(0x00a0));
        const QJsonArray spans{text(QStringLiteral("Lead")), br({}), bold, link, br(indented),
            br(marked), text(padding + QStringLiteral("End"), marked), br(marked)};
        const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), spans}};
        const QJsonObject original = block;
        QTextDocument document;
        document.setTextWidth(360);
        document.setHtml(window.blockHtml(block));
        QString plain = document.toPlainText();
        plain.replace(QChar(0x00a0), QChar(' '));
        QCOMPARE(plain, QStringLiteral("Lead\nStyled cat\n\n  End\n"));
        QVERIFY(document.toRawText().contains(padding + QStringLiteral("End")));
        const QTextCursor styled = document.find(QStringLiteral("Styled "));
        const QTextCursor linked = document.find(QStringLiteral("cat"));
        QVERIFY(!styled.isNull() && !linked.isNull());
        QCOMPARE(styled.block().position(), linked.block().position()); // A style/link boundary cannot create a new line.
        QVERIFY(styled.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(linked.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        QVERIFY(qAbs(styled.blockFormat().leftMargin() - 2 * em) < 0.1);
        QCOMPARE(styled.blockFormat().rightMargin(), 0.0);
        QCOMPARE(document.blockCount(), 5);
        QVERIFY(document.lastBlock().text().isEmpty());
        QCOMPARE(block, original);

        // A boundary break is one line boundary, not an extra stanza.
        QTextDocument boundary;
        boundary.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Before")), br({}),
                text(QStringLiteral("Verse"), marked), br({}), text(QStringLiteral("After"))}}}));
        QCOMPARE(boundary.toPlainText(), QStringLiteral("Before\nVerse\nAfter"));
        QCOMPARE(boundary.blockCount(), 3);

        // Ordinary unmarked output remains the existing inline path.
        QTextDocument ordinary;
        ordinary.setHtml(window.spansHtml(QJsonArray{text(QStringLiteral("Ordinary")), br({}),
            text(QStringLiteral("line"))}));
        QCOMPARE(ordinary.toPlainText(), QStringLiteral("Ordinary\nline"));
        QCOMPARE(ordinary.blockCount(), 1);
    }

    void poemIndentFollowsEnclosingDirectionOnWrappedLines() {
        MainWindow window{QString()};
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        for (const bool rtl : {false, true}) {
            const QString words = rtl
                ? QStringLiteral("אבגד הוזח טיכל מנסע פצקר שתאב גדוז חטיכ למנס עפצק רשתא בגדו זחטי כלמנ סעפצ קרשת")
                : QStringLiteral("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma");
            const QString classes = QStringLiteral("wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-") +
                (rtl ? QStringLiteral("rtl") : QStringLiteral("ltr"));
            // A child's opposite isolate must not change the enclosing line's margin.
            const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), words}, {QStringLiteral("classes"), classes},
                {QStringLiteral("direction"), rtl ? QStringLiteral("ltr") : QStringLiteral("rtl")}};
            QTextDocument document;
            QFont font = document.defaultFont();
            font.setPointSize(window.readingPointSize_);
            document.setDefaultFont(font);
            document.setTextWidth(230);
            document.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{span}}}));
            (void) document.documentLayout()->documentSize();
            const QTextCursor located = document.find(words.left(4));
            QVERIFY(!located.isNull());
            const QTextBlock block = located.block();
            QVERIFY(block.isValid());
            QCOMPARE(block.blockFormat().layoutDirection(), rtl ? Qt::RightToLeft : Qt::LeftToRight);
            QVERIFY(qAbs(block.blockFormat().leftMargin() - (rtl ? 0 : 2 * em)) < 0.1);
            QVERIFY(qAbs(block.blockFormat().rightMargin() - (rtl ? 2 * em : 0)) < 0.1);
            const QTextLayout *layout = block.layout();
            QVERIFY(layout && layout->lineCount() >= 2);
            const qreal available = document.textWidth() - 2 * document.documentMargin() - 2 * em;
            for (int i = 0; i < layout->lineCount(); ++i) {
                const QTextLine line = layout->lineAt(i);
                QVERIFY(line.isValid());
                QVERIFY(line.width() <= available + 0.5);
                QVERIFY(line.width() > 0);
            }
            const QString raw = document.toRawText();
            QVERIFY(raw.contains(words)); // No spaces or indentation characters were injected.
        }
    }

    void poemLinesRetainCellCaptionAndOuterIndentContexts() {
        MainWindow window{QString()};
        const auto spans = [](const QString &text, int depth) {
            return QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"),
                    QStringLiteral("wikidict-poem wikidict-poem-indent-%1").arg(depth)}}};
        };
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        const QJsonObject cell{{QStringLiteral("spans"), spans(QStringLiteral("Cell verse"), 2)}};
        const QJsonObject table{{QStringLiteral("caption"), spans(QStringLiteral("Caption verse"), 1)},
            {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        QTextDocument document;
        document.setTextWidth(400);
        document.setHtml(window.tableHtml(table, 0));
        const QTextCursor caption = document.find(QStringLiteral("Caption verse"));
        const QTextCursor content = document.find(QStringLiteral("Cell verse"));
        QVERIFY(!caption.isNull() && !content.isNull());
        QVERIFY(qAbs(caption.blockFormat().leftMargin() - em) < 0.1);
        QVERIFY(qAbs(content.blockFormat().leftMargin() - 2 * em) < 0.1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Caption verse")), 1);
        QCOMPARE(document.toPlainText().count(QStringLiteral("Cell verse")), 1);

        QTextDocument nested;
        nested.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("indent")},
            {QStringLiteral("depth"), 2}, {QStringLiteral("spans"), spans(QStringLiteral("Nested verse"), 2)}}));
        const QTextCursor verse = nested.find(QStringLiteral("Nested verse"));
        QVERIFY(!verse.isNull());
        QVERIFY(qAbs(verse.blockFormat().leftMargin() - (46 + 2 * em)) < 0.1);

        // Noncanonical or excessive numbers preserve text but cannot select arbitrary margins.
        for (const QString &number : {QStringLiteral("0"), QStringLiteral("33"), QStringLiteral("02"),
                QStringLiteral("-1"), QStringLiteral("999999999999999999999")}) {
            const QJsonArray malformed{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Bounded verse")},
                {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-") + number}}};
            QTextDocument bounded;
            bounded.setHtml(window.spansHtml(malformed));
            QCOMPARE(bounded.toPlainText(), QStringLiteral("Bounded verse"));
            QCOMPARE(bounded.begin().blockFormat().leftMargin(), 0.0);
            QCOMPARE(bounded.begin().blockFormat().rightMargin(), 0.0);
        }
        QTextDocument maximum;
        maximum.setHtml(window.spansHtml(spans(QStringLiteral("Maximum verse"), 32)));
        QVERIFY(qAbs(maximum.begin().blockFormat().leftMargin() - 32 * em) < 0.1);
    }


    void poemMetadataAndRawLineFeedsFollowTheCanonicalContract() {
        MainWindow window{QString()};
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        const auto span = [](const QString &text, const QString &classes) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"), classes}};
        };
        const QString mark = QStringLiteral("wikidict-poem");
        const QString one = mark + QStringLiteral(" wikidict-poem-indent-1");
        const QString two = mark + QStringLiteral(" wikidict-poem-indent-2");
        QJsonObject raw = span(QStringLiteral("First\n\nSecond"), one);
        raw.insert(QStringLiteral("trail"), QStringLiteral("\nTail\n"));
        raw.insert(QStringLiteral("kind"), QStringLiteral("link"));
        raw.insert(QStringLiteral("target"), QStringLiteral("cat#Noun"));
        raw.insert(QStringLiteral("bold"), true);
        const QJsonObject original = raw;
        QTextDocument lines;
        lines.setHtml(window.spansHtml(QJsonArray{raw}));
        QCOMPARE(lines.toPlainText(), QStringLiteral("First\n\nSecond\nTail\n"));
        QCOMPARE(lines.blockCount(), 5);
        for (const QString &word : {QStringLiteral("First"), QStringLiteral("Second"), QStringLiteral("Tail")}) {
            const QTextCursor found = lines.find(word);
            QVERIFY(!found.isNull());
            QCOMPARE(found.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
            QVERIFY(found.charFormat().fontWeight() >= QFont::Bold);
            const qreal expected = word == QStringLiteral("First") ? em : 0.0;
            QVERIFY(qAbs(found.blockFormat().leftMargin() - expected) < 0.1);
        }
        QCOMPARE(raw, original);
        QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")}, {QStringLiteral("classes"), one}};
        lines.setHtml(window.spansHtml(QJsonArray{raw, br}));
        QCOMPARE(lines.toPlainText(), QStringLiteral("First\n\nSecond\nTail\n\n"));
        QCOMPARE(lines.blockCount(), 6);
        lines.setHtml(window.spansHtml(QJsonArray{span(QStringLiteral("First\n"), one),
            span(QStringLiteral("New wrapper"), two)}));
        const QTextCursor separatelyWrapped = lines.find(QStringLiteral("New wrapper"));
        QVERIFY(!separatelyWrapped.isNull());
        QVERIFY(qAbs(separatelyWrapped.blockFormat().leftMargin() - 2 * em) < 0.1);

        const QList<QJsonArray> invalidIndent{
            QJsonArray{span(QStringLiteral("Left"), two + QStringLiteral(" wikidict-poem-indent-2"))},
            QJsonArray{span(QStringLiteral("Left"), two), span(QStringLiteral("Right"), one)},
            QJsonArray{span(QStringLiteral("Left"), two), span(QStringLiteral("Right"), mark)},
            QJsonArray{span(QStringLiteral("Left"), mark + QStringLiteral(" wikidict-poem-indent-+3"))},
            QJsonArray{span(QStringLiteral("Left"), mark + QStringLiteral(" wikidict-poem-indent-"))}
        };
        for (const QJsonArray &value : invalidIndent) {
            QTextDocument document;
            document.setHtml(window.spansHtml(value));
            QVERIFY(document.toPlainText().startsWith(QStringLiteral("Left")));
            QCOMPARE(document.begin().blockFormat().leftMargin(), 0.0);
            QCOMPARE(document.begin().blockFormat().rightMargin(), 0.0);
        }
        const QList<QJsonArray> invalidDirection{
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-rtl wikidict-poem-dir-rtl"))},
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-ltr wikidict-poem-dir-rtl"))},
            QJsonArray{span(QStringLiteral("Default direction"), two + QStringLiteral(" wikidict-poem-dir-sideways"))},
            QJsonArray{span(QStringLiteral("Default "), two + QStringLiteral(" wikidict-poem-dir-rtl")),
                span(QStringLiteral("direction"), two)}
        };
        for (const QJsonArray &value : invalidDirection) {
            QTextDocument document;
            document.setHtml(window.spansHtml(value));
            QCOMPARE(document.toPlainText(), QStringLiteral("Default direction"));
            QVERIFY(qAbs(document.begin().blockFormat().leftMargin() - 2 * em) < 0.1);
            QCOMPARE(document.begin().blockFormat().rightMargin(), 0.0);
        }
        for (const QString &classes : {QStringLiteral("not-wikidict-poem wikidict-poem-indent-2"),
                QStringLiteral("wikidict-poem") + QChar(0x00a0) + QStringLiteral("wikidict-poem-indent-2")}) {
            QTextDocument document;
            document.setHtml(window.spansHtml(QJsonArray{span(QStringLiteral("Ordinary"), classes)}));
            QCOMPARE(document.toPlainText(), QStringLiteral("Ordinary"));
            QCOMPARE(document.begin().blockFormat().leftMargin(), 0.0);
        }
    }


    void poemPrefixesStayOnTheFirstLineAndDefaultDirectionIsTheContainer() {
        MainWindow window{QString()};
        const QString marked = QStringLiteral("wikidict-poem wikidict-poem-indent-2");
        const auto span = [](const QString &text, const QString &classes = QString()) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"), classes}};
        };
        const QJsonArray mixed{span(QStringLiteral("Lead")),
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")}},
            span(QStringLiteral("Verse"), marked)};
        for (const QString &kind : {QStringLiteral("definition"), QStringLiteral("list_item"), QStringLiteral("example")}) {
            const QString prefix = kind == QStringLiteral("definition") ? QStringLiteral("7")
                : kind == QStringLiteral("list_item") ? QStringLiteral("7.") : QStringLiteral("Example:");
            const QJsonObject block{{QStringLiteral("kind"), kind}, {QStringLiteral("number"), QStringLiteral("7")},
                {QStringLiteral("depth"), 1}, {QStringLiteral("spans"), mixed}};
            QTextDocument document;
            document.setTextWidth(360);
            document.setHtml(window.blockHtml(block));
            QCOMPARE(document.toPlainText(), prefix + QStringLiteral(" Lead\nVerse"));
            QCOMPARE(document.blockCount(), 2);
            const QTextCursor label = document.find(prefix);
            const QTextCursor lead = document.find(QStringLiteral("Lead"));
            const QTextCursor verse = document.find(QStringLiteral("Verse"));
            QVERIFY(!label.isNull() && !lead.isNull() && !verse.isNull());
            QCOMPARE(label.block().position(), lead.block().position());
            QVERIFY(verse.block().position() > lead.block().position());
            if (kind == QStringLiteral("definition")) QVERIFY(label.charFormat().fontWeight() >= QFont::Bold);
            if (kind == QStringLiteral("example")) QVERIFY(label.charFormat().fontItalic());
            QVERIFY(!lead.charFormat().fontItalic());
        }
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        for (const bool rtlContainer : {false, true}) {
            window.reading_->setLayoutDirection(rtlContainer ? Qt::RightToLeft : Qt::LeftToRight);
            QJsonObject child = span(rtlContainer ? QStringLiteral("English child") : QStringLiteral("אבגד"), marked);
            child.insert(QStringLiteral("direction"), rtlContainer ? QStringLiteral("ltr") : QStringLiteral("rtl"));
            QTextDocument document;
            document.setHtml(window.spansHtml(QJsonArray{child}));
            const QTextBlock block = document.begin();
            QCOMPARE(block.blockFormat().layoutDirection(), rtlContainer ? Qt::RightToLeft : Qt::LeftToRight);
            QVERIFY(qAbs(block.blockFormat().leftMargin() - (rtlContainer ? 0 : 2 * em)) < 0.1);
            QVERIFY(qAbs(block.blockFormat().rightMargin() - (rtlContainer ? 2 * em : 0)) < 0.1);
            QVERIFY(document.toRawText().contains(child.value(QStringLiteral("text")).toString()));
        }
    }


    void poemReferencePrefixKeepsItsFirstLineAnchorAndMediaNavigation() {
        MainWindow window{QString()};
        const QJsonObject lead{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Lead")}, {QStringLiteral("target"), QStringLiteral("cat#Noun")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-1")},
            {QStringLiteral("bold"), true}};
        const QJsonObject br{{QStringLiteral("kind"), QStringLiteral("line_break")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-poem wikidict-poem-indent-1")}};
        const QJsonObject caption{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Poem caption")},
            {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
            {QStringLiteral("classes"), QStringLiteral("wikidict-media\twikidict-poem wikidict-poem-indent-2")}};
        const QJsonObject reference{{QStringLiteral("number"), 4}, {QStringLiteral("group_number"), 2},
            {QStringLiteral("group"), QStringLiteral("note <one>")},
            {QStringLiteral("spans"), QJsonArray{lead, br, caption}}};
        const QJsonObject ordinary{{QStringLiteral("number"), 5}, {QStringLiteral("group_number"), 3},
            {QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Ordinary citation")}}}}};
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Poem references")},
            {QStringLiteral("kind"), QStringLiteral("supplemental")}, {QStringLiteral("sections"), QJsonArray{}},
            {QStringLiteral("references"), QJsonArray{reference, ordinary}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                {QStringLiteral("file"), QStringLiteral("Tone.ogg")}, {QStringLiteral("caption"), QStringLiteral("Poem caption")}}}}};
        QTextDocument document;
        document.setTextWidth(360);
        document.setHtml(window.entryHtml(entry));
        const QString plain = document.toPlainText();
        QVERIFY(plain.contains(QStringLiteral("[note <one> 2] Lead\nPoem caption")));
        QVERIFY(plain.contains(QStringLiteral("[3] Ordinary citation")));
        QCOMPARE(plain.count(QStringLiteral("Poem caption")), 1);
        QVERIFY(plain.contains(QStringLiteral("Tone.ogg")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-4")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-5")));
        const QTextCursor label = document.find(QStringLiteral("[note <one> 2]"));
        const QTextCursor first = document.find(QStringLiteral("Lead"));
        const QTextCursor second = document.find(QStringLiteral("Poem caption"));
        QVERIFY(!label.isNull() && !first.isNull() && !second.isNull());
        QCOMPARE(label.block().position(), first.block().position());
        QCOMPARE(first.block().next().position(), second.block().position());
        QVERIFY(first.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(first.charFormat().anchorHref(), QStringLiteral("dict:cat%23Noun"));
        QCOMPARE(second.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
        const qreal em = window.readingPointSize_ * window.reading_->logicalDpiY() / 72.0;
        QVERIFY(qAbs(first.block().blockFormat().leftMargin() - em) < 0.1);
        QVERIFY(qAbs(second.block().blockFormat().leftMargin() - 2 * em) < 0.1);
    }

    void groupedReferenceLabelsUseCompiledIdentity() {
        MainWindow window{QString()};
        const auto reference = [](int number, int groupNumber, const QString &group, const QString &text) {
            return QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("group_number"), groupNumber},
                {QStringLiteral("group"), group}, {QStringLiteral("spans"), QJsonArray{QJsonObject{
                    {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}}};
        };
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Reference fixture")},
            {QStringLiteral("kind"), QStringLiteral("supplemental")}, {QStringLiteral("sections"), QJsonArray{}},
            {QStringLiteral("references"), QJsonArray{
                reference(1, 1, {}, QStringLiteral("Ordinary citation")),
                reference(2, 1, QStringLiteral("note <one>"), QStringLiteral("{{Example}} [[Link]] __NOEDITSECTION__")),
                reference(3, 2, {}, QStringLiteral("Later ordinary citation"))}}};
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        const QString text = document.toPlainText();
        QVERIFY(text.contains(QStringLiteral("[1] Ordinary citation")));
        QVERIFY(text.contains(QStringLiteral("[note <one> 1] {{Example}} [[Link]] __NOEDITSECTION__")));
        QVERIFY(text.contains(QStringLiteral("[2] Later ordinary citation")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-2")));
        QVERIFY(hasAnchor(&document, QStringLiteral("reference-3")));
    }

    void embeddedMediaCaptionKeepsTypedPresentationWithoutPlainDuplicate() {
        MainWindow window{QString()};
        const QString caption = QStringLiteral("Styled caption");
        const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), caption}, {QStringLiteral("target"), QStringLiteral("File:Caption_image.svg")},
            {QStringLiteral("classes"), QStringLiteral("note\twikidict-media")},
            {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true},
            {QStringLiteral("language"), QStringLiteral("fr")}, {QStringLiteral("direction"), QStringLiteral("rtl")}};
        const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{span}}};
        QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Media fixture")}, {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Gallery")},
                {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), QJsonArray{block}}}}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")},
                {QStringLiteral("file"), QStringLiteral("Caption image.svg")}, {QStringLiteral("caption"), caption}}}}};
        const QJsonObject original = entry;
        const auto visibleText = [](const QTextDocument &document) {
            QString text = document.toPlainText();
            for (ushort control = 0x2066; control <= 0x2069; ++control) text.remove(QChar(control));
            return text;
        };
        const QString html = window.entryHtml(entry);
        QVERIFY(html.contains(QStringLiteral("lang=\"fr\"")));
        QVERIFY(html.contains(QStringLiteral("dir=\"rtl\"")));
        QTextDocument document;
        document.setHtml(html);
        QCOMPARE(visibleText(document).count(caption), 1);
        const QTextCursor styled = document.find(caption);
        QVERIFY(!styled.isNull());
        QVERIFY(styled.charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(styled.charFormat().fontItalic());
        QCOMPARE(styled.charFormat().anchorHref(), QStringLiteral("dict:File%3ACaption_image.svg"));
        QVERIFY(document.toRawText().contains(QString(QChar(0x2067)) + caption + QChar(0x2069)));
        QVERIFY(document.toPlainText().contains(QStringLiteral("Caption image.svg"))); // Metadata link remains available.
        QCOMPARE(entry, original);

        window.collapsedSections_.insert(0);
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Hidden body needs its metadata fallback.
        QVERIFY(!document.find(caption).charFormat().fontItalic());
        window.collapsedSections_.clear();
        entry.insert(QStringLiteral("sections"), QJsonArray{});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Metadata-only legacy entry.
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Preamble captions also retain their typed owner.
        QJsonObject first = span, second = span;
        first.insert(QStringLiteral("text"), QStringLiteral("Styled "));
        second.insert(QStringLiteral("text"), QStringLiteral("caption"));
        second.insert(QStringLiteral("bold"), false);
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{first, second});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // Styled pieces share one caption owner.
        QJsonObject otherCaption = span;
        otherCaption.insert(QStringLiteral("text"), QStringLiteral("Different authored label"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{otherCaption});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1); // A different same-file label does not own this caption.
        QVERIFY(document.toPlainText().contains(QStringLiteral("Different authored label")));
        QJsonObject unrelated = span;
        unrelated.insert(QStringLiteral("classes"), QStringLiteral("not-wikidict-media"));
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{unrelated});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 2); // Ordinary prose is not a media caption owner.
        entry.remove(QStringLiteral("preamble_spans"));
        for (const QString &kind : {QStringLiteral("blank"), QStringLiteral("rule")}) {
            QJsonObject hidden = block;
            hidden.insert(QStringLiteral("kind"), kind);
            entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Ignored")},
                {QStringLiteral("blocks"), QJsonArray{hidden}}}});
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(visibleText(document).count(caption), 1);
            QVERIFY(!document.find(caption).charFormat().fontItalic()); // Ignored fields cannot own the caption.
        }
        QJsonObject table = block;
        table.insert(QStringLiteral("table"), QJsonObject{{QStringLiteral("caption"), QJsonArray{}}, {QStringLiteral("rows"), QJsonArray{}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Table")},
            {QStringLiteral("blocks"), QJsonArray{table}}}});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1);
        QVERIFY(!document.find(caption).charFormat().fontItalic()); // tableHtml ignores the adjacent block.spans.
        table.insert(QStringLiteral("table"), QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{
            {QStringLiteral("cells"), QJsonArray{QJsonObject{{QStringLiteral("spans"), QJsonArray{span}}}}}}}}});
        entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Table")},
            {QStringLiteral("blocks"), QJsonArray{table}}}});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(visibleText(document).count(caption), 1);
        QVERIFY(document.find(caption).charFormat().fontItalic()); // An actual rendered cell does own it.
    }

    void embeddedMultilineMediaCaptionKeepsTypedBreaksAndCollapsedFallback() {
        MainWindow window{QString()};
        for (bool poem : {false, true}) {
            const QString classes = poem
                ? QStringLiteral("wikidict-media\twikidict-poem wikidict-poem-indent-2")
                : QStringLiteral("note wikidict-media");
            const QString firstText = QStringLiteral("First caption");
            const QString secondText = QStringLiteral("Second verse");
            const QString caption = firstText + (poem ? QStringLiteral("\n\n") : QStringLiteral("\n")) + secondText;
            const QJsonObject first{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), firstText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}, {QStringLiteral("bold"), true}};
            const QJsonObject second{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), secondText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}, {QStringLiteral("italic"), true}};
            const QJsonObject ownedBreak{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("text"), QStringLiteral("\n")}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
                {QStringLiteral("classes"), classes}};
            QJsonArray spans{first, ownedBreak};
            if (poem) spans.append(ownedBreak); // A blank stanza remains part of this caption.
            spans.append(second);
            const QJsonObject block{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), spans}};
            const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Multiline media")},
                {QStringLiteral("kind"), QStringLiteral("supplemental")},
                {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Gallery")},
                    {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), QJsonArray{block}}}}},
                {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                    {QStringLiteral("file"), QStringLiteral("Tone.ogg")}, {QStringLiteral("caption"), caption}}}}};
            const QJsonObject original = entry;
            QTextDocument document;
            document.setTextWidth(360);
            document.setHtml(window.entryHtml(entry));
            const QString plain = document.toPlainText();
            QVERIFY(plain.contains(caption));
            QCOMPARE(plain.count(firstText), 1);
            QCOMPARE(plain.count(secondText), 1);
            const QTextCursor firstCursor = document.find(firstText);
            const QTextCursor secondCursor = document.find(secondText);
            QVERIFY(!firstCursor.isNull() && !secondCursor.isNull());
            QVERIFY(firstCursor.charFormat().fontWeight() >= QFont::Bold);
            QVERIFY(secondCursor.charFormat().fontItalic());
            QCOMPARE(firstCursor.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(secondCursor.charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            const QTextCursor fileCursor = document.find(QStringLiteral("Tone.ogg"));
            QVERIFY(!fileCursor.isNull());
            QCOMPARE(fileCursor.charFormat().anchorHref(), QStringLiteral("https://commons.wikimedia.org/wiki/File:Tone.ogg"));
            QCOMPARE(entry, original);

            window.collapsedSections_.insert(0);
            document.setHtml(window.entryHtml(entry));
            const QString collapsed = document.toPlainText();
            QCOMPARE(collapsed.count(firstText), 1);
            QCOMPARE(collapsed.count(secondText), 1);
            QVERIFY(collapsed.simplified().contains(caption.simplified()));
            QVERIFY(document.find(firstText).charFormat().fontWeight() < QFont::Bold);
            QVERIFY(!document.find(secondText).charFormat().fontItalic());
            QVERIFY(document.find(firstText).charFormat().anchorHref().isEmpty());
            QVERIFY(!document.find(QStringLiteral("Tone.ogg")).isNull());
            QCOMPARE(entry, original);
            window.collapsedSections_.clear();
        }
    }

    void explicitMediaOwnersPreserveCaptionActionsAndExactFileIdentity() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        const QString tone = QStringLiteral("wikidict-media wikidict-media-file-546f6e652e6f6767");
        const QString other = QStringLiteral("wikidict-media wikidict-media-file-4f746865722e6f6767");
        const QString caption = QStringLiteral("A domestic cat and external.");
        const auto span = [](const QString &text, const QString &target, const QString &classes,
                             const QString &kind = QStringLiteral("link")) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("classes"), classes}, {QStringLiteral("bold"), true}};
        };
        const auto media = [](const QString &file, const QString &text) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                {QStringLiteral("file"), file}, {QStringLiteral("caption"), text}};
        };
        const QJsonArray mixed{span(QStringLiteral("A "), QStringLiteral("File:Tone.ogg"), tone),
            span(QStringLiteral("domestic cat"), QStringLiteral("cat"), tone),
            span(QStringLiteral(" and "), QStringLiteral("File:Tone.ogg"), tone),
            span(QStringLiteral("external"), QStringLiteral("https://example.org"), tone, QStringLiteral("external_link")),
            span(QStringLiteral("."), QStringLiteral("File:Tone.ogg"), tone)};
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("dog"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), mixed);
        entry.insert(QStringLiteral("sections"), QJsonArray{});
        entry.insert(QStringLiteral("references"), QJsonArray{});
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Tone.ogg"), caption)});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QCOMPARE(window.reading_->toPlainText().count(caption), 1);
        const QTextCursor cat = window.reading_->document()->find(QStringLiteral("domestic cat"), 0, QTextDocument::FindCaseSensitively);
        QVERIFY(!cat.isNull());
        QCOMPARE(cat.charFormat().anchorHref(), QStringLiteral("dict:cat"));
        QVERIFY(cat.charFormat().fontWeight() >= QFont::Bold);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("external")).charFormat().anchorHref(), QStringLiteral("https://example.org"));
        QVERIFY(!window.reading_->document()->find(QStringLiteral("Tone.ogg")).isNull());
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto clearHandler = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("https://example.org")));
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(QStringLiteral("https://example.org"))});
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:cat")));
        QTRY_COMPARE(title(window), QStringLiteral("cat"));

        // Equal visible labels cannot transfer ownership to another media record.
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
            span(QStringLiteral("same"), QStringLiteral("cat"), tone),
            span(QStringLiteral("\n"), {}, {}, QStringLiteral("line_break")),
            span(QStringLiteral("same"), QStringLiteral("dog"), other)});
        entry.insert(QStringLiteral("media"), QJsonArray{
            media(QStringLiteral("Tone.ogg"), QStringLiteral("same")),
            media(QStringLiteral("Other.ogg"), QStringLiteral("same"))});
        QTextDocument document;
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span(QStringLiteral("same"), QStringLiteral("cat"), tone)});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2); // Other still needs its fallback.

        const QString unicode = QStringLiteral("wikidict-media wikidict-media-file-c38963686f20f09f948a2e6f6767");
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{span(QStringLiteral("same"), QStringLiteral("cat"), unicode)});
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Écho 🔊.ogg"), QStringLiteral("same"))});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 1);

        const QString token = QStringLiteral("wikidict-media-file-546f6e652e6f6767");
        const QString otherToken = QStringLiteral("wikidict-media-file-4f746865722e6f6767");
        entry.insert(QStringLiteral("media"), QJsonArray{media(QStringLiteral("Tone.ogg"), QStringLiteral("same"))});
        for (const QString &bad : {QStringLiteral("wikidict-media-file-"), QStringLiteral("wikidict-media-file-0"),
                QStringLiteral("wikidict-media-file-ff"), QStringLiteral("wikidict-media-file-546F6E652E6F6767"),
                QStringLiteral("wikidict-media-file-556e6b6e6f776e2e6f6767"), token + QChar(' ') + token,
                token + QChar(' ') + otherToken}) {
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
                span(QStringLiteral("same"), QStringLiteral("File:Tone.ogg"), QStringLiteral("wikidict-media ") + bad)});
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
        }
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{
            span(QStringLiteral("same"), QStringLiteral("File:Tone.ogg"), QStringLiteral("not-wikidict-media ") + token)});
        document.setHtml(window.entryHtml(entry));
        QCOMPARE(document.toPlainText().count(QStringLiteral("same")), 2);
    }

    void mediaCaptionOwnershipStopsAtUnrelatedBreaksAndOtherFiles() {
        MainWindow window{QString()};
        const QString firstText = QStringLiteral("First caption");
        const QString secondText = QStringLiteral("Second verse");
        const QString marked = QStringLiteral("wikidict-media wikidict-poem");
        const QJsonObject first{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), firstText}, {QStringLiteral("target"), QStringLiteral("File:Tone.ogg")},
            {QStringLiteral("classes"), marked}};
        QJsonObject second = first;
        second.insert(QStringLiteral("text"), secondText);
        const auto boundary = [](const QString &classes, const QString &target) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("line_break")},
                {QStringLiteral("text"), QStringLiteral("\n")}, {QStringLiteral("classes"), classes},
                {QStringLiteral("target"), target}};
        };
        const QJsonArray boundaries{
            boundary(QStringLiteral("wikidict-poem"), QStringLiteral("File:Tone.ogg")),
            boundary(QStringLiteral("not-wikidict-media wikidict-poem"), QStringLiteral("File:Tone.ogg")),
            boundary(marked, QStringLiteral("File:Other.ogg")),
            boundary(marked, QString())};
        for (const QJsonValue &separator : boundaries) {
            const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Separate captions")},
                {QStringLiteral("kind"), QStringLiteral("supplemental")},
                {QStringLiteral("preamble_spans"), QJsonArray{first, separator, second}},
                {QStringLiteral("sections"), QJsonArray{}},
                {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("audio")},
                    {QStringLiteral("file"), QStringLiteral("Tone.ogg")},
                    {QStringLiteral("caption"), firstText + QStringLiteral("\n") + secondText}}}}};
            const QJsonObject original = entry;
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            const QString plain = document.toPlainText();
            QVERIFY(plain.contains(firstText + QStringLiteral("\n") + secondText));
            // These separately owned pieces cannot suppress the full metadata caption.
            QCOMPARE(plain.count(firstText), 2);
            QCOMPARE(plain.count(secondText), 2);
            QCOMPARE(document.find(firstText).charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(document.find(secondText).charFormat().anchorHref(), QStringLiteral("dict:File%3ATone.ogg"));
            QCOMPARE(entry, original);
        }
    }

    void crossEntrySectionLinkKeepsFragmentThroughRealLookup() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Dog noun section")}, {QStringLiteral("target"), QStringLiteral("dog#Noun")}}});
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        window.renderResponse(QJsonDocument(response).toJson());
        QCOMPARE(window.reading_->verticalScrollBar()->value(), 0); // Known initial destination position.
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog%23Noun")));
        QCOMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.search_->text(), QStringLiteral("dog"));
        const QJsonObject realDog = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("dog"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        QCOMPARE(window.currentEntry_, realDog);
        const QJsonArray realSections = realDog.value(QStringLiteral("sections")).toArray();
        int nounSection = -1;
        for (qsizetype i = 0; i < realSections.size(); ++i) {
            if (realSections[i].toObject().value(QStringLiteral("title")).toString() == QStringLiteral("Noun")) {
                nounSection = static_cast<int>(i);
                break;
            }
        }
        qInfo() << "Real dog Noun section index" << nounSection << "section count" << realSections.size();
        QVERIFY(nounSection >= 0);
        const int nounChoice = window.sections_->findText(QStringLiteral("Noun"));
        QVERIFY(nounChoice >= 0);
        QCOMPARE(window.sections_->itemData(nounChoice).toInt(), nounSection);
        // Qt imports the empty section anchor onto the block's character format.
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(nounSection)));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("Noun")));
        QVERIFY(window.reading_->verticalScrollBar()->value() > 0);

        // The same selected navigation test checks the source-edition ISBN route.
        QTemporaryDir directory(QStringLiteral(".tmp/ui-booksources-XXXXXX"));
        QVERIFY(directory.isValid());
        const QString path = QDir(directory.path()).absolutePath();
        const QString ordinary = QStringLiteral("Special:BookSources/not-an-isbn");
        QVERIFY(prepareCaseTitleFixture(fixture_, path, {QStringLiteral("cat"), ordinary}));
        const QString library = path + QStringLiteral("/library");
        QFile marker(library + QStringLiteral("/.desktop-edition"));
        QVERIFY(marker.open(QIODevice::WriteOnly));
        QCOMPARE(marker.write("frwiktionary-20261001\n"), qint64(22));
        marker.close();
        MainWindow bookWindow(library, QStringLiteral("cat"));
        bookWindow.resize(780, 480);
        bookWindow.show();
        QTRY_VERIFY_WITH_TIMEOUT(!bookWindow.loading_ && bookWindow.api_, 30000);
        QTRY_COMPARE(title(bookWindow), QStringLiteral("cat"));
        QCOMPARE(bookWindow.api_->language(), QStringLiteral("English"));
        QCOMPARE(LibraryStorage::sourceHost(bookWindow.api_->root()), QStringLiteral("fr.wiktionary.org"));
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto restore = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        const auto link = [](const QString &target) {
            return QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), QStringLiteral("ISBN route")}, {QStringLiteral("target"), target}}};
        };
        const QString prefix = QStringLiteral("Special:BookSources/");
        qsizetype openedCount = 0;
        for (const QString &isbn : {QStringLiteral("123456789X"), QStringLiteral("0000000000"),
                                   QStringLiteral("9780306406157"), QStringLiteral("979123456789X")}) {
            const QString target = prefix + isbn;
            bookWindow.reading_->setHtml(bookWindow.spansHtml(link(target)));
            QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target))));
            ++openedCount;
            QCOMPARE(receiver.opened.size(), openedCount);
            QCOMPARE(receiver.opened.last(), QUrl(QStringLiteral("https://fr.wiktionary.org/wiki/") +
                QString::fromLatin1(QUrl::toPercentEncoding(target))));
            QCOMPARE(title(bookWindow), QStringLiteral("cat"));
            QCOMPARE(bookWindow.search_->text(), QStringLiteral("cat"));
        }
        QCOMPARE(receiver.opened.size(), qsizetype(4));
        for (const QString &target : {prefix + QStringLiteral("123456789x"), prefix + QStringLiteral("1234567890123"),
                                     prefix + QStringLiteral("9780306406157#Noun"), prefix + QStringLiteral("9780306406157?q=1"),
                                     prefix + QStringLiteral("9780306406157/path"), prefix + QStringLiteral("%31%32%33%34%35%36%37%38%39X"),
                                     prefix + QStringLiteral("123-456789X"), prefix + QStringLiteral("١٢٣٤٥٦٧٨٩X"),
                                     QStringLiteral("special:BookSources/123456789X")}) {
            bookWindow.reading_->setHtml(bookWindow.spansHtml(link(target)));
            QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target))));
            QCOMPARE(receiver.opened.size(), qsizetype(4));
            QCOMPARE(title(bookWindow), QStringLiteral("cat"));
        }
        // An unlabeled root must not guess the lexical language's source edition.
        QVERIFY(LibraryStorage::sourceHost(window.api_->root()).isEmpty());
        const QString unknownTarget = prefix + QStringLiteral("123456789X");
        window.reading_->setHtml(window.spansHtml(link(unknownTarget)));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(unknownTarget))));
        QCOMPARE(receiver.opened.size(), qsizetype(4));
        QCOMPARE(title(window), QStringLiteral("dog"));
        // A real ordinary title sharing the prefix still uses exact dictionary lookup.
        bookWindow.reading_->setHtml(bookWindow.spansHtml(link(ordinary)));
        QVERIFY(clickAnchor(bookWindow.reading_, QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(ordinary))));
        QCOMPARE(title(bookWindow), ordinary);
        QVERIFY(bookWindow.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QCOMPARE(receiver.opened.size(), qsizetype(4));
    }

    void captionOnlyTablesAndFosteredParagraphsKeepVisibleDepth() {
        MainWindow window{QString()};
        const auto spans = [](const QString &text) { return QJsonArray{QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text}}}; };
        const QJsonObject table{{QStringLiteral("caption"), spans(QStringLiteral("Only caption"))},
            {QStringLiteral("rows"), QJsonArray{}}};
        QTextDocument caption;
        caption.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
            {QStringLiteral("depth"), 2}, {QStringLiteral("list_path"), QStringLiteral("::")},
            {QStringLiteral("table"), table}}));
        const QTextCursor captionCursor = caption.find(QStringLiteral("Only caption"));
        QVERIFY(!captionCursor.isNull());
        QCOMPARE(caption.toPlainText().count(QStringLiteral("Only caption")), 1);
        QCOMPARE(captionCursor.block().blockFormat().leftMargin(), qreal(46));
        for (const int depth : {0, 1, 2}) {
            QTextDocument paragraph;
            paragraph.setHtml(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("depth"), depth}, {QStringLiteral("list_path"), depth ? QStringLiteral("::") : QString()},
                {QStringLiteral("spans"), spans(QStringLiteral("Fostered paragraph"))}}));
            const QTextCursor cursor = paragraph.find(QStringLiteral("Fostered paragraph"));
            QVERIFY(!cursor.isNull());
            QCOMPARE(paragraph.toPlainText(), QStringLiteral("Fostered paragraph"));
            QCOMPARE(cursor.block().blockFormat().leftMargin(), qreal(depth == 0 ? 0 : 30 + (depth - 1) * 16));
        }
    }

    void typedSelfLinksStayBoldAndNonactionableAcrossCaptionAndCell() {
        // Client-only DPR-shaped fixture. This does not claim a corpus caption.
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const auto self = [](const QString &label) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), QString()},
                {QStringLiteral("classes"), QStringLiteral("mw-selflink selflink")},
                {QStringLiteral("bold"), true}};
        };
        const auto text = [](const QString &value) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}};
        };
        const auto linked = [](const QString &label, const QString &target) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), label}, {QStringLiteral("target"), target}};
        };
        const auto html = [&](bool adjacent) {
            QJsonArray paragraph{text(QStringLiteral("CLIENT-ONLY SELF-LINK FIXTURE: "))};
            QJsonArray caption;
            if (adjacent) {
                const QJsonObject file = linked(QStringLiteral("Fixture file"), QStringLiteral("File:caption.png"));
                paragraph.append(file); paragraph.append(text(QStringLiteral(" ")));
                caption.append(file); caption.append(text(QStringLiteral(" ")));
            }
            paragraph.append(self(QStringLiteral("Paragraph self")));
            caption.append(self(QStringLiteral("Caption self")));
            if (adjacent) {
                caption.append(text(QStringLiteral(" ")));
                caption.append(linked(QStringLiteral("Next dog"), QStringLiteral("dog")));
            }
            const QJsonObject cell{{QStringLiteral("spans"), QJsonArray{self(QStringLiteral("Cell self"))}}};
            const QJsonObject row{{QStringLiteral("cells"), QJsonArray{cell}}};
            const QJsonObject table{{QStringLiteral("caption"), caption}, {QStringLiteral("rows"), QJsonArray{row}}};
            return window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                       {QStringLiteral("spans"), paragraph}})
                + window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")},
                       {QStringLiteral("table"), table}});
        };
        const QStringList labels{QStringLiteral("Paragraph self"), QStringLiteral("Caption self"), QStringLiteral("Cell self")};
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        for (const int width : {580, 780}) {
            window.resize(width, 480);
            window.reading_->setHtml(html(false));
            window.reading_->setFocus();
            QTRY_VERIFY(window.reading_->hasFocus());
            QCOMPARE(window.size(), QSize(width, 480));
            for (const QString &label : labels) {
                const QTextCursor found = window.reading_->document()->find(label);
                QVERIFY(!found.isNull());
                QCOMPARE(window.reading_->toPlainText().count(label), 1);
                for (int at = found.selectionStart(); at < found.selectionEnd(); ++at) {
                    QTextCursor character(window.reading_->document());
                    character.setPosition(at);
                    character.movePosition(QTextCursor::NextCharacter, QTextCursor::KeepAnchor);
                    QVERIFY(!character.charFormat().isAnchor());
                    QVERIFY(character.charFormat().anchorHref().isEmpty());
                    QVERIFY(character.charFormat().fontWeight() >= QFont::Bold);
                }
            }
            auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
            QVERIFY(accessible && accessible->textInterface());
            const QString accessibleText = accessible->textInterface()->text(0, accessible->textInterface()->characterCount());
            for (const QString &label : labels) QCOMPARE(accessibleText.count(label), 1);
            QTextCursor selfCursor = window.reading_->document()->find(QStringLiteral("Caption self"));
            selfCursor.setPosition(selfCursor.selectionStart() + 3);
            window.reading_->setTextCursor(selfCursor);
            window.reading_->ensureCursorVisible();
            const QPoint point = window.reading_->cursorRect(selfCursor).center();
            QVERIFY(window.reading_->viewport()->rect().contains(point));
            QVERIFY(window.reading_->anchorAt(point).isEmpty());
            QTest::mouseClick(window.reading_->viewport(), Qt::LeftButton, Qt::NoModifier, point);
            QTest::keyClick(window.reading_, Qt::Key_Return);
            QCOMPARE(activated.count(), 0);
            QCOMPARE(title(window), QStringLiteral("cat"));
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-selflink-caption-%1.png").arg(width)));
            // With no anchors in this fixture, Tab must leave the reader.
            window.reading_->setFocus();
            QTest::keyClick(window.reading_, Qt::Key_Tab);
            QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != window.reading_);
        }
        window.reading_->setHtml(html(true));
        for (const QString &label : labels) {
            const QTextCursor found = window.reading_->document()->find(label);
            QVERIFY(!found.isNull());
            QVERIFY(!found.charFormat().isAnchor());
            QVERIFY(found.charFormat().anchorHref().isEmpty());
        }
        // Preceding file action cannot leak into ordinary caption text; the
        // adjacent real dictionary action still opens the existing dog fixture.
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("dog"), 30000);
        QVERIFY(activated.count() >= 1);
    }

    void typedSpanForegroundPreservesBenDistinctionsAndLinkedActions() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const auto colored = [](const QString &text, const QString &foreground, bool bold = false) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), text},
                {QStringLiteral("foreground"), foreground}, {QStringLiteral("bold"), bold}};
        };
        // Exact authored BEN key words and forms, including a color-only form.
        const QJsonArray sourceSpans{
            colored(QStringLiteral("berda"), QStringLiteral("#008000")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("asul"), QStringLiteral("#1c39bb")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("turquesa"), QStringLiteral("#01796f")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebabe"), QStringLiteral("#008000"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebem"), QStringLiteral("#1c39bb"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiga aiguanebau"), QStringLiteral("#1c39bb")),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" | ")}},
            colored(QStringLiteral("aiguanebats"), QStringLiteral("#01796f"), true),
            QJsonObject{{QStringLiteral("text"), QStringLiteral(" plain neighbor ")}},
            // Typed link control, not a claim that this link color occurs in BEN.
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("text"), QStringLiteral("Follow")},
                {QStringLiteral("target"), QStringLiteral("dog")}, {QStringLiteral("foreground"), QStringLiteral("#008000")},
                {QStringLiteral("italic"), true}}
        };
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme);
            window.applyTheme();
            window.reading_->setHtml(window.spansHtml(QJsonArray{QJsonObject{{QStringLiteral("text"), QStringLiteral("plain neighbor")}}}));
            const QBrush defaultForeground = window.reading_->document()->find(QStringLiteral("plain neighbor")).charFormat().foreground();
            window.reading_->setHtml(window.spansHtml(sourceSpans));
            for (const QJsonValue &value : sourceSpans) {
                const QJsonObject span = value.toObject();
                if (!span.contains(QStringLiteral("foreground"))) continue;
                const QTextCursor found = window.reading_->document()->find(span.value(QStringLiteral("text")).toString());
                QVERIFY(!found.isNull());
                QCOMPARE(found.charFormat().foreground().color(), QColor(span.value(QStringLiteral("foreground")).toString()));
                QCOMPARE(found.charFormat().fontWeight() >= QFont::Bold, span.value(QStringLiteral("bold")).toBool());
            }
            QCOMPARE(window.reading_->document()->find(QStringLiteral("plain neighbor")).charFormat().foreground(), defaultForeground);
            const QTextCharFormat link = window.reading_->document()->find(QStringLiteral("Follow")).charFormat();
            QVERIFY(link.isAnchor());
            QCOMPARE(link.anchorHref(), QStringLiteral("dict:dog"));
            QVERIFY(link.fontItalic());
        }
        QSignalSpy activated(window.reading_, &QTextBrowser::anchorClicked);
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE_WITH_TIMEOUT(title(window), QStringLiteral("dog"), 30000);
        QVERIFY(activated.count() >= 1);

        const QJsonObject ordinary{{QStringLiteral("text"), QStringLiteral("unchanged")}};
        const QString unchanged = window.spansHtml(QJsonArray{ordinary});
        for (const QJsonValue &invalid : {QJsonValue(), QJsonValue(false), QJsonValue(123),
                QJsonValue(QStringLiteral("green")), QJsonValue(QStringLiteral("#008000;")),
                QJsonValue(QStringLiteral("#1C39BB")), QJsonValue(QStringLiteral("#080")),
                QJsonValue(QStringLiteral("#008000ff")), QJsonValue(QStringLiteral("#gggggg"))}) {
            QJsonObject span = ordinary;
            span.insert(QStringLiteral("foreground"), invalid);
            QCOMPARE(window.spansHtml(QJsonArray{span}), unchanged);
        }
    }

    void typedCellBackgroundPreservesBleohTableAndLinks() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        // Source-authored Bleoh row backgrounds and named swatch overrides;
        // the stored API supplies canonical RGB, not CSS or replacement labels.
        const QStringList labels{QStringLiteral("blæc"), QStringLiteral("grǣg"), QStringLiteral("hwīt"), QStringLiteral("seolfor"), QStringLiteral("gold"), QStringLiteral("rēod"), QStringLiteral("basu"), QStringLiteral("hǣwen"), QStringLiteral("grēne"), QStringLiteral("geolu"), QStringLiteral("geolorēad")};
        const QStringList targets{QStringLiteral("blæc"), QStringLiteral("grǣg"), QStringLiteral("hwīt"), QStringLiteral("Seolfor"), QStringLiteral("gold"), QStringLiteral("rēod"), QStringLiteral("basu"), QStringLiteral("hǣwen"), QStringLiteral("grēne"), QStringLiteral("geolu"), QStringLiteral("geolorēad")};
        const QStringList colors{QStringLiteral("#000000"), QStringLiteral("#808080"), QStringLiteral("#ffffff"), QStringLiteral("#c0c0c0"), QStringLiteral("#ffd700"), QStringLiteral("#ff0000"), QStringLiteral("#800080"), QStringLiteral("#0000ff"), QStringLiteral("#008000"), QStringLiteral("#ffff00"), QStringLiteral("#ffa500")};
        QJsonArray rows;
        for (int index = 0; index < labels.size(); ++index) {
            const QJsonObject link{{QStringLiteral("kind"), QStringLiteral("link")},
                {QStringLiteral("text"), labels[index]}, {QStringLiteral("target"), targets[index]}};
            const QJsonObject blank{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QString(QChar(0x00a0))}};
            rows.append(QJsonObject{{QStringLiteral("cells"), QJsonArray{
                QJsonObject{{QStringLiteral("spans"), QJsonArray{link}}, {QStringLiteral("background"), QStringLiteral("#eeeeee")}},
                QJsonObject{{QStringLiteral("spans"), QJsonArray{blank}}, {QStringLiteral("background"), colors[index]}}
            }}});
        }
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), rows}}, 0));
        QTextTable *table = nullptr;
        for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->rows(), 11);
        QCOMPARE(table->columns(), 2);
        for (int index = 0; index < labels.size(); ++index) {
            const QTextTableCell label = table->cellAt(index, 0);
            const QTextTableCell sample = table->cellAt(index, 1);
            QCOMPARE(label.format().background().color(), QColor(QStringLiteral("#eeeeee")));
            QCOMPARE(sample.format().background().color(), QColor(colors[index]));
            QCOMPARE(label.rowSpan(), 1);
            QCOMPARE(label.columnSpan(), 1);
            QCOMPARE(sample.rowSpan(), 1);
            QCOMPARE(sample.columnSpan(), 1);
            QCOMPARE(label.firstCursorPosition().block().text(), labels[index]);
            QCOMPARE(sample.firstCursorPosition().block().text(), QString(QChar(0x00a0)));
            const QTextFragment fragment = label.firstCursorPosition().block().begin().fragment();
            QVERIFY(fragment.isValid());
            QVERIFY(fragment.charFormat().isAnchor());
            QCOMPARE(fragment.charFormat().anchorHref(), QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(targets[index])));
        }
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Color sample")));

        const QJsonObject span{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("unchanged")}};
        const QJsonObject ordinary{{QStringLiteral("spans"), QJsonArray{span}}};
        const auto oneCellTable = [&](const QJsonObject &cell) {
            return QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        };
        const QString unchanged = window.tableHtml(oneCellTable(ordinary), 0);
        for (const QJsonValue &invalid : {QJsonValue(), QJsonValue(false), QJsonValue(123),
                QJsonValue(QStringLiteral("red")), QJsonValue(QStringLiteral("#FFF000")),
                QJsonValue(QStringLiteral("#ff0")), QJsonValue(QStringLiteral("#ffff0000")),
                QJsonValue(QStringLiteral("#gggggg")), QJsonValue(QStringLiteral("#ffff00;"))}) {
            QJsonObject cell = ordinary;
            cell.insert(QStringLiteral("background"), invalid);
            QCOMPARE(window.tableHtml(oneCellTable(cell), 0), unchanged);
        }
        QJsonObject colored = ordinary;
        colored.insert(QStringLiteral("background"), QStringLiteral("#000000"));
        window.reading_->setHtml(window.tableHtml(QJsonObject{{QStringLiteral("rows"), QJsonArray{
            QJsonObject{{QStringLiteral("cells"), QJsonArray{colored, ordinary}}}
        }}}, 0));
        table = nullptr;
        for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        QVERIFY(table);
        QCOMPARE(table->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#000000")));
        QCOMPARE(table->cellAt(0, 1).format().background().style(), Qt::NoBrush);
    }

    void spanBackgroundPreservesInnerPaintAndHeadingMetadata() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(accessible);
        auto *accessibleText = accessible->textInterface();
        QVERIFY(accessibleText);
        const auto attributesAt = [accessibleText](const QTextCursor &cursor) {
            int start = -1, end = -1;
            return accessibleText->attributes(cursor.selectionStart(), &start, &end).split(QChar(';'), Qt::SkipEmptyParts);
        };
        const auto painted = [](const QString &text, const QString &color) {
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), text}, {QStringLiteral("background"), color}};
        };
        QJsonObject link = painted(QStringLiteral("inner link"), QStringLiteral("#ffffe0"));
        link.insert(QStringLiteral("kind"), QStringLiteral("link"));
        link.insert(QStringLiteral("target"), QStringLiteral("dog"));
        link.insert(QStringLiteral("trail"), QStringLiteral("!"));
        link.insert(QStringLiteral("code"), true);
        QJsonObject breakTrail = painted(QStringLiteral("ignored break text"), QStringLiteral("#ff0000"));
        breakTrail.insert(QStringLiteral("kind"), QStringLiteral("line_break"));
        breakTrail.insert(QStringLiteral("trail"), QStringLiteral("break trail"));
        QJsonObject cellAuthoredInk = painted(QStringLiteral("cell authored ink"), QStringLiteral("#000000"));
        cellAuthoredInk.insert(QStringLiteral("foreground"), QStringLiteral("#123456"));
        const QJsonArray spans{link, QJsonObject{{QStringLiteral("text"), QStringLiteral(" plain neighbor")}}, breakTrail,
            painted(QStringLiteral("dark inner override"), QStringLiteral("#000000")), cellAuthoredInk,
            painted(QStringLiteral("   "), QStringLiteral("#00ff00"))};
        const QJsonObject cell{{QStringLiteral("background"), QStringLiteral("#fffdd0")}, {QStringLiteral("spans"), spans}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(table, 0));
            const auto inner = window.reading_->document()->find(QStringLiteral("inner link!"));
            QVERIFY(!inner.isNull());
            QCOMPARE(inner.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
            QVERIFY(inner.charFormat().isAnchor());
            const QString plain = window.reading_->toPlainText();
            QVERIFY(plain.contains(QStringLiteral("plain neighbor\nbreak trail")));
            QCOMPARE(plain.count(QStringLiteral("break trail")), 1);
            QVERIFY(!plain.contains(QStringLiteral("ignored break text")));
            const auto trail = window.reading_->document()->find(QStringLiteral("break trail"));
            QCOMPARE(trail.charFormat().background().color(), QColor(QStringLiteral("#ff0000")));
            QVERIFY(!trail.charFormat().isAnchor());
            const auto neighbor = window.reading_->document()->find(QStringLiteral("plain neighbor"));
            QCOMPARE(neighbor.charFormat().background().style(), Qt::NoBrush);
            QCOMPARE(neighbor.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            const auto darkInner = window.reading_->document()->find(QStringLiteral("dark inner override"));
            QCOMPARE(darkInner.charFormat().background().color(), QColor(QStringLiteral("#000000")));
            QCOMPARE(darkInner.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("cell authored ink")).charFormat().foreground().color(), QColor(QStringLiteral("#123456")));
            QCOMPARE(inner.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            QVERIFY(inner.charFormat().fontUnderline());
            QCOMPARE(trail.charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
            auto *rendered = qobject_cast<QTextTable *>(window.reading_->document()->rootFrame()->childFrames().first());
            QVERIFY(rendered);
            QCOMPARE(rendered->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#fffdd0")));
            QVERIFY(!neighbor.isNull());
            const auto neighborAttributes = attributesAt(neighbor);
            QVERIFY(neighborAttributes.contains(QStringLiteral("color:rgb(0,0,0)")));
            QVERIFY(neighborAttributes.contains(QStringLiteral("background-color:rgb(255,253,208)")));
            QVERIFY(!darkInner.isNull());
            const auto innerAttributes = attributesAt(darkInner);
            QVERIFY(innerAttributes.contains(QStringLiteral("color:rgb(255,255,255)")));
            QVERIFY(innerAttributes.contains(QStringLiteral("background-color:rgb(0,0,0)")));
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            window.resize(900, 700);
            QCoreApplication::processEvents();
            window.reading_->verticalScrollBar()->setValue(0);
            QCoreApplication::processEvents();
            QVERIFY(window.reading_->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-span-background-%1.png").arg(theme)));
        }
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            QJsonObject explicitInk = painted(QStringLiteral("authored ink"), QStringLiteral("#ffffe0"));
            explicitInk.insert(QStringLiteral("foreground"), QStringLiteral("#123456"));
            window.reading_->setHtml(window.spansHtml(QJsonArray{painted(QStringLiteral("dark paint"), QStringLiteral("#000000")), explicitInk,
                QJsonObject{{QStringLiteral("text"), QStringLiteral("theme neighbor")}}}));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("dark paint")).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("authored ink")).charFormat().foreground().color(), QColor(QStringLiteral("#123456")));
            const auto themeNeighbor = window.reading_->document()->find(QStringLiteral("theme neighbor"));
            QVERIFY(!themeNeighbor.isNull());
            QCOMPARE(themeNeighbor.charFormat().foreground().style(), Qt::NoBrush);
            QCOMPARE(themeNeighbor.charFormat().background().style(), Qt::NoBrush);
            QVERIFY(!themeNeighbor.currentTable());
            const QColor base = window.reading_->palette().color(QPalette::Base);
            QVERIFY(attributesAt(themeNeighbor).contains(QStringLiteral("background-color:rgb(%1,%2,%3)")
                .arg(base.red()).arg(base.green()).arg(base.blue())));
        }
        for (const QString &invalid : {QStringLiteral("#FFFFE0"), QStringLiteral("#fff"), QStringLiteral("yellow"), QStringLiteral("#ffffe0\n")}) {
            window.reading_->setHtml(window.spansHtml(QJsonArray{painted(QStringLiteral("invalid paint"), invalid)}));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("invalid paint")).charFormat().background().style(), Qt::NoBrush);
        }
        const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 3},
            {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("Noun"), QStringLiteral("#ffffe0"))}}};
        const QJsonObject section{{QStringLiteral("title"), QStringLiteral("Noun")}, {QStringLiteral("level"), 3},
            {QStringLiteral("blocks"), QJsonArray{heading, QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("   "), QStringLiteral("#00ff00"))}}}}}};
        window.currentEntry_ = QJsonObject{{QStringLiteral("title"), QStringLiteral("Paint title")},
            {QStringLiteral("display_title"), QJsonArray{painted(QStringLiteral("Paint title"), QStringLiteral("#ffffe0"))}},
            {QStringLiteral("preamble_spans"), QJsonArray{painted(QStringLiteral("Paint preamble"), QStringLiteral("#ffffe0"))}},
            {QStringLiteral("references"), QJsonArray{QJsonObject{{QStringLiteral("number"), 1}, {QStringLiteral("group_number"), 1},
                {QStringLiteral("spans"), QJsonArray{painted(QStringLiteral("Paint reference"), QStringLiteral("#ffffe0"))}}}}},
            {QStringLiteral("sections"), QJsonArray{section}}};
        const QJsonObject response{{QStringLiteral("entries"), QJsonArray{window.currentEntry_}}};
        window.renderResponse(QJsonDocument(response).toJson(), false);
        QCOMPARE(window.title_->document()->find(QStringLiteral("Paint title")).charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        for (const QString &label : {QStringLiteral("Paint preamble"), QStringLiteral("Paint reference")}) {
            const auto found = window.reading_->document()->find(label); QVERIFY(!found.isNull());
            QCOMPARE(found.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        }
        const auto noun = window.reading_->document()->find(QStringLiteral("Noun"));
        QVERIFY(!noun.isNull());
        QCOMPARE(noun.charFormat().background().color(), QColor(QStringLiteral("#ffffe0")));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Noun")), 1);
        QVERIFY(window.entryHtml(window.currentEntry_).contains(QStringLiteral("background-color:#00ff00")));
    }

    void aliasImportAcceptsAnchoredAndPaintedSourceVersions() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-painted-alias-XXXXXX"));
        QVERIFY(directory.isValid());
        const auto varint = [](quint64 n) { QByteArray out; do { unsigned char b = n & 127; n >>= 7; if (n) b |= 128; out.append(char(b)); } while (n); return out; };
        for (const QByteArray &magic : {QByteArrayLiteral("DPR5"), QByteArrayLiteral("DPR6")}) {
            const QByteArray presentation = magic + QByteArray(28, '\0');
            QByteArray alias = QByteArrayLiteral("DAL1") + QByteArray(4, '\0') + char(1) + char(1) + QByteArray(4, '\0') + char(1);
            for (const QByteArray &field : {QByteArrayLiteral("Alias"), QByteArrayLiteral("Alias"), QByteArrayLiteral("en"), QByteArrayLiteral("Target"), QByteArrayLiteral("Target"), QByteArrayLiteral("en"), presentation})
                alias += varint(field.size()) + field;
            QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(8) + QByteArray("1\tAlias\0", 8) + varint(alias.size()) + alias;
            const QString source = directory.filePath(QString::fromLatin1(magic) + QStringLiteral(".wikblb"));
            QFile file(source); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write(bytes), bytes.size()); file.close();
            std::atomic_bool cancelled = false;
            const QString root = directory.filePath(QString::fromLatin1(magic) + QStringLiteral("-library"));
            auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
            QVERIFY(prepared); LibraryStorage::commitImport(root, *prepared);
            QCOMPARE(LibraryStorage::installed(root).size(), qsizetype(1));
        }
    }

    void orderedCellBlocksKeepFlowHeadingContextAndChildGrid() {
        MainWindow window{QString()};
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_, 30000);
        const auto text = [](const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto block = [&](const QString &kind, const QString &value) { return QJsonObject{
            {QStringLiteral("kind"), kind}, {QStringLiteral("spans"), QJsonArray{text(value)}}}; };
        const auto table = [](const QJsonObject &cell) { return QJsonObject{{QStringLiteral("rows"), QJsonArray{
            QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}}; };
        QJsonObject heading = block(QStringLiteral("heading"), QStringLiteral("Cell heading"));
        heading.insert(QStringLiteral("level"), 4); heading.insert(QStringLiteral("anchor"), QStringLiteral("Cell_heading"));
        heading.insert(QStringLiteral("anchor_fallback"), QStringLiteral("Cell.20heading"));
        QJsonObject item = block(QStringLiteral("list_item"), QStringLiteral("Cell list body"));
        item.insert(QStringLiteral("number"), QStringLiteral("2")); item.insert(QStringLiteral("depth"), 1);
        item.insert(QStringLiteral("list_path"), QStringLiteral("#"));
        QJsonObject child = table(QJsonObject{{QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Child cell body"))}}});
        child.insert(QStringLiteral("geometry"), QJsonObject{{QStringLiteral("cell_padding"), 2},
            {QStringLiteral("width"), QJsonObject{{QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100}}}});
        QJsonObject linked = text(QStringLiteral("Cell linked body")); linked.insert(QStringLiteral("kind"), QStringLiteral("link"));
        linked.insert(QStringLiteral("target"), QStringLiteral("cat"));
        QJsonObject explicitInk = text(QStringLiteral("Authored cell ink")); explicitInk.insert(QStringLiteral("foreground"), QStringLiteral("#ff0000"));
        const QJsonArray contents{block(QStringLiteral("paragraph"), QStringLiteral("Before cell heading")), heading, item,
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("rule")}, {QStringLiteral("spans"), QJsonArray{}}},
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("depth"), 1}, {QStringLiteral("table"), child}},
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{linked, explicitInk}}},
            block(QStringLiteral("paragraph"), QStringLiteral("After cell table"))};
        const QJsonObject cell{{QStringLiteral("header"), true}, {QStringLiteral("background"), QStringLiteral("#000000")},
            {QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), contents}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(table(cell), 0, 1, {}, QStringLiteral("block-0-0")));
            QTextDocument *document = window.reading_->document();
            const QString body = document->toPlainText();
            int previous = -1;
            for (const QString &part : {QStringLiteral("Before cell heading"), QStringLiteral("Cell heading"),
                     QStringLiteral("Cell list body"), QStringLiteral("Child cell body"), QStringLiteral("Cell linked body"),
                     QStringLiteral("After cell table")}) {
                QCOMPARE(body.count(part), 1); const int at = body.indexOf(part); QVERIFY(at > previous); previous = at;
            }
            QCOMPARE(document->find(QStringLiteral("Cell heading"), 0, QTextDocument::FindCaseSensitively).blockFormat().headingLevel(), 4);
            QCOMPARE(document->find(QStringLiteral("2."), 0, QTextDocument::FindCaseSensitively).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            bool ruleFound = false;
            for (QTextBlock part = document->begin(); part.isValid(); part = part.next()) {
                if (!part.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)) continue;
                ruleFound = true;
                QVERIFY(part.blockFormat().hasProperty(QTextFormat::BackgroundBrush));
                QCOMPARE(part.blockFormat().background().color(), QColor(QStringLiteral("#ffffff")));
            }
            QVERIFY(ruleFound);
            QCOMPARE(document->find(QStringLiteral("Before cell heading")).charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QVERIFY(document->find(QStringLiteral("Before cell heading")).charFormat().fontWeight() >= QFont::Bold);
            const QTextCursor link = document->find(QStringLiteral("Cell linked body"));
            QCOMPARE(link.charFormat().anchorHref(), QStringLiteral("dict:cat"));
            QCOMPARE(link.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
            QCOMPARE(document->find(QStringLiteral("Authored cell ink")).charFormat().foreground().color(), QColor(QStringLiteral("#ff0000")));
            QVERIFY(hasAnchor(document, QStringLiteral("block-0-0-row-0-cell-0-block-1")));
            auto *outer = qobject_cast<QTextTable *>(document->rootFrame()->childFrames().first()); QVERIFY(outer);
            QCOMPARE(outer->rows(), 1); QCOMPARE(outer->columns(), 1); QCOMPARE(outer->childFrames().size(), 1);
            auto *inner = qobject_cast<QTextTable *>(outer->childFrames().first()); QVERIFY(inner);
            QCOMPARE(inner->format().cellPadding(), qreal(2));
            QCOMPARE(inner->format().width().type(), QTextLength::PercentageLength); QCOMPARE(inner->format().width().rawValue(), qreal(100));
            QCOMPARE(inner->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#000000")));
            QApplication::processEvents();
            QCOMPARE(document->toPlainText(), body);
            QDir().mkpath(QStringLiteral(".tmp/ui-screenshots"));
            QVERIFY(window.reading_->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-synthetic-cell-blocks-%1.png").arg(theme)));
        }
        QJsonObject paleCell = cell;
        paleCell.insert(QStringLiteral("background"), QStringLiteral("#ffeecc"));
        QTextDocument paleDocument;
        paleDocument.setHtml(window.tableHtml(table(paleCell), 0));
        QCOMPARE(paleDocument.find(QStringLiteral("2."), 0, QTextDocument::FindCaseSensitively).charFormat().foreground().color(), QColor(QStringLiteral("#000000")));
        QCOMPARE(paleDocument.find(QStringLiteral("Authored cell ink")).charFormat().foreground().color(), QColor(QStringLiteral("#ff0000")));
        bool paleRuleFound = false;
        for (QTextBlock part = paleDocument.begin(); part.isValid(); part = part.next()) {
            if (!part.blockFormat().hasProperty(QTextFormat::BlockTrailingHorizontalRulerWidth)) continue;
            paleRuleFound = true;
            QVERIFY(part.blockFormat().hasProperty(QTextFormat::BackgroundBrush));
            QCOMPARE(part.blockFormat().background().color(), QColor(QStringLiteral("#000000")));
        }
        QVERIFY(paleRuleFound);
        QCOMPARE(window.blockHtml(QJsonObject{{QStringLiteral("kind"), QStringLiteral("rule")}}), QStringLiteral("<hr>"));
        QJsonObject caption = text(QStringLiteral("Inline cell caption"));
        caption.insert(QStringLiteral("kind"), QStringLiteral("link")); caption.insert(QStringLiteral("target"), QStringLiteral("File:Sample.svg"));
        caption.insert(QStringLiteral("classes"), QStringLiteral("wikidict-media"));
        const QJsonObject captionCell{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{
            QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{caption}}}}}};
        const QJsonObject entry{{QStringLiteral("title"), QStringLiteral("Cell media")}, {QStringLiteral("kind"), QStringLiteral("supplemental")},
            {QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Media owner")},
                {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), table(captionCell)}}}}}}},
            {QStringLiteral("media"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("image")}, {QStringLiteral("file"), QStringLiteral("Sample.svg")},
                {QStringLiteral("caption"), QStringLiteral("Inline cell caption")}}}}};
        QTextDocument media; media.setHtml(window.entryHtml(entry));
        QCOMPARE(media.toPlainText().count(QStringLiteral("Inline cell caption")), 1);
    }

    void orderedCellHeadingFragmentsStayInsideOwningSection() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto text = [](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}; };
        const auto paragraph = [&](const QString &value) { return QJsonObject{{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("spans"), QJsonArray{text(value)}}}; };
        const QString unicode(QChar(0x00e4));
        const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 2},
            {QStringLiteral("anchor"), unicode}, {QStringLiteral("anchor_fallback"), QStringLiteral(".C3.A4")},
            {QStringLiteral("spans"), QJsonArray{text(QStringLiteral("Cell destination"))}}};
        const QJsonObject emptyHeading{{QStringLiteral("kind"), QStringLiteral("heading")}, {QStringLiteral("level"), 5},
            {QStringLiteral("anchor"), QStringLiteral("Empty_cell_heading")}, {QStringLiteral("spans"), QJsonArray{}}};
        const QJsonObject cell{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{
            paragraph(QStringLiteral("Cell prefix")), heading, paragraph(QStringLiteral("CELL TARGET BODY")), emptyHeading}}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}};
        const QJsonObject tableBlock{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), table}};
        entry.insert(QStringLiteral("sections"), QJsonArray{
            QJsonObject{{QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("level"), 2},
                {QStringLiteral("anchor"), QStringLiteral("Other")}, {QStringLiteral("blocks"), QJsonArray{paragraph(QStringLiteral("OTHER BODY"))}}},
            QJsonObject{{QStringLiteral("title"), QStringLiteral("Cell owner")}, {QStringLiteral("level"), 2},
                {QStringLiteral("anchor"), QStringLiteral("Cell_owner")}, {QStringLiteral("blocks"), QJsonArray{tableBlock}}}});
        QJsonObject localLink{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("#") + unicode},
            {QStringLiteral("text"), QStringLiteral("Read cell destination")}};
        entry.insert(QStringLiteral("preamble_spans"), QJsonArray{localLink});
        response.insert(QStringLiteral("entries"), QJsonArray{entry}); window.renderResponse(QJsonDocument(response).toJson(), true);
        QCOMPARE(window.sections_->count(), 3); // Cell-local headings are not promoted to top-level navigation.
        window.collapsedSections_ = {0, 1}; window.refreshReading(); window.jumpToFragment(unicode);
        QVERIFY(window.collapsedSections_.contains(0)); QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("CELL TARGET BODY")));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-1-0-row-0-cell-0-block-1")));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Cell destination"), 0, QTextDocument::FindCaseSensitively).blockFormat().headingLevel(), 2);
        window.collapsedSections_.insert(1); window.refreshReading(); window.jumpToFragment(QStringLiteral(".C3.A4"));
        QVERIFY(!window.collapsedSections_.contains(1)); QVERIFY(textIsVisible(window.reading_, QStringLiteral("CELL TARGET BODY")));
        window.collapsedSections_.insert(1); window.refreshReading(); window.jumpToFragment(QStringLiteral("Empty_cell_heading"));
        QVERIFY(!window.collapsedSections_.contains(1));
        QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("block-1-0-row-0-cell-0-block-3")));
    }

    void orderedCellAuthorityAndDepthAreValidated() {
        MainWindow window{QString()};
        const auto table = [](const QJsonObject &cell) { return QJsonObject{{QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{cell}}}}}}; };
        const QJsonObject empty{{QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("blocks"), QJsonArray{}}, {QStringLiteral("background"), QStringLiteral("#800080")}};
        QJsonObject legacy = empty; legacy.remove(QStringLiteral("blocks"));
        QCOMPARE(window.tableHtml(table(empty), 0), window.tableHtml(table(legacy), 0));
        QJsonObject invalid = empty; invalid.insert(QStringLiteral("blocks"), QStringLiteral("not blocks"));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("spans"), QJsonArray{QJsonObject{{QStringLiteral("text"), QStringLiteral("ambiguous")}}});
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("nested_table"), table(legacy));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        invalid = empty; invalid.insert(QStringLiteral("blocks"), QJsonArray{QStringLiteral("not a block")});
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(table(invalid), 0), DictApiError);
        QJsonObject nested = table(empty);
        const auto wrap = [&](const QJsonObject &child) { return table(QJsonObject{{QStringLiteral("spans"), QJsonArray{}},
            {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("table"), child}}}}}); };
        for (int i = 1; i < 16; ++i) nested = wrap(nested);
        QVERIFY(!window.tableHtml(nested, 0).isEmpty());
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(wrap(nested), 0), DictApiError);
    }

    void nestedSemanticTablesKeepOuterGridAndEmptyPaintedHeaders() {
        MainWindow window{QString()};
        QJsonArray outerCells;
        for (int i = 0; i < 4; ++i) {
            const QJsonObject emptyHeader{{QStringLiteral("header"), true}, {QStringLiteral("colspan"), 5},
                {QStringLiteral("background"), QStringLiteral("#800080")}, {QStringLiteral("spans"), QJsonArray{}}};
            QJsonArray cells;
            for (int j = 0; j < 4; ++j) cells.append(QJsonObject{{QStringLiteral("spans"), QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("dog")},
                {QStringLiteral("text"), QStringLiteral("form %1 %2").arg(i).arg(j)}}}}});
            const QJsonObject child{{QStringLiteral("geometry"), QJsonObject{{QStringLiteral("border"), 1}, {QStringLiteral("cell_padding"), 2},
                {QStringLiteral("width"), QJsonObject{{QStringLiteral("unit"), QStringLiteral("percent")}, {QStringLiteral("value"), 100}}}}},
                {QStringLiteral("caption"), QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")}, {QStringLiteral("target"), QStringLiteral("dog")},
                    {QStringLiteral("text"), QStringLiteral("child caption %1").arg(i)}}}},
                {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), QJsonArray{emptyHeader}}}, QJsonObject{{QStringLiteral("cells"), cells}}}}};
            outerCells.append(QJsonObject{{QStringLiteral("background"), QStringLiteral("#000000")}, {QStringLiteral("spans"), QJsonArray{}}, {QStringLiteral("nested_table"), child}});
        }
        const QJsonObject outer{{QStringLiteral("geometry"), QJsonObject{{QStringLiteral("border"), 0}, {QStringLiteral("cell_spacing"), 15}}},
            {QStringLiteral("rows"), QJsonArray{QJsonObject{{QStringLiteral("cells"), outerCells}}}}};
        for (const QString &theme : {QStringLiteral("light"), QStringLiteral("dark")}) {
            window.learning_.setTheme(theme); window.applyTheme();
            window.reading_->setHtml(window.tableHtml(outer, 0));
            auto *grid = qobject_cast<QTextTable *>(window.reading_->document()->rootFrame()->childFrames().first());
            QVERIFY(grid); QCOMPARE(grid->rows(), 1); QCOMPARE(grid->columns(), 4);
            QCOMPARE(grid->format().cellSpacing(), qreal(15));
            QCOMPARE(grid->childFrames().size(), 4);
            for (auto *frame : grid->childFrames()) {
                auto *child = qobject_cast<QTextTable *>(frame); QVERIFY(child);
                QCOMPARE(child->rows(), 2); QCOMPARE(child->columns(), 5);
                QCOMPARE(child->format().cellPadding(), qreal(2));
                QCOMPARE(child->cellAt(0, 0).columnSpan(), 5);
                QCOMPARE(child->cellAt(0, 0).format().background().color(), QColor(QStringLiteral("#800080")));
                QTextCursor empty = child->cellAt(0, 0).firstCursorPosition();
                QCOMPARE(empty.block().text(), QString());
                const auto form = window.reading_->document()->find(QStringLiteral("form 0 0"));
                QVERIFY(!form.isNull()); QVERIFY(form.charFormat().isAnchor());
                QCOMPARE(form.charFormat().anchorHref(), QStringLiteral("dict:dog"));
                QCOMPARE(form.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
                QCOMPARE(child->cellAt(1, 0).format().background().color(), QColor(QStringLiteral("#000000")));
                const auto caption = window.reading_->document()->find(QStringLiteral("child caption 0"));
                QVERIFY(!caption.isNull()); QCOMPARE(caption.charFormat().foreground().color(), QColor(QStringLiteral("#ffffff")));
                auto *accessible = QAccessible::queryAccessibleInterface(window.reading_); QVERIFY(accessible && accessible->textInterface());
                int start = -1, end = -1;
                const QString attributes = accessible->textInterface()->attributes(form.selectionStart(), &start, &end);
                QVERIFY(attributes.contains(QStringLiteral("background-color:rgb(0,0,0)")));
            }
        }
        QJsonObject missingSpacing = outer;
        QJsonObject geometry = outer.value(QStringLiteral("geometry")).toObject(); geometry.remove(QStringLiteral("cell_spacing"));
        missingSpacing.insert(QStringLiteral("geometry"), geometry);
        const QString absentHtml = window.tableHtml(missingSpacing, 0);
        geometry.insert(QStringLiteral("cell_spacing"), QJsonValue::Null); missingSpacing.insert(QStringLiteral("geometry"), geometry);
        QCOMPARE(window.tableHtml(missingSpacing, 0), absentHtml);
        geometry.insert(QStringLiteral("cell_spacing"), 0); missingSpacing.insert(QStringLiteral("geometry"), geometry);
        QVERIFY(window.tableHtml(missingSpacing, 0).contains(QStringLiteral("border-collapse:separate")));
        missingSpacing.insert(QStringLiteral("geometry"), QStringLiteral("invalid"));
        QVERIFY_EXCEPTION_THROWN(window.tableHtml(missingSpacing, 0), DictApiError);
    }

    void typedColorSwatchRendersWithAccessibleTextAndKeepsFallback() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QJsonArray fallbackSpans{QJsonObject{{QStringLiteral("kind"), QStringLiteral("link")},
            {QStringLiteral("text"), QStringLiteral("Fallback link")}, {QStringLiteral("target"), QStringLiteral("yellow")}}};
        const QJsonObject cell{{QStringLiteral("spans"), fallbackSpans}};
        const QJsonObject row{{QStringLiteral("cells"), QJsonArray{cell}}};
        const QJsonObject table{{QStringLiteral("rows"), QJsonArray{row}}};
        const QJsonObject ordinary{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("depth"), 2},
            {QStringLiteral("table"), table}};
        const QString fallback = window.blockHtml(ordinary);
        const auto featured = [&](const QString &kind, const QJsonValue &data) {
            QJsonObject block = ordinary;
            block.insert(QStringLiteral("feature"), QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("data"), data}});
            return block;
        };
        for (const QJsonValue &invalid : {QJsonValue(QStringLiteral("#FFFF00")), QJsonValue(QStringLiteral("#ff0")),
                QJsonValue(QStringLiteral("#ffff00;")), QJsonValue(QStringLiteral("#gggggg")), QJsonValue(123), QJsonValue()})
            QCOMPARE(window.blockHtml(featured(QStringLiteral("color_swatch"), invalid)), fallback);
        QCOMPARE(window.blockHtml(featured(QStringLiteral("unknown"), QStringLiteral("#ffff00"))), fallback);
        for (const auto &extra : {qMakePair(QStringLiteral("language"), QStringLiteral("en")),
                qMakePair(QStringLiteral("tail_kind"), QStringLiteral("text")),
                qMakePair(QStringLiteral("tail"), QStringLiteral("retained semantic tail"))}) {
            QJsonObject block = featured(QStringLiteral("color_swatch"), QStringLiteral("#ffff00"));
            QJsonObject feature = block.value(QStringLiteral("feature")).toObject();
            feature.insert(extra.first, extra.second);
            block.insert(QStringLiteral("feature"), feature);
            QCOMPARE(window.blockHtml(block), fallback);
        }
        for (const QString &color : {QStringLiteral("#ffff00"), QStringLiteral("#000000"), QStringLiteral("#ffffff")}) {
            window.reading_->setHtml(window.blockHtml(featured(QStringLiteral("color_swatch"), color)));
            const QString label = QStringLiteral("Color sample ") + color;
            QCOMPARE(window.reading_->toPlainText().count(label), 1);
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Fallback link")));
            QTextTable *sample = nullptr;
            for (QTextFrame *frame : window.reading_->document()->rootFrame()->childFrames())
                if (auto *candidate = qobject_cast<QTextTable *>(frame)) { sample = candidate; break; }
            QVERIFY(sample);
            QCOMPARE(sample->cellAt(0, 0).format().background().color(), QColor(color));
            QCOMPARE(sample->format().leftMargin(), qreal(46));
            for (QTextBlock block = window.reading_->document()->begin(); block.isValid(); block = block.next())
                for (auto it = block.begin(); !it.atEnd(); ++it)
                    QVERIFY(!it.fragment().charFormat().isAnchor());
        }
        window.resize(580, 480);
        window.show();
        window.reading_->setHtml(window.blockHtml(featured(QStringLiteral("color_swatch"), QStringLiteral("#ffff00"))));
        window.reading_->setFocus();
        QTRY_VERIFY(window.reading_->hasFocus());
        QTRY_VERIFY(textIsVisible(window.reading_, QStringLiteral("Color sample #ffff00")));
        const QImage rendered = window.reading_->viewport()->grab().toImage();
        int yellowPixels = 0;
        for (int y = 0; y < rendered.height(); ++y)
            for (int x = 0; x < rendered.width(); ++x)
                if (rendered.pixelColor(x, y) == QColor(QStringLiteral("#ffff00"))) ++yellowPixels;
        QVERIFY(yellowPixels >= 100);
        auto *accessible = QAccessible::queryAccessibleInterface(window.reading_);
        QVERIFY(accessible);
        auto *accessibleText = accessible->textInterface();
        QVERIFY(accessibleText);
        QCOMPARE(accessibleText->text(0, accessibleText->characterCount()).count(QStringLiteral("Color sample #ffff00")), 1);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-color-swatch.png")));
        QTest::keyClick(window.reading_, Qt::Key_A, Qt::ControlModifier);
        QVERIFY(window.reading_->textCursor().selectedText().contains(QStringLiteral("Color sample #ffff00")));
        QTest::keyClick(window.reading_, Qt::Key_Tab);
        QTRY_VERIFY(QApplication::focusWidget() != nullptr && QApplication::focusWidget() != window.reading_);
    }

    void nestedTablesKeepTheirCompiledDepth() {
        MainWindow window{QString()};
        const auto block = [](int depth, const QString &caption) {
            const auto text = [](const QString &value) { return QJsonArray{QJsonObject{
                {QStringLiteral("kind"), QStringLiteral("text")}, {QStringLiteral("text"), value}}}; };
            const QJsonObject cell{{QStringLiteral("colspan"), 1}, {QStringLiteral("rowspan"), 1},
                {QStringLiteral("spans"), text(QStringLiteral("Cell"))}};
            const QJsonObject row{{QStringLiteral("cells"), QJsonArray{cell}}};
            const QJsonObject table{{QStringLiteral("caption"), text(caption)}, {QStringLiteral("rows"), QJsonArray{row}}};
            return QJsonObject{{QStringLiteral("kind"), QStringLiteral("table")}, {QStringLiteral("depth"), depth},
                {QStringLiteral("list_path"), depth ? QStringLiteral("#:") : QString()}, {QStringLiteral("table"), table}};
        };
        QTextDocument document;
        document.setHtml(window.blockHtml(block(0, QStringLiteral("Outer caption"))) + window.blockHtml(block(2, QStringLiteral("Nested caption"))));
        QList<QTextTable *> tables;
        for(QTextFrame *frame : document.rootFrame()->childFrames())
            if(auto *table = qobject_cast<QTextTable *>(frame)) tables.append(table);
        QCOMPARE(tables.size(), 2);
        QCOMPARE(tables[0]->format().leftMargin(), 0.0);
        QCOMPARE(tables[1]->format().leftMargin(), 46.0);
        QCOMPARE(tables[1]->rows(), 1);
        QCOMPARE(tables[1]->columns(), 1);
        QVERIFY(document.toPlainText().contains(QStringLiteral("Outer caption")));
        QVERIFY(document.toPlainText().contains(QStringLiteral("Nested caption")));
    }

    void savedPreviewSkipsAudioControlsAndKeepsLinkedMeanings() {
        MainWindow window{QString()};
        const auto span = [](const QString &text, const QString &classes = QString(), const QString &target = QString()) {
            return QJsonObject{{QStringLiteral("kind"), target.isEmpty() ? QStringLiteral("text") : QStringLiteral("link")},
                {QStringLiteral("text"), text}, {QStringLiteral("classes"), classes}, {QStringLiteral("target"), target}};
        };
        const auto block = [](const QString &kind, const QJsonArray &spans) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("spans"), spans}};
        };
        const auto section = [](const QString &title, const QJsonArray &blocks) {
            return QJsonObject{{QStringLiteral("title"), title}, {QStringLiteral("blocks"), blocks}};
        };
        // Actual AF144 spinal cord shape: no definition blocks; pronunciation
        // controls precede an ordinary linked meaning, both compiled as indents.
        const QJsonObject audio = block(QStringLiteral("indent"), QJsonArray{
            span(QStringLiteral("\u00a0\u00a0")),
            span(QStringLiteral("Nuvola apps amarok.png"), QStringLiteral("wikidict-media"), QStringLiteral("File:Nuvola apps amarok.png")),
            span(QStringLiteral("\u00a0")),
            span(QStringLiteral("LL-Q1860 (eng)-Vealhurl-spinal cord.wav"), QStringLiteral("wikidict-media"), QStringLiteral("File:LL-Q1860 (eng)-Vealhurl-spinal cord.wav")),
            span(QStringLiteral("("), QStringLiteral("audiotable")),
            span(QStringLiteral("lêer"), QStringLiteral("audiotable"), QStringLiteral("Image:LL-Q1860 (eng)-Vealhurl-spinal cord.wav")),
            span(QStringLiteral(")"), QStringLiteral("audiotable"))});
        const QJsonObject meaning = block(QStringLiteral("indent"), QJsonArray{
            span(QStringLiteral("(")), span(QStringLiteral("anatomie"), {}, QStringLiteral("anatomie")),
            span(QStringLiteral(") ")), span(QStringLiteral("Rugmurg"), {}, QStringLiteral("rugmurg"))});
        QJsonObject entry{{QStringLiteral("title"), QStringLiteral("spinal cord")}, {QStringLiteral("sections"), QJsonArray{
            section(QStringLiteral("Engels (en)"), QJsonArray{block(QStringLiteral("paragraph"), QJsonArray{span(QStringLiteral(" "))}), block(QStringLiteral("table"), {})}),
            section(QStringLiteral("Uitspraak"), QJsonArray{audio}),
            section(QStringLiteral("Selfstandige naamwoord"), {}),
            section(QStringLiteral("Betekenisse"), QJsonArray{meaning})}}};
        const QJsonObject original = entry;
        QCOMPARE(window.clueFor(entry), QStringLiteral("(anatomie) Rugmurg"));
        QCOMPARE(entry, original); // Preview selection never edits the reading body.

        QJsonArray sections = entry.value(QStringLiteral("sections")).toArray();
        sections.append(section(QStringLiteral("Other"), QJsonArray{
            block(QStringLiteral("definition"), QJsonArray{span(QStringLiteral(" "))}),
            block(QStringLiteral("definition"), QJsonArray{span(QStringLiteral("Preferred definition."))})}));
        entry.insert(QStringLiteral("sections"), sections);
        QCOMPARE(window.clueFor(entry), QStringLiteral("Preferred definition."));

        entry.insert(QStringLiteral("sections"), QJsonArray{section({}, QJsonArray{audio})});
        QCOMPARE(window.clueFor(entry), QStringLiteral("Definition unavailable in this entry."));
        entry.insert(QStringLiteral("sections"), QJsonArray{section({}, QJsonArray{
            block(QStringLiteral("paragraph"), QJsonArray{
                span(QStringLiteral("controls.wav"), QStringLiteral("other\taudiotable  note"), QStringLiteral("File:controls.wav")),
                span(QStringLiteral("Useful linked prose"), QStringLiteral("not-audiotable"), QStringLiteral("ordinary")),
                span(QStringLiteral(" example.wav"), {}, QStringLiteral("example.wav"))})})});
        QCOMPARE(window.clueFor(entry), QStringLiteral("Useful linked prose example.wav"));
    }

    void savedListsRemoveSelectedWordInsteadOfCurrent_data() {
        QTest::addColumn<bool>("bookmarks");
        QTest::addColumn<bool>("staleCurrent");
        QTest::newRow("history-null-current") << false << false;
        QTest::newRow("history-stale-current") << false << true;
        QTest::newRow("saved-null-current") << true << false;
        QTest::newRow("saved-stale-current") << true << true;
    }

    void savedListsRemoveSelectedWordInsteadOfCurrent() {
        QFETCH(bool, bookmarks);
        QFETCH(bool, staleCurrent);
        MainWindow window{QString()};
        for (const QString &key : {QStringLiteral("first"), QStringLiteral("second")}) {
            SavedWord word;
            word.key = key;
            word.title = key;
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Saved meaning for %1").arg(key);
            word.originRoot = QStringLiteral("/saved-fixture/%1").arg(key);
            word.originEdition = QStringLiteral("enwiktionary-20261001");
            if (bookmarks) window.learning_.toggleBookmark(word);
            else window.learning_.record(word);
        }
        const int tab = bookmarks ? 1 : 0;
        const QString emptyText = bookmarks ? QStringLiteral("No bookmarks yet.") : QStringLiteral("No history yet.");
        const QString removeText = bookmarks ? QStringLiteral("Remove selected bookmark") : QStringLiteral("Remove selected word");
        auto words = [&]() { return bookmarks ? window.learning_.bookmarks() : window.learning_.history(); };
        bool exercised = false;
        bool removalCompleted = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *page = tabs->widget(tab);
            auto *list = page->findChild<QListWidget *>();
            auto *remove = buttonWithText(page, removeText);
            QVERIFY(list && remove);
            QCOMPARE(list->count(), 2);
            const QString keepKey = list->item(0)->data(Qt::UserRole).toString();
            const QString selectedKey = list->item(1)->data(Qt::UserRole).toString();
            QVERIFY(keepKey != selectedKey);
            list->setCurrentRow(0);
            list->selectionModel()->setCurrentIndex(staleCurrent ? list->model()->index(0, 0) : QModelIndex(), QItemSelectionModel::NoUpdate);
            list->selectionModel()->select(list->model()->index(1, 0), QItemSelectionModel::ClearAndSelect);
            QCOMPARE(list->selectedItems().size(), 1);
            QCOMPARE(list->selectedItems().first()->data(Qt::UserRole).toString(), selectedKey);
            if (staleCurrent) QCOMPARE(list->currentItem()->data(Qt::UserRole).toString(), keepKey);
            else QVERIFY(!list->currentItem());
            QVERIFY(remove->isEnabled());
            QTest::mouseClick(remove, Qt::LeftButton);
            QCOMPARE(words().size(), 1);
            QCOMPARE(words().first().key, keepKey);
            QCOMPARE(words().first().originRoot, QStringLiteral("/saved-fixture/%1").arg(keepKey));

            // A current row without selection must never remove another saved word.
            list->setCurrentRow(0);
            list->clearSelection();
            QVERIFY(list->currentItem());
            QVERIFY(!remove->isEnabled());
            remove->click();
            QCOMPARE(words().size(), 1);
            list->selectionModel()->select(list->model()->index(0, 0), QItemSelectionModel::ClearAndSelect);
            QVERIFY(remove->isEnabled());
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(words().isEmpty());
            QCOMPARE(list->count(), 1);
            QCOMPARE(list->item(0)->text(), emptyText);
            QVERIFY(!(list->item(0)->flags() & Qt::ItemIsEnabled));
            list->setCurrentRow(0);
            QVERIFY(!remove->isEnabled());
            remove->click();
            QVERIFY(words().isEmpty());
            QCOMPARE(list->count(), 1);
            removalCompleted = true;
        });
        window.showLearningDialog(tab);
        QVERIFY(exercised);
        // The baseline already recorded its single row failure in the modal callback.
        if (!removalCompleted) return;

        bool reopenedEmpty = false;
        QTimer::singleShot(0, &window, [&] {
            reopenedEmpty = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *list = tabs->widget(tab)->findChild<QListWidget *>();
            auto *remove = buttonWithText(tabs->widget(tab), removeText);
            QVERIFY(list && remove);
            QCOMPARE(list->count(), 1);
            QCOMPARE(list->item(0)->text(), emptyText);
            QVERIFY(!(list->item(0)->flags() & Qt::ItemIsEnabled));
            QVERIFY(!remove->isEnabled());
        });
        window.showLearningDialog(tab);
        QVERIFY(reopenedEmpty);
    }

    void definitionQuizUsesDistinctVisibleTitles_data() {
        QTest::addColumn<bool>("hasOtherTitle");
        QTest::newRow("duplicate-owners-only") << false;
        QTest::newRow("duplicate-owners-and-other-title") << true;
    }

    void definitionQuizUsesDistinctVisibleTitles() {
        QFETCH(bool, hasOtherTitle);
        MainWindow window{QString()};
        QVector<SavedWord> expected;
        for (int index = 0; index < (hasOtherTitle ? 3 : 2); ++index) {
            SavedWord word;
            word.key = QStringLiteral("owner-key-%1").arg(index);
            word.title = index == 2 ? QStringLiteral("dog") : QStringLiteral("cat");
            word.language = index == 1 ? QStringLiteral("French") : QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Meaning from owner %1").arg(index);
            word.originRoot = QStringLiteral("/quiz-owner/%1").arg(index);
            word.originEdition = QStringLiteral("edition-%1").arg(index);
            expected.append(word);
            window.learning_.toggleBookmark(word);
        }
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        QCOMPARE(window.learningPool().size(), expected.size());
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            QVERIFY(games);
            QWidget *quiz = games->widget(0);
            auto *next = buttonWithText(quiz, QStringLiteral("Next"));
            QVERIFY(next);
            QVector<QPushButton *> choices;
            for (auto *button : quiz->findChildren<QPushButton *>()) if (button != next && button->isVisible()) choices.append(button);
            if (!hasOtherTitle) {
                QVERIFY(hasLabel(quiz, QStringLiteral("Open or bookmark at least two different words first.")));
                QVERIFY(choices.isEmpty());
                QVERIFY(!next->isEnabled());
                QCOMPARE(window.learning_.answerCount(), 0);
                return;
            }
            QCOMPARE(choices.size(), 2);
            QSet<QString> labels;
            for (auto *button : choices) { QVERIFY(button->isEnabled()); labels.insert(button->text()); }
            QCOMPARE(labels, (QSet<QString>{QStringLiteral("cat"), QStringLiteral("dog")}));
            // Randomness selects the real question; its displayed clue identifies the exact owner.
            const SavedWord *question = nullptr;
            for (const SavedWord &word : expected) if (hasLabel(quiz, word.clue)) question = &word;
            QVERIFY(question);
            auto *correct = buttonWithText(quiz, question->title);
            QVERIFY(correct);
            QTest::mouseClick(correct, Qt::LeftButton);
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(question->key).right, 1);
            for (const SavedWord &word : expected) {
                QCOMPARE(window.learning_.study().value(word.key).wrong, 0);
                if (word.key != question->key) QCOMPARE(window.learning_.study().value(word.key).right, 0);
            }
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
        QCOMPARE(window.learning_.bookmarks().size(), expected.size());
        for (const SavedWord &word : expected) {
            const auto saved = window.learning_.bookmarks();
            const auto it = std::find_if(saved.cbegin(), saved.cend(), [&](const SavedWord &value) { return value.key == word.key; });
            QVERIFY(it != saved.cend());
            QCOMPARE(it->originRoot, word.originRoot);
            QCOMPARE(it->originEdition, word.originEdition);
            QCOMPARE(it->language, word.language);
            QCOMPARE(it->title, word.title);
        }
    }

    void definitionQuizKeepsLiteralAmpersands() {
        MainWindow window{QString()};
        QVector<SavedWord> expected;
        for (const QString &title : {QStringLiteral("R&B"), QStringLiteral("RB")}) {
            SavedWord word;
            word.key = QStringLiteral("quiz-key-") + title;
            word.title = title;
            word.language = QStringLiteral("English");
            word.kind = QStringLiteral("language");
            word.clue = QStringLiteral("Meaning for ") + title;
            word.originRoot = QStringLiteral("/ampersand-fixture");
            word.originEdition = QStringLiteral("enwiktionary-20261001");
            expected.append(word);
            window.learning_.toggleBookmark(word);
        }
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *child : window.findChildren<QDialog *>()) child->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            QVERIFY(games);
            QWidget *quiz = games->widget(0);
            auto *literal = buttonWithText(quiz, QStringLiteral("R&&B"));
            auto *plain = buttonWithText(quiz, QStringLiteral("RB"));
            QVERIFY(literal && plain);
            QVERIFY(literal->isVisible() && plain->isVisible());
            QVERIFY(QKeySequence::mnemonic(literal->text()).isEmpty());
            QVERIFY(QKeySequence::mnemonic(plain->text()).isEmpty());
            // Qt's real display-mnemonic parser must retain the literal ampersand glyph.
            const QFontMetrics metrics(literal->font());
            QCOMPARE(metrics.size(Qt::TextSingleLine | Qt::TextShowMnemonic, literal->text()).width(),
                     metrics.size(Qt::TextSingleLine, QStringLiteral("R&B")).width());
            QVERIFY(metrics.size(Qt::TextSingleLine, QStringLiteral("R&B")).width() >
                    metrics.size(Qt::TextSingleLine, QStringLiteral("RB")).width());
            const SavedWord *question = nullptr;
            for (const SavedWord &word : expected) if (hasLabel(quiz, word.clue)) question = &word;
            QVERIFY(question);
            auto *correct = question->title == QStringLiteral("R&B") ? literal : plain;
            QCOMPARE(correct->property("wordKey").toString(), question->key);
            QTest::mouseClick(correct, Qt::LeftButton);
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(question->key).right, 1);
            for (const SavedWord &word : expected) if (word.key != question->key)
                QCOMPARE(window.learning_.study().value(word.key).right, 0);
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
        QCOMPARE(window.learning_.bookmarks().size(), 2);
        QVERIFY(window.learning_.isBookmarked(QStringLiteral("quiz-key-R&B")));
        QVERIFY(window.learning_.isBookmarked(QStringLiteral("quiz-key-RB")));
    }

    void learningSourceChangesWithoutReopeningDialog() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QJsonObject dogEntry = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("dog"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        const SavedWord dog = window.savedWord(dogEntry);
        window.learning_.toggleBookmark(dog);
        window.learning_.setRandomPool(QStringLiteral("history"));
        QCOMPARE(window.learningPool().size(), 1);
        QCOMPARE(window.learningPool().first().title, QStringLiteral("cat"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *dialog : window.findChildren<QDialog *>()) dialog->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            QWidget *learn = tabs->widget(2);
            auto *games = learn->findChild<QStackedWidget *>();
            auto *picker = learn->findChild<QComboBox *>();
            QVERIFY(games && picker);
            picker->setCurrentIndex(picker->findText(QStringLiteral("Flashcards")));
            QCOMPARE(picker->currentText(), QStringLiteral("Flashcards"));
            QCOMPARE(games->currentIndex(), 1);
            QStringList cardLabels;
            for (auto *label : games->currentWidget()->findChildren<QLabel *>()) cardLabels.append(label->text());
            QVERIFY2(hasLabel(games->currentWidget(), QStringLiteral("cat")), qPrintable(cardLabels.join(QStringLiteral(" | "))));

            QTest::mouseClick(tabs->tabBar(), Qt::LeftButton, Qt::NoModifier, tabs->tabBar()->tabRect(3).center());
            QCOMPARE(tabs->currentIndex(), 3);
            QComboBox *source = nullptr;
            for (auto *combo : tabs->widget(3)->findChildren<QComboBox *>()) {
                if (combo->findData(QStringLiteral("history")) >= 0) { source = combo; break; }
            }
            QVERIFY(source);
            QCOMPARE(source->currentData().toString(), QStringLiteral("history"));
            QTest::keyClick(source, Qt::Key_Down);
            QCOMPARE(source->currentData().toString(), QStringLiteral("bookmarks"));
            QTest::mouseClick(tabs->tabBar(), Qt::LeftButton, Qt::NoModifier, tabs->tabBar()->tabRect(2).center());
            QCOMPARE(tabs->currentIndex(), 2);
            QVERIFY(hasLabel(games->currentWidget(), QStringLiteral("dog")));
            QVERIFY(!hasLabel(games->currentWidget(), QStringLiteral("cat")));

            QTest::mouseClick(tabs->tabBar(), Qt::LeftButton, Qt::NoModifier, tabs->tabBar()->tabRect(1).center());
            auto *bookmarks = tabs->widget(1)->findChild<QListWidget *>();
            auto *remove = buttonWithText(tabs->widget(1), QStringLiteral("Remove selected bookmark"));
            QVERIFY(bookmarks && remove);
            QCOMPARE(bookmarks->count(), 1);
            bookmarks->setCurrentRow(0);
            QTest::mouseClick(remove, Qt::LeftButton);
            QVERIFY(window.learning_.bookmarks().isEmpty());
            QTest::mouseClick(tabs->tabBar(), Qt::LeftButton, Qt::NoModifier, tabs->tabBar()->tabRect(2).center());
            QVERIFY(hasLabel(games->currentWidget(), QStringLiteral("No words yet")));
            picker->setCurrentIndex(picker->findText(QStringLiteral("Unscramble")));
            auto *input = games->currentWidget()->findChild<QLineEdit *>();
            QVERIFY(input);
            const int before = window.learning_.answerCount();
            QTest::keyClick(input, Qt::Key_Return);
            QCOMPARE(window.learning_.answerCount(), before);
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
    }

    void scrambleScoresEachRoundOnce() {
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        const SavedWord word = window.savedWord(window.currentEntry_);
        window.learning_.toggleBookmark(word);
        QCOMPARE(window.learningPool().size(), 1);
        QCOMPARE(window.learningPool().first().title, QStringLiteral("dog"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *dialog : window.findChildren<QDialog *>()) dialog->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            auto *picker = tabs->widget(2)->findChild<QComboBox *>();
            QVERIFY(games && picker);
            picker->setCurrentIndex(picker->findText(QStringLiteral("Unscramble")));
            QCOMPARE(picker->currentText(), QStringLiteral("Unscramble"));
            QCOMPARE(games->currentIndex(), 2);
            auto *input = games->currentWidget()->findChild<QLineEdit *>();
            auto *next = buttonWithText(games->currentWidget(), QStringLiteral("Next"));
            QVERIFY(input && next);
            QVERIFY(input->isEnabled());
            auto *inputAccessible = QAccessible::queryAccessibleInterface(input);
            QVERIFY(inputAccessible);
            QCOMPARE(inputAccessible->text(QAccessible::Name), QStringLiteral("Unscramble answer"));
            QTest::keyClicks(input, "dog");
            QCOMPARE(input->text(), QStringLiteral("dog"));
            QCOMPARE(inputAccessible->text(QAccessible::Name), QStringLiteral("Unscramble answer"));
            QTest::keyClick(input, Qt::Key_Return);
            QVERIFY(dialog->isVisible());
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(word.key).right, 1);
            QTest::keyClick(input, Qt::Key_Return);
            QTest::keyClick(input, Qt::Key_A, Qt::ControlModifier);
            QTest::keyClicks(input, "cat");
            QTest::keyClick(input, Qt::Key_Return);
            QCOMPARE(window.learning_.answerCount(), 1);
            QVERIFY(next->isVisible());
            QTest::mouseClick(next, Qt::LeftButton);
            QTest::keyClicks(input, "cat");
            QTest::keyClick(input, Qt::Key_Return);
            QCOMPARE(window.learning_.answerCount(), 2);
            QCOMPARE(window.learning_.study().value(word.key).wrong, 1);
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
    }

    void scrambleAcceptsCanonicalAnswers_data() {
        QTest::addColumn<QString>("wordTitle");
        QTest::addColumn<QString>("answer");
        QTest::addColumn<bool>("correct");
        QTest::newRow("nfc-title-nfd-answer") << QStringLiteral("caf\u00e9") << QStringLiteral(" CAFE\u0301 ") << true;
        QTest::newRow("nfd-title-nfc-answer") << QStringLiteral("cafe\u0301") << QStringLiteral("CAF\u00c9") << true;
        QTest::newRow("missing-accent") << QStringLiteral("caf\u00e9") << QStringLiteral("cafe") << false;
        QTest::newRow("different-accent") << QStringLiteral("caf\u00e9") << QStringLiteral("caf\u00e8") << false;
        QTest::newRow("compatibility-not-canonical") << QStringLiteral("\uff43\uff41\uff46\uff45") << QStringLiteral("cafe") << false;
    }

    void scrambleAcceptsCanonicalAnswers() {
        QFETCH(QString, wordTitle);
        QFETCH(QString, answer);
        QFETCH(bool, correct);
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        SavedWord word = window.savedWord(window.currentEntry_);
        word.title = wordTitle;
        word.clue = QStringLiteral("Controlled canonical-equivalence practice word");
        window.learning_.toggleBookmark(word);
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            const auto close = qScopeGuard([&] { for (auto *dialog : window.findChildren<QDialog *>()) dialog->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            auto *picker = tabs->widget(2)->findChild<QComboBox *>();
            QVERIFY(games && picker);
            picker->setCurrentIndex(picker->findText(QStringLiteral("Unscramble")));
            QWidget *practice = games->currentWidget();
            auto *input = practice->findChild<QLineEdit *>();
            QVERIFY(input && input->isEnabled());
            input->setText(answer);
            QTest::keyClick(input, Qt::Key_Return);
            QVERIFY(hasLabel(practice, correct ? QStringLiteral("Correct.") : QStringLiteral("Answer: %1").arg(wordTitle)));
            QCOMPARE(window.learning_.answerCount(), 1);
            QCOMPARE(window.learning_.study().value(word.key).right, correct ? 1 : 0);
            QCOMPARE(window.learning_.study().value(word.key).wrong, correct ? 0 : 1);
            QCOMPARE(window.learning_.bookmarks().first().title, wordTitle);
            QCOMPARE(window.learning_.bookmarks().first().key, word.key);
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-canonical-answer-%1.png").arg(QString::fromLatin1(QTest::currentDataTag()))));
            exercised = true;
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
    }

    void scrambleRequiresThreeGraphemes_data() {
        QTest::addColumn<QStringList>("clusters");
        QTest::newRow("one-combining") << QStringList{QStringLiteral("e\u0301\u0323")};
        QTest::newRow("two-combining") << QStringList{QStringLiteral("e\u0301"), QStringLiteral("t")};
        QTest::newRow("one-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c")};
        QTest::newRow("two-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c"), QStringLiteral("a")};
        QTest::newRow("three-combining") << QStringList{QStringLiteral("e\u0301"), QStringLiteral("a\u0308"), QStringLiteral("t")};
        QTest::newRow("three-joined-emoji") << QStringList{QString::fromUtf8("\U0001f469\u200d\U0001f52c"), QStringLiteral("a"), QStringLiteral("b")};
    }

    void scrambleRequiresThreeGraphemes() {
        QFETCH(QStringList, clusters);
        MainWindow window(fixture_, QStringLiteral("dog"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
        SavedWord word = window.savedWord(window.currentEntry_);
        word.title = clusters.join(QString());
        word.clue = QStringLiteral("Controlled grapheme practice word");
        window.learning_.toggleBookmark(word);
        window.learning_.setRandomPool(QStringLiteral("bookmarks"));
        bool exercised = false;
        QTimer::singleShot(0, &window, [&] {
            exercised = true;
            const auto close = qScopeGuard([&] { for (auto *dialog : window.findChildren<QDialog *>()) dialog->reject(); });
            auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
            QVERIFY(dialog);
            auto *tabs = dialog->findChild<QTabWidget *>();
            QVERIFY(tabs);
            auto *games = tabs->widget(2)->findChild<QStackedWidget *>();
            auto *picker = tabs->widget(2)->findChild<QComboBox *>();
            QVERIFY(games && picker);
            picker->setCurrentIndex(picker->findText(QStringLiteral("Unscramble")));
            QWidget *practice = games->currentWidget();
            auto *input = practice->findChild<QLineEdit *>();
            auto *check = buttonWithText(practice, QStringLiteral("Check"));
            QVERIFY(input && check);
            const bool eligible = clusters.size() >= 3;
            QCOMPARE(input->isEnabled(), eligible);
            QCOMPARE(check->isEnabled(), eligible);
            if (!eligible) {
                QVERIFY(hasLabel(practice, QStringLiteral("No longer words yet")));
                QTest::keyClick(input, Qt::Key_Return);
                QCOMPARE(window.learning_.answerCount(), 0);
            } else {
                QStringList permutations;
                for (int first = 0; first < 3; ++first)
                    for (int second = 0; second < 3; ++second)
                        if (first != second) permutations.append(clusters[first] + clusters[second] + clusters[3 - first - second]);
                bool intactPrompt = false;
                for (auto *label : practice->findChildren<QLabel *>())
                    intactPrompt |= label->text() != word.title && permutations.contains(label->text());
                QVERIFY(intactPrompt);
            }
            QCoreApplication::processEvents();
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(dialog->grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-scramble-%1.png").arg(QString::fromLatin1(QTest::currentDataTag()))));
            if (eligible) {
                input->setText(word.title);
                QTest::keyClick(input, Qt::Key_Return);
                QCOMPARE(window.learning_.study().value(word.key).right, 1);
            }
        });
        window.showLearningDialog(2);
        QVERIFY(exercised);
    }

    void compactWindowFitsRequestedSize() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480);
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QCoreApplication::processEvents();
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-compact.png")));
        QVERIFY2(window.width() <= 780, qPrintable(QStringLiteral("Actual width: %1").arg(window.width())));
        QVERIFY2(window.height() <= 480, qPrintable(QStringLiteral("Actual height: %1").arg(window.height())));
        QVERIFY(window.reading_->viewport()->width() > 100);
        QVERIFY(window.reading_->viewport()->height() > 100);
    }


    void richSectionHeadingsKeepLexicalLinksFoldsAndNavigation() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(true);
        QJsonObject response = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        QJsonObject entry = response.value(QStringLiteral("entries")).toArray().first().toObject();
        const auto span = [](const QString &text, const QString &target, const QString &kind = QStringLiteral("link"), const QString &trail = QString()) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("trail"), trail}, {QStringLiteral("bold"), true}};
        };
        const auto block = [](const QString &kind, int depth, const QJsonArray &spans, int level = 0) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("depth"), depth}, {QStringLiteral("level"), level}, {QStringLiteral("spans"), spans}};
        };
        const auto section = [&](const QString &name, int level, const QJsonObject &heading, const QString &body) {
            return QJsonObject{{QStringLiteral("title"), name}, {QStringLiteral("level"), level},
                {QStringLiteral("blocks"), QJsonArray{block(QStringLiteral("heading"), 0, QJsonArray{heading}, level),
                    block(QStringLiteral("paragraph"), 0, QJsonArray{span(body, {}, QStringLiteral("text"))})}}};
        };
        entry.insert(QStringLiteral("sections"), QJsonArray{
            section(QStringLiteral("English"), 2, span(QStringLiteral("English"), QStringLiteral("#Usage_notes")), QStringLiteral("OWNER BODY")),
            section(QStringLiteral("Etymology 1"), 3, span(QStringLiteral("Etymology 1"), QStringLiteral("dog")), QStringLiteral("RICH HISTORICAL BODY")),
            section(QStringLiteral("Usage notes"), 3, span(QStringLiteral("Usage"), QStringLiteral("https://example.org/heading"), QStringLiteral("external_link"), QStringLiteral(" notes")), QStringLiteral("RICH USAGE BODY")),
            section(QStringLiteral("Noun"), 4, span(QStringLiteral("Noun"), QStringLiteral("cat")), QStringLiteral("FOLLOWING MEANING")),
            section(QStringLiteral("Same"), 3, span(QStringLiteral("Same"), QStringLiteral("same-a")), QStringLiteral("FIRST SAME BODY")),
            section(QStringLiteral("Same"), 3, span(QStringLiteral("Same"), QStringLiteral("same-b")), QStringLiteral("SECOND SAME BODY"))
        });
        response.insert(QStringLiteral("entries"), QJsonArray{entry});
        const auto render = [&] { window.renderResponse(QJsonDocument(response).toJson()); };
        render();
        const QString plain = window.reading_->toPlainText();
        for (const QString &name : {QStringLiteral("English"), QStringLiteral("Etymology 1"), QStringLiteral("Usage notes"), QStringLiteral("Noun")})
            QCOMPARE(plain.count(name), 1);
        QCOMPARE(plain.count(QStringLiteral("Same")), 2);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("English")).charFormat().anchorHref(), QStringLiteral("dict:%23Usage_notes"));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Usage notes")).charFormat().anchorHref(), QStringLiteral("https://example.org/heading"));
        QTextCursor same = window.reading_->document()->find(QStringLiteral("Same"), 0, QTextDocument::FindCaseSensitively);
        QVERIFY(!same.isNull());
        QCOMPARE(same.selectedText(), QStringLiteral("Same"));
        QCOMPARE(same.charFormat().anchorHref(), QStringLiteral("dict:same-a"));
        same = window.reading_->document()->find(QStringLiteral("Same"), same, QTextDocument::FindCaseSensitively);
        QVERIFY(!same.isNull());
        QCOMPARE(same.selectedText(), QStringLiteral("Same"));
        QCOMPARE(same.charFormat().anchorHref(), QStringLiteral("dict:same-b"));
        QVERIFY(window.sections_->findText(QStringLiteral("English")) >= 0);
        QCOMPARE(window.sections_->itemData(window.sections_->findText(QStringLiteral("Usage notes"))).toInt(), 2);
        for (int i = 0; i < 6; ++i) QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(i)));
        QVERIFY(window.collapsedSections_.contains(1));
        QVERIFY(!plain.contains(QStringLiteral("RICH HISTORICAL BODY")));
        QVERIFY(plain.contains(QStringLiteral("FOLLOWING MEANING")));

        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:1")));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("RICH HISTORICAL BODY")));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:1")));
        const QSet<int> retained = window.collapsedSections_;
        window.collapsedSections_.clear(); window.refreshReading();
        window.collapsedSections_ = retained; window.refreshReading();
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("RICH HISTORICAL BODY")));
        QCOMPARE(window.reading_->document()->find(QStringLiteral("Etymology 1")).charFormat().anchorHref(), QStringLiteral("dict:dog"));

        window.collapsedSections_.insert(2); window.refreshReading();
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:%23Usage_notes")));
        QVERIFY(!window.collapsedSections_.contains(0));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("RICH USAGE BODY")));
        ExternalUrlReceiver receiver;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &receiver, "capture");
        const auto clearHandler = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("https://example.org/heading")));
        QCOMPARE(receiver.opened, QList<QUrl>{QUrl(QStringLiteral("https://example.org/heading"))});
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("section:2")));
        QVERIFY(window.collapsedSections_.contains(2));
        const int pickerRow = window.sections_->findText(QStringLiteral("Usage notes"));
        window.sections_->setCurrentIndex(pickerRow);
        QVERIFY(QMetaObject::invokeMethod(window.sections_, "activated", Qt::DirectConnection, Q_ARG(int, pickerRow)));
        QVERIFY(textIsVisible(window.reading_, QStringLiteral("RICH USAGE BODY")));
        QVERIFY(!window.collapsedSections_.contains(2));
        QVERIFY(clickAnchor(window.reading_, QStringLiteral("dict:dog")));
        QTRY_COMPARE(title(window), QStringLiteral("dog"));
    }

    void tableTextAccessibilityGeometryMatchesVisibleCursor() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setHtml(QStringLiteral(
            "<p>RootProbe</p><p>Before line 0</p><p>Before line 1</p><p>Before line 2</p><p>Before line 3</p><p>Before line 4</p><p>Before line 5</p><p>Before line 6</p><p>Before line 7</p><p>Before line 8</p><p>Before line 9</p><p>Before line 10</p><p>Before line 11</p>"
            "<table border='1' cellpadding='18'><tr><td>Left cell</td><td>"
            "<p>Cell preface</p><table border='1' cellpadding='12'><tr><td>NestedProbe</td></tr></table>"
            "</td></tr></table><p>AfterProbe</p><p>After one</p><p>After two</p>"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser);
        QVERIFY(accessible); auto *text = accessible->textInterface(); QVERIFY(text);
        QJsonArray observations;
        QList<bool> matches;
        const auto rectJson = [](const QRectF &rect) {
            return QJsonArray{rect.x(), rect.y(), rect.width(), rect.height()};
        };
        const auto observe = [&](const QString &label, bool scrollToTarget) {
            QTextCursor found = browser->document()->find(label);
            if (found.isNull()) return false;
            const int offset = found.selectionStart() + label.size() / 2;
            QTextCursor cursor(browser->document()); cursor.setPosition(offset);
            browser->setTextCursor(cursor);
            if (scrollToTarget) browser->ensureCursorVisible();
            else browser->verticalScrollBar()->setValue(0);
            QApplication::processEvents();
            const QRect local = browser->cursorRect(cursor);
            const QRect screen(browser->viewport()->mapToGlobal(local.topLeft()), local.size());
            const QRect reported = text->characterRect(offset);
            const bool sameText = text->text(offset, offset + 1) == QString(browser->document()->characterAt(offset));
            const bool intersects = reported.intersects(screen);
            const bool geometryRequired = scrollToTarget || label == QStringLiteral("RootProbe");
            const bool cursorVisible = browser->viewport()->rect().contains(local.center());
            const QTextBlock block = cursor.block();
            observations.append(QJsonObject{{QStringLiteral("label"), label},
                {QStringLiteral("scroll_to_target"), scrollToTarget}, {QStringLiteral("offset"), offset},
                {QStringLiteral("same_character_text"), sameText},
                {QStringLiteral("reported_screen_rect"), rectJson(reported)},
                {QStringLiteral("cursor_screen_rect"), rectJson(screen)},
                {QStringLiteral("block_local_layout_rect"), rectJson(block.layout()->boundingRect().translated(block.layout()->position()))},
                {QStringLiteral("block_document_rect"), rectJson(browser->document()->documentLayout()->blockBoundingRect(block))},
                {QStringLiteral("vertical_scroll"), browser->verticalScrollBar()->value()},
                {QStringLiteral("horizontal_scroll"), browser->horizontalScrollBar()->value()},
                {QStringLiteral("geometry_required"), geometryRequired},
                {QStringLiteral("cursor_intersects_viewport"), cursorVisible},
                {QStringLiteral("reported_intersects_cursor"), intersects}});
            matches.append(sameText && (!geometryRequired || intersects) && (!scrollToTarget || cursorVisible));
            return true;
        };
        QVERIFY(observe(QStringLiteral("RootProbe"), false));
        QVERIFY(observe(QStringLiteral("NestedProbe"), false));
        QVERIFY(observe(QStringLiteral("NestedProbe"), true));
        QVERIFY(observe(QStringLiteral("AfterProbe"), true));
        const QString reportPath = qEnvironmentVariable("DICT_QT_ACCESSIBILITY_GEOMETRY_REPORT");
        if (!reportPath.isEmpty()) {
            QFile report(reportPath); QVERIFY(report.open(QIODevice::WriteOnly | QIODevice::NewOnly));
            const QJsonObject result{{QStringLiteral("scope"), QStringLiteral("Installed Qt/current MainWindow reader synthetic geometry; no corpus or pointer activation acceptance")},
                {QStringLiteral("qt_version"), QString::fromLatin1(qVersion())},
                {QStringLiteral("observations"), observations}};
            QVERIFY(report.write(QJsonDocument(result).toJson()) > 0);
        }
        QCOMPARE(matches.size(), 4);
        QCOMPARE(observations[1].toObject().value(QStringLiteral("vertical_scroll")).toInt(), 0);
        QVERIFY(observations[2].toObject().value(QStringLiteral("vertical_scroll")).toInt() > 0);
        QVERIFY(observations[2].toObject().value(QStringLiteral("vertical_scroll")) != observations[1].toObject().value(QStringLiteral("vertical_scroll")));
        QVERIFY(observations[2].toObject().value(QStringLiteral("cursor_intersects_viewport")).toBool());
        QVERIFY(observations[3].toObject().value(QStringLiteral("cursor_intersects_viewport")).toBool());
        for (qsizetype i = 0; i < matches.size(); ++i)
            QVERIFY2(matches[i], qPrintable(QString::fromUtf8(QJsonDocument(observations[i].toObject()).toJson(QJsonDocument::Compact))));
    }

    void readerAccessibilityPreservesTextStylesSelectionAndGraphemeCoordinates() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setHtml(QString::fromUtf8(
            "<p><b><i>BoldWord</i></b> PlainWord e\xcc\x81 \xf0\x9f\x98\x80</p>"
            "<p>תשרק plain</p>"
            "<p>A wrapped accessible line with several additional words that must continue beyond one visual row.</p>"
            "<table border='1' width='1400'><tr><td width='1100' dir='rtl'>אבגדה</td>"
            "<td>WideProbe</td></tr></table><p>TailProbe</p>"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
        QCOMPARE(accessible->role(), QAccessible::StaticText);
        QCOMPARE(accessible->text(QAccessible::Name), QStringLiteral("Dictionary entry"));
        QVERIFY(accessible->state().readOnly); QVERIFY(accessible->state().multiLine);
        QVERIFY(accessible->state().selectableText); QVERIFY(!accessible->state().editable);
        QVERIFY(accessible->actionInterface());
        QVERIFY(accessible->actionInterface()->actionNames().contains(QAccessibleActionInterface::setFocusAction()));
        auto *text = accessible->textInterface(); QVERIFY(text);
        auto *editable = accessible->editableTextInterface(); QVERIFY(editable);
        QCOMPARE(text->characterCount(), browser->document()->characterCount() - 1);
        QTextCursor all(browser->document()); all.select(QTextCursor::Document);
        const QString original = all.selectedText().replace(QChar(QChar::ParagraphSeparator), QChar('\n'));
        QCOMPARE(text->text(0, -1), original);
        const auto bold = browser->document()->find(QStringLiteral("BoldWord")); QVERIFY(!bold.isNull());
        int start = -1, end = -1;
        const QString attrs = text->attributes(bold.selectionStart(), &start, &end);
        QVERIFY(attrs.contains(QStringLiteral("font-weight:700;")));
        QVERIFY(attrs.contains(QStringLiteral("font-style:italic;")));
        QVERIFY(start <= bold.selectionStart() && end >= bold.selectionEnd());
        text->setSelection(0, bold.selectionStart(), bold.selectionEnd());
        QCOMPARE(text->selectionCount(), 1); text->selection(0, &start, &end);
        QCOMPARE(start, bold.selectionStart()); QCOMPARE(end, bold.selectionEnd());
        QCOMPARE(text->text(start, end), QStringLiteral("BoldWord"));
        text->removeSelection(0); QCOMPARE(text->selectionCount(), 0);
        text->setCursorPosition(bold.selectionStart() + 2);
        QCOMPARE(text->cursorPosition(), bold.selectionStart() + 2);
        const QString word = text->textAtOffset(-2, QAccessible::WordBoundary, &start, &end);
        QCOMPARE(word, QStringLiteral("BoldWord"));
        editable->insertText(0, QStringLiteral("MUST NOT EDIT READONLY"));
        editable->deleteText(0, 1); editable->replaceText(0, 1, QStringLiteral("X"));
        QCOMPARE(text->text(0, -1), original);
        const auto wrapped = browser->document()->find(QStringLiteral("A wrapped accessible line")); QVERIFY(!wrapped.isNull());
        const auto wrappedBlock = wrapped.block();
        browser->document()->documentLayout()->blockBoundingRect(wrappedBlock);
        QVERIFY(wrappedBlock.layout()->lineCount() > 1);
        const auto secondLine = wrappedBlock.layout()->lineAt(1);
        const int lineStart = wrappedBlock.position() + secondLine.textStart();
        QCOMPARE(text->textAtOffset(lineStart + 1, QAccessible::LineBoundary, &start, &end),
                 text->text(lineStart, lineStart + secondLine.textLength()));
        QCOMPARE(start, lineStart); QCOMPARE(end, lineStart + secondLine.textLength());
        const auto emoji = browser->document()->find(QString::fromUtf8("\xf0\x9f\x98\x80")); QVERIFY(!emoji.isNull());
        text->scrollToSubstring(emoji.selectionStart(), emoji.selectionEnd());
        QVERIFY(text->characterRect(emoji.selectionStart()).width() > 1);
        QCOMPARE(text->characterRect(emoji.selectionStart()), text->characterRect(emoji.selectionStart() + 1));
        const auto combining = browser->document()->find(QString::fromUtf8("e\xcc\x81")); QVERIFY(!combining.isNull());
        QVERIFY(text->characterRect(combining.selectionStart()).width() > 1);
        QCOMPARE(text->characterRect(combining.selectionStart()), text->characterRect(combining.selectionStart() + 1));
        auto autoRtl = browser->document()->find(QString::fromUtf8("תשרק")); QVERIFY(!autoRtl.isNull());
        auto autoFormat = autoRtl.blockFormat(); autoFormat.setLayoutDirection(Qt::LayoutDirectionAuto);
        autoRtl.setBlockFormat(autoFormat);
        QCOMPARE(autoRtl.block().blockFormat().layoutDirection(), Qt::LayoutDirectionAuto);
        QCOMPARE(autoRtl.block().textDirection(), Qt::RightToLeft);
        QVERIFY(text->attributes(autoRtl.selectionStart(), &start, &end).contains(QStringLiteral("direction:rtl;")));
        const auto rtl = browser->document()->find(QString::fromUtf8("אבגדה")); QVERIFY(!rtl.isNull());
        const int rtlOffset = rtl.selectionStart() + 2;
        QCOMPARE(text->textAtOffset(rtlOffset, QAccessible::ParagraphBoundary, &start, &end), QString::fromUtf8("אבגדה"));
        QCOMPARE(start, rtl.block().position()); QCOMPARE(end, rtl.block().position() + rtl.block().length() - 1);
        text->setSelection(0, bold.selectionStart(), bold.selectionEnd());
        const auto savedSelection = browser->textCursor();
        text->scrollToSubstring(rtlOffset, rtlOffset + 1);
        QCOMPARE(browser->textCursor().selectionStart(), savedSelection.selectionStart());
        QCOMPARE(browser->textCursor().selectionEnd(), savedSelection.selectionEnd());
        QTextCursor rtlCursor(browser->document()); rtlCursor.setPosition(rtlOffset);
        const QRect caret = browser->cursorRect(rtlCursor);
        const QRect reported = text->characterRect(rtlOffset);
        QTextCursor rtlNext(browser->document()); rtlNext.setPosition(rtlOffset + 1);
        const QRect nextCaret = browser->cursorRect(rtlNext);
        const QPoint glyphCenter = browser->viewport()->mapToGlobal(
            QPoint((caret.x() + nextCaret.x()) / 2, caret.center().y()));
        QVERIFY(reported.contains(glyphCenter));
        QVERIFY(browser->viewport()->rect().contains(caret.center()));
        const int hit = text->offsetAtPoint(glyphCenter);
        QVERIFY(hit >= rtlOffset && hit <= rtlOffset + 1);
        const auto wide = browser->document()->find(QStringLiteral("WideProbe")); QVERIFY(!wide.isNull());
        QVERIFY(browser->horizontalScrollBar()->maximum() > 0);
        text->scrollToSubstring(wide.selectionStart(), wide.selectionEnd());
        QVERIFY(browser->horizontalScrollBar()->value() > 0);
        QTextCursor wideCursor(browser->document()); wideCursor.setPosition(wide.selectionStart());
        const QRect wideCaret = browser->cursorRect(wideCursor);
        const QRect wideScreen(browser->viewport()->mapToGlobal(wideCaret.topLeft()), wideCaret.size());
        QVERIFY(text->characterRect(wide.selectionStart()).intersects(wideScreen));
        QVERIFY(browser->viewport()->rect().contains(wideCaret.center()));
        QCOMPARE(text->text(0, -1), original);
    }

    void readerAccessibilityPreservesLegacyAttributeOffsetsAndSeparatorRuns() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        QTextBrowser legacy;
        const QString html = QStringLiteral("<p><b>BoldWord</b> <i>ItalicTail</i></p><p>Next</p>");
        browser->setHtml(html); legacy.setHtml(html);
        auto *currentAccessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(currentAccessible);
        auto *legacyAccessible = QAccessible::queryAccessibleInterface(&legacy); QVERIFY(legacyAccessible);
        auto *current = currentAccessible->textInterface(); QVERIFY(current);
        auto *original = legacyAccessible->textInterface(); QVERIFY(original);
        QCOMPARE(current->characterCount(), original->characterCount());
        const auto observe = [](QAccessibleTextInterface *text, int offset) {
            int start = 123456, end = 123456;
            const QString value = text->attributes(offset, &start, &end);
            return QJsonObject{{QStringLiteral("value"), value}, {QStringLiteral("start"), start}, {QStringLiteral("end"), end}};
        };
        const QString originalText = current->text(0, -1);
        auto selection = browser->document()->find(QStringLiteral("BoldWord")); QVERIFY(!selection.isNull());
        selection.setPosition(selection.selectionStart() + 1);
        selection.setPosition(selection.position() + 2, QTextCursor::KeepAnchor);
        browser->setTextCursor(selection);
        const int selectedPosition = selection.position(), selectedAnchor = selection.anchor();
        const auto positive = observe(current, selectedPosition);
        QVERIFY(positive.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-weight:700;")));
        QCOMPARE(observe(current, -2), positive);
        QCOMPARE(browser->textCursor().position(), selectedPosition);
        QCOMPARE(browser->textCursor().anchor(), selectedAnchor);
        auto legacySelection = legacy.textCursor(); legacySelection.setPosition(selectedAnchor);
        legacySelection.setPosition(selectedPosition, QTextCursor::KeepAnchor); legacy.setTextCursor(legacySelection);
        QCOMPARE(observe(original, -2), observe(original, selectedPosition));
        // Real installed Qt establishes the separator range/format contract independently.
        const auto block = browser->document()->begin();
        const int separator = block.position() + block.length() - 1;
        const auto expectedSeparator = observe(original, separator);
        const auto actualSeparator = observe(current, separator);
        QCOMPARE(expectedSeparator.value(QStringLiteral("start")).toInt(), separator);
        QCOMPARE(expectedSeparator.value(QStringLiteral("end")).toInt(), separator + 1);
        QCOMPARE(actualSeparator.value(QStringLiteral("start")), expectedSeparator.value(QStringLiteral("start")));
        QCOMPARE(actualSeparator.value(QStringLiteral("end")), expectedSeparator.value(QStringLiteral("end")));
        const bool legacyItalic = expectedSeparator.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-style:italic;"));
        QCOMPARE(actualSeparator.value(QStringLiteral("value")).toString().contains(QStringLiteral("font-style:italic;")), legacyItalic);
        QVERIFY(!legacyItalic);
        QCOMPARE(browser->textCursor().position(), selectedPosition);
        QCOMPARE(browser->textCursor().anchor(), selectedAnchor);
        const int count = current->characterCount(); QVERIFY(count > 0);
        current->setCursorPosition(count); original->setCursorPosition(count);
        const auto last = observe(current, count - 1);
        for (const int offset : {-1, count, -2}) {
            QCOMPARE(observe(current, offset), last);
            QCOMPARE(observe(original, offset), observe(original, count - 1));
        }
        QCOMPARE(current->cursorPosition(), count); QCOMPARE(current->selectionCount(), 0);
        for (const int offset : {-3, count + 1}) {
            const auto invalid = observe(current, offset);
            QVERIFY(invalid.value(QStringLiteral("value")).toString().isEmpty());
            QCOMPARE(invalid.value(QStringLiteral("start")).toInt(), -1);
            QCOMPARE(invalid.value(QStringLiteral("end")).toInt(), -1);
        }
        QCOMPARE(current->text(0, -1), originalText); QCOMPARE(current->cursorPosition(), count);
        browser->clear(); legacy.clear(); QCOMPARE(current->characterCount(), 0);
        for (const int offset : {-3, -2, -1, 0, 1}) {
            const auto empty = observe(current, offset);
            QVERIFY(empty.value(QStringLiteral("value")).toString().isEmpty());
            QCOMPARE(empty.value(QStringLiteral("start")).toInt(), -1);
            QCOMPARE(empty.value(QStringLiteral("end")).toInt(), -1);
            QCOMPARE(empty, observe(original, offset));
        }
        QCOMPARE(current->cursorPosition(), 0); QCOMPARE(current->selectionCount(), 0);
    }

    void readerAccessibilityUsesCharacterEdgesAtWrapAndBidiBoundaries() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        auto *browser = window.reading_;
        browser->setWordWrapMode(QTextOption::WrapAnywhere);
        browser->setPlainText(QString(150, QChar('W')) + QString::fromUtf8("\nLeft אבגדה Right"));
        QApplication::processEvents();
        auto *accessible = QAccessible::queryAccessibleInterface(browser); QVERIFY(accessible);
        auto *text = accessible->textInterface(); QVERIFY(text);
        const auto expectedRect = [&](int offset) {
            const auto block = browser->document()->findBlock(offset);
            const QRectF absolute = browser->document()->documentLayout()->blockBoundingRect(block);
            const auto line = block.layout()->lineForTextPosition(offset - block.position());
            const qreal a = line.cursorToX(offset - block.position(), QTextLine::Leading);
            const qreal b = line.cursorToX(offset - block.position(), QTextLine::Trailing);
            QRectF rect(absolute.left() + qMin(a, b), absolute.top() + line.y(), qAbs(b - a), line.height());
            rect.translate(browser->viewport()->mapToGlobal(QPoint())
                - QPoint(browser->horizontalScrollBar()->value(), browser->verticalScrollBar()->value()));
            return rect.toAlignedRect();
        };
        auto block = browser->document()->begin();
        browser->document()->documentLayout()->blockBoundingRect(block);
        QVERIFY(block.layout()->lineCount() > 1);
        const auto firstLine = block.layout()->lineAt(0);
        const int finalOffset = block.position() + firstLine.textStart() + firstLine.textLength() - 1;
        QTextCursor first(browser->document()); first.setPosition(finalOffset);
        QTextCursor next(browser->document()); next.setPosition(finalOffset + 1);
        QVERIFY(browser->cursorRect(first).y() != browser->cursorRect(next).y());
        text->scrollToSubstring(finalOffset, finalOffset + 1);
        QVERIFY(expectedRect(finalOffset).width() > 1);
        QCOMPARE(text->characterRect(finalOffset), expectedRect(finalOffset));
        const auto rtl = browser->document()->find(QString::fromUtf8("אבגדה")); QVERIFY(!rtl.isNull());
        const int bidiOffset = rtl.selectionEnd() - 1;
        text->scrollToSubstring(bidiOffset, bidiOffset + 1);
        first.setPosition(bidiOffset); next.setPosition(bidiOffset + 1);
        const int unrelatedCaretDistance = qAbs(browser->cursorRect(next).x() - browser->cursorRect(first).x());
        QVERIFY(unrelatedCaretDistance > expectedRect(bidiOffset).width() * 2);
        QCOMPARE(text->characterRect(bidiOffset), expectedRect(bidiOffset));
        QVERIFY(text->characterRect(bidiOffset).width() < unrelatedCaretDistance);
    }

    void settledReaderLayoutMatchesContentWidthAcrossBothResizeDirections() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QJsonArray observations;
        int step = 0;
        for (const int width : {580, 780, 1100, 780, 580}) {
            window.resize(width, 480);
            QTest::qWait(100); // Process the real child resize/layout events; never call updateReaderLayout directly.
            QTRY_COMPARE(window.compactReader_, window.readerContent_->width() < 580);
            const bool compact = window.readerContent_->width() < 580;
            int row = -1, column = -1, rowSpan = -1, columnSpan = -1;
            window.navigationLayout_->getItemPosition(window.navigationLayout_->indexOf(window.sections_), &row, &column, &rowSpan, &columnSpan);
            QCOMPARE(row, compact ? 1 : 0); QCOMPARE(column, compact ? 0 : 2);
            QCOMPARE(columnSpan, compact ? 2 : 1);
            const QRect contentGeometry = window.readerContent_->geometry();
            const QRect jumpGeometry = window.sections_->geometry();
            QTest::qWait(100);
            QCOMPARE(window.readerContent_->geometry(), contentGeometry);
            QCOMPARE(window.sections_->geometry(), jumpGeometry);
            QCOMPARE(window.compactReader_, compact);
            window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("cat"), Qt::CaseInsensitive));
            for (QWidget *control : std::array<QWidget *, 5>{window.back_, window.forward_, window.sections_, window.smaller_, window.larger_}) {
                QVERIFY(control->isVisible()); QVERIFY(window.readerContent_->rect().contains(control->geometry()));
            }
            observations.append(QJsonObject{{QStringLiteral("step"), step}, {QStringLiteral("window_width"), window.width()},
                {QStringLiteral("content_width"), window.readerContent_->width()}, {QStringLiteral("compact"), compact},
                {QStringLiteral("jump_row"), row}, {QStringLiteral("jump_column"), column},
                {QStringLiteral("jump_colspan"), columnSpan}, {QStringLiteral("reading_focus"), window.reading_->hasFocus()}});
            QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
            QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-settled-layout-%1-%2.png").arg(step++).arg(width)));
        }
        bool sawCompact = false, sawWide = false;
        int transitions = 0;
        for (qsizetype i = 0; i < observations.size(); ++i) {
            const bool compact = observations[i].toObject().value(QStringLiteral("compact")).toBool();
            sawCompact |= compact; sawWide |= !compact;
            if (i > 0 && compact != observations[i - 1].toObject().value(QStringLiteral("compact")).toBool()) ++transitions;
        }
        QVERIFY(sawCompact && sawWide); QVERIFY(transitions >= 2);
        QFile report(QStringLiteral(".tmp/ui-screenshots/desktop-settled-layout.json"));
        QVERIFY(report.open(QIODevice::WriteOnly));
        QVERIFY(report.write(QJsonDocument(observations).toJson()) > 0);
    }

    void selfOnlyHeadingCompanionRetainsStylesWithoutDuplicateOrAction() {
        MainWindow window(fixture_, QStringLiteral("cat")); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QJsonObject decoded = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        const QJsonObject self{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("Self heading")}, {QStringLiteral("target"), QString()},
            {QStringLiteral("classes"), QStringLiteral("mw-selflink selflink")},
            {QStringLiteral("bold"), true}, {QStringLiteral("italic"), true}};
        const auto render = [&](const QJsonObject &span, int level = 3, const QString &title = QStringLiteral("Self heading")) {
            QJsonObject entry = decoded;
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{}); entry.insert(QStringLiteral("references"), QJsonArray{});
            const QJsonObject heading{{QStringLiteral("kind"), QStringLiteral("heading")},
                {QStringLiteral("level"), level}, {QStringLiteral("spans"), QJsonArray{span}}};
            const QJsonObject bodySpan{{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("text"), QStringLiteral("Visible body")}};
            const QJsonObject body{{QStringLiteral("kind"), QStringLiteral("paragraph")},
                {QStringLiteral("spans"), QJsonArray{bodySpan}}};
            const QJsonArray blocks{heading, body};
            const QJsonObject section{{QStringLiteral("title"), title}, {QStringLiteral("level"), 3},
                {QStringLiteral("blocks"), blocks}};
            entry.insert(QStringLiteral("sections"), QJsonArray{section});
            return window.entryHtml(entry);
        };
        for (bool bold : {true, false}) {
            QJsonObject span = self; span.insert(QStringLiteral("bold"), bold);
            span.insert(QStringLiteral("classes"), QStringLiteral("note\tmw-selflink\nselflink extra"));
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
            const QTextCursor found = doc.find(QStringLiteral("Self heading")); QVERIFY(!found.isNull());
            QVERIFY(found.charFormat().fontItalic());
            QVERIFY(!found.charFormat().isAnchor()); QVERIFY(found.charFormat().anchorHref().isEmpty());
            if (bold) QVERIFY(found.charFormat().fontWeight() >= QFont::Bold);
            QVERIFY(doc.toPlainText().contains(QStringLiteral("Visible body")));
            if (bold) {
                // Explicit client-only heading render; no imported corpus entry.
                for (const int width : {580, 780}) {
                    window.resize(width, 480); window.reading_->setHtml(render(span));
                    window.reading_->setFocus(); QTRY_VERIFY(window.reading_->hasFocus());
                    QCOMPARE(window.size(), QSize(width, 480));
                    QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Self heading")), 1);
                    const QTextCursor heading = window.reading_->document()->find(QStringLiteral("Self heading"));
                    QVERIFY(!heading.isNull() && !heading.charFormat().isAnchor());
                    QVERIFY(heading.charFormat().fontItalic());
                    QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
                    QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-selfheading-%1.png").arg(width)));
                }
            }
        }
        for (const QString &classes : {QString(), QStringLiteral("mw-selflink"), QStringLiteral("selflink"),
             QStringLiteral("not-mw-selflink selflink"), QStringLiteral("mw-selflink selflink-suffix")}) {
            QJsonObject span = self; span.insert(QStringLiteral("classes"), classes);
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
        }
        // Each compiled style/semantic field independently makes an unlinked companion rich.
        const QJsonObject plain{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("Self heading")}};
        QList<QJsonObject> styles;
        for (const QString &flag : {QStringLiteral("bold"), QStringLiteral("italic"), QStringLiteral("code"),
             QStringLiteral("small"), QStringLiteral("superscript"), QStringLiteral("subscript"),
             QStringLiteral("strike"), QStringLiteral("underline")})
            styles.append(QJsonObject{{flag, true}});
        styles.append(QJsonObject{{QStringLiteral("foreground"), QStringLiteral("#123456")}});
        styles.append(QJsonObject{{QStringLiteral("classes"), QStringLiteral("note")}});
        styles.append(QJsonObject{{QStringLiteral("language"), QStringLiteral("fr")}});
        styles.append(QJsonObject{{QStringLiteral("direction"), QStringLiteral("rtl")}});
        styles.append(QJsonObject{{QStringLiteral("role"), QStringLiteral("label")}});
        for (const QJsonObject &style : styles) {
            QJsonObject span = plain;
            for (auto i = style.begin(); i != style.end(); ++i) span.insert(i.key(), i.value());
            QTextDocument doc; doc.setHtml(render(span));
            QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 1);
            QVERIFY(doc.find(QStringLiteral("Self heading")).charFormat().anchorHref().isEmpty());
            doc.setHtml(render(span, 2)); QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 2);
            span.insert(QStringLiteral("target"), QStringLiteral("other"));
            doc.setHtml(render(span)); QCOMPARE(doc.toPlainText().count(QStringLiteral("Self heading")), 2);
        }
        QTextDocument plainDocument; plainDocument.setHtml(render(plain));
        QCOMPARE(plainDocument.toPlainText().count(QStringLiteral("Self heading")), 2);
        QJsonObject italicOnly = plain; italicOnly.insert(QStringLiteral("italic"), true);
        window.resize(780, 480); window.reading_->setHtml(render(italicOnly));
        QCOMPARE(window.reading_->toPlainText().count(QStringLiteral("Self heading")), 1);
        const QTextCursor styledHeading = window.reading_->document()->find(QStringLiteral("Self heading"));
        QVERIFY(styledHeading.charFormat().fontItalic());
        QVERIFY(styledHeading.charFormat().anchorHref().isEmpty());
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-client-styled-unlinked-heading-780.png")));
        QJsonObject targeted = self; targeted.insert(QStringLiteral("target"), QStringLiteral("other"));
        QTextDocument invalid; invalid.setHtml(render(targeted)); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 2);
        invalid.setHtml(render(self, 2)); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 2);
        invalid.setHtml(render(self, 3, QStringLiteral("Different"))); QCOMPARE(invalid.toPlainText().count(QStringLiteral("Self heading")), 1);
    }

    void richHeadingCompanionMatchesOnlyExactFirstCanonicalLabel() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        const QJsonObject decoded = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object()
            .value(QStringLiteral("entries")).toArray().first().toObject();
        const auto span = [](const QString &kind, const QString &text, const QString &target = QString(), const QString &trail = QString()) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text},
                {QStringLiteral("target"), target}, {QStringLiteral("trail"), trail}};
        };
        const auto heading = [](const QJsonArray &spans, int level = 3, const QString &kind = QStringLiteral("heading")) {
            return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("depth"), 0}, {QStringLiteral("level"), level}, {QStringLiteral("spans"), spans}};
        };
        const QJsonObject linked = span(QStringLiteral("link"), QStringLiteral("Notes"), QStringLiteral("notes"));
        const auto check = [&](const QJsonArray &blocks, int count, const QString &name = QStringLiteral("Notes")) {
            QJsonObject entry = decoded;
            entry.insert(QStringLiteral("preamble_spans"), QJsonArray{});
            entry.insert(QStringLiteral("references"), QJsonArray{});
            entry.insert(QStringLiteral("sections"), QJsonArray{QJsonObject{{QStringLiteral("title"), name},
                {QStringLiteral("level"), 3}, {QStringLiteral("blocks"), blocks}}});
            window.collapsedSections_.clear();
            QTextDocument document;
            document.setHtml(window.entryHtml(entry));
            QCOMPARE(document.toPlainText().count(QStringLiteral("Notes")), count);
        };
        check(QJsonArray{heading(QJsonArray{linked})}, 1);
        QJsonObject nestedDepth = heading(QJsonArray{linked});
        nestedDepth.insert(QStringLiteral("depth"), 5);
        check(QJsonArray{nestedDepth}, 1);
        nestedDepth.insert(QStringLiteral("depth"), 3);
        nestedDepth.insert(QStringLiteral("level"), 0);
        check(QJsonArray{nestedDepth}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("\u00a0 \t")),
            linked, span(QStringLiteral("line_break"), QStringLiteral("ignored")), span(QStringLiteral("text"), QStringLiteral("\r "))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("external_link"), QStringLiteral("Notes"), QStringLiteral("https://example.org/notes"))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), {}, QStringLiteral("notes"), QStringLiteral("Notes"))})}, 1);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("\u2003Notes"), QStringLiteral("notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("\u2003Notes"), QStringLiteral("notes"))})}, 1, QStringLiteral("\u2003Notes"));
        check(QJsonArray{heading(QJsonArray{linked}, 2)}, 2);
        check(QJsonArray{heading(QJsonArray{linked}, 3, QStringLiteral("paragraph"))}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("Notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("Notes"), QStringLiteral("notes"))})}, 2);
        check(QJsonArray{heading(QJsonArray{linked, span(QStringLiteral("line_break"), QStringLiteral("\n"), {}, QStringLiteral("extra"))})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("text"), QStringLiteral("Before"))}, 0, QStringLiteral("paragraph")),
            heading(QJsonArray{linked})}, 2);
        check(QJsonArray{heading(QJsonArray{span(QStringLiteral("link"), QStringLiteral("Different Notes"), QStringLiteral("notes"))})}, 2);
    }

    void blankSectionHeadingsKeepBodyReachableAfterRetainedFolds() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        window.learning_.setCollapseEtymology(true);
        const QJsonObject originalResponse = QJsonDocument::fromJson(window.api_->lookup(QStringLiteral("cat"))).object();
        const QJsonObject originalEntry = originalResponse.value(QStringLiteral("entries")).toArray().first().toObject();
        const QJsonArray originalSections = originalEntry.value(QStringLiteral("sections")).toArray();
        int nounIndex = -1, etymologyIndex = -1;
        for (qsizetype i = 0; i < originalSections.size(); ++i) {
            const QString heading = originalSections[i].toObject().value(QStringLiteral("title")).toString();
            if (heading == QStringLiteral("Noun")) nounIndex = int(i);
            if (heading == QStringLiteral("Etymology")) etymologyIndex = int(i);
        }
        QVERIFY(nounIndex >= 0 && etymologyIndex >= 0);
        const QString nounToggle = QStringLiteral("section:%1").arg(nounIndex);
        const QString etymologyToggle = QStringLiteral("section:%1").arg(etymologyIndex);
        for (const QString &heading : {QString(), QStringLiteral(" \t\n ")}) {
            QJsonObject response = originalResponse, entry = originalEntry;
            QJsonArray sections = originalSections;
            QJsonObject noun = sections[nounIndex].toObject();
            noun.insert(QStringLiteral("title"), heading);
            sections[nounIndex] = noun;
            entry.insert(QStringLiteral("sections"), sections);
            response.insert(QStringLiteral("entries"), QJsonArray{entry});
            window.renderResponse(QJsonDocument(response).toJson());

            QVERIFY(!window.collapsedSections_.contains(nounIndex));
            QVERIFY(window.collapsedSections_.contains(etymologyIndex));
            QVERIFY(hasAnchor(window.reading_->document(), QStringLiteral("section-%1").arg(nounIndex)));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("The cat sleeps.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Inflection table")));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));

            // Unlike the Android heading, the desktop keeps a real chevron even with no label.
            QVERIFY(clickAnchor(window.reading_, nounToggle));
            QVERIFY(window.collapsedSections_.contains(nounIndex));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            const QSet<int> retained = window.collapsedSections_;
            window.collapsedSections_.clear(); window.refreshReading();
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            window.collapsedSections_ = retained; window.refreshReading();
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QVERIFY(clickAnchor(window.reading_, nounToggle));
            QVERIFY(!window.collapsedSections_.contains(nounIndex));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
            QCOMPARE(window.reading_->document()->find(QStringLiteral("écoles")).charFormat().anchorHref(),
                QStringLiteral("dict:%C3%A9cole"));
            QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));

            // An ordinary named heading still folds and reopens independently.
            QVERIFY(clickAnchor(window.reading_, etymologyToggle));
            QVERIFY(!window.collapsedSections_.contains(etymologyIndex));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Historical source.")));
            QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        }
    }

    void compiledPreformattedTextPreservesIndentationTabsAndLineBreaks() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.resize(780, 480); window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        const QString expected = QStringLiteral("column A  column B\n  indented\tvalue");
        QJsonArray preformatted;
        for (const QJsonValue &section : window.currentEntry_.value(QStringLiteral("sections")).toArray()) {
            for (const QJsonValue &block : section.toObject().value(QStringLiteral("blocks")).toArray()) {
                if (block.toObject().value(QStringLiteral("kind")).toString() == QStringLiteral("preformatted"))
                    preformatted.append(block);
            }
        }
        QCOMPARE(preformatted.size(), 1);
        const QJsonArray spans = preformatted.first().toObject().value(QStringLiteral("spans")).toArray();
        QCOMPARE(spans.size(), 1);
        QCOMPARE(spans.first().toObject().value(QStringLiteral("text")).toString(), expected);
        QCOMPARE(spans.first().toObject().value(QStringLiteral("trail")).toString(), QString());

        QPushButton *larger = nullptr;
        for (auto *button : window.findChildren<QPushButton *>())
            if (button->accessibleName() == QStringLiteral("Larger reading text")) larger = button;
        QVERIFY(larger);
        const int initialSize = window.readingPointSize_;
        for (int phase = 0; phase < 2; ++phase) {
            const QString plain = window.reading_->document()->toPlainText();
            const qsizetype start = plain.indexOf(QStringLiteral("column A"));
            QVERIFY(start >= 0);
            QCOMPARE(plain.mid(start, expected.size()), expected);
            QCOMPARE(plain.count(expected), 1);
            if (phase == 0) QTest::mouseClick(larger, Qt::LeftButton);
        }
        QVERIFY(window.readingPointSize_ > initialSize);
    }

    void semanticReadingZoomAndThemes() {
        MainWindow window(fixture_, QStringLiteral("cat"));
        window.show();
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QTextDocument *document = window.reading_->document();
        const QString text = document->toPlainText();
        for (const QString &expected : {QStringLiteral("PREAMBLE"), QStringLiteral("A small animal."), QStringLiteral("The cat sleeps."), QStringLiteral("column A  column B"), QStringLiteral("Inflection table"), QStringLiteral("Reference content.")}) {
            QVERIFY2(text.contains(expected), qPrintable(expected));
        }
        QVERIFY(document->find(QStringLiteral("Bold")).charFormat().fontWeight() >= QFont::Bold);
        QVERIFY(document->find(QStringLiteral("Italic")).charFormat().fontItalic());
        const QTextCharFormat marked = document->find(QStringLiteral("marked")).charFormat();
        QVERIFY(marked.fontStrikeOut());
        QVERIFY(marked.fontUnderline());
        QTextTable *table = nullptr;
        for (QTextFrame *frame : document->rootFrame()->childFrames()) {
            if (auto *candidate = qobject_cast<QTextTable *>(frame)) { table = candidate; break; }
        }
        QVERIFY(table);
        QCOMPARE(table->rows(), 3);
        QCOMPARE(table->columns(), 3);
        QCOMPARE(table->cellAt(0, 0).rowSpan(), 2);
        QCOMPARE(table->cellAt(0, 1).columnSpan(), 2);

        const qreal previousSize = document->find(QStringLiteral("A small animal.")).charFormat().fontPointSize();
        QPushButton *larger = nullptr;
        for (auto *button : window.findChildren<QPushButton *>()) {
            if (button->accessibleName() == QStringLiteral("Larger reading text")) { larger = button; break; }
        }
        QVERIFY(larger);
        QTest::mouseClick(larger, Qt::LeftButton);
        QVERIFY(window.reading_->document()->find(QStringLiteral("A small animal.")).charFormat().fontPointSize() > previousSize);
        QCOMPARE(QSettings().value(QStringLiteral("reader/pointSize")).toInt(), window.readingPointSize_);
        QVERIFY(QDir().mkpath(QStringLiteral(".tmp/ui-screenshots")));
        window.learning_.setTheme(QStringLiteral("light"));
        window.applyTheme();
        const QColor lightInk = window.palette().color(QPalette::Text);
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-light.png")));
        window.learning_.setTheme(QStringLiteral("dark"));
        window.applyTheme();
        QVERIFY(window.palette().color(QPalette::Text) != lightInk);
        QCOMPARE(window.reading_->document()->toPlainText(), text);
        QCOMPARE(window.reading_->document()->find(QStringLiteral("A small animal.")).charFormat().foreground().color(), window.palette().color(QPalette::Text));
        QVERIFY(window.grab().save(QStringLiteral(".tmp/ui-screenshots/desktop-dark.png")));
    }
};

int main(int argc, char **argv) {
    QDir().mkpath(QStringLiteral(".tmp"));
    QTemporaryDir settings(QStringLiteral(".tmp/ui-settings-XXXXXX"));
    if (!settings.isValid()) return 2;
    const QString isolatedRoot = QDir(settings.path()).absolutePath();
    qputenv("XDG_CONFIG_HOME", (isolatedRoot + QStringLiteral("/config")).toUtf8());
    qputenv("XDG_CACHE_HOME", (isolatedRoot + QStringLiteral("/cache")).toUtf8());
    qputenv("XDG_DATA_HOME", (isolatedRoot + QStringLiteral("/data")).toUtf8());
    QSettings::setDefaultFormat(QSettings::IniFormat);
    for (const QSettings::Format format : {QSettings::IniFormat, QSettings::NativeFormat}) {
        QSettings::setPath(format, QSettings::UserScope, isolatedRoot + QStringLiteral("/config"));
        QSettings::setPath(format, QSettings::SystemScope, isolatedRoot + QStringLiteral("/system"));
    }
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("SmallThingz"));
    QCoreApplication::setApplicationName(QStringLiteral("Dict"));
    const QString implicitPath = QSettings().fileName();
    const QString explicitPath = QSettings(QStringLiteral("SmallThingz"), QStringLiteral("Dict")).fileName();
    if (!implicitPath.startsWith(isolatedRoot + QChar('/')) || !explicitPath.startsWith(isolatedRoot + QChar('/'))) {
        qCritical("Refusing to run with settings outside the test directory.");
        return 3;
    }
    MainWindowTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "MainWindowTest.moc"
