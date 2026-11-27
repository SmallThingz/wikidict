// Genuine cediglia entry cycle and disclosure format-continuity regressions.
// Links the product library and uses its existing MainWindowTest friend seam.
#include "MainWindow.hpp"
#include "DictApi.hpp"
#include "CompiledDisclosureHost.hpp"
#include "FlowConstruction.hpp"
#include "AudioPlaybackStartup.hpp"
#include <QAction>
#include <QApplication>
#include <QByteArray>
#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QFocusEvent>
#include <QGlyphRun>
#include <QJsonArray>
#include <QJsonDocument>
#include <QImage>
#include <QLabel>
#include <QPointer>
#include <QMessageBox>
#include <QTimer>
#include <QScrollBar>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextFrame>
#include <QTextTable>
#include <QUrl>
#include <QRawFont>
#include <QSettings>
#include <QSignalBlocker>
#include <QSet>
#include <QTextBrowser>
#include <QTextLayout>
#include <QThread>
#include <QTest>
#include <functional>
#include <cstdio>
#include <stdexcept>
#include <QTemporaryDir>
#include <QTextStream>

namespace {
QJsonArray checks;
void check(bool ok, const QString &name) {
    checks.append(QJsonObject{{"name", name}, {"pass", ok}});
    if (!ok) throw std::runtime_error(name.toStdString());
}
QByteArray bytes(const QString &path, qint64 cap) {
    QFile f(path); check(f.open(QIODevice::ReadOnly), "open " + path);
    check(f.size() >= 0 && f.size() <= cap, "bounded " + path);
    const auto value = f.read(cap + 1); check(f.atEnd() && value.size() <= cap, "complete " + path);
    return value;
}
QString sha(const QByteArray &value) {
    return QString::fromLatin1(QCryptographicHash::hash(value, QCryptographicHash::Sha256).toHex());
}
QByteArray pinned(const QJsonObject &ref, qint64 cap) {
    const auto value = bytes(ref.value("path").toString(), cap);
    check(sha(value) == ref.value("sha256").toString(), "pinned " + ref.value("path").toString());
    if (ref.contains("bytes")) check(value.size() == ref.value("bytes").toInteger(), "pinned size");
    return value;
}
QJsonObject fixtureReference(QJsonObject ref, const QString &directory) {
    const auto relative = ref.value("path").toString();
    check(!relative.isEmpty() && QDir::isRelativePath(relative) && QDir::cleanPath(relative) == relative
          && relative != QStringLiteral("..") && !relative.startsWith(QStringLiteral("../")),
          "fixture path relative to contract directory");
    const QFileInfo file(QDir(directory).filePath(relative));
    const auto absolute = file.absoluteFilePath();
    check(file.isFile() && !file.isSymLink() && file.canonicalFilePath() == absolute
          && absolute.startsWith(directory + '/'), "checked-in fixture file inside contract directory");
    ref.insert("path", absolute);
    return ref;
}
QJsonObject object(const QByteArray &value) {
    QJsonParseError e; const auto d = QJsonDocument::fromJson(value, &e);
    check(e.error == QJsonParseError::NoError && d.isObject(), "JSON object"); return d.object();
}
void waitFor(const std::function<bool()> &predicate, const QString &name) {
    QElapsedTimer t; t.start();
    while (!predicate() && t.elapsed() < 15000) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QThread::msleep(2);
    }
    check(predicate(), name);
}
QJsonArray rectangle(const QRectF &r) { return {r.x(), r.y(), r.width(), r.height()}; }
void checkFont(CompiledDisclosure::Button *button, const QJsonObject &tables) {
    QTextLayout layout(button->text(), button->font(), button);
    layout.beginLayout();
    auto line = layout.createLine();
    check(line.isValid(), "button label line");
    line.setLineWidth(QWIDGETSIZE_MAX);
    layout.endLayout();
    const auto runs = layout.glyphRuns();
    check(!runs.isEmpty(), "label glyph runs");
    for (const auto &run : runs) {
        const auto font = run.rawFont();
        check(font.isValid() && font.familyName().compare("Arial", Qt::CaseInsensitive) == 0, "resolved Arial");
        for (auto glyph : run.glyphIndexes()) check(glyph != 0, "label glyph exists");
        for (auto it = tables.begin(); it != tables.end(); ++it) {
            const auto data = font.fontTable(it.key().toLatin1().constData());
            const auto pin = it.value().toObject();
            check(data.size() == pin.value("bytes").toInteger() && sha(data) == pin.value("sha256").toString(),
                  "Arial table " + it.key());
        }
    }
}
QJsonObject saveImage(const QImage &image, const QString &path) {
    check(!image.isNull() && image.save(path, "PNG"), "viewport PNG");
    return {{"path", path}, {"sha256", sha(bytes(path, 8 * 1024 * 1024))}, {"dpr", image.devicePixelRatio()}};
}
}

namespace {
const QString member = "languages/2cb4c2ac5779606a1fc2ff523ddacb4fd3a31294935a676b44c8e5a966586c5a.wikblb";

void writeNew(const QString &path, const QByteArray &data) {
    QFile output(path);
    check(output.open(QIODevice::WriteOnly | QIODevice::NewOnly), "fresh output " + path);
    check(output.write(data) == data.size() && output.flush(), "complete output " + path);
}
void writeAllerLibrary(const QString &library, const QString &fixture) {
    const auto payload = bytes(fixture, 38814);
    check(payload.size() == 38814 && sha(payload) == "5a9c68c51bf556afa18a69e677a0def0c2875d70eae0ebbfa780e9b464b820b0",
          "exact native Writer aller payload");
    const auto heading = QStringLiteral("Француски").toUtf8();
    check(QDir().mkpath(library + "/languages"), "private aller library");
    writeNew(library + "/languages.tsv", QByteArrayLiteral("heading\n") + heading + '\n');
    QByteArray blob = QByteArrayLiteral("WIKBLB08") + char(1) + QByteArrayLiteral("fr\0")
        + heading + '\0' + QByteArrayLiteral("aller\0");
    auto length = quint64(payload.size());
    while (length >= 128) {
        blob.append(char((length & 127) | 128));
        length >>= 7;
    }
    blob.append(char(length));
    blob.append(payload);
    writeNew(library + "/languages/" + sha(heading) + ".wikblb", blob);
}
QJsonArray storedTargets(const QJsonValue &value) {
    QJsonArray targets;
    if (value.isArray()) {
        for (const auto &child : value.toArray())
            for (const auto &target : storedTargets(child)) targets.append(target);
    } else if (value.isObject()) {
        const auto node = value.toObject();
        if (node.value("kind") == "link" && node.value("target").isString()) targets.append(node.value("target"));
        for (const auto &child : node)
            for (const auto &target : storedTargets(child)) targets.append(target);
    }
    return targets;
}
QJsonArray linkTargets(const QJsonArray &links) {
    QJsonArray result;
    for (const auto &value : links) {
        const QUrl url(value.toObject().value("href").toString());
        if (url.scheme() == "dict") result.append(url.path(QUrl::FullyDecoded));
    }
    return result;
}
struct DocumentState {
    QString raw, prefix, owner, suffix;
    QJsonArray inside, outside;
};
DocumentState documentState(QTextDocument *document, QTextFrame *owner) {
    DocumentState result;
    result.raw = document->toRawText();
    const int first = owner->firstPosition(), last = owner->lastPosition();
    check(first >= 0 && last > first && last <= result.raw.size(), "owner UTF-16 range");
    result.prefix = result.raw.left(first);
    result.owner = result.raw.mid(first, last - first);
    result.suffix = result.raw.mid(last);
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid()) continue;
            const auto format = fragment.charFormat();
            if (!format.isAnchor() || format.anchorHref().isEmpty()) continue;
            const int begin = fragment.position(), end = begin + fragment.length();
            const bool inside = begin >= first && end <= last;
            check(inside || end <= first || begin >= last, "link respects owner boundaries");
            auto &links = inside ? result.inside : result.outside;
            links.append(QJsonObject{{"href", format.anchorHref()}, {"text", fragment.text()}});
        }
    }
    return result;
}
QRectF borderInViewport(CompiledDisclosure::Button *button, QWidget *viewport) {
    return {QPointF(button->mapTo(viewport, QPoint())) + button->borderOrigin(), button->borderBoxSize()};
}
}

