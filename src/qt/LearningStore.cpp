#include "LearningStore.hpp"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <algorithm>

namespace {
QJsonObject wordJson(const SavedWord &word) {
    return {
        {QStringLiteral("key"), word.key},
        {QStringLiteral("title"), word.title},
        {QStringLiteral("language"), word.language},
        {QStringLiteral("kind"), word.kind},
        {QStringLiteral("clue"), word.clue},
        {QStringLiteral("saved_at"), static_cast<double>(word.savedAt)},
        {QStringLiteral("last_viewed"), static_cast<double>(word.lastViewed)},
        {QStringLiteral("views"), word.views},
    };
}

SavedWord parseWord(const QJsonObject &object) {
    SavedWord word;
    word.key = object.value(QStringLiteral("key")).toString();
    word.title = object.value(QStringLiteral("title")).toString();
    word.language = object.value(QStringLiteral("language")).toString();
    word.kind = object.value(QStringLiteral("kind")).toString();
    word.clue = object.value(QStringLiteral("clue")).toString();
    word.savedAt = static_cast<qint64>(object.value(QStringLiteral("saved_at")).toDouble());
    word.lastViewed = static_cast<qint64>(object.value(QStringLiteral("last_viewed")).toDouble());
    word.views = object.value(QStringLiteral("views")).toInt();
    return word;
}

bool validWord(const SavedWord &word) {
    return !word.key.isEmpty() && !word.title.isEmpty() && !word.kind.isEmpty() && !word.clue.isEmpty();
}

QVector<SavedWord> parseWords(const QJsonValue &value, int cap) {
    QVector<SavedWord> out;
    if (!value.isArray()) return out;
    for (const QJsonValue &item : value.toArray()) {
        if (!item.isObject()) continue;
        SavedWord word = parseWord(item.toObject());
        if (validWord(word)) out.push_back(std::move(word));
        if (out.size() >= cap) break;
    }
    return out;
}
}

LearningStore::LearningStore()
    : storage_(QStringLiteral("SmallThingz"), QStringLiteral("Dict")) {
    load();
}
void LearningStore::load() {
    const QByteArray bytes = storage_.value(QStringLiteral("learning/state")).toByteArray();
    QJsonParseError error{};
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return;
    const QJsonObject root = document.object();
    const QJsonObject settings = root.value(QStringLiteral("settings")).toObject();
    settingsValue_.historyEnabled = settings.value(QStringLiteral("history_enabled")).toBool(true);
    settingsValue_.historyLimit = std::clamp(settings.value(QStringLiteral("history_limit")).toInt(100), 1, 500);
    settingsValue_.quizLength = std::clamp(settings.value(QStringLiteral("quiz_length")).toInt(10), 3, 50);
    settingsValue_.randomPool = settings.value(QStringLiteral("random_pool")).toString(QStringLiteral("all"));
    if (settingsValue_.randomPool != QStringLiteral("history") &&
        settingsValue_.randomPool != QStringLiteral("bookmarks")) settingsValue_.randomPool = QStringLiteral("all");
    settingsValue_.theme = settings.value(QStringLiteral("theme")).toString(QStringLiteral("system"));
    if (settingsValue_.theme != QStringLiteral("light") && settingsValue_.theme != QStringLiteral("dark"))
        settingsValue_.theme = QStringLiteral("system");
    history_ = parseWords(root.value(QStringLiteral("history")), settingsValue_.historyLimit);
    bookmarks_ = parseWords(root.value(QStringLiteral("bookmarks")), 1000);
    const QJsonObject study = root.value(QStringLiteral("study")).toObject();
    for (auto it = study.begin(); it != study.end(); ++it) {
        if (!it.value().isObject()) continue;
        const QJsonObject value = it.value().toObject();
        StudyStat stat;
        stat.right = std::max(0, value.value(QStringLiteral("right")).toInt());
        stat.wrong = std::max(0, value.value(QStringLiteral("wrong")).toInt());
        stat.last = static_cast<qint64>(value.value(QStringLiteral("last")).toDouble());
        study_.insert(it.key(), stat);
    }
}

