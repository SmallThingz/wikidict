#pragma once

#include <QJsonObject>
#include <QMap>
#include <QJsonDocument>
#include <QColor>
#include <QMainWindow>
#include <QPointer>
#include <QSet>
#include <QVector>
#include <memory>
#include <functional>
#include <optional>
#include <atomic>

#include "DictApi.hpp"
#include "LearningStore.hpp"
#include "FlowConstruction.hpp"

class QAction;
class QToolBar;
class QSplitter;
class QComboBox;
class MediaPanel;
class InlineAudioControls;
namespace CompiledDisclosure { class Host; }
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
class QTextDocument;
class QPlainTextEdit;
class QTimer;
class QWidget;

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(const QString &root, const QString &initialWord = {});
    ~MainWindow() override;
    bool isLoading() const { return loading_; }

private:
    friend class MainWindowTest;
    void bindInlineImages();
    QPointer<InlineAudioControls> readingAudio_;
    QPointer<CompiledDisclosure::Host> readingDisclosures_;
    mutable QMap<QString, QJsonObject> disclosureSources_;
    QMap<QString, QJsonObject> disclosureStates_;
    QString pendingDisclosureFocusPath_;
    QJsonObject pendingDisclosureFocusSource_;
    bool pendingDisclosureFocusVisible_ = false;
    std::optional<int> pendingDisclosureScroll_;
    void queueDisclosureToggle(const QString &path, const QJsonObject &source, bool expanded);
    void restoreDisclosureFocus();
    mutable int nextAudioOccurrence_ = 0;
    int pendingAudioFocusOrdinal_ = -1;
    QJsonObject pendingAudioFocusSource_;
    QString pendingAudioFocusPart_;
    QString referenceTarget_;
    void updateInlineImageNotice();
    bool clearReadingProjection();
    bool editDocumentFormats(QTextBrowser *browser, const std::function<void()> &mutation);
    QPointer<QTextDocument> readingLogicalDocument_;
    QVariantList readingLogicalOwners_;
    int readingLogicalRevision_ = -1;
    bool readingUncommitted_ = false;
    quint64 inlineImageGeneration_ = 0;
    quint64 readingComposition_ = 0;
    bool readingCompositionActive_ = false;
    bool readingFloatLayoutScheduled_ = false;
    bool readingResponsiveLayoutActive_ = false;
    struct Visit {
        QString title;
        QString language;
        QString kind;
        int scroll = 0;
        QSet<int> collapsed;
        int cursorPosition = 0;
        int cursorAnchor = 0;
        bool readerFocused = false;
        int audioFocusOrdinal = -1;
        QJsonObject audioFocusSource;
        QString audioFocusPart;
        QString referenceTarget;
        QMap<QString, QJsonObject> disclosures;
        QString disclosureFocusPath;
        QJsonObject disclosureFocusSource;
        bool disclosureFocusVisible = false;
    };

    void setupUi();
    void updateReaderLayout();
    void updateCompactNavigation();
    void showCompactPane(bool search);
    void restoreCompactReadingScroll();
    void focusSearch(bool selectAll = false);
    void resizeEvent(QResizeEvent *event) override;
    void openRoot(const QString &root, const QString &word = {});
    void loadDataset(const QString &root, const QString &language, const QString &kind, bool resetVisits, const QString &word = {}, int restoreVisit = -1, const QString &expectedRoot = {}, const QString &expectedEdition = {}, const std::optional<QString> &fragment = std::nullopt, bool requireExactWord = false, bool findExactOwner = false);
    void setLoading(bool loading);
    void chooseRoot();
    void refreshSearch();
    void loadMoreResults();
    void submitSearch();
    void activateUserWord(const QString &word, bool skipCurrent = false);
    bool eventFilter(QObject *watched, QEvent *event) override;
    void selectDataset();
    bool openWord(const QString &word, const std::optional<QString> &fragment = std::nullopt, bool allowOwnerFallback = false);
    void openSavedWord(const SavedWord &word);
    void showRandomWord();
    void showLearningDialog(int tab = 0);
    void applyTheme();
    bool renderResponse(const QByteArray &json, bool addVisit = true, const std::optional<QString> &fragment = std::nullopt, bool deferCommit = false);
    bool renderDocument(const QJsonDocument &document, bool addVisit, const std::optional<QString> &fragment, bool deferCommit);
    void commitReadingEntry();
    bool refreshReading();
    void updateSectionFoldControl();
    void reflowFigures(bool resizeDocument = false);
    QVector<QPair<QString, QString>> readingExplanations() const;
    QVector<QPair<QString, QString>> readingAdvisories() const;
    void showReaderContextMenu(const QPoint &position);
    void showImageMapLinks(const QJsonObject &image);
    void showAbbreviations();
    bool resetFolding();
    bool jumpToFragment(const QString &fragment);
    bool jumpToSection(int section);
    void navigate(int direction);
    void saveVisit();
    bool restoreVisitReading(const Visit &visit);
    void updateNavigation();
    QString entryHtml(const QJsonObject &entry, bool bodyBoundary = false) const;
    QString blockHtml(const QJsonObject &block, const QString &cellBackground = {}, int tableDepth = 1, const QString &location = {}, const QString &inheritedAlignment = {}, FlowConstruction::RenderContext context = {}) const;
    QString blockContentsHtml(const QJsonObject &block, const QString &cellBackground, int tableDepth, const QString &location, const QString &alignment, const FlowConstruction::RenderContext &context, const QString *bodyOverride = nullptr) const;
    QString flowBlockHtml(const QJsonObject &block, const QString &cellBackground, int tableDepth, const QString &location, const FlowConstruction::RenderContext &context) const;
    QString spansHtml(const QJsonArray &spans, qreal leftMargin = 0, const QString &prefix = {}, const QString &cellBackground = {}, qreal contextPointSize = 0, const QColor &inheritedInk = {}, int sourceRun = -1, bool zeroFontContext = false, bool typedScopeOwnsIsolation = false, const QJsonObject &linkPaint = {}, bool computedCellTraits = false, const QJsonValue &contextFamily = {}, const QJsonArray &citationBacklinks = {}) const;
    QString tableHtml(const QJsonObject &table, int depth, int tableDepth = 1, const QString &inheritedBackground = {}, const QString &location = {}, const QString &inheritedAlignment = {}, const QString &listMarker = {}, FlowConstruction::RenderContext context = {}) const;
    SavedWord savedWord(const QJsonObject &entry) const;
    static QString clueFor(const QJsonObject &entry);
    static SavedWord savedWordForOrigin(const QJsonObject &entry, const QString &root, const QString &edition);
    QVector<SavedWord> learningPool() const;
    void reportError(const QString &title, const std::exception &error);

    std::unique_ptr<DictApi> api_;
    QString originRoot_;
    QString originEdition_;
    LearningStore learning_;
    QPointer<QWidget> learningFocusCue_;
    QLineEdit *search_ = nullptr;
    QListWidget *results_ = nullptr;
    QComboBox *language_ = nullptr;
    QComboBox *kind_ = nullptr;
    QPushButton *bookmark_ = nullptr;
    QPushButton *listen_ = nullptr;
    QPushButton *inlineImageNotice_ = nullptr;
    MediaPanel *media_ = nullptr;
    QPushButton *random_ = nullptr;
    QPushButton *back_ = nullptr;
    QPushButton *forward_ = nullptr;
    QPushButton *moreResults_ = nullptr;
    QPushButton *cancelOpening_ = nullptr;
    QProgressBar *openingProgress_ = nullptr;
    QLabel *resultStatus_ = nullptr;
    QComboBox *sections_ = nullptr;
    QPushButton *sectionFold_ = nullptr;
    QWidget *readerContent_ = nullptr;
    QWidget *readerHeading_ = nullptr;
    QGridLayout *navigationLayout_ = nullptr;
    QGridLayout *headerLayout_ = nullptr;
    QPushButton *smaller_ = nullptr;
    QPushButton *larger_ = nullptr;
    bool compactReader_ = false;
    bool compactHeader_ = false;
    QSplitter *readerSplit_ = nullptr;
    QWidget *searchPane_ = nullptr;
    QToolBar *compactToolbar_ = nullptr;
    QAction *searchPaneAction_ = nullptr;
    QAction *readingPaneAction_ = nullptr;
    QByteArray wideSplitterState_;
    int wideSidebarWidth_ = -1;
    bool compactNavigation_ = false;
    bool compactSearchPane_ = false;
    struct CompactReadingScroll {
        QPointer<QTextDocument> document;
        quint64 composition;
        int horizontal;
        int vertical;
    };
    std::optional<CompactReadingScroll> compactReadingScroll_;
    QTextBrowser *title_ = nullptr;
    QLabel *meta_ = nullptr;
    QTabWidget *entryTabs_ = nullptr;
    QTextBrowser *reading_ = nullptr;
    QPlainTextEdit *json_ = nullptr;
    QTimer *searchTimer_ = nullptr;
    QTimer *inlineImageNoticeTimer_ = nullptr;
    QJsonObject currentEntry_;
    QJsonDocument currentResponse_;
    QString resultsQuery_;
    QVector<QString> searchTitles_;
    QVector<SavedWord> sampleWords_;
    qsizetype searchFirst_ = 0;
    qsizetype searchLast_ = 0;
    QSet<int> collapsedSections_;
    QVector<Visit> visits_;
    int visitIndex_ = -1;
    int readingPointSize_ = 12;
    mutable quint32 nextLinkPaintOwner_ = 0;
    bool searchSelectionExplicit_ = false;
    bool moreAvailable_ = false;
    bool loading_ = false;
    unsigned loadSerial_ = 0;
    std::shared_ptr<std::atomic_bool> cancelLoad_;
    bool libraryDialogActive_ = false;
    std::function<void()> deferredDatasetPublication_;
};
