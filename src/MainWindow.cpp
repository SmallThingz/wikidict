#include "MainWindow.hpp"
#include "LibraryDialog.hpp"
#include "MediaPanel.hpp"

#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
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
#include <QPalette>
#include <QPushButton>
#include <QProgressBar>
#include <QRandomGenerator>
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
#include <QTextBoundaryFinder>
#include <QTextEdit>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <QWidget>
#include <QtConcurrent/QtConcurrentRun>
#include <algorithm>
namespace {
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

void MainWindow::loadDataset(const QString &root, const QString &language, const QString &kind, bool resetVisits, const QString &word, int restoreVisit, const QString &expectedRoot, const QString &expectedEdition) {
    if (cancelLoad_) cancelLoad_->store(true);
    const auto cancelled = std::make_shared<std::atomic_bool>(false);
    cancelLoad_ = cancelled;
    const unsigned serial = ++loadSerial_;
    saveVisit();
    searchTimer_->stop();
    setLoading(true);
    resultStatus_->setText(QStringLiteral("Opening dictionaries and preparing search..."));
    auto *watcher = new QFutureWatcher<std::shared_ptr<LoadedDataset>>(this);
    connect(watcher, &QFutureWatcher<std::shared_ptr<LoadedDataset>>::finished, this, [this, watcher, cancelled, serial, root, resetVisits, word, restoreVisit] {
        const auto loaded = watcher->result();
        watcher->deleteLater();
        if (serial != loadSerial_ || cancelled->load()) return;
        if (!loaded->error.isEmpty()) {
            setLoading(false);
            if (api_) {
                QSignalBlocker kindBlocker(kind_);
                QSignalBlocker languageBlocker(language_);
                kind_->setCurrentIndex(kind_->findData(api_->kind()));
                language_->setCurrentText(api_->language());
                resultStatus_->setText(QStringLiteral("Could not open dictionaries: %1").arg(loaded->error));
            } else {
                title_->setText(QStringLiteral("Open your dictionaries"));
                meta_->setText(QStringLiteral("Your words stay on this computer."));
                reading_->setHtml(QStringLiteral("<p>%1</p><p>Open <b>Library</b> to import a dictionary, download one, or choose an existing folder.</p>").arg(loaded->error.toHtmlEscaped()));
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
        title_->setText(QStringLiteral("Find the word."));
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
                    collapsedSections_ = visit.collapsed;
                    refreshReading();
                    reading_->verticalScrollBar()->setValue(visit.scroll);
                    visitIndex_ = restoreVisit;
                    updateNavigation();
                }
            } catch (const std::exception &error) { resultStatus_->setText(QString::fromUtf8(error.what())); }
        } else if (!word.isEmpty()) openWord(word);
        search_->setFocus();
        statusBar()->showMessage(QStringLiteral("Opened %1").arg(QDir::toNativeSeparators(root)), 4000);
    });
    watcher->setFuture(QtConcurrent::run([root, language, kind, resetVisits, cancelled, expectedRoot, expectedEdition] {
        auto loaded = std::make_shared<LoadedDataset>();
        try {
            if (root.isEmpty()) throw DictApiError("Choose the folder containing your compiled dictionaries.");
            loaded->originRoot = QFileInfo(root).canonicalFilePath();
            loaded->originEdition = LibraryStorage::editionIdentity(root);
            if (!expectedRoot.isEmpty() && (loaded->originRoot != expectedRoot || loaded->originEdition != expectedEdition))
                throw DictApiError("The saved dictionary has changed. Open its original folder.");
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
            QString lastError;
            for (const QString &candidate : candidates) {
                if (cancelled->load()) return loaded;
                // The core admits a neutral redirect collection only when the
                // language manifest and language directory are both empty.
                try { loaded->api->select(selected, candidate); selectedCollection = true; break; }
                catch (const std::exception &error) { lastError = QString::fromUtf8(error.what()); }
            }
            if (!selectedCollection) throw DictApiError((QStringLiteral("No readable dictionary was found for this collection. Import a dictionary in Library. ") + lastError).toStdString());
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
    dialog.exec();
    if (dialog.libraryChanged()) {
        api_.reset();
        searchTitles_.clear();
        sampleWords_.clear();
        currentEntry_ = {};
        currentJson_.clear();
        media_->setEntry({});
        visits_.clear();
        visitIndex_ = -1;
        openRoot(dialog.selectedRoot(), word);
    }
}

void MainWindow::setupUi() {
    setWindowTitle(QStringLiteral("Dict"));
    resize(1180, 780);
    setMinimumSize(680, 480);

    auto *splitter = new QSplitter(this);
    splitter->setObjectName(QStringLiteral("readerSplit"));
    auto *sidebar = new QWidget(splitter);
    auto *side = new QVBoxLayout(sidebar);
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
    resultStatus_->setAccessibleName(QStringLiteral("Search status"));
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

    auto *content = new QWidget(splitter);
    auto *right = new QVBoxLayout(content);
    right->setContentsMargins(28, 20, 28, 24);
    right->setSpacing(10);

    auto *navigation = new QHBoxLayout;
    back_ = new QPushButton(QStringLiteral("Back"), content);
    forward_ = new QPushButton(QStringLiteral("Forward"), content);
    back_->setToolTip(QStringLiteral("Previous word (Alt+Left)"));
    forward_->setToolTip(QStringLiteral("Next word (Alt+Right)"));
    back_->setEnabled(false);
    forward_->setEnabled(false);
    navigation->addWidget(back_);
    navigation->addWidget(forward_);
    sections_ = new QComboBox(content);
    sections_->setAccessibleName(QStringLiteral("Jump to section"));
    sections_->setMinimumContentsLength(10);
    sections_->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    sections_->setEnabled(false);
    navigation->addWidget(sections_, 1);
    auto *smaller = new QPushButton(QStringLiteral("A-"), content);
    auto *larger = new QPushButton(QStringLiteral("A+"), content);
    smaller->setAccessibleName(QStringLiteral("Smaller reading text"));
    larger->setAccessibleName(QStringLiteral("Larger reading text"));
    navigation->addWidget(smaller);
    navigation->addWidget(larger);
    right->addLayout(navigation);

    auto *header = new QHBoxLayout;
    auto *heading = new QVBoxLayout;
    title_ = new QLabel(QStringLiteral("Find the word."), content);
    QFont titleFont = title_->font();
    titleFont.setFamily(readerFamily());
    titleFont.setPointSize(30);
    titleFont.setBold(true);
    title_->setFont(titleFont);
    title_->setTextFormat(Qt::RichText);
    title_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    title_->setWordWrap(true);
    meta_ = new QLabel(QStringLiteral("Local Wiktionary · native Qt"), content);
    meta_->setTextFormat(Qt::PlainText);
    meta_->setWordWrap(true);
    heading->addWidget(title_);
    heading->addWidget(meta_);
    header->addLayout(heading, 1);
    listen_ = new QPushButton(QStringLiteral("Listen"), content);
    listen_->setToolTip(QStringLiteral("Pronounce this word with an installed offline voice"));
    listen_->setEnabled(false);
    header->addWidget(listen_);
    bookmark_ = new QPushButton(QStringLiteral("☆ Bookmark"), content);
    bookmark_->setEnabled(false);
    header->addWidget(bookmark_);
    right->addLayout(header);
    entryTabs_ = new QTabWidget(content);
    reading_ = new QTextBrowser(entryTabs_);
    reading_->setOpenLinks(false);
    reading_->setOpenExternalLinks(false);
    reading_->setFrameShape(QFrame::NoFrame);
    reading_->setAccessibleName(QStringLiteral("Dictionary entry"));
    json_ = new QTextEdit(entryTabs_);
    json_->setReadOnly(true);
    json_->setLineWrapMode(QTextEdit::NoWrap);
    entryTabs_->addTab(reading_, QStringLiteral("Reading"));
    media_ = new MediaPanel(entryTabs_);
    entryTabs_->addTab(media_, QStringLiteral("Media && speech"));
    entryTabs_->addTab(json_, QStringLiteral("Entry data"));
    right->addWidget(entryTabs_, 1);

    splitter->addWidget(sidebar);
    splitter->addWidget(content);
    splitter->setStretchFactor(0, 0);
    splitter->setStretchFactor(1, 1);
    splitter->setSizes({280, 900});
    splitter->setChildrenCollapsible(false);
    setCentralWidget(splitter);

    searchTimer_ = new QTimer(this);
    searchTimer_->setSingleShot(true);
    searchTimer_->setInterval(120);
    connect(search_, &QLineEdit::textChanged, this, [this] {
        results_->clear();
        moreResults_->setEnabled(false);
        resultStatus_->setText(QStringLiteral("Searching..."));
        searchTimer_->start();
    });
    connect(searchTimer_, &QTimer::timeout, this, &MainWindow::refreshSearch);
    connect(search_, &QLineEdit::returnPressed, this, &MainWindow::submitSearch);
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
            const QString word = target.section(QChar('#'), 0, 0);
            const std::optional<QString> section = target.contains(QChar('#')) ?
                std::optional<QString>(target.section(QChar('#'), 1)) : std::nullopt;
            if (!word.isEmpty()) {
                if (!openWord(word, section)) return;
            } else if (section) jumpToFragment(*section);
        }
        else if (url.scheme() == QStringLiteral("section")) {
            const int index = url.path().toInt();
            if (collapsedSections_.contains(index)) collapsedSections_.remove(index);
            else collapsedSections_.insert(index);
            refreshReading();
        }
        else if (url.scheme() == QStringLiteral("http") || url.scheme() == QStringLiteral("https")) QDesktopServices::openUrl(url);
    });
    connect(back_, &QPushButton::clicked, this, [this] { navigate(-1); });
    connect(forward_, &QPushButton::clicked, this, [this] { navigate(1); });
    connect(sections_, &QComboBox::activated, this, [this](int index) { jumpToSection(sections_->itemData(index).toInt()); });
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
    if (auto *item = results_->currentItem()) openWord(item->data(Qt::UserRole).toString());
    else openWord(search_->text().trimmed());
}

bool MainWindow::eventFilter(QObject *watched, QEvent *event) {
    if (event->type() == QEvent::KeyPress) {
        auto *key = static_cast<QKeyEvent *>(event);
        if (watched == results_ && (key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter)) {
            if (auto *item = results_->currentItem()) openWord(item->data(Qt::UserRole).toString());
            return true;
        }
        if (watched == search_ && (key->key() == Qt::Key_Down || key->key() == Qt::Key_Up)) {
            if (searchTimer_->isActive()) refreshSearch();
            if (results_->count() > 0) {
                results_->setFocus();
                results_->setCurrentRow(key->key() == Qt::Key_Down ? 0 : results_->count() - 1);
            }
            return true;
        }
        if (watched == results_ && (key->key() == Qt::Key_Escape || (key->key() == Qt::Key_Up && results_->currentRow() == 0))) {
            search_->setFocus();
            return true;
        }
    }
    return QMainWindow::eventFilter(watched, event);
}

bool MainWindow::openWord(const QString &word, const std::optional<QString> &fragment) {
    if (!api_ || loading_ || word.trimmed().isEmpty()) return false;
    try {
        QString exact = word.trimmed();
        QByteArray response = api_->lookup(exact);
        QJsonDocument document = QJsonDocument::fromJson(response);
        if (document.object().value(QStringLiteral("entries")).toArray().isEmpty()) {
            const auto found = std::lower_bound(searchTitles_.cbegin(), searchTitles_.cend(), exact, titleLess);
            if (found != searchTitles_.cend() && found->compare(exact, Qt::CaseInsensitive) == 0) {
                exact = *found;
                response = api_->lookup(exact);
                document = QJsonDocument::fromJson(response);
            }
        }
        if (document.object().value(QStringLiteral("entries")).toArray().isEmpty()) {
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
    title_->setText(displayTitle.isEmpty() ? title.toHtmlEscaped() : spansHtml(displayTitle));
    meta_->setText(QStringLiteral("%1 · %2").arg(language.isEmpty() ? QStringLiteral("All languages") : language, kindLabel(kind)));
    const QJsonArray sections = currentEntry_.value(QStringLiteral("sections")).toArray();
    sections_->clear();
    sections_->addItem(QStringLiteral("Jump to section"), -1);
    for (qsizetype i = 0; i < sections.size(); ++i) {
        const QJsonObject section = sections[i].toObject();
        const QString sectionTitle = section.value(QStringLiteral("title")).toString();
        if (!sectionTitle.isEmpty()) sections_->addItem(sectionTitle, i);
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
    if (addVisit) {
        visits_.resize(visitIndex_ + 1);
        if (visits_.isEmpty() || visits_.last().title != title || visits_.last().language != api_->language() || visits_.last().kind != api_->kind())
            visits_.push_back({title, api_->language(), api_->kind(), 0, {}});
        if (visits_.size() > 100) visits_.removeFirst();
        visitIndex_ = visits_.size() - 1;
        updateNavigation();
    }
    const QJsonObject redirect = currentEntry_.value(QStringLiteral("redirect")).toObject();
    const QString destination = fragment ? *fragment :
        (redirect.value(QStringLiteral("followed")).toBool() ? redirect.value(QStringLiteral("fragment")).toString() : QString());
    jumpToFragment(destination);
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
    if (fragment.startsWith(QStringLiteral("reference-"))) {
        reading_->scrollToAnchor(fragment);
        return;
    }
    QString heading = fragment;
    heading.replace(QChar('_'), QChar(' '));
    const int index = sections_->findText(heading);
    if (index >= 0) jumpToSection(sections_->itemData(index).toInt());
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
        collapsedSections_ = visit.collapsed;
        refreshReading();
        reading_->verticalScrollBar()->setValue(visit.scroll);
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
QString MainWindow::spansHtml(const QJsonArray &spans) const {
    QString out;
    for (const QJsonValue &value : spans) {
        const QJsonObject span = value.toObject();
        const QString kind = span.value(QStringLiteral("kind")).toString();
        if (kind == QStringLiteral("line_break")) { out += QStringLiteral("<br>"); continue; }
        QString text = (span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString()).toHtmlEscaped();
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
        const QString classes = span.value(QStringLiteral("classes")).toString();
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
            out += QStringLiteral("<%1 colspan='%2' rowspan='%3' style='border:1px solid %4'>%5</%1>")
                .arg(tag).arg(colspan).arg(rowspan).arg(palette().color(QPalette::Mid).name(), spansHtml(cell.value(QStringLiteral("spans")).toArray()));
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
    if (table.isObject()) return tableHtml(table.toObject(), block.value(QStringLiteral("depth")).toInt());
    const QString body = spansHtml(block.value(QStringLiteral("spans")).toArray());
    const int indent = std::clamp(block.value(QStringLiteral("depth")).toInt(1) - 1, 0, 20) * 16;
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
    if (kind == QStringLiteral("heading")) return QStringLiteral("<h3>%1</h3>").arg(body);
    const int depth = block.value(QStringLiteral("depth")).toInt();
    if (depth > 0)
        return QStringLiteral("<p style='margin-left:%1px'>%2</p>")
            .arg(30 + std::clamp(depth - 1, 0, 20) * 16).arg(body);
    return QStringLiteral("<p>%1</p>").arg(body);
}

QString MainWindow::entryHtml(const QJsonObject &entry) const {
    QString out = QStringLiteral(
        "<style>body{font-family:'%4';font-size:%1pt;color:%2;}"
        "h2{font-family:sans-serif;font-size:%1pt;margin-top:20px;}"
        "a{color:%3;text-decoration:none;}blockquote{margin:8px 18px;}"
        "code,pre{font-family:monospace;}</style><body>")
        .arg(readingPointSize_).arg(palette().color(QPalette::Text).name(), palette().color(QPalette::Link).name(), readerFamily());
    const QJsonObject redirect = entry.value(QStringLiteral("redirect")).toObject();
    if (redirect.value(QStringLiteral("followed")).toBool())
        out += QStringLiteral("<p><small>Redirected from %1</small></p>").arg(redirect.value(QStringLiteral("source_title")).toString().toHtmlEscaped());
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
            QString captionFile;
            if (span.value(QStringLiteral("kind")).toString() == QStringLiteral("link") &&
                classes.contains(QStringLiteral("wikidict-media")) &&
                (target.startsWith(QStringLiteral("File:"), Qt::CaseInsensitive) || target.startsWith(QStringLiteral("Image:"), Qt::CaseInsensitive)))
                captionFile = target.mid(target.indexOf(QChar(':')) + 1).replace(QChar('_'), QChar(' '));
            if (captionFile != file || captionFile.isEmpty()) finishCaption();
            if (!captionFile.isEmpty()) {
                file = captionFile;
                text += span.value(QStringLiteral("text")).toString() + span.value(QStringLiteral("trail")).toString();
            }
        }
        finishCaption();
    };
    const QJsonArray preamble = entry.value(QStringLiteral("preamble_spans")).toArray();
    collectEmbeddedMedia(preamble);
    if (!preamble.isEmpty()) out += QStringLiteral("<p>%1</p>").arg(spansHtml(preamble));
    int index = -1;
    for (const QJsonValue &sectionValue : entry.value(QStringLiteral("sections")).toArray()) {
        ++index;
        const QJsonObject section = sectionValue.toObject();
        const QString title = section.value(QStringLiteral("title")).toString();
        const int level = section.value(QStringLiteral("level")).toInt();
        out += QStringLiteral("<a name='section-%1'></a>").arg(index);
        if (level >= 3 || entry.value(QStringLiteral("kind")).toString() != QStringLiteral("language")) {
            out += QStringLiteral("<h2><a href='section:%1'>%2 %3</a></h2>").arg(index)
                .arg(collapsedSections_.contains(index) ? QStringLiteral("▸") : QStringLiteral("▾"), title.toHtmlEscaped());
        }
        if (collapsedSections_.contains(index)) continue;
        for (const QJsonValue &value : section.value(QStringLiteral("blocks")).toArray()) {
            const QJsonObject block = value.toObject();
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
            out += QStringLiteral("<p><a name='reference-%1'></a>%2 %3</p>")
                .arg(ref.value(QStringLiteral("number")).toInt())
                .arg(label.toHtmlEscaped(), spansHtml(ref.value(QStringLiteral("spans")).toArray()));
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
        auto *item = historyList->currentItem();
        if (!item || !(item->flags() & Qt::ItemIsEnabled)) return;
        learning_.removeHistory(item->data(Qt::UserRole).toString());
        delete item;
        clearHistory->setEnabled(!learning_.history().isEmpty());
    });
    connect(removeBookmark, &QPushButton::clicked, &dialog, [&] {
        auto *item = bookmarkList->currentItem(); if (!item) return;
        learning_.removeBookmark(item->data(Qt::UserRole).toString()); delete item;
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
        if (pool.size() < 2) {
            quizClue->setText(QStringLiteral("Open or bookmark at least two words first."));
            for (auto *button : quizButtons) button->hide();
            quizNext->setEnabled(false);
            return;
        }
        quizAnswer = pool.at(QRandomGenerator::global()->bounded(pool.size()));
        quizClue->setText(quizAnswer.clue);
        QVector<SavedWord> candidates;
        candidates.push_back(quizAnswer);
        for (const SavedWord &word : shuffled(pool)) {
            if (word.key == quizAnswer.key) continue;
            candidates.push_back(word);
            if (candidates.size() == 4) break;
        }
        candidates = shuffled(candidates);
        for (int i = 0; i < quizButtons.size(); ++i) {
            auto *button = quizButtons[i];
            if (i >= candidates.size()) { button->hide(); continue; }
            button->show(); button->setEnabled(true); button->setText(candidates[i].title); button->setProperty("wordKey", candidates[i].key);
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
        poolStatus->setText(QStringLiteral("%1 words ready · %2").arg(pool.size()).arg(randomPool->currentText()));
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
