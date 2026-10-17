#include "MainWindow.hpp"
#include "LibraryStore.hpp"

#include <QAbstractTextDocumentLayout>
#include <QAccessible>
#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
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
#include <QStatusBar>
#include <QPalette>
#include <QPointer>
#include <QPushButton>
#include <QScopeGuard>
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

    static bool prepareCaseTitleFixture(const QString &fixtureRoot, const QString &directory, QStringList titles) {
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
        const QByteArray record = original.mid(lengthStart, at - lengthStart + qsizetype(length));
        std::sort(titles.begin(), titles.end(), [](const QString &left, const QString &right) {
            return left.toUtf8() < right.toUtf8();
        });
        QByteArray bytes = QByteArrayLiteral("WIKBLB08") + char(1) +
            QByteArrayLiteral("en\0") + QByteArrayLiteral("English\0");
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
        QCOMPARE(window.title_->text(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), QStringLiteral("No dictionary open"));
        const QString guidance = window.reading_->toPlainText();
        QVERIFY(guidance.contains(QStringLiteral("No readable dictionary was found for this collection. Import a dictionary in Library.")));
        QVERIFY(!guidance.contains(QStringLiteral("select:")));
        QVERIFY(!guidance.contains(QStringLiteral("FileNotFound")));
        QVERIFY(!window.search_->isEnabled());
        QVERIFY(!window.results_->isEnabled());
        QVERIFY(!window.kind_->isEnabled());
        QVERIFY(!window.language_->isEnabled());
        auto *library = window.findChild<QPushButton *>(QStringLiteral("openDictionaries"));
        QVERIFY(library && library->isEnabled());
        window.openRoot(fixture_, QStringLiteral("cat"));
        QTRY_VERIFY_WITH_TIMEOUT(!window.loading_ && window.api_, 30000);
        QTRY_COMPARE(title(window), QStringLiteral("cat"));
        QVERIFY(window.search_->isEnabled());
        QVERIFY(window.results_->isEnabled());
    }

    void narrowReaderKeepsNavigationAndHeadingVisible() {
        MainWindow window{QString()};
        window.title_->setText(QStringLiteral("acupuncture"));
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
        auto restoreSources = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), sources); });
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
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QVERIFY(window.currentEntry_.isEmpty() || !window.currentEntry_.value(QStringLiteral("redirect")).toObject().value(QStringLiteral("followed")).toBool());
    }

    void removingLastDictionaryClearsVisibleEntryAndSearchState_data() {
        QTest::addColumn<bool>("cancelReload");
        QTest::newRow("reload-fails-empty") << false;
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
        QCOMPARE(window.title_->text(), QStringLiteral("Open your dictionaries"));
        QCOMPARE(window.resultStatus_->text(), cancelReload
            ? QStringLiteral("Opening cancelled. Choose a folder to try again.")
            : QStringLiteral("No dictionary open"));
        QVERIFY(window.reading_->toPlainText().contains(QStringLiteral("Open Library")));
        QVERIFY(!window.reading_->toPlainText().contains(QStringLiteral("A small animal.")));
        QStringList remainingHistory;
        for (const auto &entry : window.learning_.history()) remainingHistory.append(entry.key);
        QCOMPARE(remainingHistory, history);
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

    void malformedAliasPresentationFailsSafelyOnRead() {
        QTemporaryDir directory(QStringLiteral(".tmp/ui-invalid-alias-XXXXXX"));
        QVERIFY(directory.isValid());
        QFile fixture(fixture_ + QStringLiteral("/alias-cases/aliases.wikblb"));
        QVERIFY(fixture.open(QIODevice::ReadOnly));
        QByteArray bytes = fixture.readAll();
        const qsizetype presentation = bytes.indexOf("DPR2");
        QVERIFY(presentation >= 0 && presentation + 8 <= bytes.size());
        for (qsizetype i = 4; i < 8; ++i) bytes[presentation + i] = char(255);
        const QString source = directory.filePath(QStringLiteral("bad.wikblb"));
        QFile malformed(source); QVERIFY(malformed.open(QIODevice::WriteOnly));
        QCOMPARE(malformed.write(bytes), bytes.size()); malformed.close();
        const QString root = directory.filePath(QStringLiteral("library"));
        std::atomic_bool cancelled = false;
        auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled, [](const QString &, qint64, qint64) {});
        LibraryStorage::commitImport(root, *prepared);
        DictApi api(root); api.select(QString(), QStringLiteral("language"));
        QVERIFY_EXCEPTION_THROWN(api.lookup(QStringLiteral("Cats")), DictApiError);
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