class MainWindowTest {
public:
#include "BewPisanyCaption01.inc"
    static void tableCaption(const QString &library, const QString &fixtureDirectory, QJsonObject &report) {
        QTimer modal;
        QObject::connect(&modal, &QTimer::timeout, [&] {
            auto *box = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!box) return;
            report.insert("product_refusal", box->text());
            box->reject();
        });
        modal.start(20);
        MainWindow window(library, "aller");
        window.resize(480, 700);
        window.show();
        window.activateWindow();
        waitFor([&] { return !window.loading_; }, "ordinary aller lookup settled");
        check(!report.contains("product_refusal") && !window.readingUncommitted_
              && window.currentEntry_.value("title") == "aller", "ordinary FFI lookup and Reading commit");
        const auto source = window.currentEntry_;
        {
            // Authenticate the compact fixture before inflating its exact Entry bytes.
            const QJsonObject compressedPin{
                {"path", "mk-aller-caption.expected.qz"},
                {"sha256", "1ff368babb026e0eac86a0cf6151e800f74fb0be18505ea3e7c841f3f508fd3f"},
                {"bytes", 10893}};
            const auto expected = qUncompress(pinned(fixtureReference(compressedPin, fixtureDirectory), 10893));
            const auto expectedSha = QStringLiteral("deac77542e07accf7f7fe600357348a054d013648b980996b60f9039e665079d");
            check(expected.size() == 426058 && sha(expected) == expectedSha, "exact decoded aller Entry fixture");
            check(source == object(expected), "complete ordinary aller Entry equals retained FFI result");
            report.insert("ordinary_entry_sha256", expectedSha);
            QTextStream(stdout) << "MK complete Entry equality: PASS\n";
        }
        const auto sections = source.value("sections").toArray();
        const auto blocks = sections.at(4).toObject().value("blocks").toArray();
        const auto table = blocks.at(32).toObject().value("table").toObject();
        const auto openLabel = QStringLiteral("прикажи");
        const auto closeLabel = QStringLiteral("собери");
        check(source.value("language_code") == "fr" && table.value("rows").toArray().size() == 27
              && table.value("caption_disclosure").toObject() == QJsonObject{
                  {"initially_collapsed", true}, {"expand_label", openLabel}, {"collapse_label", closeLabel}},
              "ordinary decoder retained exact caption policy and rows");

        auto *reader = window.reading_;
        const auto caption = QStringLiteral("Коњугација на глаголот aller");
        const auto finalPerson = [&] { return reader->document()->find(QStringLiteral("vont"), 0, QTextDocument::FindWholeWords); };
        const auto button = [&]() -> CompiledDisclosure::Button * {
            const auto *host = window.readingDisclosures_.data();
            if (!host || !host->current() || host->occurrences.size() != 1) return nullptr;
            const auto &row = host->occurrences.front();
            return row.block == table ? host->button(row.path, table) : nullptr;
        };
        const auto state = [&](bool expanded) {
            const auto label = expanded ? closeLabel : openLabel;
            auto *control = button();
            if (!control || !control->isEnabled() || control->isChecked() != expanded || control->text() != label
                || control->accessibleName() != label || window.currentEntry_ != source) return false;
            const auto &row = window.readingDisclosures_->occurrences.front();
            if (!row.caption.isValid() || !row.caption.text().contains(caption) || row.expanded != expanded) return false;
            const auto person = finalPerson();
            if (!expanded) return person.isNull();
            auto *grid = person.currentTable();
            return grid && grid->rows() == 27;
        };
        check(state(false), "caption and show button retained with no visible conjugation cells");
        const auto &row = window.readingDisclosures_->occurrences.front();
        reader->verticalScrollBar()->setValue(qRound(window.readingDisclosures_->rectangle(row).top()) - 40);
        const auto captionReachable = [&] {
            auto *control = button();
            return control && control->isVisible()
                && reader->viewport()->rect().contains(borderInViewport(control, reader->viewport()).center().toPoint());
        };
        waitFor(captionReachable,
                "collapsed caption toggle reachable by scrolling");

