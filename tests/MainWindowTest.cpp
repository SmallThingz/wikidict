#include "MainWindow.hpp"

#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
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
#include <QTextTable>
#include <QTimer>
#include <QtTest>

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
                const QPoint point = browser->cursorRect(cursor).center() + QPoint(2, 0);
                if (browser->anchorAt(point) != href) continue;
                QTest::mouseClick(browser->viewport(), Qt::LeftButton, Qt::NoModifier, point);
                return true;
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
