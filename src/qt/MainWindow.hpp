#pragma once

#include <QJsonObject>
#include <QMainWindow>
#include <QVector>
#include <memory>

#include "DictApi.hpp"
#include "LearningStore.hpp"

class QComboBox;
class QLabel;
class QLineEdit;
class QListWidget;
class QPushButton;
class QTabWidget;
class QTextBrowser;
class QTextEdit;
class QTimer;
class QWidget;

class MainWindow final : public QMainWindow {
public:
    explicit MainWindow(const QString &root, const QString &initialWord = {});

private:
    void setupUi();
    void loadLanguages();
    void refreshSearch();
    void selectDataset();
    void openWord(const QString &word);
    void openSavedWord(const SavedWord &word);
    void showRandomWord();
    void showLearningDialog();
    void applyTheme();
    void renderResponse(const QByteArray &json);
    QString entryHtml(const QJsonObject &entry) const;
    QString blockHtml(const QJsonObject &block) const;
    QString spansHtml(const QJsonArray &spans) const;
    QString tableHtml(const QJsonObject &table) const;
    SavedWord savedWord(const QJsonObject &entry) const;
    QString clueFor(const QJsonObject &entry) const;
    QVector<SavedWord> learningPool() const;
    void reportError(const QString &title, const std::exception &error);

    std::unique_ptr<DictApi> api_;
    LearningStore learning_;
    QLineEdit *search_ = nullptr;
    QListWidget *results_ = nullptr;
    QComboBox *language_ = nullptr;
    QComboBox *kind_ = nullptr;
    QPushButton *bookmark_ = nullptr;
    QLabel *title_ = nullptr;
    QLabel *meta_ = nullptr;
    QTabWidget *entryTabs_ = nullptr;
    QTextBrowser *reading_ = nullptr;
    QTextEdit *json_ = nullptr;
    QTimer *searchTimer_ = nullptr;
    QJsonObject currentEntry_;
    QByteArray currentJson_;
};
