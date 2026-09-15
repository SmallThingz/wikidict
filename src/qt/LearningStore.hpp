#pragma once

#include <QHash>
#include <QSettings>
#include <QString>
#include <QVector>

struct SavedWord {
    QString key;
    QString title;
    QString language;
    QString kind;
    QString clue;
    qint64 savedAt = 0;
    qint64 lastViewed = 0;
    int views = 0;
};

struct StudyStat {
    int right = 0;
    int wrong = 0;
    qint64 last = 0;
};

struct LearningSettings {
    bool historyEnabled = true;
    int historyLimit = 100;
    int quizLength = 10;
    QString randomPool = QStringLiteral("all");
    QString theme = QStringLiteral("system");
};
class LearningStore final {
public:
    LearningStore();

    const QVector<SavedWord> &history() const { return history_; }
    const QVector<SavedWord> &bookmarks() const { return bookmarks_; }
    const QHash<QString, StudyStat> &study() const { return study_; }
    const LearningSettings &settings() const { return settingsValue_; }

    void record(const SavedWord &word);
    bool toggleBookmark(const SavedWord &word);
    void removeHistory(const QString &key);
    void removeBookmark(const QString &key);
    void clearHistory();
    void clearStudy();
    void answer(const QString &key, bool right);

    void setHistoryEnabled(bool value);
    void setHistoryLimit(int value);
    void setQuizLength(int value);
    void setRandomPool(const QString &value);
    void setTheme(const QString &value);

    bool isBookmarked(const QString &key) const;
    QVector<SavedWord> pool(const QVector<SavedWord> &fallback = {}) const;
    int answerCount() const;

private:
    void load();
    void save();

    QSettings storage_;
    QVector<SavedWord> history_;
    QVector<SavedWord> bookmarks_;
    QHash<QString, StudyStat> study_;
    LearningSettings settingsValue_;
};