        {
            // Record only this direct focus request. The original wait and key actions remain the oracle.
            struct FocusWitness final : QObject {
                struct Transition {
                    const char *kind;
                    quintptr first;
                    quintptr second;
                    int reason;
                    bool duringRequest;
                };
                static QString token(quintptr identity) {
                    return identity ? QString::number(qulonglong(identity), 16) : QString{};
                }
                Transition transitions[12]{};
                int count = 0;
                bool truncated = false;
                bool duringRequest = false;

                void record(const char *kind, QObject *first, QObject *second, int reason) {
                    if (count == 12) {
                        truncated = true;
                        return;
                    }
                    transitions[count++] = {kind, reinterpret_cast<quintptr>(first),
                                            reinterpret_cast<quintptr>(second), reason, duringRequest};
                }

                bool eventFilter(QObject *target, QEvent *event) override {
                    if (event->type() == QEvent::FocusIn || event->type() == QEvent::FocusOut) {
                        record(event->type() == QEvent::FocusIn ? "target_focus_in" : "target_focus_out",
                               target, nullptr, int(static_cast<QFocusEvent *>(event)->reason()));
                    }
                    return false;
                }
            } focus;
            const QPointer<CompiledDisclosure::Button> requested(button());
            const auto identity = [](const void *object) {
                return FocusWitness::token(reinterpret_cast<quintptr>(object));
            };
            const auto snapshot = [&](QWidget *target) {
                auto *top = target ? target->window() : nullptr;
                return QJsonObject{
                    {"target", identity(target)},
                    {"visible", target ? QJsonValue(target->isVisible()) : QJsonValue(QJsonValue::Null)},
                    {"enabled", target ? QJsonValue(target->isEnabled()) : QJsonValue(QJsonValue::Null)},
                    {"has_focus", target ? QJsonValue(target->hasFocus()) : QJsonValue(QJsonValue::Null)},
                    {"policy", target ? QJsonValue(int(target->focusPolicy())) : QJsonValue(QJsonValue::Null)},
                    {"proxy", identity(target ? target->focusProxy() : nullptr)},
                    {"target_window", identity(top)},
                    {"target_window_handle", identity(top ? top->windowHandle() : nullptr)},
                    {"active_window", identity(QApplication::activeWindow())},
                    {"focus_window", identity(QGuiApplication::focusWindow())},
                    {"focus_widget", identity(QApplication::focusWidget())}};
            };
            requested->installEventFilter(&focus);
            QObject::connect(qApp, &QApplication::focusChanged, &focus,
                             [&](QWidget *from, QWidget *to) { focus.record("app_focus_changed", from, to, -1); });
            const auto before = snapshot(requested.data());
            focus.duringRequest = true;
            requested->setFocus(Qt::TabFocusReason);
            focus.duringRequest = false;
            const auto after = snapshot(requested.data());
            struct FocusPoll {
                quintptr firstLookup = 0;
                quintptr secondLookup = 0;
                int hasFocus = -1;
            } lastPoll;
            try {
                waitFor([&] {
                    auto *first = button();
                    lastPoll = {reinterpret_cast<quintptr>(first), 0, -1};
                    if (!first) return false;
                    auto *second = button();
                    lastPoll.secondLookup = reinterpret_cast<quintptr>(second);
                    const bool hasFocus = second->hasFocus();
                    lastPoll.hasFocus = hasFocus;
                    return hasFocus;
                }, "caption toggle takes keyboard focus");
            } catch (...) {
                try {
                    const auto *host = window.readingDisclosures_.data();
                    QJsonArray transitions;
                    for (int index = 0; index < focus.count; ++index) {
                        const auto &row = focus.transitions[index];
                        transitions.append(QJsonObject{
                            {"kind", QString::fromLatin1(row.kind)},
                            {"first", FocusWitness::token(row.first)}, {"second", FocusWitness::token(row.second)},
                            {"reason", row.reason < 0 ? QJsonValue(QJsonValue::Null) : QJsonValue(row.reason)},
                            {"during_request", row.duringRequest}});
                    }
                    const QJsonObject witness{
                        {"before", before}, {"after", after}, {"resolved_at_failure", snapshot(button())},
                        {"original_at_failure", identity(requested.data())},
                        {"last_wait_poll", QJsonObject{
                            {"first_lookup", FocusWitness::token(lastPoll.firstLookup)},
                            {"second_lookup", FocusWitness::token(lastPoll.secondLookup)},
                            {"has_focus", lastPoll.hasFocus < 0 ? QJsonValue(QJsonValue::Null)
                                                               : QJsonValue(bool(lastPoll.hasFocus))}}},
                        {"window", identity(&window)}, {"reader", identity(reader)},
                        {"host", identity(host)},
                        {"host_current", host ? QJsonValue(bool(host->current())) : QJsonValue(QJsonValue::Null)},
                        {"host_occurrences", host ? QJsonValue(int(host->occurrences.size())) : QJsonValue(QJsonValue::Null)},
                        {"transitions", transitions}, {"transitions_truncated", focus.truncated}};
                    if (QJsonDocument(witness).toJson(QJsonDocument::Indented).size() <= 5120)
                        report.insert("caption_focus_witness", witness);
                } catch (...) {
                    // Keep the original exception if the diagnostic cannot be serialized.
                }
                throw;
            }
        }
        QTest::keyClick(button(), Qt::Key_Return);
        waitFor([&] { return state(true) && button()->hasFocus(); }, "Enter reveals all rows and restores caption focus");

        auto *horizontal = reader->horizontalScrollBar();
        waitFor([&] { return horizontal->maximum() > horizontal->minimum(); }, "expanded grid retains horizontal scroll range");
        horizontal->setValue(horizontal->minimum());
        const int before = reader->cursorRect(finalPerson()).x();
        horizontal->setValue(horizontal->maximum());
        check(reader->cursorRect(finalPerson()).x() < before, "horizontal scrolling moves the final-person cell in the viewport");
        horizontal->setValue(horizontal->minimum());

        QTest::keyClick(button(), Qt::Key_Space);
        waitFor([&] { return state(false) && button()->hasFocus(); }, "Space hides rows and retains caption focus");
        waitFor(captionReachable, "collapsed caption toggle remains reachable after keyboard activation");
        auto *control = button();
        QTest::mouseClick(control, Qt::LeftButton, Qt::NoModifier,
                          borderInViewport(control, control).center().toPoint());
        waitFor([&] { return state(true); }, "mouse reopens the identical conjugation grid");
    }

