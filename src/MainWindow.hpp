#pragma once

#include <QJsonObject>
#include <QMainWindow>
#include <QSet>
#include <QVector>
#include <memory>
#include <functional>
#include <optional>
#include <atomic>

#include "DictApi.hpp"
#include "LearningStore.hpp"

class QComboBox;
class MediaPanel;
class QEvent;
class QLabel;
class QLineEdit;
class QListWidget;
class QPushButton;
class QProgressBar;
class QGridLayout;
class QResizeEvent;
class QTabWidget;
class QTextBrowser;
class QTextEdit;
class QTimer;
class QWidget;

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(const QString &root, const QString &initialWord = {});
    ~MainWindow() override;
    bool isLoading() const { return loading_; }

private:
    friend class MainWindowTest;
    struct Visit {
        QString title;
        QString language;
        QString kind;
        int scroll = 0;
        QSet<int> collapsed;
        int cursorPosition = 0;
        int cursorAnchor = 0;
        bool readerFocused = false;
    };

    void setupUi();
    void updateReaderLayout();
    void openRoot(const QString &root, const QString &word = {});
    void loadDataset(const QString &root, const QString &language, const QString &kind, bool resetVisits, const QString &word = {}, int restoreVisit = -1, const QString &expectedRoot = {}, const QString &expectedEdition = {}, const std::optional<QString> &fragment = std::nullopt, bool requireExactWord = false);
    void setLoading(bool loading);
    void chooseRoot();
    void refreshSearch();
    void loadMoreResults();
    void submitSearch();
    bool eventFilter(QObject *watched, QEvent *event) override;
    void selectDataset();
    bool openWord(const QString &word, const std::optional<QString> &fragment = std::nullopt, bool allowUnclassifiedFallback = false);
    void openSavedWord(const SavedWord &word);
    void showRandomWord();
    void showLearningDialog(int tab = 0);
    void applyTheme();
    void renderResponse(const QByteArray &json, bool addVisit = true, const std::optional<QString> &fragment = std::nullopt);
    void refreshReading();
    QVector<QPair<QString, QString>> readingExplanations() const;
    void showReaderContextMenu(const QPoint &position);
    void showAbbreviations();
    void resetFolding();
    void jumpToFragment(const QString &fragment);
    void jumpToSection(int section);
    void navigate(int direction);
    void saveVisit();
    void restoreVisitReading(const Visit &visit);
    void updateNavigation();
    QString entryHtml(const QJsonObject &entry) const;
    QString blockHtml(const QJsonObject &block) const;
    QString spansHtml(const QJsonArray &spans, qreal leftMargin = 0, const QString &prefix = {}) const;
    QString tableHtml(const QJsonObject &table, int depth) const;
    SavedWord savedWord(const QJsonObject &entry) const;
    QString clueFor(const QJsonObject &entry) const;
    QVector<SavedWord> learningPool() const;
    void reportError(const QString &title, const std::exception &error);

    std::unique_ptr<DictApi> api_;
    QString originRoot_;
    QString originEdition_;
    LearningStore learning_;
    QLineEdit *search_ = nullptr;
    QListWidget *results_ = nullptr;
    QComboBox *language_ = nullptr;
    QComboBox *kind_ = nullptr;
    QPushButton *bookmark_ = nullptr;
    QPushButton *listen_ = nullptr;
    MediaPanel *media_ = nullptr;
    QPushButton *random_ = nullptr;
    QPushButton *back_ = nullptr;
    QPushButton *forward_ = nullptr;
    QPushButton *moreResults_ = nullptr;
    QPushButton *cancelOpening_ = nullptr;
    QProgressBar *openingProgress_ = nullptr;
    QLabel *resultStatus_ = nullptr;
    QComboBox *sections_ = nullptr;
    QWidget *readerContent_ = nullptr;
    QWidget *readerHeading_ = nullptr;
    QGridLayout *navigationLayout_ = nullptr;
    QGridLayout *headerLayout_ = nullptr;
    QPushButton *smaller_ = nullptr;
    QPushButton *larger_ = nullptr;
    bool compactReader_ = false;
    QTextBrowser *title_ = nullptr;
    QLabel *meta_ = nullptr;
    QTabWidget *entryTabs_ = nullptr;
    QTextBrowser *reading_ = nullptr;
    QTextEdit *json_ = nullptr;
    QTimer *searchTimer_ = nullptr;
    QJsonObject currentEntry_;
    QByteArray currentJson_;
    QString resultsQuery_;
    QVector<QString> searchTitles_;
    QVector<SavedWord> sampleWords_;
    qsizetype searchFirst_ = 0;
    qsizetype searchLast_ = 0;
    QSet<int> collapsedSections_;
    QVector<Visit> visits_;
    int visitIndex_ = -1;
    int readingPointSize_ = 12;
    bool searchSelectionExplicit_ = false;
    bool moreAvailable_ = false;
    bool loading_ = false;
    unsigned loadSerial_ = 0;
    std::shared_ptr<std::atomic_bool> cancelLoad_;
    bool libraryDialogActive_ = false;
    std::function<void()> deferredDatasetPublication_;
};