void LearningStore::save() {
    QJsonArray history;
    for (const SavedWord &word : history_) history.append(wordJson(word));
    QJsonArray bookmarks;
    for (const SavedWord &word : bookmarks_) bookmarks.append(wordJson(word));
    QJsonObject study;
    for (auto it = study_.cbegin(); it != study_.cend(); ++it) {
        study.insert(it.key(), QJsonObject{
            {QStringLiteral("right"), it.value().right},
            {QStringLiteral("wrong"), it.value().wrong},
            {QStringLiteral("last"), static_cast<double>(it.value().last)},
        });
    }
    const QJsonObject settings{
        {QStringLiteral("history_enabled"), settingsValue_.historyEnabled},
        {QStringLiteral("history_limit"), settingsValue_.historyLimit},
        {QStringLiteral("quiz_length"), settingsValue_.quizLength},
        {QStringLiteral("random_pool"), settingsValue_.randomPool},
        {QStringLiteral("theme"), settingsValue_.theme},
    };
    const QJsonObject root{
        {QStringLiteral("history"), history},
        {QStringLiteral("bookmarks"), bookmarks},
        {QStringLiteral("study"), study},
        {QStringLiteral("settings"), settings},
    };
    storage_.setValue(QStringLiteral("learning/state"), QJsonDocument(root).toJson(QJsonDocument::Compact));
}

void LearningStore::record(const SavedWord &word) {
    if (!settingsValue_.historyEnabled || !validWord(word)) return;
    SavedWord next = word;
    next.lastViewed = QDateTime::currentMSecsSinceEpoch();
    auto it = std::find_if(history_.begin(), history_.end(), [&](const SavedWord &value) { return value.key == word.key; });
    if (it != history_.end()) {
        next.views = it->views + 1;
        history_.erase(it);
    } else next.views = std::max(1, next.views);
    history_.prepend(next);
    history_.resize(std::min(history_.size(), static_cast<qsizetype>(settingsValue_.historyLimit)));
    save();
}
bool LearningStore::toggleBookmark(const SavedWord &word) {
    auto it = std::find_if(bookmarks_.begin(), bookmarks_.end(), [&](const SavedWord &value) { return value.key == word.key; });
    if (it != bookmarks_.end()) {
        bookmarks_.erase(it);
        save();
        return false;
    }
    SavedWord next = word;
    next.savedAt = QDateTime::currentMSecsSinceEpoch();
    bookmarks_.prepend(next);
    if (bookmarks_.size() > 1000) bookmarks_.resize(1000);
    save();
    return true;
}

void LearningStore::removeHistory(const QString &key) {
    history_.erase(std::remove_if(history_.begin(), history_.end(), [&](const SavedWord &word) { return word.key == key; }), history_.end());
    save();
}

void LearningStore::removeBookmark(const QString &key) {
    bookmarks_.erase(std::remove_if(bookmarks_.begin(), bookmarks_.end(), [&](const SavedWord &word) { return word.key == key; }), bookmarks_.end());
    save();
}

void LearningStore::clearHistory() { history_.clear(); save(); }
void LearningStore::clearStudy() { study_.clear(); save(); }
void LearningStore::answer(const QString &key, bool right) {
    StudyStat &stat = study_[key];
    if (right) ++stat.right; else ++stat.wrong;
    stat.last = QDateTime::currentMSecsSinceEpoch();
    save();
}

void LearningStore::setHistoryEnabled(bool value) { settingsValue_.historyEnabled = value; save(); }
void LearningStore::setHistoryLimit(int value) {
    settingsValue_.historyLimit = std::clamp(value, 1, 500);
    if (history_.size() > settingsValue_.historyLimit) history_.resize(settingsValue_.historyLimit);
    save();
}
void LearningStore::setQuizLength(int value) { settingsValue_.quizLength = std::clamp(value, 3, 50); save(); }
void LearningStore::setRandomPool(const QString &value) {
    settingsValue_.randomPool = value == QStringLiteral("history") || value == QStringLiteral("bookmarks") ? value : QStringLiteral("all");
    save();
}
void LearningStore::setTheme(const QString &value) {
    settingsValue_.theme = value == QStringLiteral("light") || value == QStringLiteral("dark") ? value : QStringLiteral("system");
    save();
}

bool LearningStore::isBookmarked(const QString &key) const {
    return std::any_of(bookmarks_.cbegin(), bookmarks_.cend(), [&](const SavedWord &word) { return word.key == key; });
}
QVector<SavedWord> LearningStore::pool(const QVector<SavedWord> &fallback) const {
    if (settingsValue_.randomPool == QStringLiteral("history")) return history_;
    if (settingsValue_.randomPool == QStringLiteral("bookmarks")) return bookmarks_;
    QVector<SavedWord> result;
    QSet<QString> seen;
    auto append = [&](const QVector<SavedWord> &values) {
        for (const SavedWord &word : values) {
            if (seen.contains(word.key)) continue;
            seen.insert(word.key);
            result.push_back(word);
        }
    };
    append(bookmarks_);
    append(history_);
    append(fallback);
    return result;
}

int LearningStore::answerCount() const {
    int total = 0;
    for (const StudyStat &stat : study_) total += stat.right + stat.wrong;
    return total;
}
