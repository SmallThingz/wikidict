#include "MainWindow.hpp"

#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QPalette>
#include <QPushButton>
#include <QRandomGenerator>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QStackedWidget>
#include <QStatusBar>
#include <QStyle>
#include <QStyleHints>
#include <QSplitter>
#include <QTabWidget>
#include <QTextBrowser>
#include <QTextEdit>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>
#include <QWidget>
#include <algorithm>
namespace {
QString kindLabel(const QString &kind) {
    if (kind == QStringLiteral("language")) return QStringLiteral("Dictionary");
    QString label = kind;
    label.replace('_', ' ');
    if (!label.isEmpty()) label[0] = label[0].toUpper();
    return label;
}
}

MainWindow::MainWindow(const QString &root, const QString &initialWord)
    : api_(std::make_unique<DictApi>(root)) {
    setupUi();
    loadLanguages();
    applyTheme();
    selectDataset();
    if (!initialWord.isEmpty()) {
        search_->setText(initialWord);
        openWord(initialWord);
    } else {
        refreshSearch();
    }
}

void MainWindow::setupUi() {
    setWindowTitle(QStringLiteral("Dict"));
    resize(1180, 780);
    setMinimumSize(820, 560);

    auto *splitter = new QSplitter(this);
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

    kind_ = new QComboBox(sidebar);
    kind_->addItem(QStringLiteral("Dictionary"), QStringLiteral("language"));
    kind_->addItem(QStringLiteral("Thesaurus"), QStringLiteral("thesaurus"));
    kind_->addItem(QStringLiteral("Citations"), QStringLiteral("citations"));
    kind_->addItem(QStringLiteral("Reconstruction"), QStringLiteral("reconstruction"));
    kind_->addItem(QStringLiteral("Rhymes"), QStringLiteral("rhymes"));
    kind_->addItem(QStringLiteral("Sign gloss"), QStringLiteral("sign_gloss"));
    side->addWidget(kind_);

    language_ = new QComboBox(sidebar);
    language_->setEditable(false);
    side->addWidget(language_);

    search_ = new QLineEdit(sidebar);
    search_->setPlaceholderText(QStringLiteral("Find a word…"));
    search_->setClearButtonEnabled(true);
    side->addWidget(search_);

    results_ = new QListWidget(sidebar);
    results_->setUniformItemSizes(true);
    side->addWidget(results_, 1);
    auto *sideActions = new QHBoxLayout;
    auto *randomButton = new QPushButton(QStringLiteral("Random"), sidebar);
    auto *libraryButton = new QPushButton(QStringLiteral("Saved & Learn"), sidebar);
    sideActions->addWidget(randomButton);
    sideActions->addWidget(libraryButton);
    side->addLayout(sideActions);

    auto *content = new QWidget(splitter);
    auto *right = new QVBoxLayout(content);
    right->setContentsMargins(28, 20, 28, 24);
    right->setSpacing(10);

    auto *header = new QHBoxLayout;
    auto *heading = new QVBoxLayout;
    title_ = new QLabel(QStringLiteral("Find the word."), content);
    QFont titleFont = title_->font();
    titleFont.setPointSize(30);
    titleFont.setBold(true);
    title_->setFont(titleFont);
    title_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    meta_ = new QLabel(QStringLiteral("Local Wiktionary · native Qt"), content);
    heading->addWidget(title_);
    heading->addWidget(meta_);
    header->addLayout(heading, 1);
    bookmark_ = new QPushButton(QStringLiteral("☆ Bookmark"), content);
    bookmark_->setEnabled(false);
    header->addWidget(bookmark_);
    right->addLayout(header);
    entryTabs_ = new QTabWidget(content);
    reading_ = new QTextBrowser(entryTabs_);
    reading_->setOpenLinks(false);
    reading_->setOpenExternalLinks(false);
    reading_->setFrameShape(QFrame::NoFrame);
    json_ = new QTextEdit(entryTabs_);
    json_->setReadOnly(true);
    json_->setLineWrapMode(QTextEdit::NoWrap);
    entryTabs_->addTab(reading_, QStringLiteral("Reading"));
    entryTabs_->addTab(json_, QStringLiteral("JSON"));
    right->addWidget(entryTabs_, 1);

    splitter->addWidget(sidebar);
    splitter->addWidget(content);
    splitter->setStretchFactor(0, 0);
    splitter->setStretchFactor(1, 1);
    splitter->setSizes({280, 900});
    setCentralWidget(splitter);

    searchTimer_ = new QTimer(this);
    searchTimer_->setSingleShot(true);
    searchTimer_->setInterval(120);
    connect(search_, &QLineEdit::textChanged, this, [this] { searchTimer_->start(); });
    connect(searchTimer_, &QTimer::timeout, this, &MainWindow::refreshSearch);
    connect(search_, &QLineEdit::returnPressed, this, [this] {
        if (auto *item = results_->currentItem()) openWord(item->data(Qt::UserRole).toString());
        else if (!search_->text().isEmpty()) openWord(search_->text());
    });
    connect(results_, &QListWidget::itemActivated, this, [this](QListWidgetItem *item) {
        openWord(item->data(Qt::UserRole).toString());
    });
    connect(kind_, &QComboBox::currentIndexChanged, this, [this] { selectDataset(); });
    connect(language_, &QComboBox::currentIndexChanged, this, [this] { selectDataset(); });
    connect(randomButton, &QPushButton::clicked, this, &MainWindow::showRandomWord);
    connect(libraryButton, &QPushButton::clicked, this, &MainWindow::showLearningDialog);
    connect(bookmark_, &QPushButton::clicked, this, [this] {
        if (currentEntry_.isEmpty()) return;
        const bool saved = learning_.toggleBookmark(savedWord(currentEntry_));
        bookmark_->setText(saved ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
    });
    connect(reading_, &QTextBrowser::anchorClicked, this, [this](const QUrl &url) {
        if (url.scheme() == QStringLiteral("dict")) openWord(QUrl::fromPercentEncoding(url.path().toUtf8()));
        else if (url.scheme() == QStringLiteral("http") || url.scheme() == QStringLiteral("https")) QDesktopServices::openUrl(url);
    });
}
void MainWindow::loadLanguages() {
    try {
        const QJsonDocument document = QJsonDocument::fromJson(api_->languages());
        const QJsonArray languages = document.object().value(QStringLiteral("languages")).toArray();
        QSignalBlocker blocker(language_);
        language_->clear();
        for (const QJsonValue &value : languages) language_->addItem(value.toString());
        const int english = language_->findText(QStringLiteral("English"));
        if (english >= 0) language_->setCurrentIndex(english);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Languages"), error);
    }
}

void MainWindow::selectDataset() {
    if (!api_ || language_->count() == 0) return;
    const QString kind = kind_->currentData().toString();
    const QString language = language_->currentText();
    language_->setEnabled(kind == QStringLiteral("language"));
    try {
        api_->select(language, kind);
        currentEntry_ = {};
        bookmark_->setEnabled(false);
        refreshSearch();
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Open collection"), error);
    }
}
void MainWindow::refreshSearch() {
    if (!api_) return;
    try {
        const QJsonDocument document = QJsonDocument::fromJson(api_->search(search_->text(), 80));
        const QJsonArray matches = document.object().value(QStringLiteral("matches")).toArray();
        QSignalBlocker blocker(results_);
        results_->clear();
        for (const QJsonValue &value : matches) {
            const QString title = value.toObject().value(QStringLiteral("title")).toString();
            auto *item = new QListWidgetItem(title, results_);
            item->setData(Qt::UserRole, title);
        }
        if (results_->count() > 0) results_->setCurrentRow(0);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Search"), error);
    }
}

void MainWindow::openWord(const QString &word) {
    if (word.trimmed().isEmpty()) return;
    try {
        const QByteArray response = api_->lookup(word, false);
        const QJsonDocument document = QJsonDocument::fromJson(response);
        if (document.object().value(QStringLiteral("entries")).toArray().isEmpty()) {
            statusBar()->showMessage(QStringLiteral("No exact entry for “%1”.").arg(word), 4000);
            return;
        }
        search_->setText(word);
        renderResponse(response);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Open word"), error);
    }
}
void MainWindow::renderResponse(const QByteArray &bytes) {
    QJsonParseError parseError{};
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject())
        throw DictApiError("invalid JSON returned by dictionary core");
    const QJsonArray entries = document.object().value(QStringLiteral("entries")).toArray();
    if (entries.isEmpty() || !entries.first().isObject()) return;
    currentJson_ = document.toJson(QJsonDocument::Indented);
    currentEntry_ = entries.first().toObject();

    const QString title = currentEntry_.value(QStringLiteral("title")).toString();
    const QString language = currentEntry_.value(QStringLiteral("language")).toString();
    const QString kind = currentEntry_.value(QStringLiteral("kind")).toString();
    title_->setText(title);
    meta_->setText(QStringLiteral("%1 · %2 · native Qt").arg(language.isEmpty() ? kindLabel(kind) : language, kindLabel(kind)));
    reading_->setHtml(entryHtml(currentEntry_));
    json_->setPlainText(QString::fromUtf8(currentJson_));
    entryTabs_->setCurrentIndex(0);

    const SavedWord word = savedWord(currentEntry_);
    learning_.record(word);
    bookmark_->setEnabled(true);
    bookmark_->setText(learning_.isBookmarked(word.key) ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
}

void MainWindow::openSavedWord(const SavedWord &word) {
    const int kindIndex = kind_->findData(word.kind);
    if (kindIndex >= 0) kind_->setCurrentIndex(kindIndex);
    if (!word.language.isEmpty()) {
        const int langIndex = language_->findText(word.language);
        if (langIndex >= 0) language_->setCurrentIndex(langIndex);
    }
    openWord(word.title);
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
            const QUrl url(span.value(QStringLiteral("target")).toString());
            if (url.scheme() == QStringLiteral("http") || url.scheme() == QStringLiteral("https"))
                text = QStringLiteral("<a href='%1'>%2</a>").arg(url.toString(QUrl::FullyEncoded).toHtmlEscaped(), text);
        }
        if (span.value(QStringLiteral("code")).toBool()) text = QStringLiteral("<code>%1</code>").arg(text);
        if (span.value(QStringLiteral("bold")).toBool()) text = QStringLiteral("<b>%1</b>").arg(text);
        if (span.value(QStringLiteral("italic")).toBool()) text = QStringLiteral("<i>%1</i>").arg(text);
        if (span.value(QStringLiteral("underline")).toBool()) text = QStringLiteral("<u>%1</u>").arg(text);
        if (span.value(QStringLiteral("strike")).toBool()) text = QStringLiteral("<s>%1</s>").arg(text);
        if (span.value(QStringLiteral("superscript")).toBool()) text = QStringLiteral("<sup>%1</sup>").arg(text);
        if (span.value(QStringLiteral("subscript")).toBool()) text = QStringLiteral("<sub>%1</sub>").arg(text);
        out += text;
    }
    return out;
}
QString MainWindow::tableHtml(const QJsonObject &table) const {
    QString out = QStringLiteral("<table cellspacing='0' cellpadding='5' style='border-collapse:collapse;margin:8px 0'>");
    const QJsonArray caption = table.value(QStringLiteral("caption")).toArray();
    if (!caption.isEmpty()) out += QStringLiteral("<caption>%1</caption>").arg(spansHtml(caption));
    for (const QJsonValue &rowValue : table.value(QStringLiteral("rows")).toArray()) {
        out += QStringLiteral("<tr>");
        for (const QJsonValue &cellValue : rowValue.toObject().value(QStringLiteral("cells")).toArray()) {
            const QJsonObject cell = cellValue.toObject();
            const QString tag = cell.value(QStringLiteral("header")).toBool() ? QStringLiteral("th") : QStringLiteral("td");
            const int colspan = std::max(1, cell.value(QStringLiteral("colspan")).toInt(1));
            const int rowspan = std::max(1, cell.value(QStringLiteral("rowspan")).toInt(1));
            out += QStringLiteral("<%1 colspan='%2' rowspan='%3' style='border:1px solid #888'>%4</%1>")
                .arg(tag).arg(colspan).arg(rowspan).arg(spansHtml(cell.value(QStringLiteral("spans")).toArray()));
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
    if (table.isObject()) return tableHtml(table.toObject());
    const QString body = spansHtml(block.value(QStringLiteral("spans")).toArray());
    if (kind == QStringLiteral("preformatted")) return QStringLiteral("<pre>%1</pre>").arg(body);
    if (kind == QStringLiteral("definition")) {
        const QString number = block.value(QStringLiteral("number")).toString();
        return QStringLiteral("<p style='margin:7px 0'><b>%1</b> %2</p>").arg(number.isEmpty() ? QStringLiteral("•") : number.toHtmlEscaped(), body);
    }
    if (kind == QStringLiteral("example")) return QStringLiteral("<blockquote><i>Example:</i> %1</blockquote>").arg(body);
    if (kind == QStringLiteral("quotation")) return QStringLiteral("<blockquote>%1</blockquote>").arg(body);
    if (kind == QStringLiteral("term")) return QStringLiteral("<p><b>%1</b></p>").arg(body);
    if (kind == QStringLiteral("list_item")) return QStringLiteral("<p style='margin-left:18px'>• %1</p>").arg(body);
    if (kind == QStringLiteral("list_detail") || kind == QStringLiteral("indent"))
        return QStringLiteral("<p style='margin-left:30px;color:#666'>%1</p>").arg(body);
    if (kind == QStringLiteral("heading")) return QStringLiteral("<h3>%1</h3>").arg(body);
    return QStringLiteral("<p>%1</p>").arg(body);
}

QString MainWindow::entryHtml(const QJsonObject &entry) const {
    QString out = QStringLiteral(
        "<style>body{font-family:sans-serif;font-size:14px;line-height:1.55;}"
        "h2{margin-top:24px;border-bottom:1px solid #aaa;padding-bottom:5px;}"
        "a{color:#315efb;text-decoration:none;}blockquote{margin:8px 18px;color:#555;}"
        "code,pre{font-family:monospace;}table{font-size:13px;}</style>");
    for (const QJsonValue &sectionValue : entry.value(QStringLiteral("sections")).toArray()) {
        const QJsonObject section = sectionValue.toObject();
        const QString title = section.value(QStringLiteral("title")).toString();
        const int level = section.value(QStringLiteral("level")).toInt();
        if (level >= 3 || entry.value(QStringLiteral("kind")).toString() != QStringLiteral("language"))
            out += QStringLiteral("<h2>%1</h2>").arg(title.toHtmlEscaped());
        const QString deferred = section.value(QStringLiteral("deferred")).toString();
        if (!deferred.isEmpty()) {
            out += QStringLiteral("<p><i>%1 details are stored in a companion section.</i></p>").arg(deferred.toHtmlEscaped());
            continue;
        }
        for (const QJsonValue &block : section.value(QStringLiteral("blocks")).toArray()) out += blockHtml(block.toObject());
    }
    const QJsonArray references = entry.value(QStringLiteral("references")).toArray();
    if (!references.isEmpty()) {
        out += QStringLiteral("<h2>References</h2><ol>");
        for (const QJsonValue &reference : references) {
            const QJsonObject ref = reference.toObject();
            out += QStringLiteral("<li>%1</li>").arg(spansHtml(ref.value(QStringLiteral("spans")).toArray()));
        }
        out += QStringLiteral("</ol>");
    }
    return out;
}

QString MainWindow::clueFor(const QJsonObject &entry) const {
    auto textFor = [](const QJsonArray &spans) {
        QString text;
        for (const QJsonValue &value : spans) {
            const QJsonObject span = value.toObject();
            if (span.value(QStringLiteral("kind")).toString() == QStringLiteral("template")) throw DictApiError("compiled dictionary contains an uncompiled template span");
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
    word.key = word.kind + QChar('\n') + word.language + QChar('\n') + word.title;
    word.lastViewed = QDateTime::currentMSecsSinceEpoch();
    word.views = 1;
    return word;
}

QVector<SavedWord> MainWindow::learningPool() const {
    return learning_.pool();
}

void MainWindow::showRandomWord() {
    try {
        const QString source = learning_.settings().randomPool;
        if (source == QStringLiteral("all")) {
            const QByteArray response = api_->random();
            const QJsonDocument document = QJsonDocument::fromJson(response);
            const QJsonArray entries = document.object().value(QStringLiteral("entries")).toArray();
            if (!entries.isEmpty()) {
                search_->setText(entries.first().toObject().value(QStringLiteral("title")).toString());
                renderResponse(response);
            }
            return;
        }
        const QVector<SavedWord> words = source == QStringLiteral("bookmarks") ? learning_.bookmarks() : learning_.history();
        if (words.isEmpty()) { statusBar()->showMessage(QStringLiteral("No words in that random-word source yet."), 4000); return; }
        openSavedWord(words.at(QRandomGenerator::global()->bounded(words.size())));
    } catch (const std::exception &error) { reportError(QStringLiteral("Random word"), error); }
}
void MainWindow::showLearningDialog() {
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
                auto *item = new QListWidgetItem(QStringLiteral("%1\n%2").arg(word.title, word.clue), list);
                item->setData(Qt::UserRole, word.key);
            }
        }
        return list;
    };

    auto *historyPage = new QWidget(tabs);
    auto *historyLayout = new QVBoxLayout(historyPage);
    auto *historyList = makeWordList(learning_.history(), QStringLiteral("No history yet."));
    auto *clearHistory = new QPushButton(QStringLiteral("Clear history"), historyPage);
    historyLayout->addWidget(historyList, 1);
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
        learning_.clearHistory(); historyList->clear();
        auto *item = new QListWidgetItem(QStringLiteral("No history yet."), historyList); item->setFlags(Qt::NoItemFlags);
    });
    connect(removeBookmark, &QPushButton::clicked, &dialog, [&] {
        auto *item = bookmarkList->currentItem(); if (!item) return;
        learning_.removeBookmark(item->data(Qt::UserRole).toString()); delete item;
        if (currentEntry_.isEmpty()) return;
        bookmark_->setText(learning_.isBookmarked(savedWord(currentEntry_).key) ? QStringLiteral("★ Saved") : QStringLiteral("☆ Bookmark"));
    });
    const QVector<SavedWord> pool = learningPool();
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
    gamePicker->addItems({QStringLiteral("Definition quiz"), QStringLiteral("Flashcards"), QStringLiteral("Unscramble")});
    auto *games = new QStackedWidget(learnPage);
    learnLayout->addWidget(gamePicker);
    learnLayout->addWidget(games, 1);
    tabs->addTab(learnPage, QStringLiteral("Learn"));

    auto *quizPage = new QWidget(games);
    auto *quizLayout = new QVBoxLayout(quizPage);
    auto *quizScore = new QLabel(QStringLiteral("0 / 0"), quizPage);
    auto *quizClue = new QLabel(quizPage);
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
        for (auto *candidate : quizButtons) candidate->setEnabled(false);
        button->setText(correct ? button->text() + QStringLiteral(" ✓") : button->text() + QStringLiteral(" ✗"));
        quizNext->setText(quizTotal >= learning_.settings().quizLength ? QStringLiteral("New round") : QStringLiteral("Next"));
        quizNext->setEnabled(true);
    });
    connect(quizNext, &QPushButton::clicked, &dialog, populateQuiz);
    populateQuiz();
    auto *cardPage = new QWidget(games);
    auto *cardLayout = new QVBoxLayout(cardPage);
    auto *cardTitle = new QLabel(cardPage);
    QFont cardFont = cardTitle->font(); cardFont.setPointSize(26); cardFont.setBold(true); cardTitle->setFont(cardFont);
    auto *cardClue = new QLabel(QStringLiteral("Recall the definition, then reveal it."), cardPage);
    cardClue->setWordWrap(true);
    auto *revealCard = new QPushButton(QStringLiteral("Reveal"), cardPage);
    auto *cardGrades = new QWidget(cardPage);
    auto *gradeLayout = new QHBoxLayout(cardGrades); gradeLayout->setContentsMargins(0, 0, 0, 0);
    auto *again = new QPushButton(QStringLiteral("Again"), cardGrades);
    auto *gotIt = new QPushButton(QStringLiteral("Got it"), cardGrades);
    gradeLayout->addWidget(again); gradeLayout->addWidget(gotIt);
    cardLayout->addWidget(cardTitle);
    cardLayout->addWidget(cardClue, 1);
    cardLayout->addWidget(revealCard);
    cardLayout->addWidget(cardGrades);
    games->addWidget(cardPage);

    SavedWord card;
    auto nextCard = [&] {
        if (pool.isEmpty()) { cardTitle->setText(QStringLiteral("No words yet")); cardClue->setText(QStringLiteral("Open or bookmark words first.")); revealCard->setEnabled(false); cardGrades->hide(); return; }
        card = pool.at(QRandomGenerator::global()->bounded(pool.size()));
        cardTitle->setText(card.title);
        cardClue->setText(QStringLiteral("Recall the definition, then reveal it."));
        revealCard->setEnabled(true); revealCard->show(); cardGrades->hide();
    };
    connect(revealCard, &QPushButton::clicked, &dialog, [&] { cardClue->setText(card.clue); revealCard->hide(); cardGrades->show(); });
    connect(again, &QPushButton::clicked, &dialog, [&] { learning_.answer(card.key, false); nextCard(); });
    connect(gotIt, &QPushButton::clicked, &dialog, [&] { learning_.answer(card.key, true); nextCard(); });
    nextCard();
    auto *scramblePage = new QWidget(games);
    auto *scrambleLayout = new QVBoxLayout(scramblePage);
    auto *scrambled = new QLabel(scramblePage);
    QFont scrambleFont = scrambled->font(); scrambleFont.setPointSize(24); scrambleFont.setBold(true); scrambled->setFont(scrambleFont);
    auto *scrambleClue = new QLabel(scramblePage); scrambleClue->setWordWrap(true);
    auto *scrambleInput = new QLineEdit(scramblePage); scrambleInput->setPlaceholderText(QStringLiteral("Type the word"));
    auto *scrambleResult = new QLabel(scramblePage);
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
    auto nextScramble = [&] {
        QVector<SavedWord> words;
        for (const SavedWord &word : pool) if (word.title.size() > 2) words.push_back(word);
        if (words.isEmpty()) { scrambled->setText(QStringLiteral("No longer words yet")); scrambleCheck->setEnabled(false); return; }
        scrambleWord = words.at(QRandomGenerator::global()->bounded(words.size()));
        QVector<QChar> characters;
        characters.reserve(scrambleWord.title.size());
        for (QChar c : scrambleWord.title) characters.push_back(c);
        for (qsizetype i = characters.size() - 1; i > 0; --i) characters.swapItemsAt(i, QRandomGenerator::global()->bounded(static_cast<int>(i + 1)));
        QString letters(characters.constData(), characters.size());
        if (letters == scrambleWord.title && letters.size() > 1) letters = letters.mid(1) + letters.left(1);
        scrambled->setText(letters); scrambleClue->setText(scrambleWord.clue); scrambleInput->clear(); scrambleResult->clear();
        scrambleCheck->show(); scrambleCheck->setEnabled(true); scrambleNext->hide();
    };
    auto checkScramble = [&] {
        if (scrambleWord.key.isEmpty()) return;
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
    auto *resetStudy = new QPushButton(QStringLiteral("Reset learning scores"), settingsPage);
    form->addRow(QStringLiteral("Remember viewed words"), rememberHistory);
    form->addRow(QStringLiteral("History limit"), historyLimit);
    form->addRow(QStringLiteral("Quiz length"), quizLength);
    form->addRow(QStringLiteral("Random word source"), randomPool);
    form->addRow(QStringLiteral("Theme"), theme);
    form->addRow(resetStudy);
    tabs->addTab(settingsPage, QStringLiteral("Settings"));

    connect(rememberHistory, &QCheckBox::toggled, &dialog, [this](bool value) { learning_.setHistoryEnabled(value); });
    connect(historyLimit, &QSpinBox::valueChanged, &dialog, [this](int value) { learning_.setHistoryLimit(value); });
    connect(quizLength, &QSpinBox::valueChanged, &dialog, [this](int value) { learning_.setQuizLength(value); });
    connect(randomPool, &QComboBox::currentIndexChanged, &dialog, [&, randomPool](int) { learning_.setRandomPool(randomPool->currentData().toString()); });
    connect(theme, &QComboBox::currentIndexChanged, &dialog, [&, theme](int) { learning_.setTheme(theme->currentData().toString()); applyTheme(); });
    connect(resetStudy, &QPushButton::clicked, &dialog, [this] { learning_.clearStudy(); });

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, &dialog);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    layout->addWidget(buttons);
    dialog.exec();
}

