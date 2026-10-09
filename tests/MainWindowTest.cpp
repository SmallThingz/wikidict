#include "MainWindow.hpp"
#include "LibraryStore.hpp"

#include <QAbstractTextDocumentLayout>
#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QDesktopServices>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QGlyphRun>
#include <QJsonArray>
#include <QJsonDocument>
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
#include <QStackedWidget>
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
        QTest::keyClicks(window.search_, "missing-word-for-ux-test");
        QTest::keyClick(window.search_, Qt::Key_Return);
        QTRY_VERIFY(window.resultStatus_->text().contains(QStringLiteral("No exact entry")));
        QCOMPARE(title(window), QStringLiteral("dog"));
        QCOMPARE(window.results_->count(), 0);
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
            QTest::keyClicks(input, "dog");
            QCOMPARE(input->text(), QStringLiteral("dog"));
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