static void formatContinuityChecks(MainWindow &window, QJsonObject entry, QJsonObject owner, QJsonObject &report) {
    using CompiledDisclosure::Host;
    using CompiledDisclosure::Button;
    const QPointer<MainWindow> live(&window);
    const auto response = QJsonDocument(QJsonObject{{"entries", QJsonArray{entry}}}).toJson();
    const char *const ids[] = {"FC02-owned-noop", "FC02-owned-reflow", "FC02-no-consume-during-hold",
        "FC02-cancel-new-ticket", "FC02-foreign-noop-rebind", "FC02-rejected-hold"};
    QJsonArray results;
    for (const auto id : ids) results.append(QJsonObject{{"id", QLatin1String(id)}, {"status", "UNRUN"}});
    report.insert("format_continuity_cases", results);
    report.insert("format_continuity_fixture_setup", "Before each case/variant, explicitly clear disclosureStates_ and render the identical captured entry; this is private fixture setup, not product reset behavior.");
    const auto liveHost = [&] {
        return live && live->readingDisclosures_ && live->readingDisclosures_->current()
            && live->readingDisclosures_->occurrences.size() == 1;
    };
    for (int caseIndex = 0; caseIndex != 6; ++caseIndex) {
        const QString id = QLatin1String(ids[caseIndex]);
        const auto verify = [&](bool ok, const char *message) { check(ok, id + ": " + QLatin1String(message)); };
        const auto record = [&](const char *status, const QString &error = QString()) {
            QJsonObject result{{"id", id}, {"status", QLatin1String(status)}};
            if (!error.isEmpty()) result.insert("error", error);
            results[caseIndex] = result; report.insert("format_continuity_cases", results);
        };
        record("RUNNING");
        try {
            // Both observed-signal and suppressed-signal foreign no-ops belong
            // to one named negative control; either failure marks it FAIL.
            for (int variant = 0; variant != (caseIndex == 4 ? 2 : 1); ++variant) {
                verify(live, "window alive before reset");
                live->disclosureStates_.clear(); // Deliberate private fixture reset; entry/source bytes stay identical.
                verify(live->renderResponse(response, false), "render exact retained entry");
                waitFor([&] {
                    return !live || (!live->readingFloatLayoutScheduled_ && !live->readingCompositionActive_ && liveHost());
                }, id + ": settled baseline");
                verify(liveHost(), "live owner after baseline wait");
                const auto row = live->readingDisclosures_->occurrences.front();
                const QPointer<Host> host(live->readingDisclosures_);
                const QPointer<Button> button(row.widget);
                const QPointer<QTextDocument> document(live->reading_->document());
                verify(host && button && document && button->isEnabled() && row.block == owner
                       && live->currentEntry_ == entry && live->disclosureSources_.value(row.path) == owner
                       && button->model().contentIndex == 1 && !row.expanded,
                       "exact owner/original content index/collapsed baseline");
                const auto composition = live->readingComposition_;
                button->click();
                verify(live && host && button && document, "activation retains observed objects");
                const auto ticket = host->pendingToggle(row.path, row.block, button, true);
                verify(ticket && host->toggleCurrent(ticket), "genuine pending activation");

                if (caseIndex < 2) {
                    const int revision = document->revision();
                    verify(live->editDocumentFormats(live->reading_, [&] {
                        verify(live && host && document, "objects alive during owned format edit");
                        if (caseIndex == 1) FlowConstruction::reflowContainers(document, qreal(live->contentsRect().width()));
                    }), "owned transaction accepted");
                    verify(live && host && document && document->revision() > revision && host->current()
                           && host->toggleCurrent(ticket) && live->readingComposition_ == composition
                           && host->button(row.path, row.block) == button,
                           "accepted revision continuity preserves exact occurrence");
                    waitFor([&] { return !live || live->readingComposition_ != composition; }, id + ": queued action commits");
                    verify(liveHost(), "live replacement after action wait");
                    verify(live->readingComposition_ == composition + 1 && live->currentEntry_ == entry, "exactly one composition");
                    const auto next = live->readingDisclosures_->occurrences.front();
                    verify(next.widget && next.widget != button && next.path == row.path && next.block == row.block
                           && next.expanded && !next.pendingToggle && next.widget->model().contentIndex == 1,
                           "original content expands once");
                    verify(!host || (!host->toggleCurrent(ticket) && !host->consumeToggle(ticket)), "consumed ticket cannot replay");
                    QCoreApplication::processEvents();
                    verify(live && live->readingComposition_ == composition + 1, "no duplicate queued action");
                } else if (caseIndex == 2) {
                    // No revision change: current() remains true, so this
                    // independently tests the formatting exclusion itself.
                    verify(host->holdFormats(), "valid owned hold");
                    verify(host->current() && !host->toggleCurrent(ticket) && !host->consumeToggle(ticket),
                           "current host still cannot consume during hold");
                    button->setChecked(false); // Disabled widgets still emit toggled from setChecked.
                    verify(host && button && button->isChecked()
                           && button->text() == button->model().collapseLabel
                           && button->accessibleName() == button->model().collapseLabel
                           && host->pendingToggle(row.path, row.block, button, true) == ticket,
                           "held pending activation restores ticket value rather than old row text");
                    host->releaseFormats(false);
                    QCoreApplication::processEvents();
                    verify(live && live->readingComposition_ == composition && live->disclosureStates_.isEmpty()
                           && (!host || !host->toggleCurrent(ticket)), "rejected cleanup leaves no action");

                    // Fresh idle fixture in this SAME case: no pending ticket and
                    // no revision change. Never treat this reset as product behavior.
                    verify(live, "window alive before idle-hold fixture reset");
                    live->disclosureStates_.clear();
                    verify(live->renderResponse(response, false), "reset exact entry for idle-hold activation");
                    waitFor([&] {
                        return !live || (!live->readingFloatLayoutScheduled_ && !live->readingCompositionActive_ && liveHost());
                    }, id + ": fresh idle fixture");
                    verify(liveHost(), "live idle owner after fixture wait");
                    const auto idleRow = live->readingDisclosures_->occurrences.front();
                    const QPointer<Host> idleHost(live->readingDisclosures_);
                    const QPointer<Button> idleButton(idleRow.widget);
                    const QPointer<QTextDocument> idleDocument(live->reading_->document());
                    verify(idleButton && idleButton->isEnabled() && !idleRow.pendingToggle
                           && !idleRow.expanded && idleRow.block == owner, "fresh enabled idle owner");
                    idleButton->setFocus(Qt::OtherFocusReason); // Visible keyboard focus without tab traversal.
                    waitFor([&] {
                        return !live || !idleHost || !idleButton || (idleButton->hasFocus()
                            && idleHost->current() && !live->readingFloatLayoutScheduled_);
                    }, id + ": idle keyboard focus");
                    verify(liveHost() && idleHost && idleButton && idleDocument && idleButton->hasFocus()
                           && idleButton->focusVisible(), "idle objects and visible focus survive wait");
                    const auto idleComposition = live->readingComposition_;
                    const int idleRevision = idleDocument->revision();
                    const bool idleEnabled = idleButton->isEnabled(), idleFocused = idleButton->hasFocus();
                    const bool idleVisibleFocus = idleButton->focusVisible(), idleChecked = idleButton->isChecked();
                    const QString idleText = idleButton->text(), idleAccessible = idleButton->accessibleName();
                    const auto idleUnchanged = [&] {
                        return live && idleHost && idleButton && idleDocument && idleHost->current()
                            && live->readingDisclosures_ == idleHost && live->reading_->document() == idleDocument
                            && idleHost->button(idleRow.path, idleRow.block) == idleButton
                            && idleHost->occurrences.size() == 1 && !idleHost->occurrences.front().pendingToggle
                            && idleHost->occurrences.front().expanded == idleRow.expanded
                            && idleButton->isEnabled() == idleEnabled && idleButton->hasFocus() == idleFocused
                            && idleButton->focusVisible() == idleVisibleFocus && idleButton->isChecked() == idleChecked
                            && idleButton->text() == idleText && idleButton->accessibleName() == idleAccessible
                            && !idleHost->pendingToggle(idleRow.path, idleRow.block, idleButton, !idleChecked)
                            && live->readingComposition_ == idleComposition && live->disclosureStates_.isEmpty()
                            && live->currentEntry_ == entry;
                    };
                    verify(idleHost->holdFormats() && idleUnchanged(), "idle hold preserves enabled/focus/state");
                    idleButton->click();
                    verify(idleUnchanged(), "idle click during hold restores checked/label/accessibility without action");
                    idleButton->setChecked(!idleChecked);
                    verify(idleUnchanged(), "programmatic held toggle also restores exact idle state");
                    idleHost->releaseFormats(true);
                    verify(idleUnchanged() && idleDocument->revision() == idleRevision,
                           "accepted idle hold preserves state without revision change");
                    QCoreApplication::processEvents();
                    verify(idleUnchanged(), "idle held attempts never produce delayed action or focus loss");
                } else if (caseIndex == 3) {
                    host->cancelToggle(row.path, button, ticket);
                    verify(host && button && button->isEnabled() && !button->isChecked() && !host->toggleCurrent(ticket),
                           "cancellation invalidates first token");
                    button->click();
                    verify(live && host && button, "successor activation retains objects");
                    const auto second = host->pendingToggle(row.path, row.block, button, true);
                    verify(second && second != ticket && host->toggleCurrent(second), "new activation has distinct token");
                    host->cancelToggle(row.path, button, ticket);
                    verify(host && !host->consumeToggle(ticket) && host->toggleCurrent(second), "old token cannot cancel or consume successor");
                    waitFor([&] { return !live || live->readingComposition_ != composition; }, id + ": successor commits");
                    verify(liveHost(), "live replacement after successor wait");
                    QCoreApplication::processEvents();
                    verify(liveHost(), "live replacement after callback drain");
                    verify(live->readingComposition_ == composition + 1 && live->currentEntry_ == entry
                           && live->readingDisclosures_->occurrences.front().expanded, "one successor commit only");
                } else if (caseIndex == 4) {
                    const int revision = document->revision(); const auto raw = document->toRawText();
                    const auto baseOffset = [&](int position) {
                        if (position == row.cursor.position()) return row.basePosition;
                        if (position == row.cursor.position() + 1) return row.basePosition + 1;
                        return -1;
                    };
                    if (variant == 0) {
                        QTextCursor foreign(document); foreign.beginEditBlock(); foreign.endEditBlock();
                    } else {
                        // Reproduce absence of contentsChanged retirement: the
                        // retained owner/source/atom are deliberately unchanged.
                        const QSignalBlocker silent(document);
                        QTextCursor foreign(document); foreign.beginEditBlock();
                        verify(host && document->revision() > revision && !host->current() && !host->empty(),
                               "foreign open block advances revision before retirement signal");
                        verify(!host->refreshRevision() && !host->seal(baseOffset) && !host->holdFormats(),
                               "foreign open block cannot reseal or acquire owned hold");
                        verify(!host->toggleCurrent(ticket) && !host->consumeToggle(ticket),
                               "foreign open block cannot authorize pending ticket");
                        foreign.endEditBlock();
                    }
                    verify(host && document && document->revision() > revision && document->toRawText() == raw
                           && !host->current() && !host->toggleCurrent(ticket), "foreign no-op invalidates revision authority");
                    if (variant == 0) verify(host->empty(), "observed foreign signal retires owner");
                    else {
                        verify(!host->empty(), "suppressed signal retains stale occurrence for direct guard check");
                        verify(!host->seal(baseOffset), "public seal cannot rescue closed foreign predecessor");
                    }
                    verify(!host->refreshRevision() && !host->holdFormats(), "unheld refresh and stale hold both refuse");
                    verify(live, "window alive before attempted owned rebind");
                    (void)live->editDocumentFormats(live->reading_, [] {});
                    verify(!host || (!host->refreshRevision() && !host->consumeToggle(ticket)), "later edit cannot rescue old ticket");
                    QCoreApplication::processEvents();
                    verify(live && live->readingComposition_ == composition && live->disclosureStates_.isEmpty()
                           && live->currentEntry_ == entry, "foreign edit never toggles");
                } else {
                    verify(host->holdFormats(), "valid hold before reseal");
                    QTextCursor mutation(document); mutation.beginEditBlock(); mutation.endEditBlock();
                    verify(host && host->refreshRevision() && host->current(), "reseal inside active predecessor hold");
                    verify(!host->toggleCurrent(ticket) && !host->consumeToggle(ticket), "reseal alone grants no action");
                    host->releaseFormats(false);
                    verify(!host || (host->empty() && !host->toggleCurrent(ticket)), "failed outer acceptance invalidates activation");
                    QCoreApplication::processEvents();
                    verify(live && live->readingComposition_ == composition && live->disclosureStates_.isEmpty(), "rejected transaction never toggles");
                }
            }
            record("PASS");
        } catch (const std::exception &error) {
            record("FAIL", QString::fromUtf8(error.what())); throw;
        } catch (...) {
            record("FAIL", "unknown exception"); throw;
        }
    }
}

    static void run(const QString &library, const QString &out, const QJsonObject &inputs,
                    const QJsonObject &expected, const QJsonObject &authored, const QJsonObject &source,
                    QJsonObject &report) {
        report.insert("native_entry_cycle", QJsonObject{{"status", "RUNNING"}});
        QTimer modal;
        QObject::connect(&modal, &QTimer::timeout, [&] {
            auto *box = qobject_cast<QMessageBox *>(QApplication::activeModalWidget());
            if (!box) return;
            report.insert("product_refusal", box->text());
            box->reject();
        });
        modal.start(20);
        MainWindow window(library, "cediglia");
        window.resize(480, 700);
        window.show();
        window.activateWindow();

            // Persist complete FFI JSON before comparing the entry.
        report.insert("stage", "product_lookup");
        QElapsedTimer elapsed;
        elapsed.start();
        while (window.loading_ && elapsed.elapsed() < 15000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
            QThread::msleep(2);
        }
        report.insert("product_status", window.resultStatus_->text());
        if (!window.currentResponse_.isNull())
            writeNew(out + "/ffi-response.json", window.currentResponse_.toJson());
        check(!report.contains("product_refusal"), "actual product refused ordinary lookup");
        check(window.api_ && window.api_->root() == library && window.api_->kind() == "language"
              && window.api_->language() == "italiano", "selected genuine library");
        check(window.currentResponse_.isObject(), "retained FFI response");
        const auto entries = window.currentResponse_.object().value("entries").toArray();
        check(entries.size() == 1 && entries.at(0).isObject(), "genuine lookup returned one complete object");
        const auto actual = entries.at(0).toObject();
        report.insert("stage", "writer_entry_equality");
        check(actual == expected, "exact FFI and Writer Entry equality");
        check(window.currentEntry_ == actual, "retained Entry");
        check(actual.value("title") == "cediglia" && actual.value("kind") == "language"
              && actual.value("language") == "italiano" && actual.value("language_code") == "it",
              "actual ordinary entry identity");
        const auto sections = actual.value("sections").toArray();
        check(sections.size() == 7, "complete seven-section entry");
        const auto blocks = sections.at(5).toObject().value("blocks").toArray();
        check(blocks.size() > 1, "translation owner path");
        const auto owner = blocks.at(1).toObject();
        const auto container = owner.value("container").toObject();
        const auto policy = container.value("disclosure").toObject();
        auto policyExpected = source;
        auto sourceButton = source.value("button").toObject();
        auto sourceSize = sourceButton.value("font_size").toObject();
        sourceSize.insert("value", double(float(sourceSize.value("value").toDouble())));
        sourceButton.insert("font_size", sourceSize);
        policyExpected.insert("button", sourceButton);
        check(policy == policyExpected && policy.value("placement") == "float_right"
              && policy.value("content_index") == 1 && policy.value("initially_collapsed") == true,
              "authored button policy with f32 size");
        const auto disclosure = authored.value("translation_disclosure").toObject();
        const QString caption = disclosure.value("retained_expanded_caption").toString();
        check(disclosure.value("initially_collapsed_in_source") == true && !caption.isEmpty()
              && policy.value("expand_label") == disclosure.value("open_label")
              && policy.value("collapse_label") == disclosure.value("close_label"), "authored disclosure text/state");
        QJsonArray expectedTargets;
        for (const auto &value : authored.value("translations").toArray()) {
            const auto item = value.toObject();
            expectedTargets.append(item.value("language_label"));
            expectedTargets.append(item.value("word_target"));
        }
        check(expectedTargets == QJsonArray{"esperanto", "cedilo", "inglese", "cedilla"},
              "authored translation targets");
        const auto children = container.value("blocks").toArray();
        check(children.size() > 1 && storedTargets(children.at(1)) == expectedTargets,
              "stored content child targets");

        report.insert("stage", "product_disclosure_composition");
        window.readingPaneAction_->trigger();
        auto *viewport = window.reading_->viewport();
        const auto hasLiveButton = [&] {
            const auto *host = window.readingDisclosures_.data();
            return host && host->current() && host->occurrences.size() == 1
                && host->occurrences.front().widget && host->occurrences.front().owner;
        };
        waitFor(hasLiveButton, "live disclosure; see product status and stderr");
        for (int attempt = 0; attempt < 8 && viewport->width() != 480; ++attempt) {
            window.resize(window.width() + 480 - viewport->width(), 700);
            QCoreApplication::processEvents();
        }
        waitFor([&] { return viewport->width() == 480 && hasLiveButton(); }, "exact 480px actual reading viewport");
        QJsonArray captures;
        DocumentState baseline;
        QString occurrencePath;
        const QStringList names{"collapsed-initial", "expanded", "collapsed-return"};
        for (int index = 0; index < names.size(); ++index) {
            const bool expanded = index == 1;
            report.insert("stage", names.at(index));
            check(hasLiveButton(), "live host");
            const auto row = window.readingDisclosures_->occurrences.front();
            const QPointer<CompiledDisclosure::Button> button = row.widget;
            if (index == 0) occurrencePath = row.path;
            check(!row.path.isEmpty() && row.path == occurrencePath && row.block == owner
                  && window.disclosureSources_.value(row.path) == owner
                  && window.readingDisclosures_->button(row.path, owner) == button.data(),
                  "live occurrence joins stored owner");
            const QString label = disclosure.value(expanded ? "close_label" : "open_label").toString();
            check(row.expanded == expanded && !row.pendingToggle && button->isEnabled()
                  && button->isChecked() == expanded && button->text() == label
                  && button->accessibleName() == label, "button state and accessible label");
            const auto state = documentState(window.reading_->document(), row.owner.data());
            check(state.owner.contains(caption), "authored caption in owner");
            check(linkTargets(state.inside) == (expanded ? expectedTargets : QJsonArray{}),
                  "owner links only when expanded");
            const QString outside = (state.prefix + state.suffix).simplified();
            const auto definition = authored.value("definition").toObject();
            const QStringList witnesses{definition.value("plain_text").toString(),
                authored.value("syllabification").toString(), authored.value("pronunciation_ipa").toString(),
                authored.value("etymology").toObject().value("plain_text").toString(), "Vocabolario Treccani"};
            for (const auto &witness : witnesses)
                check(!witness.isEmpty() && outside.contains(witness.simplified()), "actual outside text: " + witness);
            const auto outsideTargets = linkTargets(state.outside);
            for (const auto &target : definition.value("authored_link_targets").toArray())
                check(outsideTargets.contains(target), "outside definition link: " + target.toString());
            check(outsideTargets.contains(QJsonValue("cedilla")), "outside etymology cedilla");
            if (index == 0) baseline = state;
            else check(state.prefix == baseline.prefix && state.suffix == baseline.suffix
                       && state.outside == baseline.outside, "outside raw text and links stable");
            if (index == 2) check(state.raw == baseline.raw && state.inside == baseline.inside,
                                  "returned collapsed text and links");

            const auto bar = window.reading_->verticalScrollBar();
            const int scrollBefore = bar->value();
            const QRectF borderBefore = borderInViewport(button, viewport);
            if (!QRectF(viewport->rect()).contains(borderBefore)) {
                    bar->setValue(scrollBefore + qRound(borderBefore.center().y() - viewport->height() / 2.0));
            }
            waitFor([&] {
                return button && button->isVisible() && viewport->width() == 480
                    && QRectF(viewport->rect()).contains(borderInViewport(button, viewport));
            }, "native button in viewport");
            button->clearFocus();
            QEvent leave(QEvent::Leave);
            QApplication::sendEvent(button, &leave);
            QCoreApplication::processEvents();
            check(button && hasLiveButton(), "live widget after reveal");
            const auto border = borderInViewport(button, viewport);
            const QPoint hit = border.center().toPoint();
            check(!border.isEmpty() && QRectF(viewport->rect()).contains(border) && viewport->childAt(hit) == button.data(),
                  "native button under viewport hit");
            checkFont(button, inputs.value("font_tables").toObject());
            const auto image = saveImage(viewport->grab().toImage(), out + "/" + names.at(index) + ".png");
            captures.append(QJsonObject{{"state", names.at(index)}, {"label", label}, {"path", row.path},
                {"composition", qint64(window.readingComposition_)}, {"viewport_width", viewport->width()},
                {"scroll_before", scrollBefore}, {"scroll_after", bar->value()},
                {"border_before", rectangle(borderBefore)}, {"border_after", rectangle(border)},
                {"pointer_hit", QJsonArray{hit.x(), hit.y()}},
                {"owner_links", state.inside}, {"viewport_png", image}});
            report.insert("captures", captures);

            if (index == 2) break;
            const auto composition = window.readingComposition_;
            QTest::mouseClick(button.data(), Qt::LeftButton, Qt::NoModifier, button->mapFrom(viewport, hit));
            waitFor([&] {
                if (!hasLiveButton() || window.readingComposition_ == composition) return false;
                const auto &next = window.readingDisclosures_->occurrences.front();
                return next.path == occurrencePath && next.block == owner && next.widget != button
                    && next.expanded != expanded && !next.pendingToggle;
            }, "native click composed next state");
        }
        report.insert("native_entry_cycle", QJsonObject{{"status", "PASS"}, {"states", 3}});
        report.insert("stage", "six_format_continuity_controls");
        formatContinuityChecks(window, window.currentEntry_, owner, report);
    }
};