void MainWindow::applyTheme() {
    const QString theme = learning_.settings().theme;
    bool dark = theme == QStringLiteral("dark");
    if (theme == QStringLiteral("system")) dark = qApp->styleHints()->colorScheme() == Qt::ColorScheme::Dark;
    if (!dark) { qApp->setPalette(qApp->style()->standardPalette()); return; }
    QPalette palette;
    palette.setColor(QPalette::Window, QColor(28, 29, 32));
    palette.setColor(QPalette::WindowText, QColor(238, 239, 242));
    palette.setColor(QPalette::Base, QColor(20, 21, 24));
    palette.setColor(QPalette::AlternateBase, QColor(36, 38, 42));
    palette.setColor(QPalette::Text, QColor(238, 239, 242));
    palette.setColor(QPalette::Button, QColor(38, 40, 44));
    palette.setColor(QPalette::ButtonText, QColor(238, 239, 242));
    palette.setColor(QPalette::Highlight, QColor(74, 112, 255));
    palette.setColor(QPalette::HighlightedText, Qt::white);
    palette.setColor(QPalette::ToolTipBase, QColor(38, 40, 44));
    palette.setColor(QPalette::ToolTipText, QColor(238, 239, 242));
    qApp->setPalette(palette);
}

void MainWindow::reportError(const QString &title, const std::exception &error) {
    QMessageBox::warning(this, title, QString::fromUtf8(error.what()));
}