int main(int argc, char **argv) {
    const bool bewOnly = argc == 3 && QByteArray(argv[1]) == "--bew-pisany";
    const bool captionOnly = argc == 3 && QByteArray(argv[1]) == "--table-caption";
    const bool startupOnly = argc == 4 && QByteArray(argv[3]) == "--startup-only";
    if (argc != 3 && !startupOnly) return 64;
    const bool standaloneFixture = captionOnly || bewOnly;
    const QString fixture = QFileInfo(QString::fromLocal8Bit(argv[standaloneFixture ? 2 : 1])).canonicalFilePath();
    const QString policyPath = standaloneFixture ? QString() : QFileInfo(QString::fromLocal8Bit(argv[2])).canonicalFilePath();
    if (fixture.isEmpty() || (!standaloneFixture && policyPath.isEmpty()) || !QDir().mkpath(".tmp")) return 64;
    QTemporaryDir temporary(QDir::current().filePath(bewOnly ? ".tmp/bew-pisany-XXXXXX"
                                                              : ".tmp/disclosure-continuity-XXXXXX"));
    if (!temporary.isValid()) return 73;
    const QString out = temporary.path();
    QJsonObject report{{"stage", "fixture_setup"}, {"whole_grant", false},
        {"native_entry_cycle", QJsonObject{{"status", "UNRUN"}}}};
    report.insert("runtime_scope", bewOnly ? "BEW_PISANY_CAPTION_OPEN_TOGGLE_REOPEN" :
        captionOnly ? "ALLER_TABLE_CAPTION" :
        startupOnly ? "STARTUP_ONLY_NOT_CONTROLS" : "GENUINE_ENTRY_AND_SIX_CONTROLS");
    report.insert("portable_glue", QJsonObject{{"status", "RUNNING"}});
    QJsonArray caseResults;
    for (const auto id : {"FC02-owned-noop", "FC02-owned-reflow", "FC02-no-consume-during-hold",
                          "FC02-cancel-new-ticket", "FC02-foreign-noop-rebind", "FC02-rejected-hold"})
        caseResults.append(QJsonObject{{"id", QLatin1String(id)}, {"status", "UNRUN"}});
    report.insert("format_continuity_cases", caseResults);
    int result = 1;
    QJsonObject bewFixture;
    bool bewCopiesReady = false;
    const QString library = out + "/library";
    try {
        QJsonObject manifest, entry, authored, source;
        if (bewOnly) {
            report.insert("bew_pisany", QJsonObject{{"status", "RUNNING"}});
            const QJsonObject fixtureRef{{"path", fixture}, {"bytes", 1654},
                {"sha256", "b855c79a627148cf715686b057b3540c2996fbf118dcdc4adb835521fc2cd0de"}};
            bewFixture = object(pinned(fixtureRef, 16384));
            check(bewFixture.value("schema") == "wikidict.qt.bew-pisany-fixture.v1"
                  && bewFixture.value("selector") == "bew-pisany-caption-open-toggle-reopen",
                  "exact BEW fixture contract");
            const auto fixtureDirectory = QFileInfo(fixture).absolutePath();
            for (const auto *name : {"catalogue", "member", "reference_response"})
                bewFixture.insert(name, fixtureReference(bewFixture.value(name).toObject(), fixtureDirectory));
            check(QDir().mkpath(library + "/languages"), "fresh private BEW library");
            writeNew(library + "/languages.tsv", pinned(bewFixture.value("catalogue").toObject(), 4096));
            const auto relative = bewFixture.value("member_relative").toString();
            check(relative == "languages/8370565179f520e7911be82a20f5e9817c307a83d330332c53b040f077991f94.wikblb",
                  "exact BEW catalogue-selected member path");
            writeNew(library + '/' + relative, pinned(bewFixture.value("member").toObject(), 65536));
            bewCopiesReady = true;
        } else if (captionOnly) {
            writeAllerLibrary(library, fixture);
        } else {
            manifest = object(bytes(fixture + "/manifest.json", 16384));
            check(manifest.value("schema") == "wikidict.desktop.cediglia-disclosure-fixture.v1", "durable fixture schema");
            const auto readFixture = [&](const QString &name) {
                auto ref = manifest.value("files").toObject().value(name).toObject();
                check(ref.contains("bytes") && ref.contains("sha256"), "fixture pin " + name);
                ref.insert("path", fixture + '/' + name);
                return pinned(ref, 1024 * 1024);
            };
            entry = object(readFixture("entry.json"));
            authored = object(readFixture("authored.json"));
            auto policyRef = manifest.value("source_policy").toObject(); policyRef.insert("path", policyPath);
            source = object(pinned(policyRef, 16384));
            check(manifest.value("font_tables").toObject().size() == 7, "retained Arial table pins");
            check(QDir().mkpath(library + "/languages"), "private copied library");
            for (const auto &name : {QString("languages.tsv"), member})
                writeNew(library + '/' + name, readFixture(name));
        }

        // Configure every settings path before QApplication or any product object.
        for (const auto &pair : {qMakePair("HOME", "home"), qMakePair("XDG_CONFIG_HOME", "config"),
                 qMakePair("XDG_CACHE_HOME", "cache"), qMakePair("XDG_DATA_HOME", "data"),
                 qMakePair("XDG_CONFIG_DIRS", "system-config"), qMakePair("XDG_DATA_DIRS", "system-data"),
                 qMakePair("XDG_STATE_HOME", "state"), qMakePair("XDG_RUNTIME_DIR", "runtime"),
                 qMakePair("TMPDIR", "tmp")}) {
            const QString path = out + '/' + pair.second;
            check(QDir().mkpath(path), "isolated profile directory");
            check(QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner), "private profile permissions");
            check(qputenv(pair.first, path.toUtf8()), "isolated profile variable");
        }
        QSettings::setDefaultFormat(QSettings::IniFormat);
        for (auto format : {QSettings::IniFormat, QSettings::NativeFormat})
            for (auto scope : {QSettings::UserScope, QSettings::SystemScope}) {
                const QString path = out + QString("/settings/%1/%2").arg(int(format)).arg(int(scope));
                check(QDir().mkpath(path), "isolated settings directory");
                QSettings::setPath(format, scope, path);
            }
        QCoreApplication::setOrganizationName("SmallThingz");
        QCoreApplication::setApplicationName("Dict");
        const auto checkSettings = [&] {
            const auto inside = [&](const QSettings &settings) {
                check(QDir::cleanPath(QFileInfo(settings.fileName()).absoluteFilePath()).startsWith(out + '/'),
                      "settings stay in private profile");
            };
            inside(QSettings()); inside(QSettings("SmallThingz", "Dict"));
            for (auto format : {QSettings::IniFormat, QSettings::NativeFormat})
                for (auto scope : {QSettings::UserScope, QSettings::SystemScope})
                    inside(QSettings(format, scope, "SmallThingz", "Dict"));
        };
        checkSettings();
        check(qEnvironmentVariable("QT_QPA_PLATFORM") == "offscreen", "offscreen Qt test platform");
        WikiDict::configureAudioOnlyPlayback();
        QApplication app(argc, argv);
        checkSettings();
        QSettings().setValue("library/catalogSources", QStringList{});
        QSettings().setValue("reader/language", bewOnly ? QStringLiteral("Pol")
            : captionOnly ? QStringLiteral("Француски") : QStringLiteral("italiano"));
        report.insert("portable_glue", QJsonObject{{"status", "PASS"}});
        if (startupOnly) {
            // All portable setup ran; do not construct a Reader or replay controls.
            report.insert("stage", "STARTUP_ONLY_NOT_CONTROLS");
            result = 0;
        } else if (bewOnly) {
            MainWindowTest::bewPisany(library, out, bewFixture, report);
            result = 0;
        } else if (captionOnly) {
            report.insert("stage", "table_caption_activation");
            MainWindowTest::tableCaption(library, QFileInfo(fixture).absolutePath(), report);
            result = 0;
        } else {
            MainWindowTest::run(library, out, manifest, entry, authored, source, report);
            const auto continuity = report.value("format_continuity_cases").toArray();
            check(continuity.size() == 6, "six distinct continuity results");
            QSet<QString> caseIds;
            for (const auto &value : continuity) {
                const auto row = value.toObject(); const auto id = row.value("id").toString();
                check(!id.isEmpty() && !caseIds.contains(id) && row.value("status") == "PASS", "continuity result " + id);
                caseIds.insert(id);
            }
            report.insert("stage", "three_native_states_and_six_continuity_controls");
            result = 0;
        }
    } catch (const std::exception &error) {
        report.insert("error", QString::fromUtf8(error.what()));
        if (report.value("portable_glue").toObject().value("status") != "PASS")
            report.insert("portable_glue", QJsonObject{{"status", "FAIL"}});
        if (report.value("native_entry_cycle").toObject().value("status") == "RUNNING")
            report.insert("native_entry_cycle", QJsonObject{{"status", "FAIL"}, {"error", QString::fromUtf8(error.what())}});
    }
    if (bewOnly) {
        if (bewCopiesReady) {
            try {
                auto catalog = bewFixture.value("catalogue").toObject();
                auto memberRef = bewFixture.value("member").toObject();
                catalog.insert("path", library + "/languages.tsv");
                memberRef.insert("path", library + '/' + bewFixture.value("member_relative").toString());
                pinned(catalog, 4096);
                pinned(memberRef, 65536);
                report.insert("bew_private_fixture_post", "PASS");
            } catch (const std::exception &error) {
                report.insert("bew_private_fixture_post", "FAIL");
                report.insert("bew_private_fixture_error", QString::fromUtf8(error.what()));
                result = 1;
            }
        }
        if (result != 0) report.insert("bew_pisany", QJsonObject{{"status", "FAIL"}});
    }
    // Preserve setup/control evidence before any fallible report transport.
    temporary.setAutoRemove(false);
    const QString reportPath = out + "/result.json";
    report.insert("checks", checks); report.insert("exit", result);
    report.insert("primary_exit", result); report.insert("report_path", reportPath);
    QFile output(reportPath);
    const auto data = QJsonDocument(report).toJson();
    const auto transportFailure = [&](const char *operation) {
        const QString error = output.errorString();
        output.close();
        QTextStream(stderr) << "REPORT_TRANSPORT_FAILURE exit=74 primary_exit=" << result
                            << " operation=" << operation << " report_path=" << reportPath
                            << " error=" << error << "\nPrimary setup/control result:\n"
                            << QString::fromUtf8(data);
        return 74;
    };
    if (!output.open(QIODevice::WriteOnly | QIODevice::NewOnly)) return transportFailure("open");
    if (output.write(data) != data.size()) return transportFailure("write");
    if (!output.flush()) return transportFailure("flush");
    output.close();
    QTextStream(stderr) << (bewOnly ? "BEW Pisany caption: " :
                           captionOnly ? "Table caption activation: " :
                           startupOnly ? "STARTUP_ONLY_NOT_CONTROLS: " : "Disclosure continuity: ")
                        << (result == 0 ? "PASS" : "FAIL") << '\n';
    if (startupOnly) QTextStream(stdout) << QString::fromUtf8(data);
    if (bewOnly || captionOnly || startupOnly || result != 0) {
        QTextStream(stderr) << report.value("error").toString() << "\nDetails: " << reportPath << '\n';
    } else {
        // Only an ordinary successful run with a completely flushed report may clean up.
        temporary.setAutoRemove(true);
    }
    return result;
}
